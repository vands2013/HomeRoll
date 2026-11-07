import AVFoundation

/// Explicit media playback is audible even when the phone's ringer is silent.
/// Silent grid previews never activate this session.
@MainActor enum PlaybackAudioSession {
    private static var owners: Set<String> = []
    static func activate(_ owner: String) {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || session.mode != .moviePlayback {
                try session.setCategory(.playback, mode: .moviePlayback)
            }
            if owners.isEmpty { try session.setActive(true) }
            owners.insert(owner)
        } catch {
            PerfLog.mark("Playback audio session failed: \((error as NSError).domain) \((error as NSError).code)")
        }
    }
    static func release(_ owner: String) {
        guard owners.remove(owner) != nil, owners.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
