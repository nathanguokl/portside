import XCTest
import CryptoKit
import PortsideCore
@testable import Portside

@MainActor final class CompatibilityLaunchTests: XCTestCase {
    private func fixture() throws -> (root: URL, exe: URL, model: AppModel, bottle: Bottle) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Portside recognition 空間 \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes[64] = 0x50; bytes[65] = 0x45; bytes[68] = 0x64; bytes[69] = 0x86
        bytes[84] = 240; bytes[86] = 2; bytes[88] = 0x0b; bytes[89] = 0x02
        let exe = root.appendingPathComponent("downloader.exe")
        try Data(bytes).write(to: exe)
        let hash = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        let profile = CompatibilityProfile(id: "fixture", title: "Known fixture", summary: "Isolated recognition check",
                                           components: [.dxvk], executableSHA256: [hash])
        struct Catalog: Encodable { let schemaVersion = 1; let profiles: [CompatibilityProfile] }
        let resources = root.appendingPathComponent("Compatibility")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONEncoder().encode(Catalog(profiles: [profile])).write(to: resources.appendingPathComponent("profiles.json"))
        let bin = root.appendingPathComponent("Wine runtime/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for command in ["wine", "wineboot", "wineserver"] {
            let url = bin.appendingPathComponent(command)
            let script = command == "wine" ? "#!/bin/sh\nprintf '%s\\n' \"$@\"\nexit 0\n" : "#!/bin/sh\nexit 0\n"
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let model = AppModel(rootURL: root.appendingPathComponent("Library"), startsBackgroundWork: false,
                             compatibilitySetup: CompatibilitySetup(resourcesURL: resources))
        let store = try XCTUnwrap(model.store)
        let runtime = WineRuntime(wineURL: bin.appendingPathComponent("wine"), version: "wine-fixture", source: "Fixture")
        let bottle = try store.createBottle(name: "Captured bottle", runtime: runtime)
        try store.markBottleInitialized(id: bottle.id)
        model.sync()
        addTeardownBlock { await MainActor.run { model.processes?.shutdownStatusWatchers() } }
        return (root, exe, model, try store.requireBottle(id: bottle.id))
    }

    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testRecognizedSavedLaunchCapturesBottleArgumentsAndWorkingDirectory() async throws {
        let f = try fixture(), store = try XCTUnwrap(f.model.store)
        let arguments = ["argument with spaces 中文", "$(touch should-never-run)", "--flag"]
        let app = try store.registerApp(name: "Saved known app", executableURL: f.exe, bottleID: f.bottle.id,
                                        workingDirectory: f.root, arguments: arguments)
        let other = try store.createBottle(name: "Other bottle", runtime: f.bottle.runtime)
        try store.markBottleInitialized(id: other.id)
        f.model.sync()
        f.model.launch(app)
        f.model.selected = other.id
        try await eventually { !f.model.busy }
        let pending = try XCTUnwrap(f.model.compatibilityLaunch)
        XCTAssertEqual(pending.bottle.id, f.bottle.id)
        XCTAssertEqual(pending.arguments, arguments)
        XCTAssertEqual(pending.workingDirectory?.path, f.root.path)
        XCTAssertEqual(f.model.sheet, .compatibilityLaunch)
        XCTAssertNil(f.model.logURL, "Recognition must not launch Wine before the user chooses")
        XCTAssertTrue(f.model.runCompatibilityWithoutSetup(pending))
        let log = try String(contentsOf: XCTUnwrap(f.model.logURL))
        XCTAssertTrue(log.contains("argument with spaces 中文"))
        XCTAssertTrue(log.contains("$(touch should-never-run)"))
        XCTAssertEqual(f.model.selected, f.bottle.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("should-never-run").path))
    }

    func testSameFilenameWithDifferentBytesUsesGenericLaunch() async throws {
        let f = try fixture()
        var bytes = try Data(contentsOf: f.exe)
        bytes[511] = 1
        try bytes.write(to: f.exe)
        try f.model.runExternalExecutable(f.exe, bottleID: f.bottle.id, remember: false)
        try await eventually { !f.model.busy }
        XCTAssertNil(f.model.compatibilityLaunch)
        XCTAssertNil(f.model.sheet)
        XCTAssertNotNil(f.model.logURL)
        XCTAssertNil(f.model.error)
    }

    func testExternalPickerDismissesBeforeCompatibilitySheetAndCancellationReleasesQueue() async throws {
        let f = try fixture()
        f.model.openFiles([f.exe])
        try await eventually { f.model.externalOpen != nil }
        XCTAssertEqual(f.model.sheet, .openExecutable)
        try f.model.runExternalExecutable(f.exe, bottleID: f.bottle.id, remember: true)
        try await eventually { !f.model.busy }
        XCTAssertNotNil(f.model.compatibilityLaunch)
        XCTAssertEqual(f.model.sheet, .openExecutable, "Do not replace a live bottle picker with another sheet")
        f.model.sheet = nil
        f.model.sheetDidDismiss()
        XCTAssertEqual(f.model.sheet, .compatibilityLaunch)
        let next = f.root.appendingPathComponent("Another.exe")
        var data = try Data(contentsOf: f.exe); data[510] = 2
        try data.write(to: next)
        f.model.openFiles([next])
        XCTAssertEqual(f.model.queuedOpenURLs.count, 1)
        let pending = try XCTUnwrap(f.model.compatibilityLaunch)
        f.model.cancelCompatibilityLaunch(pending)
        f.model.sheet = nil
        f.model.sheetDidDismiss()
        try await eventually { f.model.externalOpen?.url == next }
        XCTAssertTrue(f.model.state.apps.isEmpty, "Cancel must not register or start the original executable")
        XCTAssertNil(f.model.logURL)
        XCTAssertEqual(f.model.sheet, .openExecutable)
    }

    func testDismissedCompatibilitySheetDoesNotReopenItself() async throws {
        let f = try fixture()
        try f.model.runExternalExecutable(f.exe, bottleID: f.bottle.id, remember: false)
        try await eventually { !f.model.busy }
        XCTAssertNotNil(f.model.compatibilityLaunch)
        // SwiftUI clears its binding before its onDismiss callback.
        f.model.sheet = nil
        f.model.sheetDidDismiss()
        XCTAssertNil(f.model.compatibilityLaunch)
        XCTAssertNil(f.model.sheet)
        XCTAssertNil(f.model.logURL)
    }

    func testRemovedBottleCannotBeReplacedByCurrentSelectionAfterPrompt() async throws {
        let f = try fixture(), store = try XCTUnwrap(f.model.store)
        let control = try store.createBottle(name: "Control", runtime: f.bottle.runtime)
        try store.markBottleInitialized(id: control.id)
        try f.model.runExternalExecutable(f.exe, bottleID: f.bottle.id, remember: false)
        try await eventually { !f.model.busy }
        let pending = try XCTUnwrap(f.model.compatibilityLaunch)
        try store.deleteBottle(id: f.bottle.id)
        f.model.selected = control.id
        XCTAssertFalse(f.model.resumeCompatibilityLaunch(pending))
        XCTAssertNotNil(f.model.error)
        XCTAssertNil(f.model.logURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.bottleURL(for: control).path))
    }
}
