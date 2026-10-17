import XCTest
import AppKit
import PortsideCore
@testable import Portside

@MainActor final class FrontendFlowTests: XCTestCase {
    private func scratchDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Portside frontend tests \(UUID().uuidString) 空間")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func runtime(in root: URL, name: String = "Runtime") throws -> WineRuntime {
        let bin = root.appendingPathComponent(name).appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // These fixtures never execute Wine or display Windows UI.
        for name in ["wine", "wineboot", "wineserver"] {
            let file = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return WineRuntime(wineURL: bin.appendingPathComponent("wine"), version: "wine-fixture", source: "Isolated frontend test",
                           validatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func executable(in root: URL) throws -> URL {
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes[64] = 0x50; bytes[65] = 0x45
        bytes[68] = 0x64; bytes[69] = 0x86
        bytes[84] = 240; bytes[86] = 2
        bytes[88] = 0x0b; bytes[89] = 0x02
        let url = root.appendingPathComponent("External App 中文.exe")
        try Data(bytes).write(to: url)
        return url
    }

    private func addBottle(_ name: String, to model: AppModel, runtime: WineRuntime) throws -> Bottle {
        let store = try XCTUnwrap(model.store)
        let bottle = try store.createBottle(name: name, runtime: runtime)
        try store.markBottleInitialized(id: bottle.id)
        model.sync()
        return try store.requireBottle(id: bottle.id)
    }

    private func settleQueue() async {
        for _ in 0..<12 { await Task.yield() }
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testDeletionKeepsCapturedTargetAndHoldsIncomingFiles() async throws {
        let root = try scratchDirectory(), wine = try runtime(in: root)
        let model = AppModel(rootURL: root.appendingPathComponent("Library"), startsBackgroundWork: false)
        defer { model.processes?.shutdownStatusWatchers() }
        let first = try addBottle("Delete this one", to: model, runtime: wine)
        let second = try addBottle("Keep this one", to: model, runtime: wine)
        model.selected = first.id
        model.requestDeletion(first)
        let dialogTarget = try XCTUnwrap(model.deletionTarget)

        model.selected = second.id
        model.openFiles([try executable(in: root)])
        await settleQueue()
        XCTAssertEqual(model.deletionTarget?.id, first.id)
        XCTAssertNil(model.externalOpen)
        XCTAssertEqual(model.queuedOpenURLs.count, 1)

        // SwiftUI may clear the presentation binding before invoking the action.
        model.dismissDeletionConfirmation()
        model.confirmDeletion(dialogTarget)
        try await eventually { !model.busy }
        await settleQueue()
        XCTAssertEqual(model.state.bottles.map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(model.store).bottleURL(for: second).path))
        let request = try XCTUnwrap(model.externalOpen)
        guard case .chooseBottle(let choices) = request.action else { return XCTFail("Expected a bottle picker") }
        XCTAssertEqual(choices.map(\.id), [second.id])
    }

    func testCancellingDeletionResumesPendingFileWithoutRemovingBottle() async throws {
        let root = try scratchDirectory(), wine = try runtime(in: root)
        let model = AppModel(rootURL: root.appendingPathComponent("Library"), startsBackgroundWork: false)
        let bottle = try addBottle("Keep", to: model, runtime: wine)
        model.requestDeletion(bottle)
        model.openFiles([try executable(in: root)])
        await settleQueue()
        XCTAssertNil(model.externalOpen)
        model.dismissDeletionConfirmation()
        await settleQueue()
        XCTAssertEqual(model.state.bottles.map(\.id), [bottle.id])
        XCTAssertNotNil(model.externalOpen)
    }

    func testNestedNativePanelsDeferFileOpeningUntilLastPanelCloses() async throws {
        let root = try scratchDirectory(), wine = try runtime(in: root)
        let model = AppModel(rootURL: root.appendingPathComponent("Library"), startsBackgroundWork: false)
        _ = try addBottle("Ready", to: model, runtime: wine)
        model.beginNativePanel()
        model.beginNativePanel()
        model.openFiles([try executable(in: root)])
        await settleQueue()
        XCTAssertNil(model.externalOpen)
        model.endNativePanel()
        await settleQueue()
        XCTAssertNil(model.externalOpen)
        model.endNativePanel()
        await settleQueue()
        XCTAssertNotNil(model.externalOpen)
    }

    func testCancelledNativePanelReleasesPendingFile() async throws {
        let root = try scratchDirectory(), wine = try runtime(in: root)
        let model = AppModel(rootURL: root.appendingPathComponent("Library"), startsBackgroundWork: false)
        _ = try addBottle("Ready", to: model, runtime: wine)
        let exe = try executable(in: root)
        let response = model.withNativePanel {
            model.openFiles([exe])
            return NSApplication.ModalResponse.cancel
        }
        XCTAssertEqual(response, .cancel)
        XCTAssertEqual(model.nativePanelDepth, 0)
        await settleQueue()
        XCTAssertNotNil(model.externalOpen)
    }

    func testSlowStartupSuccessCannotReplaceManualRuntimeSelection() async throws {
        try await verifySupersededStartup(fails: false)
    }

    func testSlowStartupFailureCannotReportErrorAfterManualSelection() async throws {
        try await verifySupersededStartup(fails: true)
    }

    private func verifySupersededStartup(fails: Bool) async throws {
        let root = try scratchDirectory()
        let old = try runtime(in: root, name: "Old"), new = try runtime(in: root, name: "New")
        var continuation: CheckedContinuation<WineRuntime, Error>?
        let model = AppModel(rootURL: root.appendingPathComponent("Library"), startsBackgroundWork: false) { url, source in
            if url == old.wineURL {
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            return WineRuntime(wineURL: url, version: "wine-new", source: source)
        }
        try XCTUnwrap(model.store).setRuntime(old)
        model.sync()
        let startup = Task { await model.checkRuntime() }
        try await eventually { continuation != nil }
        _ = try await model.useRuntime(at: new.wineURL, source: "Explicit user selection")
        let pending = try XCTUnwrap(continuation)
        if fails { pending.resume(throwing: PortsideError.invalidRuntime("Old runtime failed")) }
        else { pending.resume(returning: old) }
        await startup.value

        XCTAssertEqual(model.state.runtime?.wineURL, new.wineURL)
        XCTAssertEqual(model.state.runtime?.source, "Explicit user selection")
        XCTAssertEqual(model.runtimeStatus, "wine-new")
        XCTAssertNil(model.error)
        XCTAssertEqual(try LibraryStore(rootURL: root.appendingPathComponent("Library")).state.runtime?.wineURL, new.wineURL)
    }

    func testManualSelectionBeforeStartupTaskPreventsAutomaticProbe() async throws {
        let root = try scratchDirectory(), wine = try runtime(in: root)
        var calls = 0
        let model = AppModel(rootURL: root.appendingPathComponent("Library"), startsBackgroundWork: false) { _, _ in
            calls += 1
            return wine
        }
        _ = try await model.useRuntime(at: wine.wineURL, source: "Manual")
        await model.checkRuntime()
        XCTAssertEqual(calls, 1)
    }

    func testFailedManualSelectionEndsCheckingStatusAndPreservesCommittedRuntime() async throws {
        let root = try scratchDirectory(), old = try runtime(in: root)
        let candidate = root.appendingPathComponent("Invalid candidate/wine")
        var continuation: CheckedContinuation<WineRuntime, Error>?
        let model = AppModel(rootURL: root.appendingPathComponent("Library"), startsBackgroundWork: false) { url, _ in
            if url == old.wineURL {
                return try await withCheckedThrowingContinuation { continuation = $0 }
            }
            throw PortsideError.invalidRuntime("The candidate is unavailable")
        }
        try XCTUnwrap(model.store).setRuntime(old)
        model.sync()
        let startup = Task { await model.checkRuntime() }
        try await eventually { continuation != nil }
        do {
            _ = try await model.useRuntime(at: candidate, source: "Rejected selection")
            XCTFail("The candidate must fail validation")
        } catch { XCTAssertTrue(error.localizedDescription.contains("candidate is unavailable")) }
        try XCTUnwrap(continuation).resume(returning: old)
        await startup.value
        XCTAssertEqual(model.runtimeStatus, "Runtime selection failed")
        XCTAssertEqual(model.state.runtime, old)
        XCTAssertNil(model.error)
    }

    func testStartupSuccessCannotReplaceExternalRuntimeSelection() async throws {
        try await verifyExternalSelectionDuringStartup(clearSelection: false, fails: false)
    }

    func testStartupFailureDoesNotReportStaleErrorAfterExternalSelection() async throws {
        try await verifyExternalSelectionDuringStartup(clearSelection: false, fails: true)
    }

    func testStartupSuccessCannotRestoreRuntimeClearedExternally() async throws {
        try await verifyExternalSelectionDuringStartup(clearSelection: true, fails: false)
    }

    func testStartupFailureDoesNotReportStaleErrorAfterExternalClear() async throws {
        try await verifyExternalSelectionDuringStartup(clearSelection: true, fails: true)
    }

    private func verifyExternalSelectionDuringStartup(clearSelection: Bool, fails: Bool) async throws {
        let root = try scratchDirectory(), library = root.appendingPathComponent("Library")
        let old = try runtime(in: root, name: "Startup"), new = try runtime(in: root, name: "External")
        var continuation: CheckedContinuation<WineRuntime, Error>?
        let model = AppModel(rootURL: library, startsBackgroundWork: false) { _, _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        try XCTUnwrap(model.store).setRuntime(old)
        model.sync()
        let startup = Task { await model.checkRuntime() }
        try await eventually { continuation != nil }
        let replacement: WineRuntime? = clearSelection ? nil : new
        try LibraryStore(rootURL: library).setRuntime(replacement)
        let pending = try XCTUnwrap(continuation)
        if fails { pending.resume(throwing: PortsideError.invalidRuntime("Stale startup failure")) }
        else { pending.resume(returning: old) }
        await startup.value

        XCTAssertEqual(model.state.runtime, replacement)
        XCTAssertEqual(try LibraryStore(rootURL: library).state.runtime, replacement)
        XCTAssertEqual(model.runtimeStatus, replacement?.version ?? "Wine setup required")
        XCTAssertNil(model.error)
    }

    func testFinderRequestUsesRegistrationAddedByAnotherStore() async throws {
        let root = try scratchDirectory(), wine = try runtime(in: root)
        let library = root.appendingPathComponent("Library")
        let model = AppModel(rootURL: library, startsBackgroundWork: false)
        defer { model.processes?.shutdownStatusWatchers() }
        let bottle = try addBottle("Existing", to: model, runtime: wine)
        let exe = try executable(in: root)
        let otherStore = try LibraryStore(rootURL: library)
        _ = try otherStore.registerApp(name: "Added elsewhere", executableURL: exe, bottleID: bottle.id,
                                       workingDirectory: root, arguments: ["argument with spaces 中文"])
        XCTAssertTrue(model.state.apps.isEmpty)
        model.openFiles([exe])
        try await eventually { model.logURL != nil }
        XCTAssertNil(model.externalOpen)
        XCTAssertEqual(model.state.apps.first?.name, "Added elsewhere")
        XCTAssertTrue(model.logText.contains("argument with spaces 中文"))
    }

    func testRemovedLibraryEntryIsNotLaunchedFromStaleFrontend() throws {
        let root = try scratchDirectory(), wine = try runtime(in: root)
        let library = root.appendingPathComponent("Library")
        let model = AppModel(rootURL: library, startsBackgroundWork: false)
        let bottle = try addBottle("Existing", to: model, runtime: wine)
        let app = try XCTUnwrap(model.store).registerApp(name: "Removed elsewhere", executableURL: executable(in: root), bottleID: bottle.id)
        model.sync()
        try LibraryStore(rootURL: library).deleteApp(id: app.id)
        model.launch(app)
        XCTAssertTrue(model.state.apps.isEmpty)
        XCTAssertNil(model.logURL)
        XCTAssertTrue(model.error?.contains("removed from the library") == true)
    }

    func testRecoveryWarningBlocksFilesUntilAcknowledgedWithoutRepeatingForever() async throws {
        let root = try scratchDirectory(), library = root.appendingPathComponent("Library")
        let store = try LibraryStore(rootURL: library)
        let staged = store.bottlesURL.appendingPathComponent(".deleting-\(UUID().uuidString)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        let model = AppModel(rootURL: library, startsBackgroundWork: false)
        XCTAssertTrue(model.error?.contains(staged.path) == true)
        model.openFiles([try executable(in: root)])
        await settleQueue()
        XCTAssertNil(model.externalOpen)
        XCTAssertEqual(model.queuedOpenURLs.count, 1)
        model.error = nil
        await settleQueue()
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.externalOpen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func testFailedCatalogRefreshPreservesPendingFileForRetry() async throws {
        let root = try scratchDirectory(), wine = try runtime(in: root)
        let model = AppModel(rootURL: root.appendingPathComponent("Library"), startsBackgroundWork: false)
        _ = try addBottle("Ready", to: model, runtime: wine)
        let catalog = try XCTUnwrap(model.store).stateURL
        let saved = try Data(contentsOf: catalog)
        try Data("temporarily unreadable catalog".utf8).write(to: catalog)
        model.openFiles([try executable(in: root)])
        await settleQueue()
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.queuedOpenURLs.count, 1)
        XCTAssertNil(model.externalOpen)
        try saved.write(to: catalog)
        model.error = nil
        await settleQueue()
        XCTAssertNotNil(model.externalOpen)
        XCTAssertTrue(model.queuedOpenURLs.isEmpty)
    }

    func testActivationRefreshDoesNotRetargetAnOpenBottleEditor() throws {
        let root = try scratchDirectory(), wine = try runtime(in: root)
        let library = root.appendingPathComponent("Library")
        let model = AppModel(rootURL: library, startsBackgroundWork: false)
        let first = try addBottle("Being edited", to: model, runtime: wine)
        let second = try addBottle("Keep", to: model, runtime: wine)
        model.selected = first.id
        model.sheet = .rename
        try LibraryStore(rootURL: library).deleteBottle(id: first.id)
        model.refreshLibrary()
        XCTAssertEqual(model.selected, first.id)
        XCTAssertNil(model.bottle)
        XCTAssertTrue(model.error?.contains("removed by another Portside process") == true)
        model.error = nil
        XCTAssertFalse(model.apply(BottleSettings(windowsVersion: .win7)))
        XCTAssertTrue(model.error?.contains("no longer available") == true)
        XCTAssertEqual(model.state.bottles.first?.settings.windowsVersion, second.settings.windowsVersion)
        model.sheet = nil
        model.sheetDidDismiss()
        XCTAssertEqual(model.selected, second.id)
    }

    func testDefaultHandlerDistinguishesSameIdentifierCopiesAndAllowsSymlink() throws {
        let root = try scratchDirectory()
        func bundle(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name + ".app")
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "dev.portside.test-copy", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }
        let installed = try bundle("Installed"), older = try bundle("Older Copy")
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: installed)
        XCTAssertFalse(FileAssociation.isDefaultApplication(older, currentApplicationURL: installed))
        XCTAssertTrue(FileAssociation.isDefaultApplication(installed, currentApplicationURL: installed))
        XCTAssertTrue(FileAssociation.isDefaultApplication(alias, currentApplicationURL: installed))
    }
}
