import Foundation
import Darwin

@MainActor public final class WineProcessManager {
    public let logsURL: URL
    public private(set) var running: [RunningWineProcess] = []
    public private(set) var completed: [ProcessResult] = []
    public var onChange: (() -> Void)?
    public var onCompletion: ((ProcessResult) -> Void)?

    private static let stampFormatter = ISO8601DateFormatter()

    private enum CommandRole { case standard, stopRequest, stopConfirmation }

    private final class Entry {
        let process: Process
        let handle: FileHandle
        let record: RunningWineProcess
        let bottle: Bottle
        let bottleURL: URL
        let monitor: Bool
        let role: CommandRole
        var visible: Bool
        var timedOut = false
        var requestedStopSignals = Set<Int32>()
        var timeoutTask: Task<Void, Never>?
        var waiters: [CheckedContinuation<ProcessResult?, Never>] = []
        init(process: Process, handle: FileHandle, record: RunningWineProcess,
             bottle: Bottle, bottleURL: URL, monitor: Bool, visible: Bool, role: CommandRole) {
            self.process = process; self.handle = handle; self.record = record
            self.bottle = bottle; self.bottleURL = bottleURL
            self.monitor = monitor; self.visible = visible
            self.role = role
        }
        deinit {
            // A wait-only helper belongs to the frontend, unlike the Windows apps.
            // It has no session state to save and must not outlive its owner.
            if monitor && process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    private var entries: [UUID: Entry] = [:]
    private var stopping = Set<UUID>()
    private var refreshingStatuses = false
    private var statusWatchersShutdown = false

    public init(logsURL: URL) { self.logsURL = logsURL }

    public func isBottleRunning(_ id: UUID) -> Bool { running.contains { $0.bottleID == id } }

    /// Release frontend-owned wait helpers without stopping Windows apps or their Wine servers.
    /// This is synchronous so applicationWillTerminate can call it before the event loop exits.
    public func shutdownStatusWatchers() {
        statusWatchersShutdown = true
        discardStatusWatchers()
    }

    @discardableResult private func discardStatusWatchers(bottleID: UUID? = nil) -> [Entry] {
        let watchers = entries.values.filter { $0.monitor && (bottleID == nil || $0.bottle.id == bottleID) }
        for entry in watchers {
            entry.visible = false
            if entry.process.isRunning { kill(entry.process.processIdentifier, SIGKILL) }
        }
        publishRunning()
        return watchers
    }

    @discardableResult public func run(bottle: Bottle, bottleURL: URL, executableURL: URL, arguments: [String] = [],
                                      workingDirectory: URL? = nil, kind: String = "Application") throws -> RunningWineProcess {
        try PEExecutable.validate(url: executableURL)
        return try start(bottle: bottle, bottleURL: bottleURL, command: bottle.runtime.wineURL,
                         arguments: [executableURL.path] + arguments,
                         workingDirectory: workingDirectory ?? executableURL.deletingLastPathComponent(), kind: kind)
    }

    @discardableResult public func initialize(bottle: Bottle, bottleURL: URL) async throws -> ProcessResult {
        let result = try await runAndWait(bottle: bottle, bottleURL: bottleURL, command: bottle.runtime.wineBootURL,
                                         arguments: ["-u"], kind: "Initialize bottle", timeout: 150)
        try await applySettings(bottle: bottle, bottleURL: bottleURL)
        return result
    }

    @discardableResult public func applySettings(bottle: Bottle, bottleURL: URL) async throws -> ProcessResult {
        try await runAndWait(bottle: bottle, bottleURL: bottleURL, command: bottle.runtime.wineURL,
                             arguments: ["winecfg", "-v", bottle.settings.windowsVersion.rawValue],
                             kind: "Apply bottle settings", timeout: 45)
    }

    @discardableResult public func launchConfiguration(bottle: Bottle, bottleURL: URL) throws -> RunningWineProcess {
        try start(bottle: bottle, bottleURL: bottleURL, command: bottle.runtime.wineURL,
                  arguments: ["winecfg"], kind: "Wine configuration")
    }

    /// Stop only the Wine server selected by this explicit WINEPREFIX, then wait for it to exit.
    @discardableResult public func stopBottle(bottle: Bottle, bottleURL: URL) async throws -> ProcessResult {
        guard stopping.insert(bottle.id).inserted else {
            throw PortsideError.commandFailed("This bottle is already stopping. Wait for the current stop operation to finish.")
        }
        defer { stopping.remove(bottle.id) }
        // A launcher can be waiting on macOS permissions before it ever contacts
        // wineserver. End and reap those owned processes before confirming the server.
        try await stopTrackedLaunchers(bottleID: bottle.id)
        // Wine also returns 1 when no server owns this prefix. Confirm shutdown
        // separately rather than treating the request's exit code as the final state.
        try await runAndWait(bottle: bottle, bottleURL: bottleURL, command: bottle.runtime.wineServerURL,
                             arguments: ["-k"], kind: "Request bottle stop", timeout: 15,
                             role: .stopRequest, acceptedExitCodes: [0, 1])
        let result = try await runAndWait(bottle: bottle, bottleURL: bottleURL, command: bottle.runtime.wineServerURL,
                                         arguments: ["-w"], kind: "Stop bottle", timeout: 15, role: .stopConfirmation)
        let watchers = discardStatusWatchers(bottleID: bottle.id)
        await waitForTermination(watchers, seconds: 2)
        for entry in watchers where !entry.process.isRunning {
            finish(id: entry.record.id, process: entry.process)
        }
        return result
    }

    private func stopTrackedLaunchers(bottleID: UUID) async throws {
        let launchers = entries.values.filter { $0.bottle.id == bottleID && !$0.monitor && $0.role == .standard }
        for entry in launchers where entry.process.isRunning {
            // Keep intent on the entry: its termination callback may arrive after
            // Stop Bottle returns. Already exited processes retain their real failure.
            entry.requestedStopSignals.insert(SIGTERM)
            entry.process.terminate()
        }
        await waitForTermination(launchers, seconds: 1)
        for entry in launchers where entry.process.isRunning {
            entry.requestedStopSignals.insert(SIGKILL)
            kill(entry.process.processIdentifier, SIGKILL)
        }
        await waitForTermination(launchers, seconds: 2)
        guard launchers.allSatisfy({ !$0.process.isRunning }) else {
            throw PortsideError.commandFailed("Could not stop all launchers in this bottle. Its processes may still be running; inspect their logs and retry Stop Bottle before deleting it.")
        }
        // Consume any termination callback still queued on the main actor before
        // removing the stop guard or permitting bottle deletion.
        for entry in launchers { finish(id: entry.record.id, process: entry.process) }
    }

    private func waitForTermination(_ entries: [Entry], seconds: TimeInterval) async {
        let processes = entries.map(\.process)
        // A detached wait completes the safety operation even if its caller is cancelled,
        // while leaving the main actor free to process termination callbacks.
        await Task.detached { Self.pollForTermination(processes, seconds: seconds) }.value
    }

    private nonisolated static func pollForTermination(_ processes: [Process], seconds: TimeInterval) {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while processes.contains(where: \.isRunning) && clock.now < deadline { Thread.sleep(forTimeInterval: 0.02) }
    }

    /// Overlap probe waits without starting an unbounded number of commands at once.
    public func refreshBottleStatuses(_ bottles: [(bottle: Bottle, bottleURL: URL)]) async {
        guard !statusWatchersShutdown, !refreshingStatuses, !Task.isCancelled else { return }
        refreshingStatuses = true
        defer { refreshingStatuses = false }

        await withTaskGroup(of: Void.self) { group in
            var pending = bottles.makeIterator()
            for _ in 0..<4 {
                guard !Task.isCancelled, let next = pending.next() else { break }
                group.addTask { await self.refreshBottleStatus(bottle: next.bottle, bottleURL: next.bottleURL) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled else { group.cancelAll(); break }
                if let next = pending.next() {
                    group.addTask { await self.refreshBottleStatus(bottle: next.bottle, bottleURL: next.bottleURL) }
                }
            }
        }
    }

    /// wineserver -w does not create a Wine session. If still alive after a short probe, retain it as a watcher.
    public func refreshBottleStatus(bottle: Bottle, bottleURL: URL) async {
        guard !statusWatchersShutdown, !Task.isCancelled, !stopping.contains(bottle.id),
              !entries.values.contains(where: { $0.monitor && $0.bottle.id == bottle.id }),
              let record = try? start(bottle: bottle, bottleURL: bottleURL, command: bottle.runtime.wineServerURL,
                                      arguments: ["-w"], kind: "Windows session", monitor: true) else { return }
        do { try await Task.sleep(nanoseconds: 250_000_000) }
        catch {
            // Cancel only this wait command, never the bottle's Wine session.
            if let entry = entries[record.id], entry.process.isRunning { entry.process.terminate() }
            return
        }
        guard !statusWatchersShutdown, let entry = entries[record.id], entry.process.isRunning else { return }
        entry.visible = true
        publishRunning()
    }

    public func waitForExit(id: UUID) async -> ProcessResult? {
        if let result = completed.first(where: { $0.id == id }) { return result }
        guard let entry = entries[id] else { return nil }
        return await withCheckedContinuation { entry.waiters.append($0) }
    }

    @discardableResult
    private func runAndWait(bottle: Bottle, bottleURL: URL, command: URL, arguments: [String],
                            kind: String, timeout: TimeInterval, role: CommandRole = .standard,
                            acceptedExitCodes: Set<Int32> = [0]) async throws -> ProcessResult {
        let record = try start(bottle: bottle, bottleURL: bottleURL, command: command,
                               arguments: arguments, kind: kind, timeout: timeout, role: role)
        guard let result = await waitForExit(id: record.id) else {
            throw PortsideError.commandFailed("The process result was unavailable. Inspect \(record.logURL.path).")
        }
        guard !result.timedOut, !result.wasStopped, result.terminationSignal == nil,
              acceptedExitCodes.contains(result.exitCode) else {
            throw PortsideError.commandFailed("\(result.summary) Log: \(result.logURL.path)")
        }
        return result
    }

    private func start(bottle: Bottle, bottleURL: URL, command: URL, arguments: [String],
                       workingDirectory: URL? = nil, kind: String, timeout: TimeInterval? = nil,
                       monitor: Bool = false, role: CommandRole = .standard) throws -> RunningWineProcess {
        guard role != .standard || !stopping.contains(bottle.id) else {
            throw PortsideError.commandFailed("This bottle is stopping. Wait for Stop Bottle to finish before launching another app.")
        }
        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            throw PortsideError.invalidRuntime("The Wine command is missing or not executable: \(command.path). Select or reinstall the runtime in Runtime Setup.")
        }
        var isDirectory: ObjCBool = false
        if let workingDirectory {
            guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw PortsideError.invalidExecutable("Working directory is missing: \(workingDirectory.path)")
            }
        }
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        let id = UUID(), startedAt = Date()
        let stamp = Self.stampFormatter.string(from: startedAt).replacingOccurrences(of: ":", with: "-")
        let logURL = logsURL.appendingPathComponent("\(stamp)-\(id.uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PortsideError.commandFailed("Could not create process log at \(logURL.path). Check Application Support folder permissions.")
        }
        let handle = try FileHandle(forWritingTo: logURL)
        let runtime = bottle.runtime
        let environment = RuntimeManager.environment(runtime: runtime, bottleURL: bottleURL, settings: bottle.settings)
        // Record effective compatibility controls, never the entire inherited environment
        // (which can contain credentials). Missing listed controls were unset for the child.
        let diagnosticKeys: Set<String> = ["WINEPREFIX", "WINEARCH", "WINEDEBUG", "PATH", "LANG", "LC_ALL",
                                           "LC_CTYPE", "LC_MESSAGES", "LC_COLLATE", "LC_MONETARY", "LC_NUMERIC", "LC_TIME",
                                           "MVK_CONFIG_LOG_LEVEL", "MONO_ENV_OPTIONS", "MONO_PATH",
                                           "MONO_CFG_DIR", "DOTNET_ROOT", "COMPLUS_Version"]
        let diagnosticEnvironment = environment.filter { diagnosticKeys.contains($0.key) }
        let metadata: [String: Any] = ["kind": kind, "bottleID": bottle.id.uuidString, "bottle": bottle.name,
                                      "prefix": bottleURL.path, "runtime": runtime.version, "runtimeSource": runtime.source,
                                      "command": command.path, "arguments": arguments,
                                      "workingDirectory": workingDirectory?.path ?? bottleURL.path,
                                      "environment": diagnosticEnvironment,
                                      "bottleSettings": ["windowsVersion": bottle.settings.windowsVersion.rawValue,
                                                         "debugLogging": bottle.settings.debugLogging,
                                                         "locale": bottle.settings.locale?.rawValue ?? "system"]]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        handle.write(Data("Portside process started \(startedAt)\n".utf8)); handle.write(metadataData); handle.write(Data("\n--- Wine output ---\n".utf8))
        let process = Process()
        process.executableURL = command
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory ?? bottleURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle; process.standardError = handle
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async { self?.finish(id: id, process: process) }
        }
        do { try process.run() }
        catch {
            handle.write(Data("\nFailed to start: \(error.localizedDescription)\n".utf8)); try? handle.close()
            throw PortsideError.commandFailed("Could not start \(kind.lowercased()): \(error.localizedDescription). Check the runtime, Rosetta, and the log at \(logURL.path).")
        }
        let record = RunningWineProcess(id: id, bottleID: bottle.id, kind: kind, logURL: logURL,
                                        startedAt: startedAt, pid: process.processIdentifier, isSessionWatcher: monitor)
        // Silent session probes stay out of `running` until they prove a session is alive.
        let entry = Entry(process: process, handle: handle, record: record,
                          bottle: bottle, bottleURL: bottleURL, monitor: monitor, visible: !monitor, role: role)
        entries[id] = entry
        if let timeout {
            entry.timeoutTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) } catch { return }
                guard let self, let entry = self.entries[id], entry.process.isRunning else { return }
                entry.timedOut = true
                entry.handle.write(Data("\nPortside: command exceeded \(Int(timeout)) seconds; terminating launcher.\n".utf8))
                entry.process.terminate()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if entry.process.isRunning { kill(entry.process.processIdentifier, SIGKILL) }
            }
        }
        publishRunning()
        return record
    }

    private func finish(id: UUID, process: Process) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.timeoutTask?.cancel()
        let exitCode = process.terminationStatus
        let signal = process.terminationReason == .uncaughtSignal ? exitCode : nil
        let wasStopped = !entry.timedOut && signal.map(entry.requestedStopSignals.contains) == true
        let finishedAt = Date()
        let statusDescription = signal.map { "signal \($0)" } ?? "Wine exit code \(exitCode)"
        var summary: String
        if entry.role == .stopConfirmation {
            if entry.timedOut { summary = "Timed out confirming bottle shutdown. Processes may still be running. Inspect the log and check the selected Wine runtime before retrying Stop Bottle." }
            else if exitCode == 0 && signal == nil { summary = "Bottle is stopped." }
            else { summary = "Could not confirm bottle shutdown (\(statusDescription)). Inspect the log and check the selected Wine runtime before retrying Stop Bottle." }
        }
        else if entry.role == .stopRequest {
            if entry.timedOut { summary = "The Wine stop request timed out. Inspect the log and check the selected Wine runtime." }
            else if exitCode == 0 && signal == nil { summary = "Wine received the bottle stop request; shutdown must still be confirmed." }
            else if exitCode == 1 && signal == nil { summary = "Wine did not signal an active server; shutdown must still be confirmed." }
            else { summary = "Could not request bottle shutdown (\(statusDescription)). Inspect the log and check the selected Wine runtime." }
        }
        else if entry.timedOut { summary = "\(entry.record.kind) timed out. Stop this bottle, inspect its log, then retry." }
        else if wasStopped { summary = "\(entry.record.kind) stopped by request." }
        else if let signal { summary = "\(entry.record.kind) was terminated by signal \(signal). Open its log for details." }
        else if exitCode == 0 { summary = "\(entry.record.kind) exited successfully." }
        else { summary = "\(entry.record.kind) exited with code \(exitCode). An installer may continue in another Windows window after its launcher exits; check that window before retrying. Open its log for Wine errors and required Windows dependencies if installation has stopped." }
        let reason = signal == nil ? "exit" : "signal"
        entry.handle.write(Data("\n--- Portside: exit code \(exitCode), terminationReason=\(reason), stopRequested=\(!entry.requestedStopSignals.isEmpty), wasStopped=\(wasStopped), timedOut=\(entry.timedOut), ended \(finishedAt) ---\n".utf8))
        try? entry.handle.close()
        if entry.role == .standard, !entry.monitor, !entry.timedOut, !wasStopped, signal == nil, exitCode != 0,
           let diagnosis = WineFailureDiagnostics.monoCrashSummary(kind: entry.record.kind, exitCode: exitCode, logURL: entry.record.logURL) {
            summary = diagnosis
        }
        let result = ProcessResult(id: id, bottleID: entry.bottle.id, kind: entry.record.kind, logURL: entry.record.logURL,
                                   startedAt: entry.record.startedAt, finishedAt: finishedAt, exitCode: exitCode,
                                   timedOut: entry.timedOut, summary: summary, isSessionWatcher: entry.monitor,
                                   terminationSignal: signal, wasStopped: wasStopped)
        // A stop request is provisional; show the confirmed outcome instead.
        // Keep unexpected request failures and retained session watchers in the feed.
        let provisionalStopRequest = entry.role == .stopRequest && !entry.timedOut && signal == nil && [0, 1].contains(exitCode)
        if !provisionalStopRequest && (!entry.monitor || entry.visible) {
            completed.insert(result, at: 0)
            if completed.count > 100 { completed.removeLast(completed.count - 100) }
            onCompletion?(result)
        }
        entry.waiters.forEach { $0.resume(returning: result) }
        publishRunning()
        if !entry.monitor && !stopping.contains(entry.bottle.id) {
            let bottle = entry.bottle, bottleURL = entry.bottleURL
            Task { [weak self] in await self?.refreshBottleStatus(bottle: bottle, bottleURL: bottleURL) }
        }
    }

    /// Notifies observers only when the set of visible processes actually changed.
    private func publishRunning() {
        let next = entries.values.filter(\.visible).map(\.record).sorted { $0.startedAt < $1.startedAt }
        guard next.map(\.id) != running.map(\.id) else { return }
        running = next
        onChange?()
    }
}
