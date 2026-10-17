import Foundation
import Darwin

public enum RuntimeManager {
    public static let fallbackSetupInstructions = "Install Apple's Rosetta on Apple silicon with /usr/sbin/softwareupdate --install-rosetta --agree-to-license. Download the free macOS Wine Stable app from the Gcenx macOS Wine Builds official GitHub releases (github.com/Gcenx/macOS_Wine_builds), or run the repository’s scripts/setup-runtime.sh helper. The Homebrew wine-stable cask is currently disabled; use the publisher download path. Select Wine Stable.app, its bin/wine executable, or another compatible macOS Wine distribution. Portside does not include Wine or require CrossOver. Use a 64-bit macOS build; Linux Wine binaries will not run on macOS. Review the runtime publisher's installation and security instructions."

    /// Where a macOS Wine .app keeps its launcher, in lookup order.
    private static let bundledWineExecutables = ["Contents/Resources/wine/bin/wine", "Contents/Resources/bin/wine"]

    public static func discoverCandidates() -> [URL] {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let runtimeRoot = support.appendingPathComponent("Portside/Runtimes")
        let appRoots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                        fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"), runtimeRoot]
        var candidates = [URL(fileURLWithPath: "/opt/homebrew/bin/wine"), URL(fileURLWithPath: "/usr/local/bin/wine")]
        for root in appRoots {
            for app in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if app.pathExtension.lowercased() == "app" && app.lastPathComponent.lowercased().contains("wine") {
                    candidates += bundledWineExecutables.map { app.appendingPathComponent($0) }
                } else if root == runtimeRoot {
                    candidates.append(app.appendingPathComponent("bin/wine"))
                }
            }
        }
        var seen = Set<String>()
        return candidates.filter { fm.isExecutableFile(atPath: $0.path) && seen.insert($0.standardizedFileURL.path).inserted }
    }

    public static func resolveSelection(_ url: URL) -> URL {
        if url.pathExtension.lowercased() == "app" {
            let choices = bundledWineExecutables.map { url.appendingPathComponent($0) }
            return choices.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) ?? choices[0]
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let direct = url.appendingPathComponent("wine")
            if FileManager.default.isExecutableFile(atPath: direct.path) { return direct }
            return url.appendingPathComponent("bin/wine")
        }
        return url
    }

    public static func validate(wineURL: URL, source: String) async throws -> WineRuntime {
        let selected = resolveSelection(wineURL).standardizedFileURL
        let fm = FileManager.default
        guard selected.isFileURL, fm.isExecutableFile(atPath: selected.path) else {
            throw PortsideError.invalidRuntime("No executable Wine launcher exists at \(selected.path). \(fallbackSetupInstructions)")
        }
        let runtime = WineRuntime(wineURL: selected, version: "Unvalidated", source: source)
        guard fm.isExecutableFile(atPath: runtime.wineServerURL.path), fm.isExecutableFile(atPath: runtime.wineBootURL.path) else {
            throw PortsideError.invalidRuntime("The Wine bin directory must also contain executable wineserver and wineboot. Select a complete macOS Wine distribution.")
        }
        let result: CommandOutput
        do {
            result = try await CommandExecutor.execute(executableURL: selected, arguments: ["--version"],
                                                     environment: environment(runtime: runtime), timeout: 15)
        } catch {
            throw PortsideError.invalidRuntime("Could not execute Wine. On Apple silicon, check that Rosetta is installed. \(error.localizedDescription)")
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.timedOut, result.exitCode == 0, output.lowercased().contains("wine-") else {
            throw PortsideError.invalidRuntime("Wine --version \(result.timedOut ? "timed out" : "exited with code \(result.exitCode)"). \(output.prefix(1500))")
        }
        let version = output.split(separator: "\n").first(where: { $0.lowercased().contains("wine-") }).map(String.init) ?? output
        return WineRuntime(wineURL: selected, version: version, source: source)
    }

    /// Each invocation gets a fresh, explicit Wine environment. Parent-shell bottle overrides never leak in.
    public static func environment(runtime: WineRuntime, bottleURL: URL? = nil, settings: BottleSettings = BottleSettings()) -> [String: String] {
        let hostEnvironment = ProcessInfo.processInfo.environment
        var env = hostEnvironment.filter { key, _ in
            let name = key.uppercased()
            return !name.hasPrefix("WINE") && !name.hasPrefix("DYLD_") && !name.hasPrefix("CX_") && key != "LD_PRELOAD" &&
                !["CFProcessPath", "__CFBundleIdentifier", "PORTSIDE_WINE_UI_BUNDLE"].contains(key)
        }
        let standardPath = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = runtime.wineURL.deletingLastPathComponent().path + ":" + standardPath
        if let bottleURL {
            env["WINEPREFIX"] = bottleURL.path
            env["WINEARCH"] = "win64"
        }
        env["WINEDEBUG"] = settings.debugLogging ? "+timestamp,+pid,+tid,+seh" : "-all,err+all"
        env["MVK_CONFIG_LOG_LEVEL"] = "0"
        if let locale = settings.locale {
            env = env.filter { !$0.key.hasPrefix("LC_") }
            env["LANG"] = locale.rawValue
            env["LC_ALL"] = locale.rawValue
        }
        if let host = uiHostIdentity(bundlePath: hostEnvironment["PORTSIDE_WINE_UI_BUNDLE"]) {
            env["CFProcessPath"] = host.processPath
            env["__CFBundleIdentifier"] = host.bundleIdentifier
        }
        return env
    }

    /// Optional verification harness: give unbundled Wine windows a unique macOS
    /// identity so native UI automation can attach. This changes no Wine code,
    /// prefix, or command arguments and is unused during ordinary launches.
    private static func uiHostIdentity(bundlePath: String?) -> (processPath: String, bundleIdentifier: String)? {
        guard let bundlePath, (bundlePath as NSString).isAbsolutePath else { return nil }
        let bundle = URL(fileURLWithPath: bundlePath).standardizedFileURL
        guard bundle.pathExtension.lowercased() == "app",
              (try? bundle.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, executable != ".", executable != "..",
              !executable.contains("/"), !executable.contains("\0") else { return nil }
        let executableURL = bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path),
              (try? executableURL.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return (executableURL.path, identifier)
    }
}

struct CommandOutput: Sendable {
    let exitCode: Int32
    let timedOut: Bool
    let output: String
}

/// Short commands write to a temporary file rather than bounded pipes, so noisy Wine output cannot deadlock.
enum CommandExecutor {
    static func execute(executableURL: URL, arguments: [String], environment: [String: String],
                        timeout: TimeInterval) async throws -> CommandOutput {
        try await Task.detached(priority: .userInitiated) {
            try executeSynchronously(executableURL: executableURL, arguments: arguments, environment: environment,
                                     timeout: timeout)
        }.value
    }

    private static func executeSynchronously(executableURL: URL, arguments: [String], environment: [String: String],
                                             timeout: TimeInterval) throws -> CommandOutput {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portside-command-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executableURL; process.arguments = arguments; process.environment = environment
        process.standardOutput = handle; process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.04) }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.04) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 64 * 1024) ?? Data()
        return CommandOutput(exitCode: process.terminationStatus, timedOut: timedOut,
                             output: String(decoding: data, as: UTF8.self))
    }
}
