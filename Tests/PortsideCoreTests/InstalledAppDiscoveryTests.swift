import XCTest
@testable import PortsideCore

final class InstalledAppDiscoveryTests: XCTestCase {
    @MainActor private func fixture() throws -> (LibraryStore, Bottle, URL) {
        let root = try temporaryDirectory("Portside discovery")
        let store = try LibraryStore(rootURL: root)
        let runtime = WineRuntime(wineURL: root.appendingPathComponent("wine"), version: "wine-test", source: "Discovery fixture")
        let bottle = try store.createBottle(name: "Applications 空間", runtime: runtime)
        try store.markBottleInitialized(id: bottle.id)
        let initialized = try store.requireBottle(id: bottle.id)
        let drive = try store.bottleURL(for: initialized).appendingPathComponent("drive_c", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        return (store, initialized, drive)
    }

    @discardableResult private func gui(_ relative: String, drive: URL, subsystem: UInt8 = 2) throws -> URL {
        let url = drive.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let exe = try executable(in: url.deletingLastPathComponent(), name: url.lastPathComponent)
        var data = try Data(contentsOf: exe)
        data[128 + 24 + 68] = subsystem
        try data.write(to: exe)
        return exe.standardizedFileURL.resolvingSymlinksInPath()
    }

    @MainActor func testDiscoversCommonCustomAndNestedGUIExecutablesWithoutChoosingOneForTheUser() throws {
        let (store, bottle, drive) = try fixture()
        let zip = try gui("Program Files/7-Zip/7zFM.exe", drive: drive)
        let editor = try gui("Program Files (x86)/Acme/Editor/Editor.exe", drive: drive)
        let custom = try gui("Portside 测试/7-Zip/7zFM.exe", drive: drive)
        let launcher = try gui("XYX/R2beat_XYX/VLauncher.exe", drive: drive)
        let client = try gui("XYX/R2beat_XYX/Game.exe", drive: drive)
        let mini = try gui("XYX/R2beat_XYX/miniGame/MiniGames.exe", drive: drive)
        try gui("xiyouxidownlad/r2beat/R2beat_XYX_installer.exe", drive: drive)
        let result = try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: store.bottleURL(for: bottle), registeredApps: [])
        XCTAssertEqual(Set(result.map(\.executableURL)), Set([zip, editor, custom, launcher, client, mini]))
        let game = try XCTUnwrap(result.first { $0.executableURL == launcher })
        XCTAssertEqual(game.name, "R2beat_XYX — VLauncher")
        XCTAssertEqual(game.workingDirectoryURL, launcher.deletingLastPathComponent())
        XCTAssertEqual(game.bottleID, bottle.id)
        XCTAssertEqual(game.id, launcher.path)
    }

    @MainActor func testRejectsHelpersConsoleDLLAndInvalidPE() throws {
        let (store, bottle, drive) = try fixture()
        let main = try gui("Product/Product.exe", drive: drive)
        for name in ["unins000", "Uninstall", "setup", "DXSETUP", "vcredist_x86", "vc_redist.x86", "NDP472", "downloader", "CrashReportClient", "UnityCrashHandler64", "browser_subprocess", "settings", "autorun"] {
            try gui("Product/\(name).exe", drive: drive)
        }
        try gui("Product/console.exe", drive: drive, subsystem: 3)
        let dll = try gui("Product/DisguisedDLL.exe", drive: drive)
        var data = try Data(contentsOf: dll); data[151] = 0x20; try data.write(to: dll)
        let invalid = drive.appendingPathComponent("Product/Invalid.exe")
        try Data(repeating: 65, count: 512).write(to: invalid)
        let result = try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: store.bottleURL(for: bottle), registeredApps: [])
        XCTAssertEqual(result.map(\.executableURL), [main])
    }

    @MainActor func testSkipsSystemSupportAndLargeAssetFolders() throws {
        let (store, bottle, drive) = try fixture()
        let main = try gui("App/App.exe", drive: drive)
        for path in ["windows/System32/notepad.exe", "users/User/Other.exe", "ProgramData/Service.exe", "Program Files/Common Files/Helper.exe", "Program Files/Internet Explorer/iexplore.exe", "Program Files/Windows Media Player/wmplayer.exe", "Program Files/Windows NT/Accessories/wordpad.exe", "App/redist/Tool.exe", "App/resources/Other.exe", "App/App_Data/Unity.exe", "App/cache/Browser.exe", "App/GameGuard/GameMon.exe"] {
            try gui(path, drive: drive)
        }
        XCTAssertEqual(try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: store.bottleURL(for: bottle), registeredApps: []).map(\.executableURL), [main])
    }

    @MainActor func testRegisteredLauncherDoesNotHideSiblingGameOrNestedExecutables() throws {
        let (store, bottle, drive) = try fixture()
        let launcher = try gui("Publisher/Game/Launcher.exe", drive: drive)
        let client = try gui("Publisher/Game/Game.exe", drive: drive)
        let binary = try gui("Publisher/Game/Binaries/Win64/Game.exe", drive: drive)
        let mini = try gui("Publisher/Game/miniGame/Game.exe", drive: drive)
        let directory = try store.bottleURL(for: bottle)
        let first = try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: directory, registeredApps: [])
        XCTAssertEqual(Set(first.map(\.executableURL)), Set([launcher, client, binary, mini]))
        XCTAssertEqual(Set(first.map(\.name)).count, first.count)
        let saved = WindowsApp(name: "Saved Game", executablePath: launcher.path, workingDirectory: launcher.deletingLastPathComponent().path, arguments: ["--saved"], bottleID: bottle.id)
        let remaining = try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: directory, registeredApps: [saved, saved])
        XCTAssertEqual(Set(remaining.map(\.executableURL)), Set([client, binary, mini]),
                       "Registering the launcher excludes that exact executable, not its installation folder")
        var otherBottleEntry = saved; otherBottleEntry.bottleID = UUID()
        XCTAssertEqual(try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: directory, registeredApps: [otherBottleEntry]), first)
    }

    @MainActor func testSuiteAppsAndArchitectureVariantsRemainDistinctAfterRegisteringOne() throws {
        let (store, bottle, drive) = try fixture()
        let word = try gui("Program Files/Suite/Word.exe", drive: drive)
        let sheet = try gui("Program Files/Suite/Spreadsheet.exe", drive: drive)
        let x86 = try gui("Program Files/Suite/bin/x86/Editor.exe", drive: drive)
        let x64 = try gui("Program Files/Suite/bin/x64/Editor.exe", drive: drive)
        let saved = try store.registerApp(name: "Word", executableURL: word, bottleID: bottle.id)
        let catalogBefore = try Data(contentsOf: store.stateURL)
        let prefix = try store.bottleURL(for: bottle)
        let all = try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: prefix, registeredApps: [])
        XCTAssertEqual(Set(all.map(\.executableURL)), Set([word, sheet, x86, x64]))
        XCTAssertEqual(Set(all.map(\.name)), Set(["Suite — Word", "Suite — Spreadsheet", "Suite — bin/x86/Editor", "Suite — bin/x64/Editor"]))

        var anotherRegistration = saved
        anotherRegistration.id = UUID(); anotherRegistration.arguments = ["--another-launch-mode"]
        let alias = drive.appendingPathComponent("Word alias.exe")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: word)
        var aliasRegistration = saved; aliasRegistration.id = UUID(); aliasRegistration.executablePath = alias.path
        let result = try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: prefix,
                                                        registeredApps: [saved, anotherRegistration, aliasRegistration])
        XCTAssertEqual(Set(result.map(\.executableURL)), Set([sheet, x86, x64]))
        XCTAssertEqual(Set(result.map(\.name)).count, result.count)
        XCTAssertEqual(result, try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: prefix, registeredApps: [saved]))
        XCTAssertEqual(try Data(contentsOf: store.stateURL), catalogBefore, "Discovery must not alter existing registrations")
    }

    @MainActor func testRegisteredDownloaderDoesNotHideInstalledAppInSameFolder() throws {
        let (store, bottle, drive) = try fixture()
        let downloader = try gui("Portside/App/downloader.exe", drive: drive)
        let launcher = try gui("Portside/App/VLauncher.exe", drive: drive)
        let saved = WindowsApp(name: "Downloader", executablePath: downloader.path, workingDirectory: downloader.deletingLastPathComponent().path, bottleID: bottle.id)
        XCTAssertEqual(try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: store.bottleURL(for: bottle), registeredApps: [saved]).map(\.executableURL), [launcher])
    }

    @MainActor func testSkipsSymlinkFilesDirectoriesAndLoopsWithoutTraversingHost() throws {
        let (store, bottle, drive) = try fixture()
        let app = try gui("Own App/Main.exe", drive: drive)
        let outside = try temporaryDirectory("Host files")
        let host = try gui("Private App.exe", drive: outside)
        try FileManager.default.createSymbolicLink(at: drive.appendingPathComponent("Outside"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: drive.appendingPathComponent("Linked.exe"), withDestinationURL: host)
        try FileManager.default.createSymbolicLink(at: drive.appendingPathComponent("Loop"), withDestinationURL: drive)
        XCTAssertEqual(try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: store.bottleURL(for: bottle), registeredApps: []).map(\.executableURL), [app])
    }

    @MainActor func testRegisteredAppDoesNotAllowHelpersOrProtectedPathsInItsFolderTree() throws {
        let (store, bottle, drive) = try fixture()
        let launcher = try gui("Product/Launcher.exe", drive: drive)
        let client = try gui("Product/Game.exe", drive: drive)
        let saved = try store.registerApp(name: "Launcher", executableURL: launcher, bottleID: bottle.id)
        for path in ["Product/helper.exe", "Product/CrashReporter.exe", "Product/redist/Tool.exe", "Product/assets/Tool.exe", "windows/Unrelated.exe"] {
            try gui(path, drive: drive)
        }
        let outside = try temporaryDirectory("Outside discovery")
        let host = try gui("Host.exe", drive: outside)
        try FileManager.default.createSymbolicLink(at: drive.appendingPathComponent("Product/Linked.exe"), withDestinationURL: host)
        try FileManager.default.createSymbolicLink(at: drive.appendingPathComponent("Product/Outside"), withDestinationURL: outside)
        let result = try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: store.bottleURL(for: bottle), registeredApps: [saved])
        XCTAssertEqual(result.map(\.executableURL), [client])
    }

    @MainActor func testRejectsSymlinkDriveAndUninitializedBottle() throws {
        let (store, bottle, drive) = try fixture()
        let prefix = try store.bottleURL(for: bottle)
        var unfinished = bottle; unfinished.initialized = false
        XCTAssertThrowsError(try InstalledAppDiscovery.discover(bottle: unfinished, bottleURL: prefix, registeredApps: []))
        try FileManager.default.removeItem(at: drive)
        let host = try temporaryDirectory("Host drive")
        try gui("Host.exe", drive: host)
        try FileManager.default.createSymbolicLink(at: drive, withDestinationURL: host)
        XCTAssertThrowsError(try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: prefix, registeredApps: []))
    }

    @MainActor func testResultIsDeterministicReadOnlyAndKeepsSeparateInstallFolders() throws {
        let (store, bottle, drive) = try fixture()
        let x64 = try gui("Program Files/Editor/Editor.exe", drive: drive)
        let x86 = try gui("Program Files (x86)/Editor/Editor.exe", drive: drive)
        let catalogBefore = try Data(contentsOf: store.stateURL), imageBefore = try Data(contentsOf: x64)
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: x64.path)[.modificationDate] as? Date
        let first = try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: store.bottleURL(for: bottle), registeredApps: [])
        let second = try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: store.bottleURL(for: bottle), registeredApps: [])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.id), first.map(\.id).sorted())
        XCTAssertEqual(Set(first.map(\.executableURL)), Set([x64, x86]))
        XCTAssertEqual(try Data(contentsOf: store.stateURL), catalogBefore)
        XCTAssertEqual(try Data(contentsOf: x64), imageBefore)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: x64.path)[.modificationDate] as? Date, modifiedBefore)
    }

    @MainActor func testEntryTimeAndCandidateLimitsReportManualFallback() throws {
        let (store, bottle, drive) = try fixture()
        try gui("First/App.exe", drive: drive)
        try gui("Second/App.exe", drive: drive)
        for index in 0..<10 { try Data().write(to: drive.appendingPathComponent("data\(index).bin")) }
        let prefix = try store.bottleURL(for: bottle)
        for limits in [InstalledAppDiscovery.Limits(entries: 3), .init(candidates: 1), .init(seconds: 0)] {
            XCTAssertThrowsError(try InstalledAppDiscovery.scan(bottle: bottle, bottleURL: prefix, registeredApps: [], limits: limits)) { error in
                XCTAssertTrue(error.localizedDescription.contains("limit"))
                XCTAssertTrue(error.localizedDescription.contains("Add Manually"))
            }
        }
    }

    @MainActor func testCandidateLimitCountsGUIExecutablesSharingOneFolder() throws {
        let (store, bottle, drive) = try fixture()
        try gui("Suite/Word.exe", drive: drive)
        try gui("Suite/Spreadsheet.exe", drive: drive)
        XCTAssertThrowsError(try InstalledAppDiscovery.scan(bottle: bottle, bottleURL: store.bottleURL(for: bottle),
                                                           registeredApps: [], limits: .init(candidates: 1))) { error in
            XCTAssertTrue(error.localizedDescription.contains("candidate-count"))
            XCTAssertTrue(error.localizedDescription.contains("Add Manually"))
        }
    }

    @MainActor func testDepthScopeAndCancellation() async throws {
        let (store, bottle, drive) = try fixture()
        try gui("Vendor/Product/Deep/App.exe", drive: drive)
        let prefix = try store.bottleURL(for: bottle)
        XCTAssertTrue(try InstalledAppDiscovery.scan(bottle: bottle, bottleURL: prefix, registeredApps: [], limits: .init(depth: 2)).isEmpty)
        XCTAssertEqual(try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: prefix, registeredApps: []).count, 1)
        let task = Task { try InstalledAppDiscovery.discover(bottle: bottle, bottleURL: prefix, registeredApps: []) }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled scan must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
