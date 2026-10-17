import XCTest
import Darwin
@testable import PortsideCore

final class LocaleSettingsTests: XCTestCase {
    func testOlderSettingsDecodeWithSystemLocale() throws {
        let json = Data(#"{"windowsVersion":"win11","debugLogging":true}"#.utf8)
        let settings = try JSONDecoder().decode(BottleSettings.self, from: json)
        XCTAssertEqual(settings.windowsVersion, .win11)
        XCTAssertTrue(settings.debugLogging)
        XCTAssertNil(settings.locale)
    }

    @MainActor func testExplicitLocaleOverridesHostCategoriesAndSystemDefaultPreservesThem() {
        let keys = ["LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "LC_PORTSIDE_TEST", "WINEPREFIX"]
        let previous = keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) }
                else { unsetenv(key) }
            }
        }
        setenv("LANG", "ja_JP.UTF-8", 1)
        setenv("LC_ALL", "ko_KR.UTF-8", 1)
        setenv("LC_CTYPE", "fr_FR.UTF-8", 1)
        setenv("LC_MESSAGES", "de_DE.UTF-8", 1)
        setenv("LC_PORTSIDE_TEST", "inherited", 1)
        setenv("WINEPREFIX", "/tmp/inherited-prefix", 1)
        let runtime = WineRuntime(wineURL: URL(fileURLWithPath: "/tmp/runtime/bin/wine"), version: "test", source: "test")
        let ordinary = RuntimeManager.environment(runtime: runtime)
        for key in keys where key != "WINEPREFIX" {
            XCTAssertEqual(ordinary[key], ProcessInfo.processInfo.environment[key], key)
        }
        XCTAssertNil(ordinary["WINEPREFIX"])

        for locale in WineLocale.allCases {
            let explicit = RuntimeManager.environment(runtime: runtime, settings: BottleSettings(locale: locale))
            XCTAssertEqual(explicit["LANG"], locale.rawValue)
            XCTAssertEqual(explicit["LC_ALL"], locale.rawValue)
            XCTAssertEqual(explicit.keys.filter { $0.hasPrefix("LC_") }, ["LC_ALL"])
            XCTAssertNil(explicit["WINEPREFIX"])
        }
    }

    @MainActor func testBottleLocalePersistsAndCanReturnToSystemDefault() throws {
        let root = try temporaryDirectory()
        let runtime = WineRuntime(wineURL: root.appendingPathComponent("wine"), version: "test", source: "test")
        let store = try LibraryStore(rootURL: root.appendingPathComponent("Support"))
        let bottle = try store.createBottle(name: "Chinese applications", runtime: runtime)
        var settings = bottle.settings
        settings.locale = .simplifiedChinese
        try store.updateSettings(bottleID: bottle.id, settings: settings)
        let reloaded = try LibraryStore(rootURL: store.rootURL)
        XCTAssertEqual(try reloaded.requireBottle(id: bottle.id).settings.locale, .simplifiedChinese)

        settings.locale = nil
        try reloaded.updateSettings(bottleID: bottle.id, settings: settings)
        let reset = try LibraryStore(rootURL: store.rootURL)
        XCTAssertNil(try reset.requireBottle(id: bottle.id).settings.locale)
    }
}
