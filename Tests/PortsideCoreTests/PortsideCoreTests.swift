import XCTest
import Darwin
@testable import PortsideCore

final class PortsideCoreTests: XCTestCase {
    private func fakeRuntime(in directory: URL, wineBody: String = "printf '%s\\n' 'wine-11.0-test'\n",
                             serverBody: String = "exit 0\n") throws -> WineRuntime {
        let bin = directory.appendingPathComponent("Runtime with spaces/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in [("wine", wineBody), ("wineserver", serverBody), ("wineboot", "exit 0\n")] {
            let url = bin.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body).utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return WineRuntime(wineURL: bin.appendingPathComponent("wine"), version: "wine-test", source: "Unit-test fixture")
    }

    @MainActor func testCatalogPersistsRuntimeSettingsAndLaunchArguments() async throws {
        let root = try temporaryDirectory()
        let runtime = try fakeRuntime(in: root)
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        try store.setRuntime(runtime)
        let bottle = try store.createBottle(name: "Personal apps 日本語", runtime: runtime)
        try store.renameBottle(id: bottle.id, name: "Renamed bottle ✨")
        try store.updateSettings(bottleID: bottle.id, settings: BottleSettings(windowsVersion: .win11, debugLogging: true))
        try store.markBottleInitialized(id: bottle.id)
        let exe = try executable(in: root)
        let args = ["--open", "a path with spaces.txt", "中文", "$(this is literal)"]
        let app = try store.registerApp(name: "A desktop app", executableURL: exe, bottleID: bottle.id,
                                        workingDirectory: root, arguments: args)
        let reloaded = try LibraryStore(rootURL: store.rootURL)
        XCTAssertEqual(reloaded.state.runtime?.wineURL, runtime.wineURL)
        XCTAssertEqual(reloaded.state.runtime?.version, runtime.version)
        XCTAssertEqual(reloaded.state.runtime?.source, runtime.source)
        XCTAssertEqual(reloaded.state.runtime!.validatedAt.timeIntervalSince1970, runtime.validatedAt.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(reloaded.state.bottles[0].name, "Renamed bottle ✨")
        XCTAssertEqual(reloaded.state.bottles[0].settings, BottleSettings(windowsVersion: .win11, debugLogging: true))
        XCTAssertTrue(reloaded.state.bottles[0].initialized)
        XCTAssertEqual(reloaded.state.bottles[0].runtime.wineURL, runtime.wineURL)
        XCTAssertEqual(reloaded.state.bottles[0].runtime.version, runtime.version)
        XCTAssertEqual(reloaded.state.bottles[0].runtime.source, runtime.source)
        XCTAssertEqual(reloaded.state.apps[0], app)
        XCTAssertEqual(reloaded.state.apps[0].arguments, args)
        XCTAssertEqual(reloaded.state.apps[0].workingDirectory, root.path)
    }

    @MainActor func testDeletionOnlyRemovesSelectedManagedBottle() async throws {
        let root = try temporaryDirectory()
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let runtime = try fakeRuntime(in: root)
        let first = try store.createBottle(name: "Remove me", runtime: runtime)
        let second = try store.createBottle(name: "Keep me", runtime: runtime)
        let firstURL = try store.bottleURL(for: first), secondURL = try store.bottleURL(for: second)
        let sentinel = secondURL.appendingPathComponent("precious.txt")
        try Data("other bottle".utf8).write(to: sentinel)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let app = try store.registerApp(name: "Delete its entry", executableURL: executable(in: root), bottleID: first.id)
        try store.deleteBottle(id: first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "other bottle")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
        XCTAssertEqual(store.state.bottles.map(\.id), [second.id])
        XCTAssertFalse(store.state.apps.contains(where: { $0.id == app.id }))
    }

    @MainActor func testDeletionRejectsSymlinkMissingOwnershipAndPathEscape() async throws {
        let root = try temporaryDirectory()
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let runtime = try fakeRuntime(in: root)
        let bottle = try store.createBottle(name: "Protected", runtime: runtime)
        let bottleURL = try store.bottleURL(for: bottle)
        let outside = root.appendingPathComponent("Unrelated directory")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        var forged = bottle; forged.directoryName = "../../Unrelated directory"
        XCTAssertThrowsError(try store.bottleURL(for: forged))
        try FileManager.default.removeItem(at: bottleURL)
        try FileManager.default.createSymbolicLink(at: bottleURL, withDestinationURL: outside)
        XCTAssertThrowsError(try store.deleteBottle(id: bottle.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        try FileManager.default.removeItem(at: bottleURL)
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.deleteBottle(id: bottle.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bottleURL.path))
        XCTAssertEqual(store.state.bottles.count, 1)
    }

    @MainActor func testDeletionRestoresBottleWhenCatalogSaveFails() async throws {
        let root = try temporaryDirectory()
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Preserve on save failure", runtime: fakeRuntime(in: root))
        let directory = try store.bottleURL(for: bottle)
        let sentinel = directory.appendingPathComponent("precious.txt")
        try Data("must survive".utf8).write(to: sentinel)
        // A directory at the catalog filename makes the atomic write fail reliably,
        // including when tests run as a user who could otherwise bypass mode bits.
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.deleteBottle(id: bottle.id))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "must survive")
        XCTAssertEqual(store.state.bottles.map(\.id), [bottle.id])
        XCTAssertEqual(try store.bottleURL(for: bottle), directory)
        let remaining = try FileManager.default.contentsOfDirectory(at: store.bottlesURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(remaining.map(\.lastPathComponent), [bottle.directoryName])
    }

    func testPEValidationRejectsDamagedAndUnsupportedFiles() throws {
        let root = try temporaryDirectory()
        XCTAssertEqual(try PEExecutable.validate(url: executable(in: root)), .x64)
        XCTAssertEqual(try PEExecutable.validate(url: executable(in: root, name: "32.exe", machine: 0x14c)), .x86)
        XCTAssertThrowsError(try PEExecutable.validate(url: executable(in: root, name: "arm.exe", machine: 0xaa64)))
        let bad = root.appendingPathComponent("a text file.exe")
        try Data("this is not an executable".utf8).write(to: bad)
        XCTAssertThrowsError(try PEExecutable.validate(url: bad))
        XCTAssertThrowsError(try PEExecutable.validate(url: root.appendingPathComponent("missing.exe")))
    }

    func testRuntimeValidationReportsMissingAndReadsVersion() async throws {
        let root = try temporaryDirectory()
        do {
            _ = try await RuntimeManager.validate(wineURL: root.appendingPathComponent("missing wine"), source: "Missing fixture")
            XCTFail("A missing runtime must fail validation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Wine runtime unavailable")) }
        let runtime = try fakeRuntime(in: root)
        let validated = try await RuntimeManager.validate(wineURL: runtime.wineURL, source: "Official source recorded")
        XCTAssertEqual(validated.version, "wine-11.0-test")
        XCTAssertEqual(validated.source, "Official source recorded")
        XCTAssertNil(RuntimeManager.environment(runtime: runtime)["WINEPREFIX"])
        XCTAssertEqual(RuntimeManager.environment(runtime: runtime)["MVK_CONFIG_LOG_LEVEL"], "0")
    }

    @MainActor func testWineEnvironmentStripsHostBundleAndValidatesExplicitUIOverride() async throws {
        let root = try temporaryDirectory()
        let runtime = try fakeRuntime(in: root)
        let keys = ["CFProcessPath", "__CFBundleIdentifier", "PORTSIDE_WINE_UI_BUNDLE"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil { setenv(key, value, 1) }
                else { unsetenv(key) }
            }
        }
        setenv("CFProcessPath", "/Applications/Host.app/Contents/MacOS/Host", 1)
        setenv("__CFBundleIdentifier", "example.inherited.host", 1)
        unsetenv("PORTSIDE_WINE_UI_BUNDLE")
        let ordinary = RuntimeManager.environment(runtime: runtime)
        XCTAssertNil(ordinary["CFProcessPath"])
        XCTAssertNil(ordinary["__CFBundleIdentifier"])

        let bundle = root.appendingPathComponent("Wine Verification 空間.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/WineVerification")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        func writeInfo(executableName: String = "WineVerification", identifier: String = "example.portside.verification") throws {
            let info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": executableName]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plistURL)
        }
        try writeInfo()
        setenv("PORTSIDE_WINE_UI_BUNDLE", bundle.path, 1)
        let explicit = RuntimeManager.environment(runtime: runtime)
        XCTAssertEqual(explicit["CFProcessPath"], executable.path)
        XCTAssertEqual(explicit["__CFBundleIdentifier"], "example.portside.verification")
        XCTAssertNil(explicit["PORTSIDE_WINE_UI_BUNDLE"], "Harness configuration is consumed before spawning Wine")
        let link = executable.deletingLastPathComponent().appendingPathComponent("WineLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        try writeInfo(executableName: "WineLink")
        XCTAssertEqual(RuntimeManager.environment(runtime: runtime)["CFProcessPath"], link.path, "A bundle may link an existing Wine loader")
        let dangling = executable.deletingLastPathComponent().appendingPathComponent("DanglingLink")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("no-such-loader"))
        try writeInfo(executableName: "DanglingLink")
        XCTAssertNil(RuntimeManager.environment(runtime: runtime)["CFProcessPath"])
        try writeInfo()

        for invalid in ["relative.app", root.appendingPathComponent("Missing.app").path, root.path] {
            setenv("PORTSIDE_WINE_UI_BUNDLE", invalid, 1)
            let env = RuntimeManager.environment(runtime: runtime)
            XCTAssertNil(env["CFProcessPath"], invalid)
            XCTAssertNil(env["__CFBundleIdentifier"], invalid)
        }
        setenv("PORTSIDE_WINE_UI_BUNDLE", bundle.path, 1)
        for invalidExecutable in ["../Outside", "/usr/bin/true", ".", "MissingBinary"] {
            try writeInfo(executableName: invalidExecutable)
            XCTAssertNil(RuntimeManager.environment(runtime: runtime)["CFProcessPath"], invalidExecutable)
        }
        try writeInfo(identifier: " ")
        XCTAssertNil(RuntimeManager.environment(runtime: runtime)["CFProcessPath"])
        try writeInfo()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
        XCTAssertNil(RuntimeManager.environment(runtime: runtime)["CFProcessPath"], "Bundle binary must be executable")
    }

    @MainActor func testArgumentsRemainLiteralAndFailedLaunchHasUsefulLog() async throws {
        let root = try temporaryDirectory()
        let runtime = try fakeRuntime(in: root, wineBody: "printf 'ARG=%s\\n' \"$@\"\nprintf 'PREFIX=%s\\n' \"$WINEPREFIX\"\nexit 7\n")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support 日本語"))
        let bottle = try store.createBottle(name: "An isolated bottle", runtime: runtime)
        let bottleURL = try store.bottleURL(for: bottle)
        let exe = try executable(in: root)
        let sentinel = root.appendingPathComponent("shell expansion must never run")
        let args = ["two words", "$(touch '\(sentinel.path)')", "日本語", "quote\"literal"]
        let processes = WineProcessManager(logsURL: store.logsURL)
        let launched = try processes.run(bottle: bottle, bottleURL: bottleURL,
                                        executableURL: exe, arguments: args, workingDirectory: root)
        let result = await processes.waitForExit(id: launched.id)
        XCTAssertEqual(result?.exitCode, 7)
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertTrue(result?.summary.contains("exited with code 7") == true)
        let log = try String(contentsOf: launched.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("ARG=\(exe.path)\n"))
        for argument in args { XCTAssertTrue(log.contains("ARG=\(argument)\n")) }
        XCTAssertTrue(log.contains("PREFIX=\(bottleURL.path)\n"))
        XCTAssertTrue(log.contains("exit code 7"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        let cachedResult = await processes.waitForExit(id: launched.id)
        XCTAssertEqual(cachedResult?.id, result?.id)
        // Drain a possible silent wineserver probe before removing its log directory.
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    @MainActor func testStatusRefreshOverlapsWaitsAndBoundsConcurrentProbes() async throws {
        let root = try temporaryDirectory()
        let runtime = try fakeRuntime(in: root, serverBody: "exec /bin/sleep 30\n")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support 日本語"))
        let bottles = try (0..<20).map { index -> (bottle: Bottle, bottleURL: URL) in
            let bottle = try store.createBottle(name: "Status \(index)", runtime: runtime)
            return (bottle, try store.bottleURL(for: bottle))
        }
        let processes = WineProcessManager(logsURL: store.logsURL)
        defer { for process in processes.running { kill(process.pid, SIGTERM) } }
        var firstWaveCount: Int?
        processes.onChange = {
            if firstWaveCount == nil {
                firstWaveCount = try? FileManager.default.contentsOfDirectory(at: store.logsURL,
                                                                             includingPropertiesForKeys: nil).count
            }
        }

        let started = ContinuousClock.now
        // Repeated refresh requests must share the same concurrency limit.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { await processes.refreshBottleStatuses(bottles) } }
        }
        let elapsed = ContinuousClock.now - started
        print("20-bottle status refresh with fixture waiters: \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(3), "Sequential 250 ms probes would take at least five seconds")
        XCTAssertLessThanOrEqual(try XCTUnwrap(firstWaveCount), 4,
                                 "At most four probes may start before the first probe completes")
        XCTAssertEqual(processes.running.count, bottles.count)
        XCTAssertEqual(Set(processes.running.map(\.bottleID)), Set(bottles.map { $0.bottle.id }))

        await processes.refreshBottleStatuses(bottles)
        let logs = try FileManager.default.contentsOfDirectory(at: store.logsURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(logs.count, bottles.count, "Refreshing retained watchers must not spawn duplicates")

        let watchers = processes.running
        watchers.forEach { kill($0.pid, SIGTERM) }
        for watcher in watchers { _ = await processes.waitForExit(id: watcher.id) }
        XCTAssertTrue(processes.running.isEmpty)
    }

    @MainActor func testCancellingStatusRefreshCleansUpWaitersAndSkipsQueuedBottles() async throws {
        let root = try temporaryDirectory()
        let runtime = try fakeRuntime(in: root, serverBody: "exec /bin/sleep 1\n")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottles = try (0..<20).map { index -> (bottle: Bottle, bottleURL: URL) in
            let bottle = try store.createBottle(name: "Cancel status \(index)", runtime: runtime)
            return (bottle, try store.bottleURL(for: bottle))
        }
        let processes = WineProcessManager(logsURL: store.logsURL)
        let refresh = Task { await processes.refreshBottleStatuses(bottles) }
        var logs: [URL] = []
        for _ in 0..<100 {
            logs = try FileManager.default.contentsOfDirectory(at: store.logsURL, includingPropertiesForKeys: nil)
            if logs.count >= 4 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        refresh.cancel()
        await refresh.value
        XCTAssertEqual(logs.count, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: store.logsURL, includingPropertiesForKeys: nil).count, 4)
        XCTAssertTrue(processes.running.isEmpty, "Cancelled probes must not be promoted to running sessions")

        // Termination handlers must close the hidden waiters, allowing another refresh.
        for _ in 0..<100 {
            if try logs.allSatisfy({ try String(contentsOf: $0, encoding: .utf8).contains("--- Portside: exit code") }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for log in logs {
            XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("--- Portside: exit code"))
        }
        await processes.refreshBottleStatuses([bottles[0]])
        let watcher = try XCTUnwrap(processes.running.first)
        XCTAssertEqual(watcher.bottleID, bottles[0].bottle.id)
        kill(watcher.pid, SIGTERM)
        _ = await processes.waitForExit(id: watcher.id)
    }

    @MainActor func testStoppingAnIdleBottleIsRepeatableAndPreservesApplicationFailures() async throws {
        let root = try temporaryDirectory()
        let runtime = try fakeRuntime(in: root, wineBody: "exit 1\n", serverBody: """
        printf '%s\\n' "$1" >> "$WINEPREFIX/stop-commands.txt"
        case "$1" in
            -k) exit 1 ;;
            -w) exit 0 ;;
            *) exit 9 ;;
        esac
        """)
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support 日本語"))
        let bottle = try store.createBottle(name: "Already stopped", runtime: runtime)
        let other = try store.createBottle(name: "Do not touch", runtime: runtime)
        let bottleURL = try store.bottleURL(for: bottle)
        let otherURL = try store.bottleURL(for: other)
        let processes = WineProcessManager(logsURL: store.logsURL)
        var failures: [ProcessResult] = []
        processes.onCompletion = { if !$0.succeeded { failures.append($0) } }
        for _ in 0..<2 {
            let result = try await processes.stopBottle(bottle: bottle, bottleURL: bottleURL)
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(result.summary, "Bottle is stopped.")
        }
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(processes.completed.count, 2, "Only confirmed stop operations belong in activity history")
        XCTAssertTrue(processes.completed.allSatisfy(\.succeeded))
        XCTAssertFalse(processes.isBottleRunning(bottle.id))
        XCTAssertEqual(try String(contentsOf: bottleURL.appendingPathComponent("stop-commands.txt"), encoding: .utf8), "-k\n-w\n-k\n-w\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherURL.appendingPathComponent("stop-commands.txt").path))
        let logs = try FileManager.default.contentsOfDirectory(at: store.logsURL, includingPropertiesForKeys: nil)
        let rawLogs = try logs.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(rawLogs.filter { $0.contains("Request bottle stop") && $0.contains("exit code 1") }.count, 2)

        // Exit 1 is permitted only for the stop request, never for applications.
        let launched = try processes.run(bottle: bottle, bottleURL: bottleURL, executableURL: executable(in: root))
        let result = await processes.waitForExit(id: launched.id)
        XCTAssertEqual(result?.exitCode, 1)
        XCTAssertEqual(result?.succeeded, false)
        XCTAssertEqual(failures.count, 1)
        try await Task.sleep(nanoseconds: 350_000_000)
    }

    @MainActor func testStopDoesNotHideFailedShutdownConfirmation() async throws {
        let root = try temporaryDirectory()
        let runtime = try fakeRuntime(in: root, serverBody: """
        case "$1" in
            -k) exit 1 ;;
            -w) printf '%s\\n' 'Expected confirmation failure' >&2; exit 3 ;;
            *) exit 9 ;;
        esac
        """)
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Cannot confirm", runtime: runtime)
        let processes = WineProcessManager(logsURL: store.logsURL)
        do {
            _ = try await processes.stopBottle(bottle: bottle, bottleURL: store.bottleURL(for: bottle))
            XCTFail("A failed confirmation must not be treated as a successful stop")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not confirm bottle shutdown"))
            XCTAssertTrue(error.localizedDescription.contains("Log:"))
            XCTAssertFalse(error.localizedDescription.contains("Windows dependencies"))
        }
        XCTAssertEqual(processes.completed.count, 1)
        XCTAssertEqual(processes.completed.first?.exitCode, 3)
        XCTAssertEqual(processes.completed.first?.succeeded, false)
    }

    @MainActor func testStopRejectsUnexpectedRequestFailureWithoutWaiting() async throws {
        let root = try temporaryDirectory()
        let runtime = try fakeRuntime(in: root, serverBody: """
        if [ "$1" = '-k' ]; then exit 2; fi
        printf 'unexpected wait' > "$WINEPREFIX/unexpected-wait.txt"
        exit 0
        """)
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Request failure", runtime: runtime)
        let bottleURL = try store.bottleURL(for: bottle)
        let processes = WineProcessManager(logsURL: store.logsURL)
        do {
            _ = try await processes.stopBottle(bottle: bottle, bottleURL: bottleURL)
            XCTFail("Unexpected stop-request exit codes must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not request bottle shutdown"))
            XCTAssertTrue(error.localizedDescription.contains("Log:"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bottleURL.appendingPathComponent("unexpected-wait.txt").path))
        XCTAssertEqual(processes.completed.first?.exitCode, 2)
    }

    @MainActor func testStopDoesNotClaimSuccessWhenShutdownConfirmationTimesOut() async throws {
        let root = try temporaryDirectory()
        let runtime = try fakeRuntime(in: root, serverBody: """
        if [ "$1" = '-k' ]; then exit 1; fi
        exec /bin/sleep 30
        """)
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Shutdown hangs", runtime: runtime)
        let processes = WineProcessManager(logsURL: store.logsURL)
        do {
            _ = try await processes.stopBottle(bottle: bottle, bottleURL: store.bottleURL(for: bottle))
            XCTFail("A timed-out confirmation must not claim the bottle is stopped")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Timed out confirming bottle shutdown"))
            XCTAssertTrue(error.localizedDescription.contains("Log:"))
        }
        let result = try XCTUnwrap(processes.completed.first)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
    }
}
