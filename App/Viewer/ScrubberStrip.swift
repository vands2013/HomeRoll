import SwiftUI
import UIKit

/// One reusable thumbnail per library item. Video seeking lives in the playback bar.
struct ScrubberStrip: UIViewRepresentable {
    let assets: [Asset]
    @Binding var selection: String
    var onScrubbing: (Bool) -> Void = { _ in }

    func makeUIView(context: Context) -> ScrubberView {
        let view = ScrubberView()
        view.accessibilityIdentifier = "viewer.asset-strip"
        view.onSelect = { id in if selection != id { selection = id } }
        view.onScrubbing = onScrubbing
        return view
    }
    func updateUIView(_ view: ScrubberView, context: Context) {
        view.onSelect = { id in if selection != id { selection = id } }
        view.onScrubbing = onScrubbing
        view.update(assets: assets, selection: selection)
    }
}

final class ScrubberView: UIView, UIScrollViewDelegate {
    var onSelect: (String) -> Void = { _ in }
    var onScrubbing: (Bool) -> Void = { _ in }
    private let scroll = UIScrollView()
    private var pool: [Int: SlitView] = [:]
    private var spare: [SlitView] = []
    private var assets: [Asset] = []
    private var index = 0
    private var expanded: Int?
    private var browsing = false
    private let height: CGFloat = 30
    private let slit: CGFloat = 18
    private let gap: CGFloat = 2
    private let pad: CGFloat = 5
    private var pitch: CGFloat { slit + gap }
    var displayedAssetIDs: [String] { pool.values.map(\.assetID) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.decelerationRate = .normal
        scroll.delegate = self
        scroll.clipsToBounds = false
        addSubview(scroll)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap(_:))))
    }
    required init?(coder: NSCoder) { fatalError() }

    private var expandedWidth: CGFloat {
        guard let item = expanded, assets.indices.contains(item) else { return slit }
        return max(height * 0.75, min(height * 1.6, height * CGFloat(assets[item].ratio)))
    }
    private var extra: CGFloat { expanded == nil ? 0 : expandedWidth + 2 * pad - slit }
    private func minX(_ i: Int) -> CGFloat {
        guard let e = expanded else { return CGFloat(i) * pitch }
        if i < e { return CGFloat(i) * pitch }
        if i == e { return CGFloat(i) * pitch + pad }
        return CGFloat(i) * pitch + extra
    }
    private func width(_ i: Int) -> CGFloat { i == expanded ? expandedWidth : slit }
    private func center(_ i: Int) -> CGFloat { minX(i) + width(i) / 2 }
    private var focus: CGFloat { scroll.contentOffset.x + scroll.bounds.width / 2 }
    private func offset(centering x: CGFloat) -> CGFloat { x - scroll.bounds.width / 2 }

    private func item(at x: CGFloat) -> Int {
        guard !assets.isEmpty else { return 0 }
        let i: Int
        if let e = expanded {
            let start = CGFloat(e) * pitch, end = start + expandedWidth + 2 * pad
            if x < start { i = Int(((x + gap / 2) / pitch).rounded(.down)) }
            else if x <= end { i = e }
            else { i = e + 1 + Int(((x - end - gap / 2) / pitch).rounded(.down)) }
        } else { i = Int(((x + gap / 2) / pitch).rounded(.down)) }
        return max(0, min(assets.count - 1, i))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let oldWidth = scroll.frame.width
        scroll.frame = bounds
        if oldWidth != bounds.width {
            scroll.contentInset = UIEdgeInsets(top: 0, left: bounds.width / 2, bottom: 0, right: bounds.width / 2)
            relayout()
        }
    }

    func update(assets new: [Asset], selection: String) {
        let changed = new.count != assets.count || new.first?.id != assets.first?.id || new.last?.id != assets.last?.id
        assets = new
        guard let i = assets.firstIndex(where: { $0.id == selection }) else {
            if new.isEmpty {
                for view in pool.values { view.reset(); view.removeFromSuperview(); spare.append(view) }
                pool.removeAll(); scroll.contentSize = .zero
            }
            return
        }
        if changed {
            for view in pool.values { view.reset(); view.removeFromSuperview(); spare.append(view) }
            pool.removeAll()
        }
        let selectionChanged = i != index
        index = i
        guard !browsing else { return }
        if selectionChanged || changed || expanded != i {
            expanded = i
            relayout(animated: !changed && window != nil)
        } else { tileVisible() }
    }

    private func relayout(animated: Bool = false) {
        guard !assets.isEmpty, scroll.bounds.width > 0 else { return }
        scroll.contentSize = CGSize(width: CGFloat(assets.count) * pitch - gap + extra, height: height)
        let target = center(index)
        let apply = {
            self.scroll.contentOffset = CGPoint(x: self.offset(centering: target), y: 0)
            self.tileVisible()
        }
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState], animations: apply)
        } else { apply() }
    }

    private func tileVisible() {
        guard !assets.isEmpty else { return }
        let visible = CGRect(x: scroll.contentOffset.x - 40, y: 0, width: scroll.bounds.width + 80, height: height)
        let first = item(at: visible.minX), last = item(at: visible.maxX)
        for (i, view) in pool where i < first || i > last {
            view.removeFromSuperview(); view.reset(); spare.append(view); pool[i] = nil
        }
        for i in first...last {
            let view = pool[i] ?? {
                let view = spare.popLast() ?? SlitView()
                scroll.addSubview(view); pool[i] = view
                return view
            }()
            if view.assetID != assets[i].id { view.show(assets[i]) }
            view.frame = CGRect(x: minX(i), y: 0, width: width(i), height: height)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        browsing = true
        onScrubbing(true)
        let i = item(at: focus)
        let within = (focus - minX(i)) / max(1, width(i))
        expanded = nil
        scroll.contentSize = CGSize(width: CGFloat(assets.count) * pitch - gap, height: height)
        scroll.contentOffset.x = offset(centering: minX(i) + slit * max(0, min(1, within)))
        tileVisible()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        tileVisible()
        guard browsing else { return }
        let i = item(at: focus)
        if i != index, assets.indices.contains(i) {
            index = i
            onSelect(assets[i].id)
        }
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset target: UnsafeMutablePointer<CGPoint>) {
        let i = item(at: target.pointee.x + scrollView.bounds.width / 2)
        target.pointee.x = offset(centering: center(i))
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { settle() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }
    private func settle() {
        guard browsing, !assets.isEmpty else { return }
        browsing = false
        index = item(at: focus)
        onSelect(assets[index].id)
        expanded = index
        relayout(animated: true)
        onScrubbing(false)
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        let i = item(at: gesture.location(in: scroll).x)
        guard assets.indices.contains(i), i != index else { return }
        index = i; onSelect(assets[i].id); expanded = i
        relayout(animated: true)
    }
}

private final class SlitView: UIView {
    private let image = UIImageView()
    private(set) var assetID = ""
    private var task: Task<Void, Never>?
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.13, alpha: 1)
        clipsToBounds = true
        layer.cornerRadius = 2
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        addSubview(image)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ asset: Asset) {
        task?.cancel(); assetID = asset.id
        accessibilityIdentifier = "viewer.thumbnail.\(asset.id)"
        accessibilityLabel = asset.isVideo ? "Video" : "Photo"
        let cache = ImageCache.shared, id = asset.id
        if let cached = cache.get("\(id)-thumbnail") { image.image = cached; return }
        image.image = cache.placeholder(id)
        if cache.isMissing(id) { return }
        task = Task { [weak self] in
            let value = await cache.load(id, .thumbnail)
            guard !Task.isCancelled, let self, self.assetID == id else { return }
            self.image.image = value
        }
    }
    func reset() { task?.cancel(); task = nil; assetID = ""; image.image = nil }
    override func layoutSubviews() { super.layoutSubviews(); image.frame = bounds }
}
