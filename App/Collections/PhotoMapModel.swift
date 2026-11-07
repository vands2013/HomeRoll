import SwiftUI
import MapKit

@MainActor @Observable
final class PhotoMapModel {
    private(set) var groups: [MapScreen.MapGroup] = []
    private(set) var home: CLLocationCoordinate2D?
    @ObservationIgnored private var worker: PhotoMapWorker?
    @ObservationIgnored private var viewport: PhotoMapViewport?
    @ObservationIgnored private var query: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    func prepare(_ markers: [MapMarkerDTO]) async {
        generation += 1
        let current = generation
        query?.cancel()
        worker = nil
        let build = Task.detached(priority: .userInitiated) {
            PhotoMapIndex(photos: markers.map {
                PhotoMapPoint(id: $0.id, latitude: $0.lat, longitude: $0.lon, city: $0.city)
            })
        }
        let index = await withTaskCancellationHandler { await build.value } onCancel: { build.cancel() }
        guard !Task.isCancelled, current == generation else { return }
        worker = PhotoMapWorker(index: index)
        home = index.home.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        refresh()
    }

    func update(rect: MKMapRect, size: CGSize) {
        let world = MKMapRect.world.size.width
        viewport = PhotoMapViewport(x: rect.origin.x / world, y: rect.origin.y / world,
                                    width: rect.size.width / world, height: rect.size.height / world,
                                    screenWidth: Double(size.width), screenHeight: Double(size.height))
        refresh()
    }

    func resize(_ size: CGSize) {
        guard let old = viewport else { return }
        viewport = PhotoMapViewport(x: old.x, y: old.y, width: old.width, height: old.height,
                                    screenWidth: Double(size.width), screenHeight: Double(size.height))
        refresh()
    }

    private func refresh() {
        query?.cancel()
        guard let worker, let viewport else { return }
        let current = generation
        query = Task { [weak self] in
            // Schnelle aufeinanderfolgende Kamera-/Layout-Updates zusammenfassen.
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            let result = await worker.clusters(in: viewport)
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.groups = result.map {
                MapScreen.MapGroup(id: $0.id, coord: .init(latitude: $0.latitude, longitude: $0.longitude),
                                   ids: $0.ids, title: $0.city ?? String(localized: "Fotos"))
            }
        }
    }
}
