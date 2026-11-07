import SwiftUI
import MapKit

/// One native map stays alive while pins and SwiftUI controls change.
struct PhotoMapCanvas: UIViewRepresentable {
    let groups: [MapScreen.MapGroup]
    let home: CLLocationCoordinate2D?
    let satellite: Bool
    let reload: Int
    let onViewport: (MKMapRect, CGSize) -> Void
    let onSelect: (MapScreen.MapGroup) -> Void
    let onTiles: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PhotoMapUIView {
        let map = PhotoMapUIView()
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsScale = false
        map.isPitchEnabled = false
        map.accessibilityIdentifier = "photo-map"
        map.register(PhotoMapPinView.self, forAnnotationViewWithReuseIdentifier: "photo")
        map.onLayout = { [weak map, weak coordinator = context.coordinator] in
            guard let map else { return }
            coordinator?.publishViewport(map)
        }
        context.coordinator.map = map
        context.coordinator.configure(map)
        return map
    }
    func updateUIView(_ map: PhotoMapUIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.configure(map)
        context.coordinator.updatePins(map)
    }
    static func dismantleUIView(_ map: PhotoMapUIView, coordinator: Coordinator) {
        coordinator.timeout?.cancel()
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        map.onLayout = nil
        map.delegate = nil
        map.annotations.forEach { (map.view(for: $0) as? PhotoMapPinView)?.cancelLoad() }
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PhotoMapCanvas
        weak var map: PhotoMapUIView?
        var timeout: Task<Void, Never>?
        var observer: NSObjectProtocol?
        private var pins: [String: PhotoMapAnnotation] = [:]
        private var style: Bool?
        private var reloadID = -1
        private var centered = false
        private var rendered = false
        private var lastRect: MKMapRect?
        private var lastSize: CGSize?

        init(_ parent: PhotoMapCanvas) {
            self.parent = parent
            super.init()
            observer = NotificationCenter.default.addObserver(forName: .thumbChanged, object: nil, queue: .main) { [weak self] notification in
                guard let id = notification.object as? String else { return }
                MainActor.assumeIsolated {
                    guard let self, let map = self.map else { return }
                    for pin in self.pins.values where pin.group.ids.first == id {
                        (map.view(for: pin) as? PhotoMapPinView)?.show(pin.group, force: true)
                    }
                }
            }
        }

        func configure(_ map: PhotoMapUIView) {
            let reset = reloadID != parent.reload
            if reset { reloadID = parent.reload; rendered = false; startTimeout() }
            if style != parent.satellite || reset {
                style = parent.satellite
                rendered = false
                startTimeout()
                Task { @MainActor [weak self] in self?.parent.onTiles("loading") }
                let configuration: MKMapConfiguration
                if parent.satellite {
                    let hybrid = MKHybridMapConfiguration(elevationStyle: .flat)
                    hybrid.pointOfInterestFilter = .excludingAll
                    configuration = hybrid
                } else {
                    let standard = MKStandardMapConfiguration(elevationStyle: .flat)
                    standard.pointOfInterestFilter = .excludingAll
                    configuration = standard
                }
                // Assign only when the style changes, never during camera/annotation updates.
                map.preferredConfiguration = configuration
                if reset, !pins.isEmpty {
                    // Explicit retry reloads tile configuration without losing the camera or photo index.
                    map.mapType = parent.satellite ? .satellite : .hybrid
                    map.preferredConfiguration = configuration
                }
            }
            if !centered, let home = parent.home {
                centered = true
                map.setRegion(MKCoordinateRegion(center: home, span: .init(latitudeDelta: 6, longitudeDelta: 6)), animated: false)
            }
        }

        func updatePins(_ map: PhotoMapUIView) {
            let keep = Set(parent.groups.map(\.id))
            let removed = pins.keys.filter { !keep.contains($0) }
            map.removeAnnotations(removed.compactMap { pins.removeValue(forKey: $0) })
            var added: [PhotoMapAnnotation] = []
            for group in parent.groups {
                if let pin = pins[group.id] {
                    let changed = pin.group.ids.count != group.ids.count || pin.group.ids.first != group.ids.first
                    pin.group = group
                    if abs(pin.coordinate.latitude - group.coord.latitude) > 1e-8 || abs(pin.coordinate.longitude - group.coord.longitude) > 1e-8 {
                        pin.coordinate = group.coord
                    }
                    if changed { (map.view(for: pin) as? PhotoMapPinView)?.show(group) }
                } else {
                    let pin = PhotoMapAnnotation(group)
                    pins[group.id] = pin
                    added.append(pin)
                }
            }
            if !added.isEmpty { map.addAnnotations(added) }
        }

        func publishViewport(_ map: MKMapView) {
            let rect = map.visibleMapRect, size = map.bounds.size
            guard size.width > 0, size.height > 0, !rect.isNull,
                  lastRect != rect || lastSize != size else { return }
            lastRect = rect; lastSize = size
            // Layout/delegate callbacks must not mutate SwiftUI state in updateUIView.
            Task { @MainActor [weak self] in self?.parent.onViewport(rect, size) }
        }
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            PerfLog.motionBegan("Map pan/zoom")
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            PerfLog.motionEnded()
            publishViewport(mapView)
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? PhotoMapAnnotation,
                  let view = mapView.dequeueReusableAnnotationView(withIdentifier: "photo", for: annotation) as? PhotoMapPinView else { return nil }
            view.show(pin.group)
            return view
        }
        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let pin = annotation as? PhotoMapAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            parent.onSelect(pin.group)
        }
        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            guard fullyRendered, !rendered else { return }
            rendered = true
            timeout?.cancel()
            PerfLog.mark("Map tiles fully rendered")
            Task { @MainActor [weak self] in self?.parent.onTiles("ready") }
        }
        func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
            PerfLog.mark("Map tiles failed: \((error as NSError).domain) \((error as NSError).code)")
            Task { @MainActor [weak self] in
                self?.parent.onTiles("failed:Apple Maps could not load the background. Retry or switch map style.")
            }
        }
        private func startTimeout() {
            timeout?.cancel()
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, !self.rendered else { return }
                PerfLog.mark("Map tiles: 20-second loading timeout")
                self.parent.onTiles("failed:Apple Maps is taking longer to load. You can retry or switch map style.")
            }
        }
    }
}

final class PhotoMapUIView: MKMapView {
    var onLayout: (() -> Void)?
    private lazy var photoCompass: MKCompassButton = {
        let compass = MKCompassButton(mapView: self)
        compass.compassVisibility = .adaptive
        compass.accessibilityIdentifier = "map.compass"
        addSubview(compass)
        return compass
    }()
    private var previousSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        let top = max(safeAreaInsets.top, window?.safeAreaInsets.top ?? 0)
        // Below the custom header, never underneath the status bar/battery.
        photoCompass.frame = CGRect(x: bounds.width - 62, y: top + 76, width: 46, height: 46)
        if previousSize != bounds.size { previousSize = bounds.size; onLayout?() }
    }
}

final class PhotoMapAnnotation: NSObject, MKAnnotation {
    var group: MapScreen.MapGroup
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(_ group: MapScreen.MapGroup) { self.group = group; coordinate = group.coord; super.init() }
    var title: String? { group.title }
}

final class PhotoMapPinView: MKAnnotationView {
    private let photo = UIImageView()
    private let badge = UILabel()
    private var cover = ""
    private var load: Task<Void, Never>?
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 72, height: 76)
        centerOffset = CGPoint(x: 0, y: -38)
        collisionMode = .rectangle
        displayPriority = .required
        canShowCallout = false
        photo.frame = CGRect(x: 4, y: 12, width: 58, height: 58)
        photo.contentMode = .scaleAspectFill
        photo.clipsToBounds = true
        photo.layer.cornerRadius = 12
        photo.layer.borderColor = UIColor.white.cgColor
        photo.layer.borderWidth = 2.5
        photo.backgroundColor = UIColor(white: 0.15, alpha: 1)
        addSubview(photo)
        badge.font = .systemFont(ofSize: 12, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = .systemBlue
        badge.textAlignment = .center
        badge.layer.cornerRadius = 11
        badge.clipsToBounds = true
        addSubview(badge)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError() }
    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoad(); cover = ""; photo.image = nil
    }
    func cancelLoad() { load?.cancel(); load = nil }
    func show(_ group: MapScreen.MapGroup, force: Bool = false) {
        badge.text = group.ids.count.formatted()
        badge.isHidden = group.ids.count < 2
        let width = max(22, min(72, badge.intrinsicContentSize.width + 14))
        badge.frame = CGRect(x: 70 - width, y: 4, width: width, height: 22)
        accessibilityLabel = "\(group.title), \(group.ids.count) photos"
        guard let id = group.ids.first, cover != id || force else { return }
        cancelLoad(); cover = id
        let cache = ImageCache.shared
        photo.image = cache.get("\(id)-thumbnail") ?? cache.placeholder(id)
        if cache.get("\(id)-thumbnail") != nil || cache.isMissing(id) { return }
        load = Task { [weak self] in
            let image = await cache.load(id, .thumbnail)
            guard !Task.isCancelled, let self, self.cover == id else { return }
            self.photo.image = image
        }
    }
}
