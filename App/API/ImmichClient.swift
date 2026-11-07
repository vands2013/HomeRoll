import Foundation
import UIKit
import UniformTypeIdentifiers

enum APIError: LocalizedError {
    case notLoggedIn, http(Int, String), badURL
    var errorDescription: String? {
        switch self {
        case .notLoggedIn: String(localized: "Nicht angemeldet")
        case .http(let c, let m): String(localized: "Server-Fehler \(c): \(m)")
        case .badURL: String(localized: "Ungültige Server-Adresse")
        }
    }
}

/// Spricht mit dem eigenen Immich-Server (getestet mit v3.3.5). Wer eine eigene Heimnetz-CA nutzt, legt deren
/// Zertifikat als `Resources/HeimnetzCA.der` ins Projekt – dann vertraut die App ihr zusätzlich.
final class ImmichClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    static let shared = ImmichClient()

    private(set) var baseURL: URL?
    private(set) var token: String?
    private var session: URLSession!
    private let anchor: SecCertificate? = {
        guard let url = Bundle.main.url(forResource: "HeimnetzCA", withExtension: "der"),
              let data = try? Data(contentsOf: url) else { return nil }
        return SecCertificateCreateWithData(nil, data as CFData)
    }()

    let decoder = JSONDecoder()

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 1 << 30)   // 1 GB Bild-Cache
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        if let s = UserDefaults.standard.string(forKey: "serverURL") { baseURL = URL(string: s) }
        token = Keychain.get("accessToken")
        #if DEBUG
        // Simulator-Tests: Token/Server per Startumgebung (SIMCTL_CHILD_FOTOS_*), kein Passwort-Tippen.
        let env = ProcessInfo.processInfo.environment
        if let s = env["FOTOS_SERVER"], let t = env["FOTOS_TOKEN"] { baseURL = URL(string: s); token = t }
        #endif
    }

    var isLoggedIn: Bool { baseURL != nil && token != nil }

    // MARK: Anmeldung

    func login(server: String, email: String, password: String) async throws -> LoginResponse {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s.removeLast() }
        if !s.hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s) else { throw APIError.badURL }
        baseURL = url
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let r: LoginResponse = try await request("auth/login", method: "POST", body: body, auth: false)
        token = r.accessToken
        UserDefaults.standard.set(s, forKey: "serverURL")
        Keychain.set(r.accessToken, for: "accessToken")
        return r
    }

    func logout() {
        token = nil
        Keychain.set(nil, for: "accessToken")
        AppGroup.saveAccess(nil)
    }

    // MARK: Basis

    func url(_ path: String, query: [String: String] = [:]) throws -> URL {
        guard let baseURL else { throw APIError.notLoggedIn }
        var c = URLComponents(url: baseURL.appendingPathComponent("api/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    func authorized(_ url: URL) throws -> URLRequest {
        guard let token else { throw APIError.notLoggedIn }
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    var authHeaders: [String: String] { token.map { ["Authorization": "Bearer \($0)"] } ?? [:] }

    func request<T: Decodable>(_ path: String, query: [String: String] = [:], method: String = "GET",
                               body: Data? = nil, auth: Bool = true) async throws -> T {
        let data = try await raw(path, query: query, method: method, body: body, auth: auth)
        return try decoder.decode(T.self, from: data)
    }

    @discardableResult
    func raw(_ path: String, query: [String: String] = [:], method: String = "GET",
             body: Data? = nil, auth: Bool = true) async throws -> Data {
        var req = auth ? try authorized(try url(path, query: query)) : URLRequest(url: try url(path, query: query))
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req); Connectivity.report(nil) }
        catch { Connectivity.report(error); throw error }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 401 { await MainActor.run { NotificationCenter.default.post(name: .sessionExpired, object: nil) } }
            throw APIError.http(code, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
        }
        return data
    }

    func json(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data() }

    // MARK: Endpunkte

    /// Monatsliste als Rohdaten (die Zeitleiste merkt sie sich auf dem iPhone, siehe TimelineStore).
    func bucketsData() async throws -> Data {
        // withPartners: Fotos aus der Geteilten Mediathek (nur Partner mit „in Mediathek zeigen“)
        try await raw("timeline/buckets", query: ["visibility": "timeline", "withStacked": "true", "withPartners": "true"])
    }
    func bucketData(_ b: String) async throws -> Data {
        try await raw("timeline/bucket", query: ["timeBucket": b, "visibility": "timeline", "withStacked": "true", "withPartners": "true"])
    }
    /// Dekodieren außerhalb des Hauptthreads (2 000 Objekte ≈ 20 ms).
    nonisolated static func decodeBucket(_ d: Data) -> [Asset]? {
        (try? JSONDecoder().decode(BucketColumns.self, from: d))?.assets().sorted { $0.date < $1.date }
    }

    func asset(_ id: String) async throws -> AssetDTO { try await request("assets/\(id)") }

    func memories() async throws -> [MemoryDTO] {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return try await request("memories", query: ["for": f.string(from: Date())])
    }

    func albums() async throws -> [AlbumDTO] { try await request("albums") }
    func people() async throws -> [PersonDTO] {
        let p: PeopleDTO = try await request("people", query: ["withHidden": "false"])
        return p.people.filter { !($0.isHidden ?? false) }
    }
    func mapMarkers() async throws -> [MapMarkerDTO] { try await request("map/markers") }
    /// Freigabelink (ohne Anmeldung aufrufbar) – Adresse aus der Server-Einstellung „externe Domain“.
    func shareLink(_ ids: [String], days: Int = 30) async throws -> URL? {
        struct Link: Decodable { let key: String }
        struct Config: Decodable { let externalDomain: String? }
        let exp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(Double(days) * 86400))
        let l: Link = try await request("shared-links", method: "POST", body: json(["type": "INDIVIDUAL", "assetIds": ids,
                                                                                  "allowDownload": true, "showMetadata": false,
                                                                                  "expiresAt": exp] as [String: Any]))
        let cfg: Config? = try? await request("server/config")
        let base = cfg?.externalDomain.flatMap { $0.isEmpty ? nil : URL(string: $0) } ?? baseURL
        return base?.appendingPathComponent("share").appendingPathComponent(l.key)
    }
    /// Werte für Suchvorschläge (type: country | state | city | camera-make | camera-model)
    func suggestions(_ type: String) async throws -> [String] { try await request("search/suggestions", query: ["type": type]) }
    /// IDs geteilter Alben (die Liste „Alben mit Foto X“ liefert `shared` nicht zuverlässig)
    func sharedAlbumIDs() async -> Set<String> {
        let list: [AlbumDTO] = (try? await request("albums", query: ["shared": "true"])) ?? []
        return Set(list.filter { $0.shared == true }.map(\.id))
    }
    /// Kommentare und Likes zu einem Foto in einem geteilten Album
    func activities(album: String, asset: String) async throws -> [ActivityDTO] {
        try await request("activities", query: ["albumId": album, "assetId": asset])
    }
    func addActivity(album: String, asset: String, comment: String?) async throws -> ActivityDTO {
        var b: [String: Any] = ["albumId": album, "assetId": asset, "type": comment == nil ? "like" : "comment"]
        if let comment { b["comment"] = comment }
        return try decoder.decode(ActivityDTO.self, from: try await raw("activities", method: "POST", body: json(b)))
    }
    func deleteActivity(_ id: String) async throws { _ = try await raw("activities/\(id)", method: "DELETE") }

    /// Alben, in denen ein Objekt liegt (Info-Bereich „In Alben“)
    func albums(containing id: String) async throws -> [AlbumDTO] { try await request("albums", query: ["assetId": id]) }
    func allPeople(withHidden: Bool) async throws -> [PersonDTO] {
        let p: PeopleDTO = try await request("people", query: ["withHidden": withHidden ? "true" : "false", "size": "1000"])
        return p.people
    }
    func updatePerson(_ id: String, _ fields: [String: Any]) async throws {
        try await raw("people/\(id)", method: "PUT", body: json(fields))
    }
    /// `others` gehen in `id` auf (Immich: POST /people/{id}/merge)
    func mergePeople(into id: String, _ others: [String]) async throws {
        try await raw("people/\(id)/merge", method: "POST", body: json(["ids": others]))
    }
    func cities() async throws -> [AssetDTO] { try await request("search/cities") }
    func me() async throws -> UserDTO { try await request("users/me") }

    /// Metadaten-Suche mit dem neuen Filter-Objekt (v3.2+), blättert über `nextCursor` bis `size`.
    @MainActor func search(filter: [String: Any], size: Int = 250, order: String = "desc") async throws -> [AssetDTO] {
        let filter = Self.visible(filter)
        var out: [AssetDTO] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["filter": filter, "size": min(1000, size - out.count), "withExif": true,
                                       "orderBy": ["field": "fileCreatedAt", "direction": order]]
            if let cursor { body["cursor"] = cursor }
            let r: SearchResponseDTO = try await request("search/metadata", method: "POST", body: json(body))
            out += r.assets.items
            cursor = r.assets.nextCursor
        } while cursor != nil && out.count < size
        return out
    }

    /// Ohne eigene Sichtbarkeit nur die Mediathek: Immich liefert sonst auch die Videoteile der Live Photos
    /// („hidden“) und Ausgeblendetes („archive“) mit.
    static func visible(_ f: [String: Any]) -> [String: Any] {
        guard f["visibility"] == nil, f["trashedAt"] == nil else { return f }
        var f = f; f["visibility"] = ["eq": "timeline"]; return f
    }

    /// Search one page. The mobile-compatible smart API uses page numbers; the
    /// newer metadata API uses cursors. Filtered smart search has no cursor.
    @MainActor func searchPage(query: String, filter: [String: Any], cursor: String? = nil, page: Int? = nil) async throws -> SearchResponseDTO.Page {
        let smart = !query.isEmpty
        let legacySmart = smart && filter.isEmpty
        var body: [String: Any] = ["size": smart && !legacySmart ? 1000 : 100, "withExif": true]
        if smart {
            body["query"] = query
            if legacySmart {
                body["visibility"] = "timeline"
                if let page { body["page"] = page }
            } else {
                body["filter"] = Self.visible(filter)
            }
        } else {
            body["filter"] = Self.visible(filter)
            body["orderBy"] = ["field": "fileCreatedAt", "direction": "desc"]
            if let cursor { body["cursor"] = cursor }
        }
        let response: SearchResponseDTO = try await request(smart ? "search/smart" : "search/metadata", method: "POST", body: json(body))
        return response.assets
    }

    /// KI-Suche (mehrsprachiges Bild-Text-Modell auf dem Server); optional mit zusätzlichem Filter.
    @MainActor func smartSearch(_ query: String, filter: [String: Any] = [:], size: Int = 120) async throws -> [AssetDTO] {
        let body: [String: Any] = ["query": query, "size": size, "withExif": true, "filter": Self.visible(filter)]
        let r: SearchResponseDTO = try await request("search/smart", method: "POST", body: json(body))
        return r.assets.items
    }

    /// Zusatzdienste neben Immich (Ordner server/): direkt über ihren Port (http://<server>:<port>) oder über den
    /// Reverse-Proxy unter /fotos-dienst/<name> (siehe server/README.md).
    func serviceURL(_ name: String, port: Int) -> URL? {
        guard let base = baseURL, var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        if c.port == 2283 { c.port = port; c.path = "/\(name)" } else { c.path = "/fotos-dienst/\(name)" }
        return c.url
    }

    /// Welche KI-Treffer wirklich passen (Relevanz-Dienst auf Port 2284 neben Immich, siehe server/relevanz.py).
    /// nil = Dienst nicht erreichbar → App zeigt dann die ungeprüfte Liste.
    func relevant(_ query: String, ids: [String]) async -> Set<String>? {
        guard !ids.isEmpty, let url = serviceURL("relevanz", port: 2284), var req = try? authorized(url) else { return nil }
        req.httpMethod = "POST"; req.timeoutInterval = 8
        req.httpBody = json(["query": query, "ids": ids] as [String: Any])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct R: Decodable { let keep: [String] }
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? decoder.decode(R.self, from: data) else { return nil }
        return Set(r.keep)
    }

    /// Heikle Fotos unter `ids` (Relevanz-Dienst rechnet fehlende KI-Merkmale selbst nach, ~3 s je Foto).
    /// nil = Dienst nicht erreichbar.
    func sensitive(_ ids: [String], queries: [String]) async -> Set<String>? {
        guard !ids.isEmpty, let url = serviceURL("relevanz", port: 2284), var req = try? authorized(url) else { return nil }
        req.httpMethod = "POST"; req.timeoutInterval = 240
        req.httpBody = json(["check": ids, "queries": queries] as [String: Any])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct R: Decodable { let flagged: [String] }
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? decoder.decode(R.self, from: data) else { return nil }
        return Set(r.flagged)
    }

    /// „Ist das X?“: noch nicht zugeordnete Gesichter, die dieser Person ähneln (Relevanz-Dienst, server/relevanz.py).
    struct FaceSuggestion: Decodable, Identifiable, Hashable {
        let faceId: String
        let assetId: String
        let distance: Double
        let box: [Int]       // x1, y1, x2, y2 in Pixeln von `size`
        let size: [Int]      // Breite, Höhe des Bildes, auf dem das Gesicht erkannt wurde
        var id: String { faceId }
    }
    func similarFaces(_ personId: String) async -> [FaceSuggestion]? {
        guard let url = serviceURL("relevanz", port: 2284), var req = try? authorized(url) else { return nil }
        req.httpMethod = "POST"; req.timeoutInterval = 15
        req.httpBody = json(["personId": personId])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct R: Decodable { let faces: [FaceSuggestion] }
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? decoder.decode(R.self, from: data) else { return nil }
        return r.faces
    }
    /// „Nicht diese Person“ (REA: PXPhotoKitNotThisPersonActionPerformer): Immich kennt kein Lösen eines Gesichts –
    /// wie die Immich-Weboberfläche kommt das Gesicht zu einer neuen, unbenannten Person (leere räumt Immich selbst weg).
    func notThisPerson(asset: String, person: String) async throws {
        struct Face: Decodable { let id: String; let person: P?; struct P: Decodable { let id: String } }
        let faces: [Face] = try await request("faces", query: ["id": asset])
        guard let face = faces.first(where: { $0.person?.id == person }) else { return }
        struct NewPerson: Decodable { let id: String }
        let fresh: NewPerson = try await request("people", method: "POST", body: json([String: String]()))
        try await assignFace(face.id, to: fresh.id)
    }

    /// Gesicht einer Person zuordnen (Immich: PUT /faces/{personId}, Gesicht im Body).
    func assignFace(_ faceId: String, to personId: String) async throws {
        try await raw("faces/\(personId)", method: "PUT", body: json(["id": faceId]))
    }

    /// Bereinigen (Objekte entfernen) über den Dienst auf Port 2285 neben Immich (server/bereinigen).
    func cleanup(image: Data, mask: Data) async -> Data? {
        guard let url = serviceURL("bereinigen", port: 2285), var req = try? authorized(url) else { return nil }
        let boundary = "fotos-\(UUID().uuidString)"
        var body = Data()
        for (name, file, type, d) in [("image", "bild.jpg", "image/jpeg", image), ("mask", "maske.png", "image/png", mask)] {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(file)\"\r\nContent-Type: \(type)\r\n\r\n".data(using: .utf8)!)
            body.append(d); body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpMethod = "POST"; req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        guard let (d, resp) = try? await session.upload(for: req, from: body), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return d
    }

    func tags() async throws -> [TagDTO] { try await request("tags") }

    /// Legt Tags (Pfad „Kategorie/Bearbeitet“) an und hängt sie an Objekte.
    func tag(_ ids: [String], with path: String) async throws {
        let tags: [TagDTO] = try await request("tags", method: "PUT", body: json(["tags": [path]]))
        guard let t = tags.first(where: { $0.value == path }) else { return }
        try await raw("tags/assets", method: "PUT", body: json(["tagIds": [t.id], "assetIds": ids]))
    }

    // MARK: Mehrfach-Aktionen (Auswahl)

    func update(_ ids: [String], _ fields: [String: Any]) async throws {
        var body = fields; body["ids"] = ids
        try await raw("assets", method: "PUT", body: json(body))
    }

    func addToAlbum(_ albumID: String, _ ids: [String]) async throws {
        try await raw("albums/\(albumID)/assets", method: "PUT", body: json(["ids": ids]))
    }

    @discardableResult
    func createAlbum(_ name: String, _ ids: [String]) async throws -> AlbumDTO {
        try await request("albums", method: "POST", body: json(["albumName": name, "assetIds": ids] as [String: Any]))
    }

    /// Titel, Schlüsselfoto (`albumThumbnailAssetId`) oder Sortierung (`order`: asc/desc) ändern.
    func updateAlbum(_ id: String, _ fields: [String: Any]) async throws {
        try await raw("albums/\(id)", method: "PATCH", body: json(fields))
    }
    /// Löscht nur das Album – die Fotos bleiben in der Mediathek.
    func deleteAlbum(_ id: String) async throws { try await raw("albums/\(id)", method: "DELETE") }
    func removeFromAlbum(_ id: String, _ ids: [String]) async throws {
        try await raw("albums/\(id)/assets", method: "DELETE", body: json(["ids": ids]))
    }
    func albumAssets(_ id: String) async throws -> [AssetDTO] {
        try await search(filter: ["albumIds": ["any": [id]]], size: 20000, order: "asc")
    }
    func albumMarkers(_ id: String) async throws -> [MapMarkerDTO] { try await request("albums/\(id)/map-markers") }

    // MARK: Bearbeiten

    /// Zuschneiden/Drehen/Spiegeln macht der Server selbst (nicht-destruktiv, Original bleibt).
    func setEdits(_ id: String, _ edits: [[String: Any]]) async throws {
        try await raw("assets/\(id)/edits", method: "PUT", body: json(["edits": edits]))
    }
    func removeEdits(_ id: String) async throws { try await raw("assets/\(id)/edits", method: "DELETE") }

    func setMetadata(_ id: String, key: String, value: [String: Any]) async throws {
        try await raw("assets/\(id)/metadata", method: "PUT", body: json(["items": [["key": key, "value": value]]]))
    }
    func metadata(_ id: String, key: String) async -> [String: Any]? {
        guard let d = try? await raw("assets/\(id)/metadata/\(key)"),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["value"] as? [String: Any]
    }

    func createStack(_ ids: [String]) async throws {
        try await raw("stacks", method: "POST", body: json(["assetIds": ids]))
    }

    /// Lädt eine Datei hoch (bearbeitete Fassung) und gibt die neue ID zurück.
    func upload(_ data: Data, filename: String, created: String) async throws -> String {
        let boundary = "fotos-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("fileCreatedAt", created); field("fileModifiedAt", ISO8601DateFormatter().string(from: Date())); field("filename", filename)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(data); body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = try authorized(try url("assets"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        let (d, resp) = try await session.upload(for: req, from: body)
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode),
              let o = try JSONSerialization.jsonObject(with: d) as? [String: Any], let id = o["id"] as? String else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: d, encoding: .utf8) ?? "")
        }
        return id
    }
    // MARK: Backup

    /// Kennt der Server die Datei schon (SHA1)? → vorhandene ID, sonst nil.
    func bulkUploadCheck(id: String, checksum: String) async throws -> String? {
        struct R: Decodable { struct Item: Decodable { let action: String; let assetId: String?; let isTrashed: Bool? }; let results: [Item] }
        let r: R = try await request("assets/bulk-upload-check", method: "POST",
                                     body: json(["assets": [["id": id, "checksum": checksum]]]))
        guard let i = r.results.first, i.action == "reject", let a = i.assetId, i.isTrashed != true else { return nil }
        return a
    }

    struct UploadResult: Decodable { let id: String; let status: String }

    /// Lädt eine Datei vom Datenträger hoch (Multipart wird als Datei gebaut – auch große Videos ohne viel Speicher).
    func uploadAsset(file: URL, filename: String, uti: String, fields: [String: String],
                     checksum: String, expensive: Bool) async throws -> UploadResult {
        let boundary = "fotos-\(UUID().uuidString)"
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: body.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: body) }
        let out = try FileHandle(forWritingTo: body)
        var head = ""
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n"
        }
        let mime = UTType(uti)?.preferredMIMEType ?? "application/octet-stream"
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n"
        try out.write(contentsOf: Data(head.utf8))
        let src = try FileHandle(forReadingFrom: file)
        while let chunk = try src.read(upToCount: 4 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
        try src.close()
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()

        var req = try authorized(try url("assets"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")
        req.timeoutInterval = 600
        req.allowsExpensiveNetworkAccess = expensive
        req.allowsConstrainedNetworkAccess = expensive
        let (d, resp) = try await session.upload(for: req, fromFile: body)
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: d, encoding: .utf8)?.prefix(200).description ?? "")
        }
        return try decoder.decode(UploadResult.self, from: d)
    }

    func duplicates() async throws -> [DuplicateGroupDTO] { try await request("duplicates") }

    /// Behält `keep`, verschiebt die übrigen der Gruppe in „Zuletzt gelöscht“.
    func resolveDuplicate(_ g: DuplicateGroupDTO, keep: [String]) async throws {
        let trash = g.assets.map(\.id).filter { !keep.contains($0) }
        try await raw("duplicates/resolve", method: "POST",
                      body: json(["groups": [["duplicateId": g.duplicateId, "keepAssetIds": keep, "trashAssetIds": trash]]]))
    }

    func random(size: Int = 12) async throws -> [AssetDTO] {
        try await request("search/random", method: "POST", body: json(["size": size, "withExif": true] as [String: Any]))
    }

    func setFavorite(_ id: String, _ fav: Bool) async throws {
        try await raw("assets/\(id)", method: "PUT", body: json(["isFavorite": fav]))
    }

    func trash(_ ids: [String]) async throws {
        try await raw("assets", method: "DELETE", body: json(["ids": ids, "force": false] as [String: Any]))
    }

    /// Aus „Zuletzt gelöscht“ zurückholen.
    func restore(_ ids: [String]) async throws {
        try await raw("trash/restore/assets", method: "POST", body: json(["ids": ids]))
    }

    /// Endgültig löschen (nur aus „Zuletzt gelöscht“ heraus anbieten).
    func deleteForever(_ ids: [String]) async throws {
        try await raw("assets", method: "DELETE", body: json(["ids": ids, "force": true] as [String: Any]))
    }

    // MARK: Medien-URLs

    enum Size: String { case thumbnail, preview, fullsize, original }

    /// Immer die bearbeitete Fassung (ohne Bearbeitung = Original); `v` umgeht den 1-Tages-Cache nach Änderungen.
    func thumbnailURL(_ id: String, _ size: Size = .thumbnail) -> URL? {
        var q = ["size": size.rawValue, "edited": "true"]
        if let v = ImageCache.shared.version(id) { q["v"] = v }
        return try? url("assets/\(id)/thumbnail", query: q)
    }
    func videoURL(_ id: String) -> URL? { try? url("assets/\(id)/video/playback") }
    func originalURL(_ id: String, edited: Bool = true) -> URL? {
        try? url("assets/\(id)/original", query: ["edited": edited ? "true" : "false"])
    }
    func personThumbURL(_ id: String) -> URL? { try? url("people/\(id)/thumbnail") }

    func data(_ url: URL) async throws -> Data {
        let (d, resp): (Data, URLResponse)
        do { (d, resp) = try await session.data(for: try authorized(url)); Connectivity.report(nil) }
        catch { Connectivity.report(error); throw error }
        guard let h = resp as? HTTPURLResponse, (200..<300).contains(h.statusCode) else {
            throw APIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, "Medien")
        }
        return d
    }

    // MARK: TLS – Heimnetz-CA als zusätzlicher Anker

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        if SecTrustEvaluateWithError(trust, nil) { return (.useCredential, URLCredential(trust: trust)) }
        if let anchor {
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, false)
            if SecTrustEvaluateWithError(trust, nil) { return (.useCredential, URLCredential(trust: trust)) }
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}

extension Notification.Name {
    static let sessionExpired = Notification.Name("sessionExpired")
}

