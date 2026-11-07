import SwiftUI
import MapKit

/// Lädt die Inhalte einer Sammlung und zeigt sie als Raster.
struct CollectionDetail: View {
    let route: CollectionRoute
    let model: CollectionsModel
    @Environment(TimelineStore.self) private var timeline
    @Environment(AppModel.self) private var app
    @State private var loaded: [Asset]?
    /// Person umbenannt: neuer Titel ohne Neuladen
    @State private var renamed: String?

    var body: some View {
        switch route {
        case .category(.map): MapScreen(markers: model.markers)
        case .category(.duplicates): DuplicatesScreen()
        case .category(.largeVideos): LargeVideosScreen()
        case .category(let c) where c.locked: LockGate(title: c.title) { grid }
        case .allMemories: MemoriesScreen()
        case .allMediaTypes: CategoryListScreen(title: String(localized: "Medienarten"), items: Category.mediaTypes)
        case .allOthers: CategoryListScreen(title: String(localized: "Sonstige"), items: Category.others)
        case .allAlbums: AlbumsListScreen(model: model)
        case .albumFolder(let id): AlbumsListScreen(model: model, folderID: id)
        case .album(let a): AlbumScreen(ref: a)
        case .allPeople:
            PeopleScreen(people: model.people)
        default: grid
        }
    }

    private var grid: some View {
        AssetGridScreen(title: renamed ?? title, subtitle: loaded.map { $0.count == 1 ? String(localized: "1 Objekt") : String(localized: "\($0.count) Objekte") } ?? "",
                        assets: loaded ?? [], loading: loaded == nil,
                        menu: personMenu,
                        onRemove: { id in withAnimation(.snappy) { loaded?.removeAll { $0.id == id } } })
            .task { if loaded == nil { loaded = await load() } }
            // nach Einblenden/Wiederherstellen in der Einzelansicht die Liste auffrischen
            .onChange(of: app.viewer == nil) { _, closed in
                guard closed, case .category(let c) = route, c.locked else { return }
                Task { loaded = await load() }
            }
    }

    private var personMenu: AnyView? {
        if case .category(let c) = route, c == .recentlyViewed || c == .recentlyShared {
            // wie Apple: Verlauf von „Zuletzt angesehen/geteilt“ löschen
            return AnyView(Menu {
                Button(String(localized: "Verlauf löschen"), systemImage: "clock.badge.xmark", role: .destructive) {
                    RecentStore.clear(c); withAnimation(.snappy) { loaded = [] }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).contentShape(.rect)
            }
            .glassEffect(.regular.interactive(), in: .circle))
        }
        guard case .person(let p) = route else { return nil }
        return AnyView(PersonMenu(person: p) { renamed = $0.isEmpty ? String(localized: "Unbenannt") : $0 })
    }

    private var title: String {
        switch route {
        case .category(let c): c.title
        case .album(let a): a.name
        case .person(let p): p.name.isEmpty ? String(localized: "Unbenannt") : p.name
        case .assets(let t, _): t
        case .allTrips: String(localized: "Reisen")
        case .allMemories: String(localized: "Rückblicke")
        default: ""
        }
    }

    private func load() async -> [Asset] {
        let c = ImmichClient.shared
        let all = timeline.allLoaded
        switch route {
        case .category(let cat): return await CategoryLoader.load(cat, timeline: timeline)
        case .allTrips, .allMemories: return all
        case .album(let a):
            return ((try? await c.search(filter: ["albumIds": ["any": [a.id]]], size: 1000, order: "asc")) ?? []).map(\.asset)
        case .person(let p):
            return ((try? await c.search(filter: ["personIds": ["any": [p.id]]], size: 1000, order: "asc")) ?? []).map(\.asset)
        case .assets(_, let ids):
            let set = Set(ids); return all.filter { set.contains($0.id) }
        default: return []
        }
    }
}

/// Raster-Seite mit großem Titel (Alben, Personen, Tage, Reisen, Favoriten …) – dasselbe Raster wie die Mediathek:
/// Zoom mit zwei Fingern (1/3/5/Monate/Jahre), Wisch-Auswahl, Vorausladen. Wie Apple: „Neueste zuerst“ oder „Älteste zuerst“.
struct AssetGridScreen: View {
    let title: String
    var subtitle: String = ""
    let assets: [Asset]
    var loading = false
    var menu: AnyView? = nil
    var onRemove: ((String) -> Void)? = nil
    @Environment(AppModel.self) private var app
    @Environment(TimelineStore.self) private var timeline
    @AppStorage("collections.newestFirst") private var newestFirst = true
    @AppStorage("collections.columns") private var columns = 3
    @State private var grid = GridController()

    private var sorted: [Asset] { assets.sorted { newestFirst ? $0.date > $1.date : $0.date < $1.date } }

    var body: some View {
        let list = sorted
        Group {
            // „Zuletzt gelöscht“ zeigt unter jedem Foto die verbleibenden Tage – dafür das einfache Raster
            if list.contains(where: { $0.trashedAt != nil }) { trashGrid(list) }
            else {
                PhotoGrid(items: list.map { .asset($0, bucket: "") }, columns: columns, topInset: 120, controller: grid,
                          fit: false, selection: nil, highlight: nil, me: app.userID,
                          onTop: { _ in }, onShow: { _ in },
                          onColumns: { columns = $0 },
                          onOpen: { i, _ in app.open(list, at: i) },
                          onToggle: { _ in }, onSelect: { _ in },
                          menu: { a in AssetMenuUIKit.context(a, app: app, timeline: timeline) { onRemove?(a.id) } },
                          autoplay: app.autoplay, startAtTop: newestFirst)
                    .id(newestFirst)        // Reihenfolge gewechselt → neu aufbauen und oben bzw. unten beginnen
                    .ignoresSafeArea()
            }
        }
        .background(Color.black)
        .overlay(alignment: .top) {
            ScreenHeader(title: title, subtitle: subtitle, menu: AnyView(HStack(spacing: 10) { sortMenu; if let menu { menu } }))
        }
        .overlay {
            if loading { ProgressView().tint(.white) }
            else if assets.isEmpty { ContentUnavailableView(String(localized: "Keine Fotos oder Videos"), systemImage: "photo.on.rectangle") }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var sortMenu: some View {
        Menu {
            Picker(String(localized: "Sortieren"), selection: $newestFirst) {
                Label(String(localized: "Neueste zuerst"), systemImage: "arrow.down").tag(true)
                Label(String(localized: "Älteste zuerst"), systemImage: "arrow.up").tag(false)
            }
            Section {
                Button(String(localized: "Vergrößern"), systemImage: "plus.magnifyingglass") { columns = GridZoom.steps.last { $0 < columns } ?? columns }
                    .disabled(columns == GridZoom.steps.first)
                Button(String(localized: "Verkleinern"), systemImage: "minus.magnifyingglass") { columns = GridZoom.steps.first { $0 > columns } ?? columns }
                    .disabled(columns == GridZoom.steps.last)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44).contentShape(.rect)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(String(localized: "Sortieren und Zoomen"))
    }

    private func trashGrid(_ list: [Asset]) -> some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                    Button { app.open(list, at: i) } label: {
                        GridCell(asset: a)
                            .overlay(alignment: .bottom) {
                                // „Zuletzt gelöscht“: verbleibende Tage wie bei Apple
                                if a.trashedAt != nil {
                                    Text(TrashDays.text(a)).font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white).shadow(color: .black.opacity(0.7), radius: 3)
                                        .padding(.bottom, 5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .assetContextMenu(a) { onRemove?(a.id) }
                }
            }
            .padding(.top, 130)
            .padding(.bottom, 110)
        }
        .defaultScrollAnchor(newestFirst ? .top : .bottom, for: .initialOffset)
        .ignoresSafeArea(edges: .top)
    }
}

struct CardGridScreen: View {
    let title: String
    let items: [(String?, String, CollectionRoute)]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    NavigationLink(value: it.2) {
                        VStack(alignment: .leading, spacing: 6) {
                            Group { if let id = it.0 { AssetThumb(id: id, size: .preview) } else { Color(white: 0.14) } }
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            Text(it.1).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(Color.black)
        .navigationTitle(title)
    }
}

struct PeopleScreen: View {
    let people: [PersonDTO]
    @State private var all: [PersonDTO]?
    @State private var showHidden = false

    /// wie Apple: Favoriten zuerst, dann benannte, dann unbenannte
    private var list: [PersonDTO] {
        let src = (all ?? people).filter { showHidden || $0.isHidden != true }
        return src.filter { $0.isFavorite == true } + src.filter { $0.isFavorite != true && !$0.name.isEmpty }
            + src.filter { $0.isFavorite != true && $0.name.isEmpty }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                ForEach(list) { p in
                    NavigationLink(value: CollectionRoute.person(PersonRef(id: p.id, name: p.name))) {
                        VStack(spacing: 6) {
                            PersonThumb(id: p.id).aspectRatio(1, contentMode: .fit).clipShape(Circle())
                                .opacity(p.isHidden == true ? 0.45 : 1)
                                .overlay(alignment: .bottomTrailing) {
                                    if p.isFavorite == true {
                                        Image(systemName: "heart.fill").font(.system(size: 13)).foregroundStyle(.white)
                                            .padding(6).background(Circle().fill(.black.opacity(0.55)))
                                    }
                                }
                            Text(p.name.isEmpty ? String(localized: "Name hinzufügen") : p.name).font(.system(size: 14, weight: .medium))
                                .foregroundStyle(p.name.isEmpty ? Color.blue : .white).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
        .background(Color.black)
        .navigationTitle(String(localized: "Personen"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $showHidden) { Label(String(localized: "Ausgeblendete anzeigen"), systemImage: "eye") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        .task { all = try? await ImmichClient.shared.allPeople(withHidden: true) }
    }
}

/// „…“ einer Person wie in Fotos: benennen, Favorit, zusammenführen, ausblenden.
struct PersonMenu: View {
    let person: PersonRef
    let renamed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var askName = false
    @State private var name = ""
    @State private var merging = false
    @State private var reviewing = false
    @State private var askBirthday = false
    @State private var birthday: Date?
    @State private var birthdayDraft = Date()
    @State private var favorite = false
    @State private var hidden = false

    var body: some View {
        Menu {
            Button(person.name.isEmpty ? String(localized: "Name hinzufügen") : String(localized: "Umbenennen"), systemImage: "pencil") { name = person.name; askName = true }
            Button(favorite ? String(localized: "Kein Favorit") : String(localized: "Als Favorit"), systemImage: favorite ? "heart.slash" : "heart") {
                favorite.toggle()
                let on = favorite
                Task { try? await ImmichClient.shared.updatePerson(person.id, ["isFavorite": on]) }
            }
            Button(String(localized: "Mit Person zusammenführen …"), systemImage: "person.2.badge.plus") { merging = true }
            Button(String(localized: "Weitere Fotos prüfen"), systemImage: "person.crop.circle.badge.questionmark") { reviewing = true }
            Button(birthday == nil ? String(localized: "Geburtstag hinzufügen") : String(localized: "Geburtstag ändern"), systemImage: "gift") {
                birthdayDraft = birthday ?? Calendar.current.date(byAdding: .year, value: -30, to: Date())!; askBirthday = true
            }
            Divider()
            Button(hidden ? String(localized: "Wieder anzeigen") : String(localized: "Aus „Personen“ ausblenden"), systemImage: hidden ? "eye" : "eye.slash") {
                hidden.toggle()
                let on = hidden
                Task { try? await ImmichClient.shared.updatePerson(person.id, ["isHidden": on]) }
                app.toast(on ? String(localized: "Ausgeblendet") : String(localized: "Wird wieder angezeigt"))
                if on { dismiss() }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).contentShape(.rect)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .alert(person.name.isEmpty ? String(localized: "Name hinzufügen") : String(localized: "Umbenennen"), isPresented: $askName) {
            TextField(String(localized: "Name"), text: $name)
            Button(String(localized: "Abbrechen"), role: .cancel) {}
            Button(String(localized: "Sichern")) {
                let n = name.trimmingCharacters(in: .whitespaces)
                Task { try? await ImmichClient.shared.updatePerson(person.id, ["name": n]) }
                renamed(n)
            }
        }
        .sheet(isPresented: $merging) { MergePeopleSheet(target: person) { dismiss() } }
        .sheet(isPresented: $reviewing) { FaceReviewSheet(person: person) }
        .sheet(isPresented: $askBirthday) {
            NavigationStack {
                DatePicker(String(localized: "Geburtstag"), selection: $birthdayDraft, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.wheel).labelsHidden().padding()
                    .navigationTitle(String(localized: "Geburtstag")).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button(String(localized: "Abbrechen")) { askBirthday = false } }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(String(localized: "Sichern")) {
                                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                                let d = f.string(from: birthdayDraft); birthday = birthdayDraft; askBirthday = false
                                Task { try? await ImmichClient.shared.updatePerson(person.id, ["birthDate": d]) }
                                app.toast(String(localized: "Geburtstag gesichert – erscheint in Rückblicken"))
                            }.bold()
                        }
                    }
            }
            .presentationDetents([.medium])
        }
        .task {
            if let all = try? await ImmichClient.shared.allPeople(withHidden: true), let me = all.first(where: { $0.id == person.id }) {
                favorite = me.isFavorite == true; hidden = me.isHidden == true
                if let b = me.birthDate { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; birthday = f.date(from: String(b.prefix(10))) }
            }
        }
    }
}

/// „Ist das X?“ wie in Fotos (Weitere Fotos prüfen): ähnliche, noch keiner Person zugeordnete Gesichter einzeln
/// bestätigen. Ja ordnet das Gesicht in Immich zu, Nein merkt sich die App (wird nicht wieder gefragt).
struct FaceReviewSheet: View {
    let person: PersonRef
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var queue: [ImmichClient.FaceSuggestion]?
    @State private var index = 0
    @State private var face: UIImage?
    @State private var confirmed = 0
    @AppStorage("faces.rejected") private var rejectedRaw = ""

    private var name: String { person.name.isEmpty ? String(localized: "diese Person") : person.name }
    private var current: ImmichClient.FaceSuggestion? { queue.flatMap { index < $0.count ? $0[index] : nil } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                if let queue, let f = current {
                    Text(String(localized: "\(index + 1) von \(queue.count)")).font(.subheadline).foregroundStyle(.secondary)
                    ZStack {
                        if let face { Image(uiImage: face).resizable().scaledToFill() } else { Color(white: 0.15); ProgressView() }
                    }
                    .frame(width: 220, height: 220).clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                    AssetThumb(id: f.assetId, size: .thumbnail).frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(String(localized: "Ist das \(name)?")).font(.title2.bold())
                    HStack(spacing: 14) {
                        Button { answer(false) } label: { Text(String(localized: "Nein")).frame(maxWidth: .infinity).frame(height: 50) }
                            .buttonStyle(.bordered).tint(.white)
                        Button { answer(true) } label: { Text("Ja").bold().frame(maxWidth: .infinity).frame(height: 50) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 30)
                } else if queue != nil {
                    ContentUnavailableView(confirmed > 0 ? (confirmed == 1 ? String(localized: "1 Foto bestätigt") : String(localized: "\(confirmed) Fotos bestätigt")) : String(localized: "Keine weiteren Vorschläge"),
                                           systemImage: "person.crop.circle.badge.checkmark",
                                           description: Text(String(localized: "Sobald der Server weitere Gesichter erkannt hat, erscheinen hier neue Vorschläge.")))
                } else {
                    ProgressView(String(localized: "Ähnliche Gesichter werden gesucht …")).tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(String(localized: "Weitere Fotos prüfen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(String(localized: "Fertig")) { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .task {
            let rejected = Set(rejectedRaw.split(separator: ",").map(String.init))
            queue = (await ImmichClient.shared.similarFaces(person.id) ?? []).filter { !rejected.contains($0.faceId) }
            await loadFace()
        }
    }

    private func answer(_ yes: Bool) {
        guard let f = current else { return }
        if yes {
            confirmed += 1
            Task { try? await ImmichClient.shared.assignFace(f.faceId, to: person.id) }
        } else {
            rejectedRaw = (rejectedRaw.isEmpty ? "" : rejectedRaw + ",") + f.faceId
        }
        index += 1; face = nil
        if current == nil, confirmed > 0 { app.toast(confirmed == 1 ? String(localized: "1 Foto zu \(name) hinzugefügt") : String(localized: "\(confirmed) Fotos zu \(name) hinzugefügt")) }
        Task { await loadFace() }
    }

    /// Gesicht aus der Vorschau schneiden (etwas Rand wie in Fotos).
    private func loadFace() async {
        guard let f = current, f.box.count == 4, f.size.count == 2, f.size[0] > 0,
              let img = await ImageCache.shared.load(f.assetId, .preview), let cg = img.cgImage else { return }
        let sx = CGFloat(cg.width) / CGFloat(f.size[0]), sy = CGFloat(cg.height) / CGFloat(f.size[1])
        var r = CGRect(x: CGFloat(f.box[0]) * sx, y: CGFloat(f.box[1]) * sy,
                       width: CGFloat(f.box[2] - f.box[0]) * sx, height: CGFloat(f.box[3] - f.box[1]) * sy)
        let side = max(r.width, r.height) * 1.6
        r = CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard current?.faceId == f.faceId, let crop = cg.cropping(to: r.integral) else { return }
        face = UIImage(cgImage: crop)
    }
}

/// Andere Personen auswählen, die dieselbe sind – sie gehen in `target` auf (Immich: zusammenführen).
struct MergePeopleSheet: View {
    let target: PersonRef
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var people: [PersonDTO] = []
    @State private var chosen: Set<String> = []
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                    ForEach(people.filter { $0.id != target.id }) { p in
                        Button { if chosen.contains(p.id) { chosen.remove(p.id) } else { chosen.insert(p.id) } } label: {
                            VStack(spacing: 6) {
                                PersonThumb(id: p.id).aspectRatio(1, contentMode: .fit).clipShape(Circle())
                                    .overlay(alignment: .bottomTrailing) {
                                        if chosen.contains(p.id) {
                                            Image(systemName: "checkmark.circle.fill").font(.system(size: 24))
                                                .symbolRenderingMode(.palette).foregroundStyle(.white, .blue)
                                        }
                                    }
                                Text(p.name.isEmpty ? String(localized: "Unbenannt") : p.name).font(.system(size: 13)).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
            .navigationTitle(String(localized: "Gleiche Person auswählen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(String(localized: "Abbrechen")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button(String(localized: "Zusammenführen")) { confirm = true }.bold().disabled(chosen.isEmpty) }
            }
            .confirmationDialog(chosen.count == 1 ? String(localized: "Diese Person ist „\(target.name.isEmpty ? String(localized: "Unbenannt") : target.name)“?")
                                                  : String(localized: "Diese \(chosen.count) Personen sind „\(target.name.isEmpty ? String(localized: "Unbenannt") : target.name)“?"),
                                isPresented: $confirm, titleVisibility: .visible) {
                Button(String(localized: "Zusammenführen")) {
                    let ids = Array(chosen)
                    Task { try? await ImmichClient.shared.mergePeople(into: target.id, ids) }
                    app.toast(String(localized: "Zusammengeführt"))
                    dismiss(); done()
                }
            } message: { Text(String(localized: "Alle Fotos dieser Personen erscheinen danach unter einem Namen.")) }
        }
        .task { people = (try? await ImmichClient.shared.allPeople(withHidden: false)) ?? [] }
    }
}

/// Karte wie in Fotos: Fotos als Vorschaubilder, je nach Zoomstufe zusammengefasst;
/// Tippen öffnet das Raster der Fotos an diesem Ort.
struct MapScreen: View {
    @Environment(AppModel.self) private var app
    let markers: [MapMarkerDTO]
    @Environment(TimelineStore.self) private var timeline
    @Environment(\.dismiss) private var dismiss
    @State private var clusters = PhotoMapModel()
    @State private var satellite = false
    @State private var opened: MapGroup?

    struct MapGroup: Identifiable, Hashable {
        let id: String
        let coord: CLLocationCoordinate2D
        let ids: [String]
        let title: String
        static func == (a: MapGroup, b: MapGroup) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    var body: some View {
        PhotoMapCanvas(groups: clusters.groups, home: clusters.home, satellite: satellite,
                       reload: clusters.reloadID,
                       onViewport: { rect, size in clusters.update(rect: rect, size: size) },
                       onSelect: { opened = $0 }, onTiles: { clusters.setTileStatus($0) })
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).frame(width: 46, height: 46).contentShape(.rect)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                Spacer()
                Text(String(localized: "Karte")).font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 16).frame(height: 40).glassEffect(.regular, in: .capsule)
                Spacer()
                Button { satellite.toggle() } label: {
                    Image(systemName: satellite ? "map" : "globe.europe.africa").font(.system(size: 18)).frame(width: 46, height: 46).contentShape(.rect)
                }
                .glassEffect(.regular.interactive(), in: .circle)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await clusters.prepare(markers) }
        .onAppear { OfflineSync.shared.foregroundMedia("map", active: app.tab == .collections) }
        .onChange(of: app.tab) { _, tab in OfflineSync.shared.foregroundMedia("map", active: tab == .collections) }
        .onDisappear { clusters.cancelQuery(); OfflineSync.shared.foregroundMedia("map", active: false) }
        .onChange(of: markers) { _, value in Task { await clusters.prepare(value) } }
        .overlay(alignment: .top) {
            if let message = clusters.tileMessage {
                VStack(spacing: 8) {
                    Text(message).font(.footnote).multilineTextAlignment(.center)
                    HStack(spacing: 24) {
                        Button("Retry") { clusters.retryTiles() }.accessibilityIdentifier("map.retry")
                        ShareLink("Diagnostics", item: PerfLog.url)
                    }
                }
                .padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20).padding(.top, 80)
            }
        }
        .overlay(alignment: .bottomLeading) {
            #if DEBUG
            Text(clusters.tileStatus).font(.caption2).padding(8)
                .accessibilityIdentifier("map.tile-status")
            #endif
        }
        .navigationDestination(item: $opened) { g in
            AssetGridScreen(title: g.title, subtitle: String(localized: "\(g.ids.count) Objekte"), assets: assets(for: g.ids))
        }
    }

    private func assets(for ids: [String]) -> [Asset] {
        let set = Set(ids)
        return timeline.allLoaded.filter { set.contains($0.id) }
    }
}



