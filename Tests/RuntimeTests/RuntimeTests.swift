import XCTest
import AVFoundation
import MapKit
@testable import HomeRoll

@MainActor final class RuntimeTests: XCTestCase {
    func testPlaybackUsesAudibleMediaCategory() {
        PlaybackAudioSession.activate("test")
        defer { PlaybackAudioSession.release("test") }
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
        XCTAssertEqual(AVAudioSession.sharedInstance().mode, .moviePlayback)
        XCTAssertFalse(VideoState().muted)
    }

    func testUnchangedLibraryDoesNotPublishRepeatedSnapshots() async {
        let timeline = TimelineStore()
        await timeline.loadAll()
        let version = timeline.version
        await timeline.loadAll()
        await timeline.loadAll()
        XCTAssertEqual(timeline.version, version)
    }

    func testBackgroundWorkYieldsAndCanBeCancelledDuringMapUse() async {
        let sync = OfflineSync.shared
        sync.foregroundMedia("test-map", active: true)
        defer { sync.foregroundMedia("test-map", active: false) }
        let waiting = Task { await sync.waitForForegroundIdle() }
        await Task.yield()
        waiting.cancel()
        let permitted = await waiting.value
        XCTAssertFalse(permitted)
    }

    func testCompassClearsStatusBarAndHeader() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let map = PhotoMapUIView(frame: controller.view.bounds)
        controller.view.addSubview(map)
        map.layoutIfNeeded()
        let compass = map.subviews.compactMap { $0 as? MKCompassButton }.first
        XCTAssertNotNil(compass)
        XCTAssertGreaterThanOrEqual(compass?.frame.minY ?? 0, window.safeAreaInsets.top + 76)
    }

    func testReusablePhotoPinClearsOldImageIdentity() {
        let cache = ImageCache.shared
        cache.setHash("test-cover-one", nil)
        cache.setHash("test-cover-two", nil)
        let view = PhotoMapPinView(annotation: nil, reuseIdentifier: "test")
        let one = MapScreen.MapGroup(id: "one", coord: .init(latitude: 0, longitude: 0),
                                     ids: ["test-cover-one"], title: "First")
        view.show(one)
        XCTAssertEqual(view.accessibilityLabel, "First, 1 photos")
        view.prepareForReuse()
        let two = MapScreen.MapGroup(id: "two", coord: .init(latitude: 1, longitude: 1),
                                     ids: ["test-cover-two", "another"], title: "Second")
        view.show(two)
        XCTAssertEqual(view.accessibilityLabel, "Second, 2 photos")
    }
}
