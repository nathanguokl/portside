import Foundation
import Darwin

/// A small atomic JSON catalog. Names never become paths; bottles use UUID directories.
@MainActor public final class LibraryStore {
    public let rootURL: URL
    public let bottlesURL: URL
    public let logsURL: URL
    public let stateURL: URL
    public private(set) var state: LibraryState
    public private(set) var recoveryWarnings: [String] = []
    private let manager = FileManager.default
    private static let markerName = ".portside-bottle.json"
    private static let ownerID = "app.portside.mac"
    private struct Ownership: Codable { let owner: String; let bottleID: UUID }

    public init(rootURL: URL? = nil) throws {
        self.rootURL = (rootURL ?? Self.defaultRootURL).standardizedFileURL
        self.bottlesURL = self.rootURL.appendingPathComponent("Bottles", isDirectory: true)
        self.logsURL = self.rootURL.appendingPathComponent("Logs", isDirectory: true)
        self.stateURL = self.rootURL.appendingPathComponent("library.json")
        self.state = LibraryState()
        for directory in [self.rootURL, bottlesURL, logsURL] {
            try Self.rejectSymlink(directory)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.rejectSymlink(directory)
        }
        try withCurrentCatalog {}
    }

    public static var defaultRootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Portside", isDirectory: true)
    }

    /// Refresh after another frontend or CLI process has changed the catalog.
    public func refresh() throws { try withCurrentCatalog {} }

    public func setRuntime(_ runtime: WineRuntime?) throws {
        try withCurrentCatalog { try mutate { $0.runtime = runtime } }
    }

    /// Commit a background validation only if no process has changed its selection.
    @discardableResult public func setRuntime(_ runtime: WineRuntime?, ifCurrentMatches expected: WineRuntime?) throws -> Bool {
        try withCurrentCatalog {
            guard state.runtime == expected else { return false }
            try mutate { $0.runtime = runtime }
            return true
        }
    }

    @discardableResult public func createBottle(name: String, runtime: WineRuntime) throws -> Bottle {
        try withCurrentCatalog {
            let bottle = Bottle(name: try cleanName(name), runtime: runtime)
            let directory = bottlesURL.appendingPathComponent(bottle.directoryName, isDirectory: true)
            guard !itemExists(directory) else { throw PortsideError.unsafeBottle("A bottle already occupies the generated directory.") }
            try manager.createDirectory(at: directory, withIntermediateDirectories: false)
            do {
                let marker = Ownership(owner: Self.ownerID, bottleID: bottle.id)
                try JSONEncoder().encode(marker).write(to: directory.appendingPathComponent(Self.markerName), options: .atomic)
                try mutate { $0.bottles.append(bottle) }
            } catch {
                try? manager.removeItem(at: directory)
                throw error
            }
            return bottle
        }
    }

    public func bottleURL(for bottle: Bottle) throws -> URL {
        // Keep owned files inspectable after a catalog-save failure. Callers can refresh
        // before choosing a bottle; all mutations reload independently under this lock.
        try withCatalogLock { try checkedBottleURL(for: bottle) }
    }

    private func checkedBottleURL(for bottle: Bottle) throws -> URL {
        guard state.bottles.contains(where: { $0.id == bottle.id }), bottle.directoryName == bottle.id.uuidString else {
            throw PortsideError.unsafeBottle("The selected directory is not an app-managed bottle.")
        }
        try Self.rejectSymlink(rootURL)
        try Self.rejectSymlink(bottlesURL)
        let result = bottlesURL.appendingPathComponent(bottle.directoryName, isDirectory: true).standardizedFileURL
        guard result.deletingLastPathComponent() == bottlesURL.standardizedFileURL,
              result.resolvingSymlinksInPath().deletingLastPathComponent() == bottlesURL.resolvingSymlinksInPath() else {
            throw PortsideError.unsafeBottle("The bottle points outside the managed Bottles directory.")
        }
        try Self.rejectSymlink(result)
        let markerURL = result.appendingPathComponent(Self.markerName)
        try Self.rejectSymlink(markerURL)
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(Ownership.self, from: data),
              marker.owner == Self.ownerID, marker.bottleID == bottle.id else {
            throw PortsideError.unsafeBottle("The ownership marker is missing or does not match this bottle. Its files have been left untouched.")
        }
        return result
    }

    /// The catalog entry for `id`, or `PortsideError.missingBottle`.
    @discardableResult public func requireBottle(id: UUID) throws -> Bottle {
        try withCurrentCatalog { try currentBottle(id: id) }
    }

    private func currentBottle(id: UUID) throws -> Bottle {
        guard let bottle = state.bottles.first(where: { $0.id == id }) else { throw PortsideError.missingBottle }
        return bottle
    }

    public func renameBottle(id: UUID, name: String) throws {
        let clean = try cleanName(name)
        try updateBottle(id) { $0.name = clean }
    }

    public func markBottleInitialized(id: UUID, error: String? = nil) throws {
        try updateBottle(id) {
            $0.initialized = error == nil
            $0.initializationError = error
        }
    }

    public func updateSettings(bottleID: UUID, settings: BottleSettings) throws {
        try updateBottle(bottleID) { $0.settings = settings }
    }

    /// The caller must stop and wait for bottle processes before deletion.
    public func deleteBottle(id: UUID) throws {
        try withCurrentCatalog {
            let bottle = try currentBottle(id: id)
            let directory = try checkedBottleURL(for: bottle)
            // Keep the rename, catalog commit, and removal under the same process lock.
            // Startup restores an owned staged directory if the catalog commit never happened.
            let staged = bottlesURL.appendingPathComponent(".deleting-\(id.uuidString)-\(UUID().uuidString)", isDirectory: true)
            try manager.moveItem(at: directory, to: staged)
            do {
                try mutate {
                    $0.bottles.removeAll { $0.id == id }
                    $0.apps.removeAll { $0.bottleID == id }
                }
            } catch {
                do { try manager.moveItem(at: staged, to: directory) }
                catch { throw PortsideError.persistence("The bottle could not be restored after a catalog save failure. Its files are preserved at \(staged.path). \(error.localizedDescription)") }
                throw error
            }
            do { try manager.removeItem(at: staged) }
            catch { throw PortsideError.commandFailed("The bottle was removed from the library, but its files could not be deleted. Remove the preserved directory manually: \(staged.path). \(error.localizedDescription)") }
        }
    }

    @discardableResult public func registerApp(name: String, executableURL: URL, bottleID: UUID,
                                               workingDirectory: URL? = nil, arguments: [String] = []) throws -> WindowsApp {
        try withCurrentCatalog {
            _ = try currentBottle(id: bottleID)
            try PEExecutable.validate(url: executableURL)
            let working = (workingDirectory ?? executableURL.deletingLastPathComponent()).standardizedFileURL
            try validateWorkingDirectory(working)
            let app = WindowsApp(name: try cleanName(name), executablePath: executableURL.standardizedFileURL.path,
                                 workingDirectory: working.path, arguments: arguments, bottleID: bottleID)
            try mutate { $0.apps.append(app) }
            return app
        }
    }

    public func updateApp(_ app: WindowsApp) throws {
        try withCurrentCatalog {
            guard let index = state.apps.firstIndex(where: { $0.id == app.id }),
                  state.bottles.contains(where: { $0.id == app.bottleID }) else { throw PortsideError.missingBottle }
            try PEExecutable.validate(url: app.executableURL)
            try validateWorkingDirectory(app.workingDirectoryURL)
            var updated = app; updated.name = try cleanName(app.name)
            try mutate { $0.apps[index] = updated }
        }
    }

    public func deleteApp(id: UUID) throws { try withCurrentCatalog { try mutate { $0.apps.removeAll { $0.id == id } } } }

    private func cleanName(_ name: String) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw PortsideError.invalidName }
        return cleaned
    }

    private func validateWorkingDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PortsideError.invalidExecutable("The working directory does not exist: \(url.path)")
        }
    }

    private func updateBottle(_ id: UUID, _ change: (inout Bottle) -> Void) throws {
        try withCurrentCatalog {
            guard let index = state.bottles.firstIndex(where: { $0.id == id }) else { throw PortsideError.missingBottle }
            try mutate { change(&$0.bottles[index]) }
        }
    }

    /// All callers hold the stable sidecar lock and have reloaded the latest catalog.
    private func mutate(_ change: (inout LibraryState) -> Void) throws {
        var next = state; change(&next)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        do {
            try Self.rejectSymlink(stateURL)
            try encoder.encode(next).write(to: stateURL, options: .atomic)
            state = next
        } catch { throw PortsideError.persistence(error.localizedDescription) }
    }

    private func withCurrentCatalog<T>(_ operation: () throws -> T) throws -> T {
        try withCatalogLock {
            state = try readCatalog()
            recoveryWarnings = try recoverStagedDeletions()
            return try operation()
        }
    }

    private func withCatalogLock<T>(_ operation: () throws -> T) throws -> T {
        try Self.rejectSymlink(rootURL)
        try Self.rejectSymlink(bottlesURL)
        let lockURL = rootURL.appendingPathComponent(".library.lock")
        // Unlike library.json, this inode is never replaced or removed by Portside.
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw PortsideError.persistence("Could not open the catalog lock: \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), information.st_nlink == 1 else {
            throw PortsideError.persistence("The catalog lock must be a regular file with one link: \(lockURL.path)")
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EWOULDBLOCK {
                throw PortsideError.persistence("Another Portside process is updating the library. Wait for that operation to finish, then try again.")
            }
            guard code == EINTR else { throw PortsideError.persistence("Could not lock the catalog: \(String(cString: strerror(code)))") }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func readCatalog() throws -> LibraryState {
        do {
            try Self.rejectSymlink(stateURL)
            guard itemExists(stateURL) else { return LibraryState() }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let latest = try decoder.decode(LibraryState.self, from: Data(contentsOf: stateURL))
            guard latest.schemaVersion == LibraryState.currentSchemaVersion else { throw PortsideError.persistence("Unsupported library format \(latest.schemaVersion).") }
            guard Set(latest.bottles.map(\.id)).count == latest.bottles.count,
                  Set(latest.apps.map(\.id)).count == latest.apps.count,
                  latest.bottles.allSatisfy({ $0.directoryName == $0.id.uuidString }) else {
                throw PortsideError.persistence("The catalog contains duplicate IDs or unsafe bottle directory names.")
            }
            return latest
        } catch { throw PortsideError.persistence("Your existing catalog was preserved at \(stateURL.path). \(error.localizedDescription)") }
    }

    private func recoverStagedDeletions() throws -> [String] {
        let entries = try manager.contentsOfDirectory(at: bottlesURL, includingPropertiesForKeys: nil)
        var groups: [UUID: [URL]] = [:]
        for entry in entries {
            let name = entry.lastPathComponent
            let prefix = ".deleting-"
            guard name.hasPrefix(prefix) else { continue }
            let identifiers = String(name.dropFirst(prefix.count))
            guard identifiers.count == 73 else { continue }
            let split = identifiers.index(identifiers.startIndex, offsetBy: 36)
            guard identifiers[split] == "-",
                  let bottleID = UUID(uuidString: String(identifiers[..<split])),
                  let transactionID = UUID(uuidString: String(identifiers[identifiers.index(after: split)...])),
                  name == "\(prefix)\(bottleID.uuidString)-\(transactionID.uuidString)" else { continue }
            groups[bottleID, default: []].append(entry)
        }
        var warnings: [String] = []
        for (id, staged) in groups.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let paths = staged.map(\.path).sorted().joined(separator: ", ")
            guard staged.count == 1, let directory = staged.first,
                  isOwnedDirectory(directory, bottleID: id) else {
                warnings.append("Interrupted deletion needs review; ambiguous or unowned files were preserved at \(paths).")
                continue
            }
            guard state.bottles.contains(where: { $0.id == id }) else {
                warnings.append("A completed deletion left files preserved at \(paths). Review them before removing them manually.")
                continue
            }
            let destination = bottlesURL.appendingPathComponent(id.uuidString, isDirectory: true)
            guard !itemExists(destination) else {
                warnings.append("Interrupted deletion has both a current bottle and staged files. Both were preserved: \(paths).")
                continue
            }
            do { try manager.moveItem(at: directory, to: destination) }
            catch { warnings.append("Could not restore interrupted deletion; files remain at \(paths). \(error.localizedDescription)") }
        }
        return warnings
    }

    private func isOwnedDirectory(_ url: URL, bottleID: UUID) -> Bool {
        guard (try? manager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeDirectory else { return false }
        let markerURL = url.appendingPathComponent(Self.markerName)
        guard (try? manager.attributesOfItem(atPath: markerURL.path)[.type]) as? FileAttributeType == .typeRegular,
              let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(Ownership.self, from: data) else { return false }
        return marker.owner == Self.ownerID && marker.bottleID == bottleID
    }

    private func itemExists(_ url: URL) -> Bool {
        (try? manager.attributesOfItem(atPath: url.path)) != nil
    }

    private static func rejectSymlink(_ url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw PortsideError.unsafeBottle("Symbolic links cannot be used for managed data: \(url.path)")
        }
    }
}
