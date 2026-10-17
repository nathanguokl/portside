import XCTest
import PortsideCore
@testable import Portside

/// A controllable filesystem-scan stand-in. Deliberately ignores cancellation
/// while blocked so the frontend must also reject stale scan results.
private final class ScanProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked: Set<UUID>
    private var results: [UUID: [InstalledAppCandidate]]
    private var starts: [UUID] = []
    private var finished: Set<UUID> = []
    private var scannedOnMainThread = false

    init(results: [UUID: [InstalledAppCandidate]], blocked: Set<UUID> = []) {
        self.results = results; self.blocked = blocked
    }
    func scan(_ bottle: Bottle) -> [InstalledAppCandidate] {
        condition.lock(); defer { condition.unlock() }
        starts.append(bottle.id)
        scannedOnMainThread = scannedOnMainThread || Thread.isMainThread
        while blocked.contains(bottle.id) { condition.wait() }
        finished.insert(bottle.id)
        return results[bottle.id] ?? []
    }
    func release(_ id: UUID) { condition.lock(); blocked.remove(id); condition.broadcast(); condition.unlock() }
    func releaseAll() { condition.lock(); blocked.removeAll(); condition.broadcast(); condition.unlock() }
    func hasStarted(_ id: UUID) -> Bool { condition.lock(); defer { condition.unlock() }; return starts.contains(id) }
    func hasFinished(_ id: UUID) -> Bool { condition.lock(); defer { condition.unlock() }; return finished.contains(id) }
    func count(_ id: UUID) -> Int { condition.lock(); defer { condition.unlock() }; return starts.filter { $0 == id }.count }
    func setResults(_ values: [InstalledAppCandidate], for id: UUID) { condition.lock(); results[id] = values; condition.unlock() }
    var ranOnMainThread: Bool { condition.lock(); defer { condition.unlock() }; return scannedOnMainThread }
}

@MainActor final class InstalledAppReviewTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Portside discovery UI \(UUID().uuidString) 空間")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func runtime(_ root: URL) throws -> WineRuntime {
        let bin = root.appendingPathComponent("Fixture Runtime/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["wine", "wineboot", "wineserver"] {
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then printf 'wine-fixture\\n'; fi\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return WineRuntime(wineURL: bin.appendingPathComponent("wine"), version: "wine-fixture", source: "Isolated fixture")
    }
    private func bottle(_ store: LibraryStore, runtime: WineRuntime, name: String) throws -> Bottle {
        let bottle = try store.createBottle(name: name, runtime: runtime)
        try store.markBottleInitialized(id: bottle.id)
        return try store.requireBottle(id: bottle.id)
    }
    private func executable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes[64] = 0x50; bytes[65] = 0x45; bytes[68] = 0x64; bytes[69] = 0x86
        bytes[84] = 240; bytes[86] = 2; bytes[88] = 0x0b; bytes[89] = 0x02; bytes[156] = 2
        try Data(bytes).write(to: url)
    }
    private func candidate(_ store: LibraryStore, bottle: Bottle, name: String = "Installed Game") throws -> InstalledAppCandidate {
        let exe = try store.bottleURL(for: bottle).appendingPathComponent("drive_c/Program Files/\(name)/VLauncher.exe")
        try executable(exe)
        return InstalledAppCandidate(name: name, executableURL: exe, workingDirectoryURL: exe.deletingLastPathComponent(), bottleID: bottle.id)
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    private func settle() async { for _ in 0..<12 { await Task.yield() } }

    func testScanRunsOffMainThreadAndOnlySuggestsUntilUserAdds() async throws {
        let root = try scratch(), wine = try runtime(root)
        let library = root.appendingPathComponent("Library"), store = try LibraryStore(rootURL: library)
        let bottle = try bottle(store, runtime: wine, name: "Game bottle"), found = try candidate(store, bottle: bottle)
        let probe = ScanProbe(results: [bottle.id: [found]])
        let model = AppModel(rootURL: library, startsBackgroundWork: false, installedAppScanner: { b, _, _ in probe.scan(b) })
        defer { model.cancelInstalledAppDiscovery() }
        model.requestInstalledAppDiscovery(userInitiated: true)
        try await eventually { model.installedAppCandidates.count == 1 }
        XCTAssertFalse(probe.ranOnMainThread)
        XCTAssertTrue(model.state.apps.isEmpty)
        XCTAssertNil(model.logURL)
        XCTAssertTrue(try XCTUnwrap(model.processes).running.isEmpty)
        XCTAssertNil(model.sheet)

        model.addDiscoveredApp(found, launchAfterAdding: false)
        XCTAssertEqual(model.state.apps.count, 1)
        XCTAssertEqual(model.state.apps.first?.bottleID, bottle.id)
        XCTAssertEqual(model.state.apps.first?.executableURL, found.executableURL)
        XCTAssertEqual(model.state.apps.first?.workingDirectoryURL, found.workingDirectoryURL)
        XCTAssertNil(model.logURL)
        XCTAssertTrue(model.installedAppCandidates.isEmpty)
        XCTAssertEqual(try LibraryStore(rootURL: library).state.apps.count, 1)
    }

    func testAddAndLaunchUsesChosenCandidateWithoutRerunningDownloader() async throws {
        let root = try scratch(), wine = try runtime(root), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library), bottle = try bottle(store, runtime: wine, name: "Game")
        let found = try candidate(store, bottle: bottle)
        let downloader = root.appendingPathComponent("downloader.exe")
        try executable(downloader)
        _ = try store.registerApp(name: "Downloader", executableURL: downloader, bottleID: bottle.id)
        let model = AppModel(rootURL: library, startsBackgroundWork: false, installedAppScanner: { _, _, _ in [found] })
        defer { model.cancelInstalledAppDiscovery(); model.processes?.shutdownStatusWatchers() }
        model.requestInstalledAppDiscovery()
        try await eventually { model.installedAppCandidates.count == 1 }
        model.addDiscoveredApp(found, launchAfterAdding: true)
        try await eventually { !model.busy && model.logURL != nil }
        XCTAssertEqual(model.state.apps.count, 2)
        XCTAssertTrue(model.logText.contains(found.executableURL.path))
        XCTAssertFalse(model.logText.contains(downloader.path))
        XCTAssertEqual(model.selected, bottle.id)
    }

    func testChangingBottlesDiscardsLateScanWithoutOverwritingNewResults() async throws {
        let root = try scratch(), wine = try runtime(root), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library)
        let first = try bottle(store, runtime: wine, name: "First"), second = try bottle(store, runtime: wine, name: "Second")
        let old = try candidate(store, bottle: first, name: "Old"), fresh = try candidate(store, bottle: second, name: "Fresh")
        let probe = ScanProbe(results: [first.id: [old], second.id: [fresh]], blocked: [first.id])
        let model = AppModel(rootURL: library, startsBackgroundWork: false, installedAppScanner: { b, _, _ in probe.scan(b) })
        defer { probe.releaseAll(); model.cancelInstalledAppDiscovery() }
        model.selected = first.id
        model.requestInstalledAppDiscovery()
        try await eventually { probe.hasStarted(first.id) }
        model.selected = second.id
        model.requestInstalledAppDiscovery()
        try await eventually { model.installedAppCandidates == [fresh] }
        probe.release(first.id)
        try await eventually { probe.hasFinished(first.id) }
        await settle()
        XCTAssertEqual(model.installedAppCandidates, [fresh])
        XCTAssertFalse(model.isDiscoveringInstalledApps)
        XCTAssertTrue(model.state.apps.isEmpty)
    }

    func testFinderQueueAndExistingEditorTakePriorityOverDiscovery() async throws {
        let root = try scratch(), wine = try runtime(root), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library), bottle = try bottle(store, runtime: wine, name: "Game")
        let found = try candidate(store, bottle: bottle), external = root.appendingPathComponent("Another Installer.exe")
        try executable(external)
        let probe = ScanProbe(results: [bottle.id: [found]])
        let model = AppModel(rootURL: library, startsBackgroundWork: false, installedAppScanner: { b, _, _ in probe.scan(b) })
        defer { model.cancelInstalledAppDiscovery() }
        model.sheet = .rename
        model.requestInstalledAppDiscovery(userInitiated: true)
        model.openFiles([external])
        await settle()
        XCTAssertFalse(probe.hasStarted(bottle.id))
        XCTAssertEqual(model.sheet, .rename)
        model.sheet = nil; model.sheetDidDismiss()
        await settle()
        XCTAssertEqual(model.externalOpen?.url, external)
        XCTAssertFalse(probe.hasStarted(bottle.id))
        model.sheet = nil; model.sheetDidDismiss()
        try await eventually { model.installedAppCandidates == [found] }
        XCTAssertNil(model.sheet)
        XCTAssertNil(model.logURL)
    }

    func testNativePanelAndErrorHoldDiscoveryUntilBothAreClosed() async throws {
        let root = try scratch(), wine = try runtime(root), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library), bottle = try bottle(store, runtime: wine, name: "Game")
        let found = try candidate(store, bottle: bottle), probe = ScanProbe(results: [bottle.id: [found]])
        let model = AppModel(rootURL: library, startsBackgroundWork: false, installedAppScanner: { b, _, _ in probe.scan(b) })
        defer { model.cancelInstalledAppDiscovery() }
        model.beginNativePanel(); model.error = "Current error"
        model.requestInstalledAppDiscovery()
        await settle()
        XCTAssertFalse(probe.hasStarted(bottle.id))
        model.endNativePanel()
        await settle()
        XCTAssertFalse(probe.hasStarted(bottle.id))
        model.error = nil
        try await eventually { model.installedAppCandidates == [found] }
    }

    func testDeletedBottleCannotAcceptItsLateCandidates() async throws {
        let root = try scratch(), wine = try runtime(root), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library), bottle = try bottle(store, runtime: wine, name: "Removed")
        let found = try candidate(store, bottle: bottle), probe = ScanProbe(results: [bottle.id: [found]], blocked: [bottle.id])
        let model = AppModel(rootURL: library, startsBackgroundWork: false, installedAppScanner: { b, _, _ in probe.scan(b) })
        defer { probe.releaseAll(); model.cancelInstalledAppDiscovery() }
        model.requestInstalledAppDiscovery()
        try await eventually { probe.hasStarted(bottle.id) }
        try LibraryStore(rootURL: library).deleteBottle(id: bottle.id)
        probe.release(bottle.id)
        try await eventually { !model.isDiscoveringInstalledApps }
        XCTAssertTrue(model.installedAppCandidates.isEmpty)
        XCTAssertTrue(model.state.apps.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.installedDiscoveryMessage)
    }

    func testDriveReplacedWithOutsideSymlinkCannotBeAddedOrLaunched() async throws {
        let root = try scratch(), wine = try runtime(root), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library), bottle = try bottle(store, runtime: wine, name: "Game")
        let found = try candidate(store, bottle: bottle)
        let model = AppModel(rootURL: library, startsBackgroundWork: false, installedAppScanner: { _, _, _ in [found] })
        defer { model.cancelInstalledAppDiscovery() }
        model.requestInstalledAppDiscovery()
        try await eventually { model.installedAppCandidates == [found] }
        let prefix = try store.bottleURL(for: bottle), drive = prefix.appendingPathComponent("drive_c")
        try FileManager.default.moveItem(at: drive, to: prefix.appendingPathComponent("preserved_drive"))
        let outside = root.appendingPathComponent("Outside files")
        let outsideExe = outside.appendingPathComponent("Program Files/Installed Game/VLauncher.exe")
        try executable(outsideExe)
        try FileManager.default.createSymbolicLink(at: drive, withDestinationURL: outside)
        model.addDiscoveredApp(found, launchAfterAdding: true)
        XCTAssertTrue(model.state.apps.isEmpty)
        XCTAssertNil(model.logURL)
        XCTAssertTrue(model.installedDiscoveryMessage?.contains("symbolic link") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideExe.path))
    }

    func testConcurrentRegistrationUsesExistingSavedLaunchSettings() async throws {
        let root = try scratch(), wine = try runtime(root), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library), bottle = try bottle(store, runtime: wine, name: "Game")
        let found = try candidate(store, bottle: bottle)
        let model = AppModel(rootURL: library, startsBackgroundWork: false, installedAppScanner: { _, _, _ in [found] })
        defer { model.cancelInstalledAppDiscovery(); model.processes?.shutdownStatusWatchers() }
        model.requestInstalledAppDiscovery()
        try await eventually { model.installedAppCandidates == [found] }
        let app = try LibraryStore(rootURL: library).registerApp(name: "Chosen settings", executableURL: found.executableURL,
                                                               bottleID: bottle.id, workingDirectory: root, arguments: ["saved argument 中文"])
        model.addDiscoveredApp(found, launchAfterAdding: true)
        XCTAssertEqual(model.state.apps.map(\.id), [app.id])
        try await eventually { !model.busy && model.logURL != nil }
        XCTAssertTrue(model.logText.contains("saved argument 中文"))
        XCTAssertTrue(model.logText.contains(root.path))
    }

    func testAutomaticEmptySearchIsQuietAndManualEmptySearchExplainsFallback() async throws {
        let root = try scratch(), wine = try runtime(root), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library), bottle = try bottle(store, runtime: wine, name: "Empty")
        let probe = ScanProbe(results: [bottle.id: []])
        let model = AppModel(rootURL: library, startsBackgroundWork: false, installedAppScanner: { b, _, _ in probe.scan(b) })
        defer { model.cancelInstalledAppDiscovery() }
        model.requestInstalledAppDiscovery()
        try await eventually { probe.hasFinished(bottle.id) && !model.isDiscoveringInstalledApps }
        XCTAssertNil(model.installedDiscoveryMessage)
        model.requestInstalledAppDiscovery(userInitiated: true)
        try await eventually { model.installedDiscoveryMessage != nil }
        XCTAssertTrue(model.installedDiscoveryMessage?.contains("Add Manually") == true)
        XCTAssertNil(model.error)
        XCTAssertNil(model.sheet)
    }

    func testSearchFailureStaysInlineWithoutOpeningAnAlertOrSheet() async throws {
        let root = try scratch(), wine = try runtime(root), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library)
        _ = try bottle(store, runtime: wine, name: "Game")
        let model = AppModel(rootURL: library, startsBackgroundWork: false, installedAppScanner: { _, _, _ in
            throw PortsideError.commandFailed("Search limit reached. Use Add Manually.")
        })
        defer { model.cancelInstalledAppDiscovery() }
        model.requestInstalledAppDiscovery()
        try await eventually { model.installedDiscoveryMessage != nil }
        XCTAssertTrue(model.installedDiscoveryMessage?.contains("Search limit") == true)
        XCTAssertNil(model.error)
        XCTAssertNil(model.sheet)
        XCTAssertNil(model.logURL)
    }

    func testManualEmptySearchDistinguishesSavedAppsWithoutLaunchingThem() async throws {
        let root = try scratch(), wine = try runtime(root), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library)
        let empty = try bottle(store, runtime: wine, name: "Empty")
        let saved = try bottle(store, runtime: wine, name: "Saved application")
        let found = try candidate(store, bottle: saved)
        let app = try store.registerApp(name: found.name, executableURL: found.executableURL, bottleID: saved.id)
        let model = AppModel(rootURL: library, startsBackgroundWork: false, installedAppScanner: { _, _, _ in [] })
        defer { model.cancelInstalledAppDiscovery(); model.processes?.shutdownStatusWatchers() }

        model.selected = empty.id
        model.requestInstalledAppDiscovery(userInitiated: true)
        try await eventually { model.installedDiscoveryMessage != nil }
        XCTAssertTrue(model.installedDiscoveryMessage?.contains("Add Manually") == true,
                      "Another bottle's saved entry must not hide manual-registration guidance")

        model.selected = saved.id
        model.requestInstalledAppDiscovery(userInitiated: true)
        try await eventually { model.installedDiscoveryMessage != nil }
        XCTAssertEqual(model.installedDiscoveryMessage, "No additional launchers found. Your saved apps are listed below.")
        XCTAssertEqual(model.state.apps, [app])
        XCTAssertTrue(model.installedAppCandidates.isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.processes).running.isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.processes).completed.isEmpty)
        XCTAssertNil(model.logURL)
        XCTAssertNil(model.sheet)
        XCTAssertNil(model.error)
        XCTAssertEqual(try LibraryStore(rootURL: library).state.apps, [app])
    }

    func testApplicationCompletionRequestsReviewWithoutAutomaticallyRegistering() async throws {
        try await verifyAutomaticReview(triggerWithRunningStatus: false)
    }

    func testRunningBottlePeriodicCheckRequestsReviewWithoutWaitingForCompletion() async throws {
        try await verifyAutomaticReview(triggerWithRunningStatus: true)
    }

    private func verifyAutomaticReview(triggerWithRunningStatus: Bool) async throws {
        let root = try scratch(), wine = try runtime(root), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library)
        try store.setRuntime(wine)
        let bottle = try bottle(store, runtime: wine, name: "Active setup"), found = try candidate(store, bottle: bottle)
        let probe = ScanProbe(results: [bottle.id: []])
        // All startup commands point to isolated no-op scripts, not a real Wine runtime.
        let model = AppModel(rootURL: library, startsBackgroundWork: true, installedAppScanner: { b, _, _ in probe.scan(b) })
        defer { model.cancelInstalledAppDiscovery(); model.processes?.shutdownStatusWatchers() }
        try await eventually { probe.count(bottle.id) >= 1 && !model.isDiscoveringInstalledApps }
        let initialCount = probe.count(bottle.id)
        probe.setResults([found], for: bottle.id)
        if triggerWithRunningStatus {
            model.processes?.onCompletion = nil
            // Recognition is asynchronous. Keep this owned fixture alive long
            // enough to observe a running app after the launch task yields.
            try Data("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then printf 'wine-fixture\\n'; else sleep 1; fi\nexit 0\n".utf8)
                .write(to: wine.wineURL)
        }
        let setup = root.appendingPathComponent("downloader.exe")
        try executable(setup)
        try model.runExternalExecutable(setup, bottleID: bottle.id, remember: false)
        try await eventually { !model.busy && model.logURL != nil }
        if triggerWithRunningStatus {
            XCTAssertTrue(model.isRunning(bottle))
            model.discoverWhileBottleIsRunning()
        }
        try await eventually { model.installedAppCandidates == [found] }
        XCTAssertGreaterThan(probe.count(bottle.id), initialCount)
        XCTAssertTrue(model.state.apps.isEmpty)
        XCTAssertNil(model.sheet)
    }

    func testInstalledLauncherSortsBeforeDownloaderWithoutMislabelingDownloadManager() {
        let bottleID = UUID()
        let downloader = WindowsApp(name: "A Downloader", executablePath: "/tmp/downloader.exe", workingDirectory: "/tmp", bottleID: bottleID)
        let launcher = WindowsApp(name: "Z Game Launcher", executablePath: "/tmp/VLauncher.exe", workingDirectory: "/tmp", bottleID: bottleID)
        let manager = WindowsApp(name: "Download Manager", executablePath: "/tmp/IDMan.exe", workingDirectory: "/tmp", bottleID: bottleID)
        let sorted = LibraryEntryPresentation.sorted([downloader, launcher, manager])
        XCTAssertEqual(sorted.last?.id, downloader.id)
        XCTAssertFalse(LibraryEntryPresentation.isSetupTool(launcher))
        XCTAssertFalse(LibraryEntryPresentation.isSetupTool(manager))
        XCTAssertTrue(LibraryEntryPresentation.isSetupTool(downloader))
    }
}
