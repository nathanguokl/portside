import XCTest
import Darwin
@testable import PortsideCore

final class LibraryStoreSafetyTests: XCTestCase {
    private let runtime = WineRuntime(wineURL: URL(fileURLWithPath: "/fixture-only/bin/wine"),
                                      version: "fixture-only", source: "No Wine process is executed")

    @MainActor func testStaleWritersPreserveOtherBottlesAppsAndSettings() throws {
        let root = try temporaryDirectory()
        let firstWriter = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let secondWriter = try LibraryStore(rootURL: firstWriter.rootURL)
        let first = try firstWriter.createBottle(name: "First", runtime: runtime)
        let second = try secondWriter.createBottle(name: "Second", runtime: runtime)
        let app = try firstWriter.registerApp(name: "Saved app", executableURL: executable(in: root), bottleID: first.id,
                                              arguments: ["two words", "日本語"])
        let settings = BottleSettings(windowsVersion: .win11, debugLogging: true, locale: .simplifiedChinese)
        try secondWriter.updateSettings(bottleID: second.id, settings: settings)
        try firstWriter.renameBottle(id: first.id, name: "Renamed first")
        try secondWriter.setRuntime(runtime)

        let reloaded = try LibraryStore(rootURL: firstWriter.rootURL)
        XCTAssertEqual(Set(reloaded.state.bottles.map(\.id)), [first.id, second.id])
        XCTAssertEqual(try reloaded.requireBottle(id: first.id).name, "Renamed first")
        XCTAssertEqual(try reloaded.requireBottle(id: second.id).settings, settings)
        XCTAssertEqual(reloaded.state.apps, [app])
        try firstWriter.refresh()
        XCTAssertEqual(firstWriter.state.bottles, reloaded.state.bottles)
        XCTAssertEqual(firstWriter.state.apps, [app])
    }

    @MainActor func testConditionalRuntimeCommitUsesTheCurrentSelectionIncludingNil() throws {
        let root = try temporaryDirectory()
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let other = try LibraryStore(rootURL: store.rootURL)
        let initial = WineRuntime(wineURL: runtime.wineURL, version: "first", source: "First choice",
                                  validatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = WineRuntime(wineURL: URL(fileURLWithPath: "/another-fixture/bin/wine"), version: "second",
                                source: "Newer choice", validatedAt: Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertTrue(try store.setRuntime(initial, ifCurrentMatches: nil))
        XCTAssertFalse(try other.setRuntime(newer, ifCurrentMatches: nil))
        XCTAssertEqual(other.state.runtime, initial)
        XCTAssertTrue(try other.setRuntime(newer, ifCurrentMatches: initial))
        XCTAssertFalse(try store.setRuntime(initial, ifCurrentMatches: initial))
        XCTAssertEqual(store.state.runtime, newer)
        XCTAssertEqual(try LibraryStore(rootURL: store.rootURL).state.runtime, newer)
        XCTAssertFalse(try store.setRuntime(nil, ifCurrentMatches: initial))
        XCTAssertTrue(try store.setRuntime(nil, ifCurrentMatches: newer))
        XCTAssertNil(try LibraryStore(rootURL: store.rootURL).state.runtime)
        XCTAssertTrue(try other.setRuntime(initial, ifCurrentMatches: nil))
    }

    @MainActor func testStaleIndexesAndDeletionUseTheLatestCatalog() throws {
        let root = try temporaryDirectory()
        let firstWriter = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let first = try firstWriter.createBottle(name: "Delete", runtime: runtime)
        let second = try firstWriter.createBottle(name: "Keep", runtime: runtime)
        let exe = try executable(in: root)
        let removed = try firstWriter.registerApp(name: "Remove entry", executableURL: exe, bottleID: second.id)
        var kept = try firstWriter.registerApp(name: "Keep entry", executableURL: exe, bottleID: second.id)
        let staleWriter = try LibraryStore(rootURL: firstWriter.rootURL)
        try firstWriter.deleteApp(id: removed.id)
        kept.name = "Updated after index changed"
        try staleWriter.updateApp(kept)
        let newest = try firstWriter.createBottle(name: "Created after stale snapshot", runtime: runtime)
        let sentinel = try firstWriter.bottleURL(for: newest).appendingPathComponent("keep.txt")
        try Data("other bottle".utf8).write(to: sentinel)
        try staleWriter.deleteBottle(id: first.id)
        XCTAssertThrowsError(try firstWriter.renameBottle(id: first.id, name: "Must not resurrect"))

        let reloaded = try LibraryStore(rootURL: firstWriter.rootURL)
        XCTAssertEqual(Set(reloaded.state.bottles.map(\.id)), [second.id, newest.id])
        XCTAssertEqual(reloaded.state.apps, [kept])
        XCTAssertEqual(try String(contentsOf: sentinel), "other bottle")
    }

    @MainActor func testAnotherProcessCannotWriteThroughAnActiveCatalogLock() async throws {
        let root = try temporaryDirectory()
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Original", runtime: runtime)
        let descriptor = open(store.rootURL.appendingPathComponent(".library.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        var locked = true
        defer { if locked { flock(descriptor, LOCK_UN) } }

        let blocked = try await runCLI(["rename", bottle.id.uuidString, "Child rename"], home: store.rootURL)
        XCTAssertNotEqual(blocked.code, 0)
        XCTAssertTrue(blocked.output.contains("Another Portside process is updating the library"), blocked.output)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        locked = false
        let retried = try await runCLI(["rename", bottle.id.uuidString, "Child rename"], home: store.rootURL)
        XCTAssertEqual(retried.code, 0, retried.output)
        // This store predates the child's write. Its next mutation must preserve the rename.
        try store.setRuntime(runtime)
        XCTAssertEqual(try LibraryStore(rootURL: store.rootURL).requireBottle(id: bottle.id).name, "Child rename")
    }

    @MainActor func testBusyAndFailedSavesDoNotLeaveNewOrStagedBottleDirectories() throws {
        let root = try temporaryDirectory()
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Preserve", runtime: runtime)
        let directory = try store.bottleURL(for: bottle)
        let sentinel = directory.appendingPathComponent("data.txt")
        try Data("preserve".utf8).write(to: sentinel)
        let originalCatalog = try Data(contentsOf: store.stateURL)
        let lock = open(store.rootURL.appendingPathComponent(".library.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(lock, 0)
        guard lock >= 0 else { return }
        defer { close(lock) }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try store.createBottle(name: "Busy", runtime: runtime))
        XCTAssertEqual(flock(lock, LOCK_UN), 0)

        guard geteuid() != 0 else { throw XCTSkip("Root bypasses the read-only-directory fixture") }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.rootURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.rootURL.path) }
        XCTAssertThrowsError(try store.createBottle(name: "Save must fail", runtime: runtime))
        XCTAssertThrowsError(try store.deleteBottle(id: bottle.id))
        XCTAssertEqual(try Data(contentsOf: store.stateURL), originalCatalog)
        XCTAssertEqual(try String(contentsOf: sentinel), "preserve")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.bottlesURL.path), [bottle.directoryName])
        XCTAssertEqual(store.state.bottles.map(\.id), [bottle.id])
    }

    @MainActor func testInterruptedDeletionBeforeCommitRestoresOwnedBottleAndEntries() throws {
        let root = try temporaryDirectory()
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let first = try store.createBottle(name: "Interrupted", runtime: runtime)
        let second = try store.createBottle(name: "Other", runtime: runtime)
        let sentinel = try store.bottleURL(for: second).appendingPathComponent("keep.txt")
        try Data("other bottle".utf8).write(to: sentinel)
        let app = try store.registerApp(name: "Preserved entry", executableURL: executable(in: root), bottleID: first.id)
        let staged = try stage(first, in: store)

        let reopened = try LibraryStore(rootURL: store.rootURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try reopened.bottleURL(for: first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(reopened.state.apps, [app])
        XCTAssertEqual(try String(contentsOf: sentinel), "other bottle")
        XCTAssertTrue(reopened.recoveryWarnings.isEmpty)
    }

    @MainActor func testInterruptedDeletionAfterCommitPreservesRemainingFilesAndReportsPath() throws {
        let root = try temporaryDirectory()
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let removed = try store.createBottle(name: "Committed deletion", runtime: runtime)
        let other = try store.createBottle(name: "Keep", runtime: runtime)
        let staged = try stage(removed, in: store)
        var committed = store.state
        committed.bottles.removeAll { $0.id == removed.id }
        try save(committed, to: store.stateURL)

        let reopened = try LibraryStore(rootURL: store.rootURL)
        XCTAssertEqual(reopened.state.bottles.map(\.id), [other.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.bottlesURL.appendingPathComponent(removed.directoryName).path))
        XCTAssertTrue(reopened.recoveryWarnings.joined().contains(staged.path))
        XCTAssertNoThrow(try reopened.bottleURL(for: other))
    }

    @MainActor func testRecoveryPreservesAmbiguousUnownedAndSymlinkStages() throws {
        for kind in ["ambiguous", "wrong owner", "wrong ID", "directory symlink", "marker symlink"] {
            let root = try temporaryDirectory(kind)
            let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
            let bottle = try store.createBottle(name: "Recover cautiously", runtime: runtime)
            let canonical = try store.bottleURL(for: bottle)
            let staged = try stage(bottle, in: store)
            let marker = staged.appendingPathComponent(".portside-bottle.json")
            let outside = root.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let sentinel = outside.appendingPathComponent("keep.txt")
            try Data("outside".utf8).write(to: sentinel)
            switch kind {
            case "ambiguous":
                try FileManager.default.copyItem(at: staged, to: stagingURL(bottle, in: store))
            case "wrong owner", "wrong ID":
                let value = ["owner": kind == "wrong owner" ? "another app" : "app.portside.mac",
                             "bottleID": kind == "wrong ID" ? UUID().uuidString : bottle.id.uuidString]
                try JSONSerialization.data(withJSONObject: value).write(to: marker)
            case "directory symlink":
                try FileManager.default.moveItem(at: marker, to: outside.appendingPathComponent(marker.lastPathComponent))
                try FileManager.default.removeItem(at: staged)
                try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: outside)
            default:
                let externalMarker = outside.appendingPathComponent(marker.lastPathComponent)
                try FileManager.default.moveItem(at: marker, to: externalMarker)
                try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: externalMarker)
            }
            let reopened = try LibraryStore(rootURL: store.rootURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path), kind)
            XCTAssertNotNil(try? FileManager.default.attributesOfItem(atPath: staged.path), kind)
            XCTAssertTrue(reopened.recoveryWarnings.joined().contains(staged.path), kind)
            XCTAssertEqual(try String(contentsOf: sentinel), "outside", kind)
        }
    }

    @MainActor func testRecoveryDoesNotOverwriteAnExistingBottleOrFollowALockSymlink() throws {
        let root = try temporaryDirectory()
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Current", runtime: runtime)
        let canonical = try store.bottleURL(for: bottle)
        let staged = stagingURL(bottle, in: store)
        try FileManager.default.copyItem(at: canonical, to: staged)
        let sentinel = canonical.appendingPathComponent("current.txt")
        try Data("current".utf8).write(to: sentinel)
        let reopened = try LibraryStore(rootURL: store.rootURL)
        XCTAssertEqual(try String(contentsOf: sentinel), "current")
        XCTAssertTrue(reopened.recoveryWarnings.joined().contains(staged.path))
        let lock = store.rootURL.appendingPathComponent(".library.lock")
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: sentinel)
        XCTAssertThrowsError(try LibraryStore(rootURL: store.rootURL))
        XCTAssertEqual(try String(contentsOf: sentinel), "current")
    }

    @MainActor private func stage(_ bottle: Bottle, in store: LibraryStore) throws -> URL {
        let source = try store.bottleURL(for: bottle)
        let destination = stagingURL(bottle, in: store)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    @MainActor private func stagingURL(_ bottle: Bottle, in store: LibraryStore) -> URL {
        store.bottlesURL.appendingPathComponent(".deleting-\(bottle.id.uuidString)-\(UUID().uuidString)")
    }

    private func save(_ state: LibraryState, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    @MainActor private func runCLI(_ arguments: [String], home: URL) async throws -> (code: Int32, output: String) {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let binary = repository.appendingPathComponent(".build/debug/portside-cli")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Build portside-cli for the subprocess lock check") }
        let process = Process(), output = Pipe()
        process.executableURL = binary; process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PORTSIDE_HOME": home.path]) { _, new in new }
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !process.isRunning else { XCTFail("Catalog-only CLI operation did not finish promptly"); return (-1, "Timed out") }
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
