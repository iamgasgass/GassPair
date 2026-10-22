import AVFAudio
import CoreLocation
import Foundation

/// Optional ways to keep GassPair running while the user is in Settings
/// entering the pairing code (on top of the system's continued-processing task).
@MainActor
final class KeepAlive: NSObject {

    // MARK: Silent audio

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var audioWanted = false
    private var observers: [NSObjectProtocol] = []

    func startAudio() {
        guard !audioWanted else { return }
        audioWanted = true
        installObservers()
        startEngine()
    }

    func stopAudio() {
        guard audioWanted else { return }
        audioWanted = false
        stopEngine()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func startEngine() {
        guard audioWanted, engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = engine.mainMixerNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { return }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)

            let frames = AVAudioFrameCount(format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            // Explicit silence (buffers are not guaranteed to be zeroed).
            if let channels = buffer.floatChannelData {
                for c in 0..<Int(format.channelCount) {
                    channels[c].update(repeating: 0, count: Int(frames))
                }
            }

            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player
        } catch {
            stopEngine()
        }
    }

    private func stopEngine() {
        player?.stop()
        engine?.stop()
        if let player, let engine { engine.detach(player) }
        player = nil
        engine = nil
    }

    private func restartEngine() {
        stopEngine()
        startEngine()
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Resume after phone calls, Siri, other apps taking the audio session…
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            onMainQueue { [self] in
                if rawType == AVAudioSession.InterruptionType.ended.rawValue {
                    self.restartEngine()
                }
            }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { _ in
            onMainQueue { [self] in self.restartEngine() }
        })
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { note in
            let changed = note.object as AnyObject?
            onMainQueue { [self] in
                guard changed === self.engine else { return }
                self.restartEngine()
            }
        })
    }

    // MARK: Location

    private lazy var location: CLLocationManager = {
        let m = CLLocationManager()
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        m.distanceFilter = kCLDistanceFilterNone
        m.pausesLocationUpdatesAutomatically = false
        m.showsBackgroundLocationIndicator = true
        return m
    }()
    private var locationRunning = false

    func startLocation() {
        guard !locationRunning else { return }
        locationRunning = true
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginLocationUpdates()
        default:
            break
        }
    }

    func stopLocation() {
        guard locationRunning else { return }
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
        locationRunning = false
    }

    private func beginLocationUpdates() {
        guard locationRunning, CLLocationManager.locationServicesEnabled() else { return }
        location.allowsBackgroundLocationUpdates = true
        location.startUpdatingLocation()
    }

    func stopAll() {
        stopAudio()
        stopLocation()
    }
}

extension KeepAlive: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status == .authorizedAlways || status == .authorizedWhenInUse else { return }
        onMainQueue { [self] in beginLocationUpdates() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
