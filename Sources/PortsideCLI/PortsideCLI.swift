import Foundation
import Darwin
import PortsideCore

/// A deliberately small companion for repeatable runtime and bottle diagnostics.
/// Every Wine operation uses the same implementation as the native application.
@main
struct PortsideCLI {
    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || ["help", "--help", "-h"].contains(arguments[0]) {
            print(usage)
            return
        }
        do {
            try await execute(arguments)
        } catch {
            try? emit(Failure(error: error.localizedDescription, command: arguments[0]), to: .standardError)
            exit(1)
        }
    }

    @MainActor private static func execute(_ arguments: [String]) async throws {
        let command = arguments[0]
        let values = Array(arguments.dropFirst())
        let root = ProcessInfo.processInfo.environment["PORTSIDE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let store = try LibraryStore(rootURL: root)
        let manager = WineProcessManager(logsURL: store.logsURL)
        defer { manager.shutdownStatusWatchers() }
        for warning in store.recoveryWarnings {
            try emit(["warning": warning], to: .standardError)
        }
        switch command {
        case "list":
            try requireCount(values, 0, command: command)
            try emit(Catalog(root: store.rootURL.path, state: store.state))

        case "runtime":
            guard values.count <= 1 else { throw UsageError("runtime accepts at most one Wine application, directory, or launcher path.") }
            let candidates: [URL]
            if let path = values.first {
                candidates = [fileURL(path)]
            } else {
                let saved = store.state.runtime.map { [$0.wineURL] } ?? []
                candidates = saved + RuntimeManager.discoverCandidates().filter { candidate in !saved.contains(candidate) }
            }
            guard !candidates.isEmpty else { throw PortsideError.invalidRuntime(RuntimeManager.fallbackSetupInstructions) }
            var failures = [String]()
            var runtime: WineRuntime?
            for candidate in candidates {
                do {
                    let source = values.isEmpty ? (store.state.runtime?.wineURL == candidate ? store.state.runtime!.source : "Detected local runtime") : "User-selected local runtime"
                    runtime = try await RuntimeManager.validate(wineURL: candidate, source: source)
                    break
                } catch { failures.append(error.localizedDescription) }
            }
            guard let runtime else { throw PortsideError.invalidRuntime(failures.joined(separator: "\n")) }
            try store.setRuntime(runtime)
            try emit(runtime)

        case "create":
            try requireCount(values, 1, command: command)
            let runtime = try await selectedRuntime(store)
            let bottle = try store.createBottle(name: values[0], runtime: runtime)
            try emit(BottleEvent(event: "initializing", bottle: bottle, path: try store.bottleURL(for: bottle).path))
            do {
                let result = try await manager.initialize(bottle: bottle, bottleURL: store.bottleURL(for: bottle))
                try store.markBottleInitialized(id: bottle.id)
                try emit(resultOutput(result))
                try emit(store.requireBottle(id: bottle.id))
            } catch {
                try? store.markBottleInitialized(id: bottle.id, error: error.localizedDescription)
                throw error
            }

        case "install":
            guard values.count >= 2 else { throw UsageError("install requires BOTTLE_UUID EXE [installer arguments…].") }
            let bottle = try findBottle(values[0], in: store)
            let process = try manager.run(bottle: bottle, bottleURL: store.bottleURL(for: bottle),
                                          executableURL: fileURL(values[1]), arguments: Array(values.dropFirst(2)),
                                          kind: "Installer")
            try await waitForProcess(process, manager: manager)

        case "register":
            guard values.count >= 3 else { throw UsageError("register requires BOTTLE_UUID NAME EXE [--working-directory DIR] [-- launch arguments…].") }
            let bottle = try findBottle(values[0], in: store)
            var launchArguments = Array(values.dropFirst(3))
            var workingDirectory: URL?
            if launchArguments.first == "--working-directory" {
                guard launchArguments.count >= 2 else { throw UsageError("--working-directory requires a directory path.") }
                workingDirectory = fileURL(launchArguments[1])
                launchArguments.removeFirst(2)
            }
            if launchArguments.first == "--" { launchArguments.removeFirst() }
            let entry = try store.registerApp(name: values[1], executableURL: fileURL(values[2]), bottleID: bottle.id,
                                              workingDirectory: workingDirectory, arguments: launchArguments)
            try emit(entry)

        case "launch":
            try requireCount(values, 1, command: command)
            let appID = try identifier(values[0])
            guard let app = store.state.apps.first(where: { $0.id == appID }) else { throw UsageError("No registered application has ID \(appID). Run list to inspect the library.") }
            let bottle = try store.requireBottle(id: app.bottleID)
            let process = try manager.run(bottle: bottle, bottleURL: store.bottleURL(for: bottle),
                                          executableURL: app.executableURL, arguments: app.arguments,
                                          workingDirectory: app.workingDirectoryURL)
            try await waitForProcess(process, manager: manager)

        case "stop":
            try requireCount(values, 1, command: command)
            let bottle = try findBottle(values[0], in: store)
            let result = try await manager.stopBottle(bottle: bottle, bottleURL: store.bottleURL(for: bottle))
            try emit(resultOutput(result))

        case "rename":
            try requireCount(values, 2, command: command)
            let bottle = try findBottle(values[0], in: store)
            try store.renameBottle(id: bottle.id, name: values[1])
            try emit(store.requireBottle(id: bottle.id))

        case "delete":
            try requireCount(values, 1, command: command)
            let bottle = try findBottle(values[0], in: store)
            try await manager.stopBottle(bottle: bottle, bottleURL: store.bottleURL(for: bottle))
            try store.deleteBottle(id: bottle.id)
            try emit(Deletion(deletedBottleID: bottle.id))

        case "settings":
            guard (3...4).contains(values.count) else {
                throw UsageError("settings requires BOTTLE_UUID win10|win11|win7 debug|quiet [system|en_US.UTF-8|zh_CN.UTF-8].")
            }
            var bottle = try findBottle(values[0], in: store)
            guard let version = WindowsVersion(rawValue: values[1]), ["debug", "quiet"].contains(values[2]) else {
                throw UsageError("settings requires BOTTLE_UUID win10|win11|win7 debug|quiet.")
            }
            bottle.settings.windowsVersion = version
            bottle.settings.debugLogging = values[2] == "debug"
            if values.count == 4 {
                guard values[3] == "system" || WineLocale(rawValue: values[3]) != nil else {
                    throw UsageError("Language must be system, en_US.UTF-8, or zh_CN.UTF-8.")
                }
                bottle.settings.locale = WineLocale(rawValue: values[3])
            }
            let result = try await manager.applySettings(bottle: bottle, bottleURL: store.bottleURL(for: bottle))
            try emit(resultOutput(result))
            try store.updateSettings(bottleID: bottle.id, settings: bottle.settings)
            try emit(bottle)

        default:
            throw UsageError("Unknown command '\(command)'. Run portside-cli --help.")
        }
    }

    @MainActor private static func selectedRuntime(_ store: LibraryStore) async throws -> WineRuntime {
        guard let saved = store.state.runtime else {
            throw PortsideError.invalidRuntime("Run portside-cli runtime [PATH] first. " + RuntimeManager.fallbackSetupInstructions)
        }
        let validated = try await RuntimeManager.validate(wineURL: saved.wineURL, source: saved.source)
        try store.setRuntime(validated)
        return validated
    }

    @MainActor private static func findBottle(_ value: String, in store: LibraryStore) throws -> Bottle {
        try store.requireBottle(id: identifier(value))
    }

    @MainActor private static func waitForProcess(_ process: RunningWineProcess, manager: WineProcessManager) async throws {
        try emit(RunningOutput(event: "started", id: process.id, bottleID: process.bottleID, kind: process.kind,
                               pid: process.pid, log: process.logURL.path))
        guard let result = await manager.waitForExit(id: process.id) else {
            throw PortsideError.commandFailed("The process result is unavailable. Inspect \(process.logURL.path).")
        }
        try emit(resultOutput(result))
        try result.requireSuccess()
    }

    private static func identifier(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else { throw UsageError("Expected a UUID, received '\(value)'. Run list to inspect IDs.") }
        return id
    }

    private static func fileURL(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    }

    private static func requireCount(_ values: [String], _ count: Int, command: String) throws {
        guard values.count == count else { throw UsageError("\(command) expects \(count) argument\(count == 1 ? "" : "s"). Run portside-cli --help.") }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func emit<T: Encodable>(_ value: T, to handle: FileHandle = .standardOutput) throws {
        handle.write(try encoder.encode(value))
        handle.write(Data([10]))
    }

    private static func resultOutput(_ result: ProcessResult) -> ResultOutput {
        ResultOutput(event: "finished", id: result.id, bottleID: result.bottleID, kind: result.kind,
                     exitCode: result.exitCode, terminationSignal: result.terminationSignal, wasStopped: result.wasStopped,
                     timedOut: result.timedOut, succeeded: result.succeeded,
                     log: result.logURL.path, summary: result.summary, startedAt: result.startedAt, finishedAt: result.finishedAt)
    }

    private struct Failure: Encodable { let error: String; let command: String }
    private struct Catalog: Encodable { let root: String; let state: LibraryState }
    private struct BottleEvent: Encodable { let event: String; let bottle: Bottle; let path: String }
    private struct Deletion: Encodable { let deletedBottleID: UUID }
    private struct RunningOutput: Encodable { let event: String; let id: UUID; let bottleID: UUID; let kind: String; let pid: Int32; let log: String }
    private struct ResultOutput: Encodable {
        let event: String; let id: UUID; let bottleID: UUID; let kind: String
        let exitCode: Int32; let terminationSignal: Int32?; let wasStopped: Bool
        let timedOut: Bool; let succeeded: Bool; let log: String; let summary: String
        let startedAt: Date; let finishedAt: Date
    }
    private struct UsageError: LocalizedError {
        let text: String
        init(_ text: String) { self.text = text }
        var errorDescription: String? { text }
    }

    private static let usage = """
    Portside CLI — native frontend diagnostics using PortsideCore

    Usage:
      portside-cli runtime [PATH]
      portside-cli list
      portside-cli create NAME
      portside-cli install BOTTLE_UUID EXE [installer arguments…]
      portside-cli register BOTTLE_UUID NAME EXE [--working-directory DIR] [-- launch arguments…]
      portside-cli launch APP_UUID
      portside-cli stop BOTTLE_UUID
      portside-cli rename BOTTLE_UUID NAME
      portside-cli delete BOTTLE_UUID
      portside-cli settings BOTTLE_UUID win10|win11|win7 debug|quiet [system|en_US.UTF-8|zh_CN.UTF-8]

    Quote paths and names containing spaces. Arguments are passed directly to Wine.
    Installer and launch commands stay alive until the direct Wine process exits.
    Use stop from another terminal to stop all Wine processes in a selected bottle.
    Successful operations emit JSON; process operations emit started/finished objects.
    PORTSIDE_HOME overrides the Application Support root for isolated integration tests.
    runtime PATH accepts Wine.app, a runtime directory, bin directory, or Wine launcher.
    """
}
