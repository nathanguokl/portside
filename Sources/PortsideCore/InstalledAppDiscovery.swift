import Foundation

public struct InstalledAppCandidate: Identifiable, Equatable, Sendable {
    public var id: String { executableURL.path }
    public let name: String
    public let executableURL: URL
    public let workingDirectoryURL: URL
    public let bottleID: UUID

    public init(name: String, executableURL: URL, workingDirectoryURL: URL, bottleID: UUID) {
        self.name = name
        self.executableURL = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        self.workingDirectoryURL = workingDirectoryURL.standardizedFileURL.resolvingSymlinksInPath()
        self.bottleID = bottleID
    }
}

/// A read-only search for reviewable GUI executables, not a claim that an installer has finished.
/// Call off the main actor with a bottle URL obtained from `LibraryStore.bottleURL(for:)`.
/// Searches six folder levels in C:, excluding system and support folders. Manual registration
/// remains available for user-profile installs, deeper layouts, console apps, and unusual launchers.
public enum InstalledAppDiscovery {
    struct Limits {
        var entries = 12_000
        var depth = 6
        var candidates = 200
        var seconds = 5.0
    }
    private static let systemFolders: Set<String> = ["windows", "users", "programdata", "$recycle.bin", "recovery"]
    private static let supportFolders: Set<String> = [
        "common files", "resources", "redist", "redistributables", "directx", "dxredist", "dotnet",
        "installers", "cache", "caches", "temp", "tmp", "logs", "log", "crashdumps", "dumps",
        "fonts", "locales", "translations", "lang", "cef", "cef32", "cef64", "gameguard",
        "anticheat", "easyanticheat", "battleye", "thirdparty", "third_party", "3rdparty",
        "support", "prerequisites", "dependencies", "content", "assets", "textures",
        "internet explorer", "windows media player", "windows nt"
    ]
    private static let binaryFolders: Set<String> = ["bin", "binaries", "win32", "win64", "x86", "x64", "amd64"]
    private static let containers: Set<String> = ["program files", "program files (x86)", "games", "applications"]

    public static func discover(bottle: Bottle, bottleURL: URL,
                                registeredApps: [WindowsApp]) throws -> [InstalledAppCandidate] {
        try scan(bottle: bottle, bottleURL: bottleURL, registeredApps: registeredApps, limits: Limits())
    }

    static func scan(bottle: Bottle, bottleURL: URL, registeredApps: [WindowsApp],
                     limits: Limits) throws -> [InstalledAppCandidate] {
        guard bottle.initialized else { throw PortsideError.commandFailed("Initialize this bottle before looking for installed apps.") }
        let files = FileManager.default
        let prefix = bottleURL.standardizedFileURL.resolvingSymlinksInPath()
        let drive = prefix.appendingPathComponent("drive_c", isDirectory: true)
        guard bottleURL.isFileURL, isDirectoryWithoutLink(bottleURL), isDirectoryWithoutLink(drive),
              drive.resolvingSymlinksInPath().deletingLastPathComponent() == prefix else {
            throw PortsideError.unsafeBottle("The bottle's C: drive is missing or is a symbolic link. Its files were left untouched.")
        }
        let registered = registeredApps.filter { $0.bottleID == bottle.id }
        let registeredPaths = Set(registered.map { $0.executableURL.standardizedFileURL.resolvingSymlinksInPath().path })
        var queue = [(drive, 0)], cursor = 0, visited = 0
        var candidates: [String: InstalledAppCandidate] = [:]
        let deadline = ContinuousClock.now.advanced(by: .seconds(limits.seconds))
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        while cursor < queue.count {
            try Task.checkCancellation()
            let (directory, depth) = queue[cursor]; cursor += 1
            guard directory == drive || (contains(directory, in: drive) && isDirectoryWithoutLink(directory)) else { continue }
            guard let enumerator = files.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }
            var children: [(URL, Bool)] = []
            while let child = enumerator.nextObject() as? URL {
                let url = child.standardizedFileURL
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw limitError("time") }
                visited += 1
                guard visited <= limits.entries else { throw limitError("file-count") }
                guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true,
                      contains(url, in: drive), url.resolvingSymlinksInPath() == url.standardizedFileURL else { continue }
                if values.isDirectory == true { children.append((url, true)) }
                else if values.isRegularFile == true { children.append((url, false)) }
            }
            // Visit each folder's files before descending, so large data trees cannot hide
            // a neighboring launcher. Sort the breadth-first queue and tie breaks consistently.
            for (url, isDirectory) in children.sorted(by: { $0.0.path < $1.0.path }) {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw limitError("time") }
                if isDirectory {
                    let name = url.lastPathComponent.lowercased()
                    guard depth < limits.depth - 1, !(depth == 0 && systemFolders.contains(name)),
                          !supportFolders.contains(name), !name.hasSuffix("_data") else { continue }
                    queue.append((url, depth + 1))
                    continue
                }
                guard url.pathExtension.lowercased() == "exe", !isHelper(url), !registeredPaths.contains(url.path),
                      isGUIExecutable(url) else { continue }
                let group = installDirectory(for: url, drive: drive)
                let executableLabel = url.deletingPathExtension().pathComponents.dropFirst(group.pathComponents.count).joined(separator: "/")
                let name = isContainer(group, drive: drive) || executableLabel.localizedCaseInsensitiveCompare(group.lastPathComponent) == .orderedSame
                    ? executableLabel : "\(group.lastPathComponent) — \(executableLabel)"
                let candidate = InstalledAppCandidate(name: name, executableURL: url,
                                                       workingDirectoryURL: url.deletingLastPathComponent(), bottleID: bottle.id)
                candidates[candidate.id] = candidate
                guard candidates.count <= limits.candidates else { throw limitError("candidate-count") }
            }
        }
        guard ContinuousClock.now < deadline else { throw limitError("time") }
        return candidates.values.sorted { $0.id < $1.id }
    }

    private static func contains(_ child: URL, in parent: URL) -> Bool {
        let root = parent.pathComponents, path = child.pathComponents
        return path.count > root.count && path.starts(with: root)
    }
    private static func isDirectoryWithoutLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }
    private static func isContainer(_ directory: URL, drive: URL) -> Bool {
        directory == drive || (directory.deletingLastPathComponent() == drive && containers.contains(directory.lastPathComponent.lowercased()))
    }
    private static func installDirectory(for executable: URL, drive: URL) -> URL {
        var directory = executable.deletingLastPathComponent()
        while directory != drive && binaryFolders.contains(directory.lastPathComponent.lowercased()) {
            directory.deleteLastPathComponent()
        }
        return directory
    }
    private static func isHelper(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return ["unins", "uninstall", "setup", "install", "redist", "vcredist", "dxsetup", "ndp"].contains(where: name.hasPrefix) ||
            ["installer", "downloader", "crash", "helper", "subprocess", "vc_redist"].contains(where: name.contains) ||
            ["update", "updater", "config", "configuration", "settings", "autorun", "elevate", "notification"].contains(name)
    }
    private static func isGUIExecutable(_ url: URL) -> Bool {
        guard (try? PEExecutable.validate(url: url)) != nil, let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let dos = try? file.read(upToCount: 64), dos.count == 64 else { return false }
        let offset = UInt32(dos[60]) | UInt32(dos[61]) << 8 | UInt32(dos[62]) << 16 | UInt32(dos[63]) << 24
        do {
            try file.seek(toOffset: UInt64(offset) + 20)
            let size = Array(try file.read(upToCount: 2) ?? Data())
            guard size.count == 2, UInt16(size[0]) | UInt16(size[1]) << 8 >= 70 else { return false }
            try file.seek(toOffset: UInt64(offset) + 24 + 68)
            return Array(try file.read(upToCount: 2) ?? Data()) == [2, 0]
        } catch { return false }
    }
    private static func limitError(_ kind: String) -> PortsideError {
        .commandFailed("The installed-app search reached its \(kind) limit. Use Add Manually… to choose the app's executable.")
    }
}
