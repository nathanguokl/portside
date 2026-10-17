import Foundation
import CryptoKit
import Darwin

public enum CompatibilityComponent: String, Codable, CaseIterable, Sendable {
    case dxvk = "dxvk-macos", cjk = "noto-cjk-sc"
    public var displayName: String { self == .dxvk ? "Graphics compatibility" : "Simplified Chinese fonts" }
}

public struct CompatibilityProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let components: [CompatibilityComponent]
    public let windowsVersion: WindowsVersion
    public let locale: WineLocale?
    public let executableSHA256: [String]
    public let executableSize: UInt64?
    public let publisherURL: URL?
    public let limitations: [String]

    public init(id: String, title: String, summary: String, components: [CompatibilityComponent],
                windowsVersion: WindowsVersion = .win10, locale: WineLocale? = nil,
                executableSHA256: [String] = [], executableSize: UInt64? = nil, publisherURL: URL? = nil, limitations: [String] = []) {
        self.id = id; self.title = title; self.summary = summary; self.components = components
        self.windowsVersion = windowsVersion; self.locale = locale; self.executableSHA256 = executableSHA256
        self.executableSize = executableSize; self.publisherURL = publisherURL; self.limitations = limitations
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, components, windowsVersion, locale, executableSHA256, executableSize, publisherURL, limitations
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  summary: try c.decode(String.self, forKey: .summary), components: try c.decode([CompatibilityComponent].self, forKey: .components),
                  windowsVersion: try c.decode(WindowsVersion.self, forKey: .windowsVersion), locale: try c.decodeIfPresent(WineLocale.self, forKey: .locale),
                  executableSHA256: try c.decodeIfPresent([String].self, forKey: .executableSHA256) ?? [],
                  executableSize: try c.decodeIfPresent(UInt64.self, forKey: .executableSize),
                  publisherURL: try c.decodeIfPresent(URL.self, forKey: .publisherURL), limitations: try c.decodeIfPresent([String].self, forKey: .limitations) ?? [])
    }
}

public struct CompatibilitySetupPlan: Sendable {
    public let pythonURL: URL
    public let dataDirectories: [CompatibilityComponent: URL]
}

public struct CompatibilitySetupResult: Sendable {
    public let bottleID: UUID
    public let installedComponents: [CompatibilityComponent]
    public let logURL: URL
    public init(bottleID: UUID, installedComponents: [CompatibilityComponent], logURL: URL) {
        self.bottleID = bottleID; self.installedComponents = installedComponents; self.logURL = logURL
    }
}

public struct CompatibilityBottleStatus: Sendable {
    public let missingComponents: [CompatibilityComponent]
    public let settingsMatch: Bool
    public var isConfigured: Bool { missingComponents.isEmpty && settingsMatch }
}

public struct CompatibilitySetupFailure: LocalizedError, Sendable {
    public let message: String
    public let installedComponents: [CompatibilityComponent]
    public let logURL: URL?
    public var errorDescription: String? {
        let partial = installedComponents.isEmpty ? "" : " Already installed: \(installedComponents.map(\.displayName).joined(separator: ", ")). These components were not rolled back."
        return message + partial + (logURL.map { " Log: \($0.path)" } ?? "")
    }
}

/// Runs only the app's trusted helpers. A selected pack supplies pinned data, never executable scripts.
public struct CompatibilitySetup: Sendable {
    public static let pythonDownloadURL = URL(string: "https://www.python.org/downloads/macos/")!
    public let resourcesURL: URL
    private let pythonCandidates: [URL]
    private let developerCheckURL: URL?
    private let timeout: TimeInterval
    private let installedHashes: [CompatibilityComponent: [String: String]]

    public init(resourcesURL: URL) {
        self.init(resourcesURL: resourcesURL, pythonCandidates: [
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/usr/bin/python3"
        ].map { URL(fileURLWithPath: $0) }, developerCheckURL: URL(fileURLWithPath: "/usr/bin/xcode-select"))
    }

    // Dependencies vary only in isolated tests; production never accepts a Python/helper path from a pack.
    init(resourcesURL: URL, pythonCandidates: [URL], developerCheckURL: URL? = nil,
         timeout: TimeInterval = 600, installedHashes: [CompatibilityComponent: [String: String]]? = nil) {
        self.resourcesURL = resourcesURL.standardizedFileURL; self.pythonCandidates = pythonCandidates
        self.developerCheckURL = developerCheckURL; self.timeout = timeout
        self.installedHashes = installedHashes ?? Self.pinnedInstalledHashes
    }

    public func loadProfiles() throws -> [CompatibilityProfile] {
        struct Catalog: Decodable { let schemaVersion: Int; let profiles: [CompatibilityProfile] }
        let data = try Self.readFile(resourcesURL.appendingPathComponent("profiles.json"), within: resourcesURL, limit: 128 * 1024)
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.schemaVersion == 1, !catalog.profiles.isEmpty, catalog.profiles.count <= 20,
              Set(catalog.profiles.map(\.id)).count == catalog.profiles.count else {
            throw PortsideError.commandFailed("Compatibility profiles are invalid. Reinstall Portside from a complete release.")
        }
        for profile in catalog.profiles { try Self.validate(profile) }
        return catalog.profiles
    }

    /// Exact, bounded fingerprints only: filenames never identify an application or trigger setup.
    public func detectProfile(executableURL: URL) async throws -> CompatibilityProfile? {
        guard FileManager.default.fileExists(atPath: resourcesURL.appendingPathComponent("profiles.json").path) else { return nil }
        let profiles = try loadProfiles()
        return try await Task.detached(priority: .userInitiated) {
            let size = (try? FileManager.default.attributesOfItem(atPath: executableURL.path)[.size]) as? UInt64
            let candidates = profiles.filter { !$0.executableSHA256.isEmpty && ($0.executableSize == nil || $0.executableSize == size) }
            guard !candidates.isEmpty else { return nil }
            guard (try? PEExecutable.validate(url: executableURL)) != nil,
                  let hash = try Self.fileHash(executableURL, limit: 32 * 1024 * 1024) else { return nil }
            let matches = candidates.filter { $0.executableSHA256.contains(hash) }
            return matches.count == 1 ? matches[0] : nil
        }.value
    }

    /// Reads receipts and actual installed payloads without starting Wine or changing the bottle.
    public func bottleStatus(profile: CompatibilityProfile, bottle: Bottle, libraryRootURL: URL) async throws -> CompatibilityBottleStatus {
        try Self.validate(profile)
        return try await Task.detached(priority: .userInitiated) {
            let target = try Self.target(bottle, root: libraryRootURL)
            let missing = profile.components.filter { !self.componentInstalled($0, bottle: target.bottle, prefix: target.prefix) }
            return CompatibilityBottleStatus(missingComponents: missing,
                settingsMatch: target.bottle.settings.windowsVersion == profile.windowsVersion && target.bottle.settings.locale == profile.locale)
        }.value
    }

    /// Presence is checked here; the trusted helpers verify publisher/build pins before installation.
    public func prepare(profile: CompatibilityProfile, packURL: URL? = nil) async throws -> CompatibilitySetupPlan {
        try Self.validate(profile)
        for component in profile.components { _ = try helper(component) }
        let root = (packURL ?? resourcesURL).standardizedFileURL
        try Self.directory(root)
        var directories: [CompatibilityComponent: URL] = [:]
        for component in profile.components {
            let relative = component == .dxvk ? "Components/dxvk-macos" : "Fonts/noto-cjk"
            let directory = root.appendingPathComponent(relative, isDirectory: true)
            let files = component == .dxvk ? ["component.json", "x32/d3d10core.dll", "x32/d3d11.dll", "x64/d3d10core.dll", "x64/d3d11.dll"] : ["NotoSansCJKsc-Regular.otf", "OFL.txt"]
            do {
                try Self.directory(directory)
                for file in files { try Self.regularFile(directory.appendingPathComponent(file), within: root) }
            } catch {
                throw PortsideError.commandFailed("\(component.displayName) data is missing or unsafe. Choose a complete Portside compatibility data pack, or use a release that includes it. Expected \(directory.path).")
            }
            directories[component] = directory
        }
        return CompatibilitySetupPlan(pythonURL: try await python(), dataDirectories: directories)
    }

    public func install(profile: CompatibilityProfile, bottle: Bottle, libraryRootURL: URL,
                        packURL: URL? = nil) async throws -> CompatibilitySetupResult {
        _ = try Self.target(bottle, root: libraryRootURL)
        let plan = try await prepare(profile: profile, packURL: packURL)
        _ = try Self.target(bottle, root: libraryRootURL)
        let logs = libraryRootURL.appendingPathComponent("Logs", isDirectory: true)
        try Self.directory(logs)
        let logURL = logs.appendingPathComponent("compatibility-\(bottle.id.uuidString)-\(UUID().uuidString).log")
        let fd = open(logURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PortsideError.commandFailed("Could not create the compatibility setup log in \(logs.path). Check folder permissions.") }
        let log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? log.close() }
        var installed: [CompatibilityComponent] = []
        do {
            let header: [String: Any] = ["profile": profile.id, "bottleID": bottle.id.uuidString,
                                       "libraryRoot": libraryRootURL.path, "python": plan.pythonURL.path]
            try log.write(contentsOf: JSONSerialization.data(withJSONObject: header, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            for component in profile.components {
                try Task.checkCancellation()
                _ = try Self.target(bottle, root: libraryRootURL)
                let script = try helper(component)
                let data = plan.dataDirectories[component]!
                let option = component == .dxvk ? "--component-dir" : "--font-dir"
                let arguments = ["-I", "-B", script.path, bottle.id.uuidString, "--home", libraryRootURL.path, option, data.path]
                try log.write(contentsOf: Data("\n--- \(component.displayName) ---\n".utf8))
                let result = try await CommandExecutor.execute(executableURL: plan.pythonURL, arguments: arguments,
                                                               environment: Self.environment, timeout: timeout)
                try log.write(contentsOf: Data(result.output.utf8))
                try log.write(contentsOf: Data("\nexit=\(result.exitCode), timedOut=\(result.timedOut)\n".utf8))
                guard result.exitCode == 0, !result.timedOut else {
                    let reason = result.timedOut ? "timed out" : "failed (exit \(result.exitCode))"
                    throw PortsideError.commandFailed("\(component.displayName) setup \(reason). \(result.output.suffix(1800)) Inspect this component’s .portside-components state and operations.log before retrying; its helper owns recovery.")
                }
                installed.append(component)
                // Registry helpers can leave Wine's idle server alive briefly. Wait
                // passively before the next helper's stopped-bottle preflight.
                let target = try Self.target(bottle, root: libraryRootURL)
                let idle = try await CommandExecutor.execute(executableURL: target.bottle.runtime.wineServerURL, arguments: ["-w"],
                    environment: RuntimeManager.environment(runtime: target.bottle.runtime, bottleURL: target.prefix), timeout: 15)
                try log.write(contentsOf: Data("\nPassive Wine shutdown wait: exit=\(idle.exitCode), timedOut=\(idle.timedOut)\n\(idle.output)\n".utf8))
                guard idle.exitCode == 0, !idle.timedOut else {
                    throw PortsideError.commandFailed("\(component.displayName) was installed, but Wine shutdown could not be confirmed. Stop this bottle before retrying. No stop request was sent by setup.")
                }
            }
            return CompatibilitySetupResult(bottleID: bottle.id, installedComponents: installed, logURL: logURL)
        } catch {
            try? log.write(contentsOf: Data("\nSetup stopped: \(error.localizedDescription)\nEarlier completed components: \(installed.map(\.rawValue).joined(separator: ", "))\n".utf8))
            throw CompatibilitySetupFailure(message: error.localizedDescription, installedComponents: installed, logURL: logURL)
        }
    }

    private func helper(_ component: CompatibilityComponent) throws -> URL {
        // CJK imports the sibling DXVK helper for shared ownership/idle/registry checks.
        let scripts = resourcesURL.appendingPathComponent("Scripts", isDirectory: true)
        do {
            try Self.directory(resourcesURL); try Self.directory(scripts)
            let dxvk = scripts.appendingPathComponent("setup-bottle-dxvk.py")
            try Self.regularFile(dxvk, within: resourcesURL)
            let selected = component == .dxvk ? dxvk : scripts.appendingPathComponent("setup-bottle-cjk.py")
            try Self.regularFile(selected, within: resourcesURL)
            return selected
        } catch {
            throw PortsideError.commandFailed("Portside’s bundled compatibility helpers are missing or unsafe. Reinstall a complete Portside release. \(error.localizedDescription)")
        }
    }

    private func python() async throws -> URL {
        for candidate in pythonCandidates {
            guard candidate.isFileURL, FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            if candidate.path == "/usr/bin/python3" {
                guard let check = developerCheckURL,
                      let result = try? await CommandExecutor.execute(executableURL: check, arguments: ["-p"], environment: Self.environment, timeout: 3),
                      result.exitCode == 0, !result.timedOut else { continue }
            }
            guard let result = try? await CommandExecutor.execute(executableURL: candidate, arguments: ["-I", "-B", "--version"], environment: Self.environment, timeout: 5),
                  result.exitCode == 0, !result.timedOut else { continue }
            let fields = result.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard fields.count == 2, fields[0] == "Python" else { continue }
            let version = fields[1].split(separator: ".").compactMap { Int($0) }
            if version.count >= 2, version[0] > 3 || (version[0] == 3 && version[1] >= 9) { return candidate }
        }
        throw PortsideError.commandFailed("Python 3.9 or newer is required for compatibility setup. Install Python 3 for macOS from \(Self.pythonDownloadURL.absoluteString), then reopen this setup. Portside does not install developer tools or Python automatically.")
    }

    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment.filter {
            let key = $0.key.uppercased()
            return !key.hasPrefix("PYTHON") && !key.hasPrefix("WINE") && !key.hasPrefix("DYLD_") && !key.hasPrefix("CX_") &&
                   !["LD_PRELOAD", "CFPROCESSPATH", "__CFBUNDLEIDENTIFIER", "PORTSIDE_WINE_UI_BUNDLE"].contains(key)
        }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["LANG"] = "en_US.UTF-8"; env["LC_ALL"] = "en_US.UTF-8"
        return env
    }

    private static func validate(_ profile: CompatibilityProfile) throws {
        guard !profile.id.isEmpty, profile.id.count <= 80, !profile.title.isEmpty, profile.title.count <= 160,
              profile.summary.count <= 3000, !profile.components.isEmpty, Set(profile.components).count == profile.components.count,
              profile.executableSHA256.count <= 20, profile.executableSHA256.allSatisfy({ $0.count == 64 && $0.allSatisfy({ "0123456789abcdef".contains($0) }) }) else {
            throw PortsideError.commandFailed("Compatibility profile is invalid. Choose a bundled profile from a complete Portside release.")
        }
    }

    private static func target(_ bottle: Bottle, root: URL) throws -> (bottle: Bottle, prefix: URL) {
        try directory(root)
        let bottles = root.appendingPathComponent("Bottles", isDirectory: true)
        try directory(bottles)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(LibraryState.self, from: readFile(root.appendingPathComponent("library.json"), within: root, limit: 8 * 1024 * 1024))
        guard state.schemaVersion == LibraryState.currentSchemaVersion,
              state.bottles.filter({ $0.id == bottle.id }).count == 1,
              let current = state.bottles.first(where: { $0.id == bottle.id }), current.initialized,
              current.directoryName == current.id.uuidString, bottle.directoryName == current.directoryName,
              current.runtime == bottle.runtime else {
            throw PortsideError.unsafeBottle("Compatibility setup requires the same existing, initialized bottle and runtime. Refresh the library and choose it again.")
        }
        let prefix = bottles.appendingPathComponent(current.directoryName, isDirectory: true)
        try directory(prefix)
        struct Owner: Decodable { let owner: String; let bottleID: UUID }
        let marker = try JSONDecoder().decode(Owner.self, from: readFile(prefix.appendingPathComponent(".portside-bottle.json"), within: prefix, limit: 4096))
        guard marker.owner == "app.portside.mac", marker.bottleID == current.id,
              prefix.resolvingSymlinksInPath().deletingLastPathComponent() == bottles.resolvingSymlinksInPath() else {
            throw PortsideError.unsafeBottle("The bottle ownership marker does not match. No setup was started.")
        }
        return (current, prefix)
    }

    private func componentInstalled(_ component: CompatibilityComponent, bottle: Bottle, prefix: URL) -> Bool {
        do {
            let receiptURL = prefix.appendingPathComponent(".portside-components/\(component.rawValue)/state.json")
            let data = try Self.readFile(receiptURL, within: prefix, limit: 128 * 1024)
            guard let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  receipt["schemaVersion"] as? Int == 1, receipt["owner"] as? String == "app.portside.mac",
                  receipt["bottleID"] as? String == bottle.id.uuidString, receipt["status"] as? String == "installed" else { return false }
            if component == .dxvk {
                guard receipt["componentVersion"] as? String == "1.10.3-portside1",
                      let manifest = receipt["component"] as? [String: Any], manifest["id"] as? String == component.rawValue,
                      manifest["version"] as? String == "1.10.3-portside1", manifest["upstreamCommit"] as? String == "8f1e28deed3ad30802f7e1bdff428ec14e6e7817" else { return false }
                let overrides = try Self.registryValues(prefix.appendingPathComponent("user.reg"), section: "Software\\Wine\\DllOverrides", within: prefix)
                guard overrides["d3d10core"] == "native,builtin", overrides["d3d11"] == "native,builtin", overrides["dxgi"] == "builtin" else { return false }
            } else {
                guard receipt["componentID"] as? String == component.rawValue, receipt["version"] as? String == "2.004",
                      receipt["upstreamCommit"] as? String == "f8d157532fbfaeda587e826d4cd5b21a49186f7c" else { return false }
                let fonts = try Self.registryValues(prefix.appendingPathComponent("system.reg"), section: "Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts", within: prefix)
                let aliases = try Self.registryValues(prefix.appendingPathComponent("user.reg"), section: "Software\\Wine\\Fonts\\Replacements", within: prefix)
                guard fonts["noto sans cjk sc (opentype)"]?.lowercased() == "c:\\windows\\fonts\\notosanscjksc-regular.otf",
                      aliases["noto sans cjk jp"] == "Noto Sans CJK SC" else { return false }
            }
            guard let files = installedHashes[component], !files.isEmpty else { return false }
            for (relative, expected) in files {
                let url = prefix.appendingPathComponent(relative)
                try Self.regularFile(url, within: prefix)
                guard try Self.fileHash(url, limit: 64 * 1024 * 1024) == expected else { return false }
            }
            return true
        } catch { return false }
    }

    private static let pinnedInstalledHashes: [CompatibilityComponent: [String: String]] = [
        .dxvk: [
            "drive_c/windows/syswow64/d3d10core.dll": "01e2b0890d25decbfe67babd74515944b355b85fe1881dfbad564cd6e5aadffc",
            "drive_c/windows/syswow64/d3d11.dll": "f79d417f675d00008375eb4ea2318af6fcd0b27971d604d3cf345a0dcfa998a0",
            "drive_c/windows/system32/d3d10core.dll": "e7c1a633fefcebae3803f015b5e4f267ace447c6517bef7b3e1d35f16a50363a",
            "drive_c/windows/system32/d3d11.dll": "0ff0b0835dde29556bd01dfce7b1ae348d7f229cb1e1a37cc71ea1a028beeca4"
        ],
        .cjk: ["drive_c/windows/Fonts/NotoSansCJKsc-Regular.otf": "2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b",
               ".portside-components/noto-cjk-sc/OFL.txt": "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"]
    ]

    /// Only exact string entries needed by the bundled helpers; this does not import a registry file or execute Wine.
    private static func registryValues(_ url: URL, section: String, within root: URL) throws -> [String: String] {
        let text = String(decoding: try readFile(url, within: root, limit: 8 * 1024 * 1024), as: UTF8.self)
        let heading = "[" + section.replacingOccurrences(of: "\\", with: "\\\\") + "]"
        var active = false, values: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { active = line.lowercased().hasPrefix(heading.lowercased()); continue }
            guard active, let split = line.range(of: "\"=\"") else { continue }
            let nameData = Data(line[..<split.lowerBound].appending("\"").utf8)
            let valueData = Data(line[split.lowerBound...].dropFirst(2).utf8)
            if let name = try? JSONDecoder().decode(String.self, from: nameData),
               let value = try? JSONDecoder().decode(String.self, from: valueData) { values[name.lowercased()] = value }
        }
        return values
    }

    private static func directory(_ url: URL) throws {
        guard url.isFileURL, (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeDirectory else {
            throw PortsideError.commandFailed("Expected a local folder without a symbolic link: \(url.path)")
        }
    }

    private static func regularFile(_ url: URL, within root: URL) throws {
        guard url.isFileURL, (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeRegular,
              url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
            throw PortsideError.commandFailed("Expected a regular file inside \(root.path): \(url.path)")
        }
    }

    private static func readFile(_ url: URL, within root: URL, limit: Int) throws -> Data {
        try regularFile(url, within: root)
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw PortsideError.commandFailed("Setup metadata exceeds its safe size limit: \(url.path)") }
        return data
    }

    private static func fileHash(_ url: URL, limit: Int) throws -> String? {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        guard try reader.seekToEnd() <= UInt64(limit) else { return nil }
        try reader.seek(toOffset: 0)
        var digest = SHA256(), count = 0
        while let data = try reader.read(upToCount: 128 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            count += data.count
            guard count <= limit else { return nil }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
