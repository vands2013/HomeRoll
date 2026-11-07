import Foundation

@main struct PhotoMapChecks {
    static func point(_ id: String, _ latitude: Double, _ longitude: Double) -> PhotoMapPoint {
        PhotoMapPoint(id: id, latitude: latitude, longitude: longitude, city: "Test")
    }
    static func viewport(x: Double = 0, y: Double = 0, width: Double = 1,
                         height: Double = 1) -> PhotoMapViewport {
        PhotoMapViewport(x: x, y: y, width: width, height: height, screenWidth: 390, screenHeight: 844)
    }
    static func ids(_ groups: [PhotoMapCluster]) -> [String] { groups.flatMap(\.ids).sorted() }
    static func main() async {
        let world = viewport()
        precondition(PhotoMapIndex(photos: []).clusters(in: world).isEmpty)
        let invalid = PhotoMapIndex(photos: [point("nan", .nan, 0), point("bad", 91, 0)])
        precondition(invalid.home == nil && invalid.clusters(in: world).isEmpty)
        let poles = PhotoMapIndex(photos: [point("north", 90, 0), point("south", -90, 0)])
        precondition(ids(poles.clusters(in: world)) == ["north", "south"])
        precondition(poles.clusters(in: world).allSatisfy { $0.latitude.isFinite })

        // Date line: both sides of the world must be queried exactly once.
        let dateLine = PhotoMapIndex(photos: [point("east", 0, 179.9), point("west", 0, -179.9),
                                             point("zero", 0, 0)])
        precondition(ids(dateLine.clusters(in: viewport(x: 0.99, y: 0.49, width: 0.02, height: 0.02))) == ["east", "west"])
        precondition(ids(dateLine.clusters(in: viewport(x: -0.01, y: 0.49, width: 0.02, height: 0.02))) == ["east", "west"])
        precondition(ids(dateLine.clusters(in: viewport(x: -2, width: 5))) == ["east", "west", "zero"])

        // Same grid level: tiny zoom changes and input order preserve IDs and cover.
        let local = [point("z", -34.9, 138.6), point("a", -34.9001, 138.6001)]
        let first = PhotoMapIndex(photos: local).clusters(in: world)
        let second = PhotoMapIndex(photos: local.reversed()).clusters(in: viewport(width: 1.001))
        precondition(first.count == 1 && second.count == 1)
        precondition(first[0].id == second[0].id && first[0].ids[0] == "a" && second[0].ids[0] == "a")
        let duplicates = PhotoMapIndex(photos: (0..<1000).map { point("same-\($0)", -34.9, 138.6) })
        precondition(duplicates.clusters(in: world).count == 1)
        precondition(duplicates.clusters(in: world)[0].ids.count == 1000)

        // Nearby photos straddling a grid boundary must not produce overlapping pins.
        let boundary = PhotoMapIndex(photos: [point("left", 0, -0.0001), point("right", 0, 0.0001)])
        precondition(boundary.clusters(in: world).count == 1)
        let wrapped = dateLine.clusters(in: viewport(x: 0.99, y: 0.49, width: 0.02, height: 0.02))
        precondition(wrapped.count == 1 && abs(wrapped[0].longitude) > 179)

        // 85,000 locations spread around the world: preserve all IDs, bound the pin count,
        // and exclude distant locations from a small viewport without losing nearby photos.
        let photos = (0..<85_000).map { i in
            point("p\(i)", -80 + Double(i % 400) * 0.4, -179 + Double((i * 137) % 1000) * 0.358)
        }
        let start = Date()
        let index = PhotoMapIndex(photos: photos)
        let global = index.clusters(in: world)
        precondition(ids(global).count == photos.count)
        precondition(Set(ids(global)).count == photos.count)
        precondition(global.count <= 16)
        let nearby = index.clusters(in: viewport(x: 0.495, y: 0.495, width: 0.01, height: 0.01))
        precondition(ids(nearby).count < photos.count / 10)
        precondition(nearby.count < 200)
        let worker = PhotoMapWorker(index: index)
        let background = await worker.clusters(in: world)
        precondition(ids(background) == ids(global))
        let elapsed = Date().timeIntervalSince(start)
        precondition(elapsed < 10, "Unexpected clustering slowdown: \(elapsed)s")
        print("PASS: empty/invalid data, poles, date-line wrapping, stable IDs/covers, coincident photos, and 85,000-location coverage (\(String(format: "%.3f", elapsed))s)")
    }
}

