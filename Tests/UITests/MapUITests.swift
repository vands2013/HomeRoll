import XCTest

final class MapUITests: XCTestCase {
    @MainActor func testVideoViewerHasFileStripAndCompactPlaybackBar() {
        let app = XCUIApplication()
        app.launchEnvironment["FOTOS_VIEWER_DEMO"] = "1"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let mute = app.buttons["viewer.video-mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(mute.frame.midY, app.frame.height / 2)
        XCTAssertTrue(app.sliders["viewer.video-progress"].exists)
        let header = app.descendants(matching: .any)["viewer.date-header"].firstMatch
        XCTAssertTrue(header.exists)
        XCTAssertEqual(header.frame.midX, app.frame.midX, accuracy: 8)
        let thumbnails = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "viewer.thumbnail."))
        XCTAssertEqual(thumbnails.count, 6)
        thumbnails.element(boundBy: 4).tap()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Video viewer with file thumbnails and playback bar"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor func testMapTilesAndGesturesWithLargeLibrary() {
        let app = XCUIApplication()
        app.launchEnvironment["FOTOS_MAP_DEMO"] = "1"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 20))
        let status = app.staticTexts["map.tile-status"]
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "ready"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 60), .completed, "Apple Maps tiles did not finish rendering")
        map.pinch(withScale: 3, velocity: 2)
        map.swipeLeft()
        map.swipeRight()
        map.rotate(.pi / 3, withVelocity: 1)
        XCTAssertTrue(map.exists)
        let compass = app.buttons["map.compass"]
        if compass.waitForExistence(timeout: 5) {
            XCTAssertGreaterThan(compass.frame.minY, 110)
        } else { XCTFail("Rotated map must expose the compass") }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Map after pan zoom and rotation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
