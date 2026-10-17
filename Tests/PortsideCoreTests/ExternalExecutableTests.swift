import XCTest
@testable import PortsideCore

final class ExternalExecutableTests: XCTestCase {
    private var root: URL!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        root = manager.temporaryDirectory.appendingPathComponent("Portside external open \(UUID().uuidString) 空間")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try manager.removeItem(at: root) }

    private func bottle(_ name: String = "Test", initialized: Bool = true) -> Bottle {
        let runtime = WineRuntime(wineURL: root.appendingPathComponent("wine"), version: "wine-test", source: "Test")
        var bottle = Bottle(name: name, runtime: runtime)
        bottle.initialized = initialized
        return bottle
    }

    private func executable(_ path: String = "Windows App.exe", isDLL: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 64
        bytes[64] = 0x50; bytes[65] = 0x45
        bytes[68] = 0x64; bytes[69] = 0x86
        bytes[84] = 240; bytes[86] = 2; bytes[87] = isDLL ? 0x20 : 0
        bytes[88] = 0x0b; bytes[89] = 0x02
        try Data(bytes).write(to: url)
        return url
    }

    func testRejectsNonPEAndDLLDisguisedAsEXE() throws {
        let text = root.appendingPathComponent("Not Windows.exe")
        try Data(repeating: 65, count: 512).write(to: text)
        for url in [text, try executable("Library.exe", isDLL: true), root.appendingPathComponent("Missing.exe")] {
            XCTAssertThrowsError(try ExternalExecutable.resolve(url: url, state: LibraryState(), bottleDirectories: [:]))
        }
    }

    func testRegisteredEntryPreservesArgumentsWorkingDirectoryAndBottle() throws {
        let first = bottle("First"), second = bottle("Second")
        let exe = try executable()
        let app = WindowsApp(name: "Saved name", executablePath: exe.path,
                             workingDirectory: root.appendingPathComponent("Different working directory").path,
                             arguments: ["--open", "a path with spaces 中文", "$(literal)"], bottleID: second.id)
        var state = LibraryState(); state.bottles = [first, second]; state.apps = [app]
        XCTAssertEqual(try ExternalExecutable.resolve(url: exe, state: state,
                       bottleDirectories: [first.id: root.appendingPathComponent("First"), second.id: root.appendingPathComponent("Second")]), .registered(app))
    }

    func testMultipleRegistrationsRequireChoiceEvenInTheSameBottle() throws {
        let first = bottle(), second = bottle("Other")
        let exe = try executable()
        let apps = [first, second, first].enumerated().map { index, bottle in
            WindowsApp(name: "App \(index)", executablePath: exe.path, workingDirectory: root.path,
                       arguments: ["\(index)"], bottleID: bottle.id)
        }
        var state = LibraryState(); state.bottles = [first, second]; state.apps = apps
        XCTAssertEqual(try ExternalExecutable.resolve(url: exe, state: state,
                       bottleDirectories: [first.id: root, second.id: root]), .chooseRegistration(apps))
    }

    func testCanonicalSymlinkMatchesSavedEntry() throws {
        let bottle = bottle(), exe = try executable()
        let alias = root.appendingPathComponent("Alias 空間.exe")
        try manager.createSymbolicLink(at: alias, withDestinationURL: exe)
        let app = WindowsApp(name: "Saved", executablePath: exe.path, workingDirectory: root.path, bottleID: bottle.id)
        var state = LibraryState(); state.bottles = [bottle]; state.apps = [app]
        XCTAssertEqual(try ExternalExecutable.resolve(url: alias, state: state,
                       bottleDirectories: [bottle.id: root.appendingPathComponent("Bottle")]), .registered(app))
    }

    func testContainedExecutableUsesItsOwnBottleAndResolvesSymlinks() throws {
        let first = bottle("First"), second = bottle("Second")
        let directory = root.appendingPathComponent("Bottle 空間")
        let exe = try executable("Bottle 空間/drive_c/Program Files/App.exe")
        let alias = root.appendingPathComponent("Outside alias.exe")
        try manager.createSymbolicLink(at: alias, withDestinationURL: exe)
        var state = LibraryState(); state.bottles = [first, second]
        XCTAssertEqual(try ExternalExecutable.resolve(url: alias, state: state,
                       bottleDirectories: [first.id: root.appendingPathComponent("Other Bottle"), second.id: directory]), .bottle(second))
    }

    func testContainmentUsesComponentsAndDoesNotFollowBottleSymlinkEscape() throws {
        let bottle = bottle(), directory = root.appendingPathComponent("Bottle")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let similarName = try executable("Bottle Other/App.exe")
        let outside = try executable("Outside/App.exe")
        let escape = directory.appendingPathComponent("Outside.exe")
        try manager.createSymbolicLink(at: escape, withDestinationURL: outside)
        var state = LibraryState(); state.bottles = [bottle]
        for exe in [similarName, escape] {
            XCTAssertEqual(try ExternalExecutable.resolve(url: exe, state: state,
                           bottleDirectories: [bottle.id: directory]), .chooseBottle([bottle]))
        }
    }

    func testExternalExecutableAlwaysPromptsAndExcludesUnavailableBottles() throws {
        let ready = bottle("Ready"), unfinished = bottle("Unfinished", initialized: false), unavailable = bottle("Unavailable")
        var state = LibraryState(); state.bottles = [unfinished, ready, unavailable]
        XCTAssertEqual(try ExternalExecutable.resolve(url: executable(), state: state,
                       bottleDirectories: [ready.id: root.appendingPathComponent("Ready"), unfinished.id: root.appendingPathComponent("Unfinished")]), .chooseBottle([ready]))
    }

    func testKnownUninitializedOrMissingBottleDoesNotSilentlyUseAnother() throws {
        let ready = bottle("Ready"), unfinished = bottle("Unfinished", initialized: false)
        let exe = try executable("Unfinished/App.exe")
        var state = LibraryState(); state.bottles = [ready, unfinished]
        let directories = [ready.id: root.appendingPathComponent("Ready"), unfinished.id: root.appendingPathComponent("Unfinished")]
        XCTAssertThrowsError(try ExternalExecutable.resolve(url: exe, state: state, bottleDirectories: directories))
        state.apps = [WindowsApp(name: "Saved", executablePath: exe.path, workingDirectory: root.path, bottleID: unfinished.id)]
        XCTAssertThrowsError(try ExternalExecutable.resolve(url: exe, state: state, bottleDirectories: directories))
        state.bottles = [ready]
        XCTAssertThrowsError(try ExternalExecutable.resolve(url: exe, state: state, bottleDirectories: directories)) { error in
            guard case PortsideError.missingBottle = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
