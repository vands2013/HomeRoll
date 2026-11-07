#if DEBUG
import SwiftUI

/// Simulator-only fixture: exercises the real map without a login or any Immich requests.
struct MapPerfDemo: View {
    @State private var markers: [MapMarkerDTO] = []
    var body: some View {
        NavigationStack { MapScreen(markers: markers) }
            .task {
                let values = await Task.detached {
                    (0..<85_000).map { i in
                        let latitude = 37.33 + Double(i % 200) * 0.001
                        let longitude = -122.05 + Double((i * 137) % 300) * 0.001
                        let id = "demo-\(i)"
                        ImageCache.shared.setHash(id, nil)
                        return MapMarkerDTO(id: id, lat: latitude, lon: longitude, city: "California", country: "US")
                    }
                }.value
                markers = values
            }
    }
}
#endif
