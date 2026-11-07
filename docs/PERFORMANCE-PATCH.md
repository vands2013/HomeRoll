# HomeRoll performance test build 0.1.2

This branch changes the iPhone app and its build workflow. It does not change an Immich server.

## Changes

- Use a persistent native MKMapView and reusable UIKit photo annotations instead of rebuilding SwiftUI map annotation views.
- Assign the native map configuration only on initial setup, explicit retry, or a style change. Report tile errors/timeouts and provide Retry and Diagnostics controls.
- Keep the compass below the status bar and custom map header.
- Query a projected photo index off the main thread. Merge nearby visible groups across cell boundaries, including the date line, without repeating full-library comparisons.
- Pause offline downloads and background OCR/curation during map and foreground media use. Limit bulk offline download concurrency to two.
- Preserve Library/Collections state across tab switches and build offscreen collection sections lazily. Stop hidden library autoplay.
- Coalesce full-library loads, skip publishing unchanged timeline snapshots, share disk image decodes/downloads, and cache thumbnail version preferences.
- Configure explicit video playback as AVAudioSession.playback/moviePlayback so the phone's ringer Silent mode does not suppress video sound. Keep the in-app mute control and release the session when playback stops.

- Use a separate compact play/progress/mute capsule for videos, with a centred date/time header. The bottom strip has one thumbnail per file; no playback-frame requests are generated. AirPlay remains available in the More menu.

## Validation

GitHub Actions runs clustering checks with 85,000 generated locations, native simulator tests for audio configuration, compass positioning, annotation reuse, unchanged timeline snapshots, and background-work cancellation, plus UI tests that load Apple Maps tiles and pan, zoom, and rotate a map backed by 85,000 synthetic locations. The fixture is Debug-only and requires no Immich account. The Release IPA excludes it.

The workflow also verifies the IPA ZIP and app/extension property lists and publishes a source commit record and SHA-256 checksum. Simulator evidence and logs are retained in the build-log artifact.

## Device testing

Install the IPA using the existing sideloading method. Test panning/zooming, opening a photo stack, switching tabs, and playing a video with the ringer in Silent mode and the in-app speaker enabled. Actual device smoothness and audible output need verification on the iPhone; simulator timings are not device frame-rate measurements.

If tiles stall again, use the map's Diagnostics share control after a tile timeout, or share the performance log from Backup & Offline. The log records tile completion/failure, index/query timings, and map gesture hitches. Tile delivery is still provided by Apple Maps.
