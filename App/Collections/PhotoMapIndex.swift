import Foundation

/// Reine Werte: Aufbau und Abfragen laufen außerhalb des UI-Threads.
struct PhotoMapPoint: Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let city: String?
}

struct PhotoMapViewport: Sendable {
    // Web-Mercator-Koordinaten, auf eine Weltbreite von 1 normiert.
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let screenWidth: Double
    let screenHeight: Double
}

struct PhotoMapCluster: Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let ids: [String]
    let city: String?
}

/// Einmal nach x sortieren; Abfragen verwenden binäre Suche statt alle Orte zu vergleichen.
struct PhotoMapIndex: Sendable {
    private struct Entry: Sendable {
        let photo: PhotoMapPoint
        let x: Double
        let y: Double
    }
    private struct Cell: Hashable { let x: Int; let y: Int }
    private struct Bucket {
        var x = 0.0
        var y = 0.0
        var ids: [String] = []
        var cities: [String: Int] = [:]
    }
    private let entries: [Entry]
    let home: PhotoMapPoint?

    init(photos: [PhotoMapPoint]) {
        var projected: [Entry] = []
        projected.reserveCapacity(photos.count)
        var homes: [Cell: (count: Int, latitude: Double, longitude: Double)] = [:]
        for photo in photos {
            guard photo.latitude.isFinite, photo.longitude.isFinite,
                  abs(photo.latitude) <= 90, abs(photo.longitude) <= 180 else { continue }
            let latitude = min(85.05112878, max(-85.05112878, photo.latitude))
            let radians = latitude * .pi / 180
            let rawX = (photo.longitude + 180) / 360
            let x = rawX - floor(rawX)
            let y = min(1, max(0, (1 - log(tan(.pi / 4 + radians / 2)) / .pi) / 2))
            projected.append(Entry(photo: photo, x: x, y: y))
            let cell = Cell(x: Int(floor(photo.longitude)), y: Int(floor(photo.latitude)))
            var value = homes[cell, default: (0, 0, 0)]
            value.count += 1; value.latitude += photo.latitude; value.longitude += photo.longitude
            homes[cell] = value
        }
        entries = projected.sorted { $0.x == $1.x ? $0.photo.id < $1.photo.id : $0.x < $1.x }
        let largest = homes.sorted {
            if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
            return $0.key.x == $1.key.x ? $0.key.y < $1.key.y : $0.key.x < $1.key.x
        }.first?.value
        home = largest.map { PhotoMapPoint(id: "home", latitude: $0.latitude / Double($0.count),
                                          longitude: $0.longitude / Double($0.count), city: nil) }
    }

    func clusters(in viewport: PhotoMapViewport) -> [PhotoMapCluster] {
        guard viewport.x.isFinite, viewport.y.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              viewport.screenWidth.isFinite, viewport.screenHeight.isFinite,
              viewport.width > 0, viewport.height > 0,
              viewport.screenWidth > 0, viewport.screenHeight > 0 else { return [] }
        let unitsPerPoint = max(viewport.width / viewport.screenWidth, viewport.height / viewport.screenHeight)
        // Feste Zoomstufen geben jeder Zelle eine stabile ID, auch bei kleinen Zoomänderungen.
        let level = min(26, max(0, Int(floor(-log2(max(unitsPerPoint * 88, 1e-12))))))
        let count = 1 << level
        let step = 1 / Double(count)
        let padding = 88 * unitsPerPoint
        // Ganze Zellen abfragen, damit Zahl und Titelbild beim Verschieben stabil bleiben.
        let minX = floor((viewport.x - padding) / step) * step
        let maxX = ceil((viewport.x + viewport.width + padding) / step) * step
        let minY = max(0, floor((viewport.y - padding) / step) * step)
        let maxY = min(1, ceil((viewport.y + viewport.height + padding) / step) * step)
        guard maxY >= minY else { return [] }
        let ranges: [(Double, Double)]
        if maxX - minX >= 1 { ranges = [(0, 1)] }
        else {
            let start = minX - floor(minX)
            let end = start + maxX - minX
            ranges = end <= 1 ? [(start, end)] : [(start, 1), (0, end - 1)]
        }
        var buckets: [Cell: Bucket] = [:]
        for (start, end) in ranges {
            let lower = lowerBound(start), upper = lowerBound(end)
            for i in lower..<upper {
                if i & 1023 == 0, Task.isCancelled { return [] }
                let entry = entries[i]
                guard entry.y >= minY, entry.y <= maxY else { continue }
                let cell = Cell(x: min(count - 1, Int(floor(entry.x / step))),
                                y: min(count - 1, Int(floor(entry.y / step))))
                // Mutate in place: copying a growing bucket would repeatedly copy its ID array.
                buckets[cell, default: Bucket()].x += entry.x
                buckets[cell, default: Bucket()].y += entry.y
                buckets[cell, default: Bucket()].ids.append(entry.photo.id)
                if let city = entry.photo.city, !city.isEmpty {
                    buckets[cell, default: Bucket()].cities[city, default: 0] += 1
                }
            }
        }
        // Cell centres can fall against opposite sides of a grid boundary. Merge only
        // the small visible cluster set using cached sums, never the full photo library.
        let ordered = buckets.sorted {
            if $0.value.ids.count != $1.value.ids.count { return $0.value.ids.count > $1.value.ids.count }
            return $0.key.x == $1.key.x ? $0.key.y < $1.key.y : $0.key.x < $1.key.x
        }
        var merged: [(cell: Cell, bucket: Bucket)] = []
        let separation = 78 * unitsPerPoint
        for (cell, bucket) in ordered {
            let x = bucket.x / Double(bucket.ids.count), y = bucket.y / Double(bucket.ids.count)
            if let target = merged.firstIndex(where: {
                let dx = abs($0.bucket.x / Double($0.bucket.ids.count) - x)
                return min(dx, abs(1 - dx)) < separation &&
                    abs($0.bucket.y / Double($0.bucket.ids.count) - y) < separation
            }) {
                let shift = (merged[target].bucket.x / Double(merged[target].bucket.ids.count) - x).rounded()
                merged[target].bucket.x += bucket.x + shift * Double(bucket.ids.count)
                merged[target].bucket.y += bucket.y
                merged[target].bucket.ids.append(contentsOf: bucket.ids)
                for (city, n) in bucket.cities { merged[target].bucket.cities[city, default: 0] += n }
            } else { merged.append((cell, bucket)) }
        }
        return merged.map { cell, bucket in
            let rawX = bucket.x / Double(bucket.ids.count), y = bucket.y / Double(bucket.ids.count)
            let x = rawX - floor(rawX)
            let city = bucket.cities.sorted {
                $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
            }.first?.key
            // Ein deterministisches Titelbild, unabhängig von der Server-Reihenfolge.
            var ids = bucket.ids
            if let cover = ids.indices.min(by: { ids[$0] < ids[$1] }) { ids.swapAt(0, cover) }
            return PhotoMapCluster(id: "\(level)/\(cell.x)/\(cell.y)",
                                   latitude: atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi,
                                   longitude: x * 360 - 180, ids: ids, city: city)
        }.sorted { $0.id < $1.id }
    }

    private func lowerBound(_ x: Double) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].x < x { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// Actor hält die CPU-Arbeit von SwiftUIs MainActor fern.
actor PhotoMapWorker {
    private let index: PhotoMapIndex
    init(index: PhotoMapIndex) { self.index = index }
    func clusters(in viewport: PhotoMapViewport) -> [PhotoMapCluster] { index.clusters(in: viewport) }
}

