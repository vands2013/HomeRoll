import SwiftUI
import AVKit

/// Video der Einzelansicht wie bei Apple: eigene Leiste (Filmstreifen zum Spulen, Ton, AirPlay) statt der
/// AVKit-Standardknöpfe. Ein Player für das gerade gezeigte Video; Seite und Leisten lesen denselben Zustand.
@MainActor @Observable
final class VideoState {
    private(set) var id = ""
    private(set) var player: AVPlayer?
    private(set) var playing = false
    var muted = false { didSet {
        player?.isMuted = muted
        if playing {
            if muted { PlaybackAudioSession.release("video") }
            else { PlaybackAudioSession.activate("video") }
        }
    } }
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    /// Zeitlupe (120/240 fps): wird verlangsamt abgespielt wie bei Apple
    private(set) var slowMo: SlowMo?
    /// Beim Ziehen am Filmstreifen nicht vom Player überschreiben lassen
    @ObservationIgnored var scrubbing = false
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    /// Neues Video zeigen (alter Player wird angehalten und freigegeben).
    func attach(_ asset: Asset) {
        guard asset.id != id else { return }
        stop()
        id = asset.id
        duration = Double(asset.durationMs ?? 0) / 1000
        guard let url = ImmichClient.shared.videoURL(asset.id) else { return }
        let av = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ImmichClient.shared.authHeaders])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: av))
        p.isMuted = muted
        p.volume = 1
        player = p
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                self.time = t.seconds
                if let d = p.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
            }
        }
        observeEnd(p)
        let want = asset.id
        Task { [weak self] in
            guard let s = await SlowMo.detect(av), let comp = try? await s.composition(av) else { return }
            guard let self, self.id == want, let p = self.player else { return }
            let resume = self.playing
            p.replaceCurrentItem(with: SlowMo.item(comp))
            self.slowMo = s
            self.duration = (try? await comp.load(.duration).seconds) ?? self.duration
            self.observeEnd(p)
            if resume { self.play() }
        }
    }

    private func observeEnd(_ p: AVPlayer) {
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
    }

    func play() {
        guard let p = player else { return }
        if !muted { PlaybackAudioSession.activate("video") }
        // am Ende: von vorn (wie Apple)
        if duration > 0, time >= duration - 0.15 { p.seek(to: .zero); time = 0 }
        p.play(); playing = true
    }
    func pause() { player?.pause(); playing = false; PlaybackAudioSession.release("video") }
    func toggle() { playing ? pause() : play() }

    func seek(fraction f: Double) {
        guard let p = player, duration > 0 else { return }
        let t = max(0, min(1, f)) * duration
        time = t
        p.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Spulen aus der Vorschau-Leiste (wie PXVideoScrubberController: höchstens eine Suche läuft,
    // neuere warten und nur die letzte zählt – sonst stauen sich Bereichsanfragen ans Server-Video und es hängt)

    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var pendingSeek: Double?

    func beginScrub() {
        guard player != nil else { return }
        scrubbing = true
        player?.pause()
        playing = false
    }

    func scrub(to fraction: Double) {
        guard duration > 0 else { return }
        let t = max(0, min(1, fraction)) * duration
        time = t
        if seeking { pendingSeek = t } else { startSeek(t, exact: false) }
    }

    func endScrub(resume: Bool) {
        guard scrubbing else { return }
        scrubbing = false
        let t = pendingSeek ?? time
        pendingSeek = nil
        if seeking { pendingSeek = t } else { startSeek(t, exact: true) }
        if resume { play() }
    }

    private func startSeek(_ t: Double, exact: Bool) {
        guard let p = player else { return }
        seeking = true
        // beim Ziehen reicht das nächste Schlüsselbild in der Nähe (schnell), am Ende genau
        let tol = exact ? CMTime.zero : CMTime(seconds: 0.15, preferredTimescale: 600)
        p.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player === p else { return }
                self.seeking = false
                if let next = self.pendingSeek { self.pendingSeek = nil; self.startSeek(next, exact: !self.scrubbing) }
            }
        }
    }

    func stop() {
        player?.pause()
        PlaybackAudioSession.release("video")
        if let o = timeObserver { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        timeObserver = nil; endObserver = nil
        player = nil; playing = false; time = 0; id = ""; slowMo = nil
        seeking = false; pendingSeek = nil; scrubbing = false
    }

}

/// Bildfläche für den Player (ohne AVKit-Knöpfe).
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer?
    func makeUIView(context: Context) -> PlayerLayerView { PlayerLayerView() }
    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = .resizeAspect
    }
    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Photos-style playback controls, independent of the file-thumbnail strip.
struct VideoControls: View {
    @Bindable var video: VideoState
    @State private var resumeAfterScrub = false

    var body: some View {
        HStack(spacing: 6) {
            Button { video.toggle() } label: {
                Image(systemName: video.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 44).contentShape(.rect)
            }
            .accessibilityIdentifier("viewer.video-play")
            .accessibilityLabel(video.playing ? String(localized: "Pause") : String(localized: "Wiedergabe"))
            Slider(value: Binding(get: {
                video.duration > 0 ? min(1, max(0, video.time / video.duration)) : 0
            }, set: { video.scrub(to: $0) }), in: 0...1, onEditingChanged: { editing in
                if editing { resumeAfterScrub = video.playing; video.beginScrub() }
                else { video.endScrub(resume: resumeAfterScrub) }
            }) { Text("Video playback position") }
            .labelsHidden()
            .tint(.white)
            .disabled(video.duration <= 0)
            .accessibilityIdentifier("viewer.video-progress")
            Button { video.muted.toggle() } label: {
                Image(systemName: video.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 36, height: 44).contentShape(.rect)
            }
            .accessibilityIdentifier("viewer.video-mute")
            .accessibilityLabel(video.muted ? String(localized: "Ton an") : String(localized: "Ton aus"))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 20)
    }
}

/// AirPlay-Knopf (Video auf Fernseher/Lautsprecher).
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white; v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

