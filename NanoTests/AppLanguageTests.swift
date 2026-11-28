import XCTest
@testable import Nano

final class AppLanguageTests: XCTestCase {
    private let bundleID = "com.nanoapp.Nano.AppLanguageTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: bundleID)
        defaults.removePersistentDomain(forName: bundleID)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: bundleID)
        super.tearDown()
    }

    func testNoOwnSettingFollowsTheSystem() {
        XCTAssertEqual(AppLanguage.current(defaults: defaults, bundleID: bundleID), .system)
    }

    func testStoredChoiceRoundTrips() {
        AppLanguage.turkish.store(in: defaults)
        XCTAssertEqual(AppLanguage.current(defaults: defaults, bundleID: bundleID), .turkish)
        AppLanguage.english.store(in: defaults)
        XCTAssertEqual(AppLanguage.current(defaults: defaults, bundleID: bundleID), .english)
        AppLanguage.system.store(in: defaults)
        XCTAssertEqual(AppLanguage.current(defaults: defaults, bundleID: bundleID), .system)
    }

    func testRegionalCodesMapToTheirLanguage() {
        XCTAssertEqual(AppLanguage.choice(for: "tr-TR"), .turkish)
        XCTAssertEqual(AppLanguage.choice(for: "en-GB"), .english)
        XCTAssertEqual(AppLanguage.choice(for: "de"), .system)
        XCTAssertEqual(AppLanguage.choice(for: "system"), .system)
    }
}
