import Combine
import Foundation
import GassPairFFI
import UIKit
import UserNotifications

/// Drives both on-device pairing flows:
/// * **iPhone / iPad** — GassPair advertises itself as a pairable host and the
///   device pairs to it from Settings › Privacy & Security › Developer Mode.
/// * **Apple TV** — GassPair connects to the TV and the user types its PIN here.
@MainActor
final class PairingController: NSObject, ObservableObject {

    static let shared = PairingController()
    /// The device-initiated "Pair with …" entry in Settings › Developer Mode
    /// exists from iOS 27. Older systems can still host pairing for another device.
    static var thisDeviceCanSelfPair: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
    }
    static let hostName = "GassPair"
    static let hostModel = "Mac17,7"

    enum Kind: String, Codable {
        case iOSDevice
        case appleTV

        var fileName: String {
            switch self {
            case .iOSDevice: return "rp_pairing_file.plist"
            case .appleTV: return "appletv_rp_pairing_file.plist"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case preparing
        case waiting
        case showPin(String)
        case browsingAppleTV
        case enteringAppleTVPin(AppleTVDevice, attempt: Int)
        case pairingAppleTV(String)
        case success(PairedDevice)
        case failed(String)
    }

    struct PairedDevice: Equatable, Codable {
        var name: String
        var model: String
        var udid: String
        var pairingFilePath: String
        var kind: Kind
        var verified: Bool
        var date: Date
    }

    @Published var phase: Phase = .idle
    /// Secondary, human-readable progress line ("Device connected…", errors of a
    /// single attempt, etc.).
    @Published private(set) var statusLine: String?
    @Published private(set) var appleTVs: [AppleTVDevice] = []
    @Published private(set) var lastPairing: PairedDevice?

    @Published var keepAliveAudio: Bool {
        didSet { UserDefaults.standard.set(keepAliveAudio, forKey: Keys.audio) }
    }
    @Published var keepAliveLocation: Bool {
        didSet { UserDefaults.standard.set(keepAliveLocation, forKey: Keys.location) }
    }

    private enum Keys {
        static let audio = "keepAlive.audio"
        static let location = "keepAlive.location"
        static let lastPairing = "lastPairing"
    }

    private let localNetwork = LocalNetworkAuthorization()
    private let keepAlive = KeepAlive()
    private let appleTVDiscovery = AppleTVDiscovery()
    private var discoverySubscription: AnyCancellable?

    // Current run
    private var runCounter: UInt64 = 0
    private var activeRun: UInt64 = 0
    private var activeKind: Kind?
    private var session: OpaquePointer?
    private var activeAppleTV: AppleTVDevice?

    // Advertising (iPhone/iPad flow)
    private var netService: NetService?
    private var advertisement: (id: String, port: Int32, txt: [String: Data])?

    // Background execution (iOS 16+): silent-audio / location keep-alive plus
    // a UIKit background task. No iOS 26-only APIs.
    private var uiBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    var isBusy: Bool {
        if activeRun != 0 { return true }
        switch phase {
        case .preparing, .waiting, .showPin, .enteringAppleTVPin, .pairingAppleTV: return true
        default: return false
        }
    }

    private override init() {
        // Silent audio is the most reliable way to stay alive while the user is
        // in Settings, so it's on unless the user turned it off.
        UserDefaults.standard.register(defaults: [Keys.audio: true, Keys.location: false])
        _keepAliveAudio = Published(initialValue: UserDefaults.standard.bool(forKey: Keys.audio))
        _keepAliveLocation = Published(initialValue: UserDefaults.standard.bool(forKey: Keys.location))
        super.init()
        lastPairing = Self.loadLastPairing()
        discoverySubscription = appleTVDiscovery.$devices
            .sink { [weak self] devices in self?.appleTVs = devices }
    }

    // MARK: - iPhone / iPad flow

    func startDevicePairing() {
        guard !isBusy else { return }
        phase = .preparing
        statusLine = nil

        Task {
            await requestNotificationPermission()
            let authorized = await localNetwork.request()
            guard case .preparing = phase else { return } // cancelled meanwhile
            guard authorized else {
                phase = .failed(Self.localNetworkMessage)
                return
            }
            beginHostRun()
        }
    }

    private func beginHostRun() {
        guard let session = gasspair_session_new() else {
            phase = .failed("Couldn't start a pairing session.")
            return
        }
        runCounter += 1
        let run = runCounter
        activeRun = run
        activeKind = .iOSDevice
        self.session = session
        phase = .waiting
        statusLine = nil

        if keepAliveAudio { keepAlive.startAudio() }
        if keepAliveLocation { keepAlive.startLocation() }
        beginUIKitBackgroundTask()

        let name = Self.hostName
        let model = Self.hostModel
        let outPath = Self.pairingFileURL(for: .iOSDevice).path
        let sessionBits = UInt(bitPattern: session)
        let ctxBits = UInt(bitPattern: Unmanaged.passRetained(RunContext(run: run)).toOpaque())

        startWorker {
            guard let session = OpaquePointer(bitPattern: sessionBits) else { return }
            let ctx = UnsafeMutableRawPointer(bitPattern: ctxBits)
            var result = GassPairResult()
            let rc = name.withCString { nameC in
                model.withCString { modelC in
                    outPath.withCString { outC in
                        gasspair_run_host(
                            session, nameC, modelC, outC, 0,
                            hostReadyCallback, hostPinCallback, statusCallback,
                            ctx, &result)
                    }
                }
            }
            let outcome = RunOutcome(rc: rc, result: result)
            gasspair_result_free(&result)
            if let ctx { Unmanaged<RunContext>.fromOpaque(ctx).release() }

            onMainQueue {
                PairingController.shared.finishRun(run, session: session, kind: .iOSDevice, outcome: outcome)
            }
        }
    }

    // MARK: - Apple TV flow

    func browseForAppleTVs() {
        guard !isBusy || phase == .browsingAppleTV else { return }
        phase = .browsingAppleTV
        statusLine = nil
        Task {
            let authorized = await localNetwork.request()
            guard case .browsingAppleTV = phase else { return }
            guard authorized else {
                phase = .failed(Self.localNetworkMessage)
                return
            }
            appleTVDiscovery.start()
        }
    }

    func refreshAppleTVs() {
        guard case .browsingAppleTV = phase else { return }
        appleTVDiscovery.restart()
    }

    func pairAppleTV(_ device: AppleTVDevice) {
        guard activeRun == 0, let session = gasspair_session_new() else { return }
        appleTVDiscovery.stop()
        runCounter += 1
        let run = runCounter
        activeRun = run
        activeKind = .appleTV
        activeAppleTV = device
        self.session = session
        phase = .pairingAppleTV("Connecting to \(device.name)…")
        statusLine = nil
        beginUIKitBackgroundTask()

        let hosts = device.connectCandidates.joined(separator: "\n")
        let port = UInt16(clamping: device.port)
        let name = Self.hostName
        let outPath = Self.pairingFileURL(for: .appleTV).path
        let sessionBits = UInt(bitPattern: session)
        let ctxBits = UInt(bitPattern: Unmanaged.passRetained(RunContext(run: run)).toOpaque())

        startWorker {
            guard let session = OpaquePointer(bitPattern: sessionBits) else { return }
            let ctx = UnsafeMutableRawPointer(bitPattern: ctxBits)
            var result = GassPairResult()
            let rc = hosts.withCString { hostsC in
                name.withCString { nameC in
                    outPath.withCString { outC in
                        gasspair_pair_apple_tv(
                            session, hostsC, port, nameC, outC,
                            appleTVPinRequestCallback, statusCallback,
                            ctx, &result)
                    }
                }
            }
            let outcome = RunOutcome(rc: rc, result: result)
            gasspair_result_free(&result)
            if let ctx { Unmanaged<RunContext>.fromOpaque(ctx).release() }

            onMainQueue {
                PairingController.shared.finishRun(run, session: session, kind: .appleTV, outcome: outcome)
            }
        }
    }

    func submitAppleTVPin(_ pin: String) {
        guard pin.count == 6, pin.allSatisfy(\.isASCIIDigit), let session,
              case .enteringAppleTVPin(let device, _) = phase else { return }
        let rc = pin.withCString { gasspair_session_submit_pin(session, $0) }
        if rc == GASSPAIR_OK {
            phase = .pairingAppleTV("Pairing with \(device.name)…")
            statusLine = nil
        } else {
            statusLine = "Enter the six digits shown on the Apple TV."
        }
    }

    // MARK: - Cancel / reset

    func cancel() {
        if let session { gasspair_session_cancel(session) }
        session = nil // the worker frees it when it returns
        activeRun = 0
        activeKind = nil
        activeAppleTV = nil
        appleTVDiscovery.stop()
        tearDownRunResources()
        phase = .idle
        statusLine = nil
    }

    func reset() {
        guard activeRun == 0 else { return }
        appleTVDiscovery.stop()
        phase = .idle
        statusLine = nil
    }

    /// Called when the app returns to the foreground.
    func appBecameActive() {
        guard activeKind == .iOSDevice else { return }
        // mDNS registrations can go stale while suspended; publish again.
        republishAdvertisement()
    }

    // MARK: - Run completion

    private func finishRun(_ run: UInt64, session: OpaquePointer, kind: Kind, outcome: RunOutcome) {
        gasspair_session_free(session)
        if self.session == session { self.session = nil }
        guard run == activeRun else { return } // cancelled earlier; UI already reset

        activeRun = 0
        activeKind = nil
        activeAppleTV = nil
        let succeeded = outcome.rc == GASSPAIR_OK
        tearDownRunResources(success: succeeded)

        switch outcome.rc {
        case GASSPAIR_OK:
            let device = PairedDevice(
                name: outcome.name,
                model: outcome.model,
                udid: outcome.udid,
                pairingFilePath: outcome.path,
                kind: kind,
                verified: outcome.verified,
                date: Date())
            lastPairing = device
            Self.saveLastPairing(device)
            statusLine = nil
            phase = .success(device)
            notify(id: "gasspair.done",
                   title: "Pairing complete",
                   body: "Return to GassPair to export the pairing file.")
        case GASSPAIR_ERR_CANCELLED:
            phase = .idle
        default:
            let message = outcome.error.isEmpty ? "Pairing failed (code \(outcome.rc))." : outcome.error
            phase = .failed(message)
            if kind == .iOSDevice {
                notify(id: "gasspair.failed", title: "Pairing failed", body: message)
            }
        }
    }

    private func tearDownRunResources(success: Bool = false) {
        stopAdvertising()
        advertisement = nil
        keepAlive.stopAll()
        endUIKitBackgroundTask()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["gasspair.pin"])
    }

    // MARK: - Callbacks from Rust (already on the main queue)

    fileprivate func handleReady(run: UInt64, serviceID: String, port: Int32, txt: [String: Data]) {
        guard run == activeRun else { return }
        advertisement = (serviceID, port, txt)
        republishAdvertisement()
    }

    fileprivate func handlePin(run: UInt64, pin: String) {
        guard run == activeRun else { return }
        phase = .showPin(pin)
        statusLine = "Code copied to the clipboard."
        UIPasteboard.general.string = pin
        notify(id: "gasspair.pin",
               title: "GassPair code: \(pin)",
               body: "Enter \(pin) on this device to finish pairing.")
    }

    fileprivate func handlePinRequest(run: UInt64, attempt: Int) {
        guard run == activeRun, let device = activeAppleTV else { return }
        phase = .enteringAppleTVPin(device, attempt: attempt)
    }

    fileprivate func handleStatus(run: UInt64, code: Int32, message: String) {
        guard run == activeRun else { return }
        switch code {
        case GASSPAIR_STATUS_LISTENING, GASSPAIR_STATUS_RELISTENING:
            if code == GASSPAIR_STATUS_RELISTENING { statusLine = "Listener restarted." }
        case GASSPAIR_STATUS_CONNECTED:
            statusLine = "Device connected…"
        case GASSPAIR_STATUS_ATTEMPT_FAILED:
            // The listener keeps running: the user can simply tap
            // "Pair with GassPair" again and a new code will be generated.
            statusLine = message
            if case .showPin = phase {
                phase = .waiting
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["gasspair.pin"])
                notify(id: "gasspair.retry", title: "Pairing attempt failed", body: message)
            }
        case GASSPAIR_STATUS_CONNECTING:
            statusLine = "Connecting to \(message)…"
        case GASSPAIR_STATUS_WRONG_PIN:
            statusLine = message
        case GASSPAIR_STATUS_VERIFYING:
            phase = .pairingAppleTV("Verifying the pairing…")
            statusLine = nil
        case GASSPAIR_STATUS_VERIFY_FAILED:
            statusLine = "Verification: \(message)"
        case GASSPAIR_STATUS_SAVING:
            statusLine = "Saving the pairing file…"
        default:
            if !message.isEmpty { statusLine = message }
        }
    }

    // MARK: - Advertising

    private func republishAdvertisement() {
        guard let ad = advertisement else { return }
        stopAdvertising()
        let service = NetService(
            domain: "local.",
            type: "_remotepairing-pairable-host._tcp.",
            name: ad.id,
            port: ad.port)
        service.includesPeerToPeer = false
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: ad.txt))
        service.publish()
        netService = service
    }

    private func stopAdvertising() {
        netService?.delegate = nil
        netService?.stop()
        netService = nil
    }

    // MARK: - Background execution

    private func beginUIKitBackgroundTask() {
        endUIKitBackgroundTask()
        uiBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GassPair pairing") {
            // Must end the task synchronously, before this handler returns.
            runOnMainNow { PairingController.shared.uiBackgroundTaskExpired() }
        }
    }

    private func uiBackgroundTaskExpired() {
        endUIKitBackgroundTask()
        // Without a keep-alive iOS suspends us now; the listener resumes and
        // re-advertises when the app is opened again.
        if activeKind == .iOSDevice && !keepAliveAudio && !keepAliveLocation {
            notify(id: "gasspair.expired",
                   title: "GassPair needs more time",
                   body: "Open GassPair to keep waiting, or turn on Silent audio keep-alive.")
        }
    }

    private func endUIKitBackgroundTask() {
        guard uiBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(uiBackgroundTask)
        uiBackgroundTask = .invalid
    }

    // MARK: - Notifications

    private func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    private func notify(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Files

    static func pairingFileURL(for kind: Kind) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(kind.fileName)
    }

    private static func loadLastPairing() -> PairedDevice? {
        guard let data = UserDefaults.standard.data(forKey: Keys.lastPairing),
              var device = try? JSONDecoder().decode(PairedDevice.self, from: data) else { return nil }
        // The app container path changes between installs/updates.
        device.pairingFilePath = pairingFileURL(for: device.kind).path
        return FileManager.default.fileExists(atPath: device.pairingFilePath) ? device : nil
    }

    private static func saveLastPairing(_ device: PairedDevice) {
        if let data = try? JSONEncoder().encode(device) {
            UserDefaults.standard.set(data, forKey: Keys.lastPairing)
        }
    }

    private static let localNetworkMessage =
        "Local Network permission is required. Enable it in Settings › Apps › GassPair › Local Network, then try again."

    // MARK: - Worker thread

    /// Pairing blocks for minutes and runs deep async state machines, so it gets
    /// a dedicated thread with a generous stack instead of a GCD worker.
    private func startWorker(_ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.name = "GassPair pairing"
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

extension PairingController: NetServiceDelegate {
    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        Task { @MainActor in
            guard sender === self.netService else { return }
            self.statusLine = "Couldn't advertise on the local network (\(code)). Retrying…"
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard sender === self.netService else { return }
            self.republishAdvertisement()
        }
    }
}

// MARK: - FFI glue

private final class RunContext {
    let run: UInt64
    init(run: UInt64) { self.run = run }
}

private struct RunOutcome {
    var rc: Int32
    var error: String
    var name: String
    var model: String
    var udid: String
    var path: String
    var verified: Bool

    init(rc: Int32, result: GassPairResult) {
        self.rc = rc
        error = cString(result.error)
        name = cString(result.device_name)
        model = cString(result.device_model)
        udid = cString(result.device_udid)
        path = cString(result.pairing_file_path)
        verified = result.verified != 0
    }
}

private func runID(_ ctx: UnsafeMutableRawPointer?) -> UInt64? {
    guard let ctx else { return nil }
    return Unmanaged<RunContext>.fromOpaque(ctx).takeUnretainedValue().run
}

private let hostReadyCallback: GassPairReadyCb = { ctx, serviceID, port, keys, vals, count in
    guard let run = runID(ctx), let serviceID else { return }
    let id = String(cString: serviceID)
    var txt: [String: Data] = [:]
    if let keys, let vals {
        for i in 0..<count {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }
    onMainQueue {
        PairingController.shared.handleReady(run: run, serviceID: id, port: Int32(port), txt: txt)
    }
}

private let hostPinCallback: GassPairPinCb = { ctx, pin in
    guard let run = runID(ctx), let pin else { return }
    let value = String(cString: pin)
    onMainQueue {
        PairingController.shared.handlePin(run: run, pin: value)
    }
}

private let appleTVPinRequestCallback: GassPairPinRequestCb = { ctx, attempt in
    guard let run = runID(ctx) else { return }
    onMainQueue {
        PairingController.shared.handlePinRequest(run: run, attempt: Int(attempt))
    }
}

private let statusCallback: GassPairStatusCb = { ctx, code, message in
    guard let run = runID(ctx) else { return }
    let text = message.map { String(cString: $0) } ?? ""
    onMainQueue {
        PairingController.shared.handleStatus(run: run, code: code, message: text)
    }
}

/// Runs main-actor code on the main dispatch queue, preserving FIFO order of
/// the Rust callbacks. Equivalent of `MainActor.assumeIsolated` (iOS 17+)
/// that also works on iOS 16.
func onMainQueue(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        dispatchPrecondition(condition: .onQueue(.main))
        typealias Plain = () -> Void
        unsafeBitCast(body, to: Plain.self)()
    }
}

/// Runs main-actor code synchronously; caller must already be on the main queue.
func runOnMainNow(_ body: @MainActor () -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    typealias Plain = () -> Void
    withoutActuallyEscaping(body) { fn in
        unsafeBitCast(fn, to: Plain.self)()
    }
}

private func cString(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr else { return "" }
    return String(cString: ptr)
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
