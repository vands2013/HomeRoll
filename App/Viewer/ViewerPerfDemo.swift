#if DEBUG
import SwiftUI

/// Synthetic video covers for viewer layout tests; no server or user photos are used.
struct ViewerPerfDemo: View {
    @State private var assets: [Asset] = []
    var body: some View {
        Group {
            if assets.isEmpty { ProgressView() }
            else { ViewerView(assets: assets, start: 3) }
        }
        .task {
            let colors: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal, .systemRed]
            assets = colors.enumerated().map { index, color in
                let id = "viewer-demo-\(index)"
                let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90)).image { context in
                    color.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
                    let text = "Video \(index + 1)" as NSString
                    text.draw(at: CGPoint(x: 16, y: 35), withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .bold), .foregroundColor: UIColor.white])
                }
                ImageCache.shared.set("\(id)-thumbnail", image)
                ImageCache.shared.set("\(id)-preview", image)
                return Asset(id: id, isImage: false, isFavorite: false, date: Date(timeIntervalSince1970: 1_782_562_320),
                             ratio: 16 / 9, durationMs: 60_000 * (index + 1), livePhotoVideoId: nil, city: nil, country: nil)
            }
        }
    }
}
#endif
