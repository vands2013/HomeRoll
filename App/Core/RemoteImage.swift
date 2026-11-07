import SwiftUI
import UIKit
import ImageIO

/// Speicher-Cache für dekodierte Bilder (Platte erledigt URLCache im Client).
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.totalCostLimit = 200 << 20 }
    func get(_ k: String) -> UIImage? { cache.object(forKey: k as NSString) }
    /// Fingerabdruck der Server-Vorschau (thumbhash). Ändert er sich (Bearbeitung, auch von anderem Gerät),
    /// bekommt die Vorschau eine neue Adresse → Zwischenspeicher wird umgangen.
    /// Fehlt er, hat der Server noch keine Vorschau gerechnet → `missing`: dann gar nicht erst anfragen (404),
    /// sondern warten, bis eine neuere Zeitleisten-Antwort den Hash liefert (→ `.thumbChanged`).
    private var hashes: [String: String] = [:]
    private var versions = (UserDefaults.standard.dictionary(forKey: "thumbVersions") as? [String: String]) ?? [:]
    private var missing: Set<String> = []
    private let lock = NSLock()
    func setHash(_ id: String, _ h: String?) {
        lock.lock()
        guard let h else {
            if hashes[id] == nil { missing.insert(id) }
            lock.unlock(); return
        }
        let old = hashes[id]; hashes[id] = h
        let arrived = missing.remove(id) != nil
        lock.unlock()
        if let old, old != h {
            for s in ["thumbnail", "preview", "fullsize"] { cache.removeObject(forKey: "\(id)-\(s)" as NSString) }
            cache.removeObject(forKey: "ph-\(id)" as NSString)
        }
        if arrived || (old != nil && old != h) {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .thumbChanged, object: id) }
        }
    }
    func hash(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return hashes[id] }
    func isMissing(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return missing.contains(id) }

    /// Unscharfes Sofortbild aus dem thumbhash (≈ 0,1 ms, im Speicher gemerkt).
    func placeholder(_ id: String) -> UIImage? {
        let key = "ph-\(id)" as NSString
        if let i = cache.object(forKey: key) { return i }
        guard var h = hash(id) else { return nil }
        while h.count % 4 != 0 { h += "=" }          // Immich liefert base64 ohne Auffüllung
        guard let img = ThumbHash.image(base64: h) else { return nil }
        cache.setObject(img, forKey: key, cost: 32 * 32 * 4)
        return img
    }

    /// Nach dem Bearbeiten: neue Bildfassung erzwingen (bleibt über Neustarts gemerkt).
    func version(_ id: String) -> String? {
        lock.lock(); let h = hashes[id], v = versions[id]; lock.unlock()
        let parts = [v, h.map { String($0.prefix(10)) }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "-")
    }
    func bump(_ id: String) {
        let snapshot = lock.withLock {
            versions[id] = String(Int(Date().timeIntervalSince1970))
            return versions
        }
        UserDefaults.standard.set(snapshot, forKey: "thumbVersions")
        for s in ["thumbnail", "preview", "fullsize"] { cache.removeObject(forKey: "\(id)-\(s)" as NSString) }
        NotificationCenter.default.post(name: .thumbChanged, object: id)
    }
    /// Personenbild neu laden (nach „Als Titelbild für …“); URLSession-Cache umgehen über `v`
    func bumpPerson(_ id: String) {
        cache.removeObject(forKey: "person-\(id)" as NSString)
        lock.withLock { personVersion[id, default: 0] += 1 }
        NotificationCenter.default.post(name: .personThumbChanged, object: id)
    }
    func personVersionOf(_ id: String) -> Int { lock.withLock { personVersion[id] ?? 0 } }
    private var personVersion: [String: Int] = [:]

    func set(_ k: String, _ img: UIImage) {
        cache.setObject(img, forKey: k as NSString, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4))
    }

    private func kind(_ size: ImmichClient.Size) -> OfflineStore.Kind? {
        size == .thumbnail ? .thumbnail : size == .preview ? .preview : nil
    }

    /// Speicher → iPhone (Offline-Speicher) → Server; vom Server Geholtes landet auch im Offline-Speicher.
    /// Gleichzeitige Anfragen für dasselbe Bild teilen sich einen Download (Kachel + Vorausladen); bricht der
    /// letzte Wartende ab (Kachel weggescrollt), wird auch der Download abgebrochen – wie Apple: Verbindungen
    /// gehören den Kacheln, die man gleich sieht, nicht denen, an denen man vorbeigewischt ist.
    func load(_ id: String, _ size: ImmichClient.Size) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(id)-\(size.rawValue)"
        if let image = get(key) { return image }
        let entry: (task: Task<UIImage?, Never>, token: UUID) = lock.withLock {
            if let e = inflight[key] { inflight[key]!.waiters += 1; return (e.task, e.token) }
            let token = UUID()
            let t = Task<UIImage?, Never> { [weak self] in
                // nur den eigenen Eintrag entfernen (nach einem Abbruch kann schon ein neuer Download laufen)
                defer { self?.lock.withLock { if self?.inflight[key]?.token == token { self?.inflight.removeValue(forKey: key) } } }
                if let stored = await self?.loadStored(id, size) { return stored }
                guard !Task.isCancelled, let url = ImmichClient.shared.thumbnailURL(id, size),
                      let data = try? await ImmichClient.shared.data(url) else { return nil }
                if let k = self?.kind(size), OfflineSync.enabledFlag { OfflineStore.shared.store(k, id, data) }
                guard let ready = await Task.detached(priority: .userInitiated, operation: { Self.decode(data) }).value else { return nil }
                self?.set(key, ready)
                return ready
            }
            inflight[key] = (t, 1, token)
            return (t, token)
        }
        return await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: { [weak self] in
            self?.lock.withLock {
                guard var e = self?.inflight[key], e.token == entry.token else { return }
                e.waiters -= 1
                if e.waiters <= 0 { e.task.cancel(); self?.inflight.removeValue(forKey: key) } else { self?.inflight[key] = e }
            }
        }
    }
    private var inflight: [String: (task: Task<UIImage?, Never>, waiters: Int, token: UUID)] = [:]

    /// Sofort entpacken (im Hintergrund). `byPreparingForDisplay` greift bei WebP-Vorschauen nicht –
    /// dann dekodierte der Hauptthread beim Anzeigen (Profiler: VP8 auf dem Main-Thread).
    /// (`CGImageSourceCreateImageAtIndex` + ShouldCacheImmediately entpackt WebP trotzdem erst beim Zeichnen –
    /// die Thumbnail-Funktion liefert immer ein fertiges Bitmap, hier in Originalgröße.)
    nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceShouldCacheImmediately: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1)]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }

    /// Nur Speicher und iPhone – nie das Netz (dichte Zoom-Stufen, offline).
    func loadStored(_ id: String, _ size: ImmichClient.Size) async -> UIImage? {
        let key = "\(id)-\(size.rawValue)"
        if let i = get(key) { return i }
        guard let k = kind(size) else { return nil }
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let d = OfflineStore.shared.data(k, id) else { return nil }
            return ImageCache.decode(d)
        }.value
        if let img { set(key, img) }
        return img
    }

    /// Hintergrund-Füllung des Offline-Speichers: nur laden und ablegen, nicht dekodieren.
    func fetchToStore(_ id: String, _ k: OfflineStore.Kind) async {
        guard !OfflineStore.shared.has(k, id),
              let url = ImmichClient.shared.thumbnailURL(id, k == .thumbnail ? .thumbnail : .preview),
              let data = try? await ImmichClient.shared.data(url) else { return }
        OfflineStore.shared.store(k, id, data)
    }
}

/// Quadratische/gefüllte Kachel für ein Asset.
struct AssetThumb: View {
    let id: String
    var size: ImmichClient.Size = .thumbnail
    @State private var image: UIImage?
    @State private var blur: UIImage?
    @State private var reload = 0

    var body: some View {
        Rectangle()
            .fill(Color(white: 0.13))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .transition(.opacity)
                } else if let blur {
                    Image(uiImage: blur).resizable().interpolation(.medium).scaledToFill()
                }
            }
            .clipped()
            .onReceive(NotificationCenter.default.publisher(for: .thumbChanged)) { n in
                if n.object as? String == id { image = nil; reload += 1 }
            }
            .task(id: "\(id)\(size.rawValue)\(reload)") {
                let cache = ImageCache.shared
                image = nil; blur = nil
                if let cached = cache.get("\(id)-\(size.rawValue)") { image = cached; return }
                if size != .thumbnail { image = await cache.loadStored(id, .thumbnail) }
                if image == nil { blur = cache.placeholder(id) }
                // Noch keine Vorschau auf dem Server → nicht anfragen; `.thumbChanged` meldet, wenn sie da ist.
                if cache.isMissing(id) { return }
                for attempt in 0..<2 {
                    if let img = await cache.load(id, size) {
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.15)) { image = img }
                        return
                    }
                    if attempt == 0 { try? await Task.sleep(for: .seconds(3)) }
                    if Task.isCancelled { return }
                }
            }
    }
}

/// Lädt Vorschaubilder für Kacheln, die gleich ins Bild scrollen (höchstens 6 gleichzeitig, Neueste zuerst).
/// `cancel` nimmt Kacheln wieder heraus, an denen man schon vorbei ist (bricht laufende Downloads ab).
@MainActor
final class ThumbPrefetcher {
    static let shared = ThumbPrefetcher()
    private var queue: [(String, ImmichClient.Size)] = []
    private var running: [String: Task<Void, Never>] = [:]
    func prefetch(_ ids: [String], size: ImmichClient.Size = .thumbnail) {
        let c = ImageCache.shared
        let fresh = ids.filter { c.hash($0) != nil && c.get("\($0)-\(size.rawValue)") == nil && running[$0] == nil }
        guard !fresh.isEmpty else { return }
        let set = Set(fresh)
        queue.removeAll { set.contains($0.0) }
        queue = Array((fresh.map { ($0, size) } + queue).prefix(240))
        pump()
    }
    /// Schwung endet bei `ids`: diese zuerst, alles andere Wartende verwerfen, laufende Fremde abbrechen.
    func focus(on ids: [String], size: ImmichClient.Size) {
        let keep = Set(ids)
        queue.removeAll { !keep.contains($0.0) }
        for (id, t) in running where !keep.contains(id) { t.cancel(); running[id] = nil }
        prefetch(ids, size: size)
    }
    func cancel(_ ids: [String]) {
        let set = Set(ids)
        queue.removeAll { set.contains($0.0) }
        for id in ids { running.removeValue(forKey: id)?.cancel() }
        pump()
    }
    private func pump() {
        while running.count < 6, !queue.isEmpty {
            let (id, size) = queue.removeFirst()
            running[id] = Task {
                _ = await ImageCache.shared.load(id, size)
                running[id] = nil; pump()
            }
        }
    }
}

/// Personen-Bild (rundes/abgerundetes Gesicht).
struct PersonThumb: View {
    let id: String
    @State private var image: UIImage?
    @State private var reload = 0
    var body: some View {
        Rectangle().fill(Color(white: 0.15))
            .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
            .clipped()
            .onReceive(NotificationCenter.default.publisher(for: .personThumbChanged)) { n in
                if n.object as? String == id { reload += 1 }
            }
            .task(id: "\(id)-\(reload)") {
                let key = "person-\(id)"
                if let c = ImageCache.shared.get(key) { image = c; return }
                // nach neuem Titelbild eine andere Adresse, sonst liefert der URL-Cache das alte Bild
                let v = ImageCache.shared.personVersionOf(id)
                if let base = ImmichClient.shared.personThumbURL(id),
                   case let url = v == 0 ? base : base.appending(queryItems: [URLQueryItem(name: "v", value: String(v))]),
                   let d = try? await ImmichClient.shared.data(url), let i = UIImage(data: d) {
                    ImageCache.shared.set(key, i); image = i; return
                }
                // Server hat noch kein Personenbild gerechnet → Gesicht selbst aus einem Foto der Person schneiden
                if let i = await Self.faceCrop(id) { ImageCache.shared.set(key, i); image = i }
            }
    }

    /// Erstes Foto der Person laden und ihr Gesicht (Box aus Immich) mit etwas Rand ausschneiden.
    @MainActor static func faceCrop(_ person: String) async -> UIImage? {
        let api = ImmichClient.shared
        guard let a = (try? await api.search(filter: ["personIds": ["any": [person]]], size: 1))?.first,
              let url = try? api.url("faces", query: ["id": a.id]),
              let data = try? await api.data(url) else { return nil }
        struct Face: Decodable {
            struct P: Decodable { let id: String }
            let person: P?
            let imageWidth: Int, imageHeight: Int
            let boundingBoxX1: Int, boundingBoxY1: Int, boundingBoxX2: Int, boundingBoxY2: Int
        }
        guard let f = (try? JSONDecoder().decode([Face].self, from: data))?.first(where: { $0.person?.id == person }),
              f.imageWidth > 0, f.imageHeight > 0,
              let img = await ImageCache.shared.load(a.id, .preview), let cg = img.cgImage else { return nil }
        let sx = CGFloat(cg.width) / CGFloat(f.imageWidth), sy = CGFloat(cg.height) / CGFloat(f.imageHeight)
        let r = CGRect(x: CGFloat(f.boundingBoxX1) * sx, y: CGFloat(f.boundingBoxY1) * sy,
                       width: CGFloat(f.boundingBoxX2 - f.boundingBoxX1) * sx, height: CGFloat(f.boundingBoxY2 - f.boundingBoxY1) * sy)
        let side = max(r.width, r.height) * 1.6
        let sq = CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height)).integral
        return cg.cropping(to: sq).map { UIImage(cgImage: $0) }
    }
}

extension Notification.Name {
    static let thumbChanged = Notification.Name("thumbChanged")
}

