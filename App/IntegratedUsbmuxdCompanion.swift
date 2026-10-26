import Foundation
import GassPairFFI
import UIKit
import CryptoKit
import Darwin

/// In-app replacement for the macOS usbmuxd companion.
///
/// The Rust side (`gasspair_mux_*`) performs usbmuxd's `Connect` step itself
/// and then runs exactly the flow the Mac helper ran. This object drives it
/// without any user input: it finds the device (LocalDevVPN 10.7.0.1 first,
/// then the Wi-Fi addresses), retries on its own while the route is down,
/// creates + independently verifies the RPPairing record, and saves it with
/// complete file protection.
@MainActor
final class IntegratedUsbmuxdCompanion: ObservableObject {
    static let shared = IntegratedUsbmuxdCompanion()

    struct Device: Equatable {
        var udid: String
        var name: String
        var productType: String
        var iosVersion: String
        var endpoint: String
    }

    enum Phase: Equatable {
        /// No Lockdown.plist imported yet.
        case needsLockdown
        /// Ready; nothing running.
        case ready
        /// Looking for the device on `endpoint`.
        case searching(endpoint: String)
        /// The device could not be reached; an automatic retry is scheduled.
        case waitingForRoute(reason: String, retryIn: Int)
        /// Device attached, running a pairing/verification stage.
        case working(stage: String)
        /// A verified record is available.
        case succeeded(file: URL, message: String)
        /// Stopped after the device was reached (no automatic retry).
        case failed(message: String)
    }

    enum Job { case create, verifyImported }

    @Published private(set) var phase: Phase
    @Published private(set) var device: Device?
    @Published private(set) var log: [String] = []
    @Published var automatic: Bool {
        didSet {
            UserDefaults.standard.set(automatic, forKey: Keys.automatic)
            if !automatic { cancelRetry() }
        }
    }
    @Published var extraEndpoints: String {
        didSet { UserDefaults.standard.set(extraEndpoints, forKey: Keys.extraEndpoints) }
    }

    private enum Keys {
        static let automatic = "gasspair.mux.automatic"
        static let extraEndpoints = "gasspair.mux.extraEndpoints"
    }

    private let localNetwork = LocalNetworkAuthorization()
    private var askedLocalNetwork = false
    private var session: OpaquePointer?
    private var runCounter: UInt64 = 0
    private var activeRun: UInt64 = 0
    /// True between `start` and the moment the Rust run is launched (the Local
    /// Network prompt may be on screen); bumping the generation aborts it.
    private var launching = false
    private var launchGeneration: UInt64 = 0
    private var activeOperation: Job = .create
    private var attachedThisRun = false
    private var retryTask: Task<Void, Never>?
    private var consecutiveRouteFailures = 0
    private var isPresented = false
    /// Set when a new Lockdown.plist arrives while the screen is closed.
    private var createOnNextAppear = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {
        UserDefaults.standard.register(defaults: [Keys.automatic: true, Keys.extraEndpoints: ""])
        _automatic = Published(initialValue: UserDefaults.standard.bool(forKey: Keys.automatic))
        _extraEndpoints = Published(initialValue: UserDefaults.standard.string(forKey: Keys.extraEndpoints) ?? "")
        _phase = Published(initialValue: Self.initialPhase())
    }

    // MARK: - Files

    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var lockdownURL: URL { documents.appendingPathComponent("lockdown_pairing_imported.plist") }
    static var outputURL: URL { documents.appendingPathComponent("rp_pairing_file_from_lockdown_verified.plist") }
    static var importedRPURL: URL { documents.appendingPathComponent("rp_pairing_file_imported.plist") }
    static var verifiedImportedURL: URL { documents.appendingPathComponent("rp_pairing_file_imported_usbmuxd_verified.plist") }

    var hasLockdown: Bool { FileManager.default.fileExists(atPath: Self.lockdownURL.path) }
    var hasImportedRP: Bool { FileManager.default.fileExists(atPath: Self.importedRPURL.path) }
    var isBusy: Bool { activeRun != 0 || launching }

    private var isWaitingForRoute: Bool {
        if case .waitingForRoute = phase { return true }
        return false
    }

    private static func initialPhase() -> Phase {
        guard FileManager.default.fileExists(atPath: lockdownURL.path) else { return .needsLockdown }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return .succeeded(file: outputURL, message: "A verified RPPairing record created by the integrated companion is ready.")
        }
        return .ready
    }

    // MARK: - Lifecycle hooks (called by the view / app)

    func viewAppeared() {
        isPresented = true
        if createOnNextAppear && !isBusy && hasLockdown {
            createOnNextAppear = false
            phase = .ready
            start(.create)
            return
        }
        if !isBusy && !isWaitingForRoute { phase = Self.initialPhase() }
        if automatic { startAutomatically() }
    }

    func viewDisappeared() {
        isPresented = false
        cancelRetry() // a running operation keeps going; only the retry loop stops
    }

    func appBecameActive() {
        // The user typically returns after switching LocalDevVPN on: try now.
        guard isPresented, automatic, !isBusy, isWaitingForRoute else { return }
        start(.create)
    }

    /// Called after a new Lockdown.plist has been imported anywhere in the app.
    func lockdownImported() {
        guard !isBusy else { return }
        device = nil
        consecutiveRouteFailures = 0
        phase = .ready
        if isPresented {
            if automatic { start(.create) }
        } else {
            createOnNextAppear = automatic
        }
    }

    // MARK: - Actions

    /// Automatic mode: create a record unless a verified one already exists.
    func startAutomatically() {
        guard !isBusy else { return }
        switch phase {
        case .needsLockdown, .succeeded, .failed, .searching, .working: return
        case .ready, .waitingForRoute: start(.create)
        }
    }

    func start(_ operation: Job) {
        guard !isBusy else { return }
        cancelRetry()
        guard hasLockdown else { phase = .needsLockdown; return }
        if operation == .verifyImported && !hasImportedRP {
            phase = .failed(message: "Import an RPPairing file first (main screen › Import / Validate RP Pairing File).")
            return
        }
        launching = true
        launchGeneration += 1
        let generation = launchGeneration
        Task { await launch(operation, generation: generation) }
    }

    func cancel() {
        cancelRetry()
        launching = false
        launchGeneration += 1
        if let session { gasspair_session_cancel(session) }
        session = nil // the worker frees it when it returns
        activeRun = 0
        endBackgroundTask()
        phase = hasLockdown ? .ready : .needsLockdown
        append("Cancelled.")
    }

    // MARK: - Run

    private func launch(_ operation: Job, generation: UInt64) async {
        if !askedLocalNetwork {
            // Needed for Wi-Fi endpoints; LocalDevVPN (10.7.0.1) works either way,
            // so a refusal does not stop the flow.
            askedLocalNetwork = true
            phase = .searching(endpoint: "Local Network permission…")
            let granted = await localNetwork.request(timeout: 20)
            if !granted { append("Local Network permission not granted: only LocalDevVPN (10.7.0.1) will be tried.") }
        }
        guard generation == launchGeneration, activeRun == 0 else { return }
        launching = false
        guard let session = gasspair_session_new() else {
            phase = .failed(message: "Couldn't start an integrated usbmuxd session.")
            return
        }

        runCounter += 1
        let run = runCounter
        activeRun = run
        activeOperation = operation
        attachedThisRun = false
        self.session = session
        if consecutiveRouteFailures == 0 { log.removeAll() }
        beginBackgroundTask()

        let endpoints = candidateEndpoints()
        append("Endpoints: \(endpoints.joined(separator: ", "))")
        phase = .searching(endpoint: endpoints.first ?? "10.7.0.1")

        let endpointList = endpoints.joined(separator: "\n")
        let lockdownPath = Self.lockdownURL.path
        let rpPath = Self.importedRPURL.path
        let outPath = (operation == .create ? Self.outputURL : Self.verifiedImportedURL).path
        let sessionBits = UInt(bitPattern: session)
        let ctxBits = UInt(bitPattern: Unmanaged.passRetained(MuxRunContext(run: run)).toOpaque())

        let thread = Thread {
            guard let session = OpaquePointer(bitPattern: sessionBits) else { return }
            let ctx = UnsafeMutableRawPointer(bitPattern: ctxBits)
            var result = GassPairResult()
            let rc: Int32 = endpointList.withCString { e in
                lockdownPath.withCString { l in
                    "GassPair".withCString { n in
                        outPath.withCString { o in
                            switch operation {
                            case .create:
                                return gasspair_mux_create_rppairing(session, e, l, n, o, muxStatusCallback, ctx, &result)
                            case .verifyImported:
                                return rpPath.withCString { r in
                                    gasspair_mux_verify_rppairing(session, e, l, r, n, o, muxStatusCallback, ctx, &result)
                                }
                            }
                        }
                    }
                }
            }
            let outcome = MuxOutcome(rc: rc, result: result)
            gasspair_result_free(&result)
            if let ctx { Unmanaged<MuxRunContext>.fromOpaque(ctx).release() }
            onMainQueue {
                IntegratedUsbmuxdCompanion.shared.finish(run: run, session: session, outcome: outcome)
            }
        }
        thread.name = "GassPair integrated usbmuxd"
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    fileprivate func handleStatus(run: UInt64, code: Int32, message: String) {
        guard run == activeRun else { return }
        switch code {
        case GASSPAIR_STATUS_MUX_PROBING:
            phase = .searching(endpoint: message)
            append("Looking for the device on \(message)…")
        case GASSPAIR_STATUS_MUX_ENDPOINT_FAILED:
            append("✗ \(message)")
        case GASSPAIR_STATUS_MUX_ATTACHED:
            let parts = message.components(separatedBy: "\n")
            func part(_ i: Int) -> String { i < parts.count ? parts[i] : "" }
            device = Device(udid: part(0), name: part(1), productType: part(2), iosVersion: part(3), endpoint: part(4))
            attachedThisRun = true
            consecutiveRouteFailures = 0
            phase = .working(stage: "Device found — opening remotepairingdeviced…")
            append("✓ Device \(part(1).isEmpty ? part(0) : part(1)) (iOS \(part(3))) via \(part(4))")
        case GASSPAIR_STATUS_RP_COMPLETE:
            append("✓ Saved \(URL(fileURLWithPath: message).lastPathComponent)")
        case GASSPAIR_STATUS_RP_TRUST_LOADING:
            append(message)
        default:
            if attachedThisRun { phase = .working(stage: message) }
            append(message)
        }
    }

    private func finish(run: UInt64, session: OpaquePointer, outcome: MuxOutcome) {
        gasspair_session_free(session)
        if self.session == session { self.session = nil }
        guard run == activeRun else { return } // cancelled; UI already reset
        activeRun = 0
        endBackgroundTask()

        if !outcome.endpoint.isEmpty, var device {
            device.endpoint = outcome.endpoint
            if !outcome.osVersion.isEmpty { device.iosVersion = outcome.osVersion }
            self.device = device
        }

        if outcome.rc == GASSPAIR_OK {
            let url = URL(fileURLWithPath: outcome.path)
            do {
                try Self.protectAndValidate(url)
                let what = activeOperation == .create
                    ? "New RPPairing record created through the integrated usbmuxd companion and accepted by an independent pair-verify."
                    : "The imported RPPairing record passed pair-verify on the live device; a verified copy was written."
                phase = .succeeded(file: url, message: what)
                append("✓ Done.")
            } catch {
                try? FileManager.default.removeItem(at: url)
                phase = .failed(message: "The device verified the record but the saved file failed the local check: \(error.localizedDescription). It was removed.")
            }
            return
        }

        let message = outcome.error.isEmpty ? "Operation failed (code \(outcome.rc))." : outcome.error
        append("✗ \(message)")
        if outcome.rc == GASSPAIR_ERR_CANCELLED {
            phase = hasLockdown ? .ready : .needsLockdown
        } else if !attachedThisRun && automatic && isPresented {
            // The device was never reached: typically LocalDevVPN is off or the
            // phone is on another network. Keep retrying on our own.
            consecutiveRouteFailures += 1
            scheduleRetry(reason: message)
        } else if !attachedThisRun {
            phase = .waitingForRoute(reason: message, retryIn: 0)
        } else {
            phase = .failed(message: message)
        }
    }

    // MARK: - Automatic retry

    private func scheduleRetry(reason: String) {
        cancelRetry()
        let delay = min(5 * consecutiveRouteFailures, 30)
        phase = .waitingForRoute(reason: reason, retryIn: delay)
        retryTask = Task { [weak self] in
            for remaining in stride(from: delay, to: 0, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if case .waitingForRoute = self.phase {
                    self.phase = .waitingForRoute(reason: reason, retryIn: remaining - 1)
                }
            }
            guard !Task.isCancelled, let self, self.automatic, self.isPresented else { return }
            self.start(.create)
        }
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    // MARK: - Endpoints

    /// Order: user-provided addresses, LocalDevVPN, then this device's own
    /// Wi-Fi/Ethernet IPv4 addresses.
    func candidateEndpoints() -> [String] {
        var list: [String] = []
        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !list.contains(trimmed) { list.append(trimmed) }
        }
        extraEndpoints.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " }).forEach { add(String($0)) }
        add("10.7.0.1")
        Self.localInterfaceIPv4().forEach(add)
        return list
    }

    private static func localInterfaceIPv4() -> [String] {
        var result: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue } // Wi-Fi / Ethernet only; utun is the VPN itself
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254.") { result.append(ip) }
            }
        }
        return result
    }

    // MARK: - Helpers

    private func append(_ line: String) {
        log.append(line)
        if log.count > 60 { log.removeFirst(log.count - 60) }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "GassPair integrated usbmuxd") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Applies complete file protection and re-checks the record's structure and
    /// Ed25519 key consistency after the Rust side wrote and read it back.
    static func protectAndValidate(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try RPPairingFileCheck.validate(data)
    }

    /// Validates and stores an imported Lockdown pairing record.
    static func storeLockdown(_ data: Data) throws {
        guard data.count <= 2_097_152 else { throw RPPairingFileCheck.Failure("Lockdown plist exceeds 2 MiB.") }
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw RPPairingFileCheck.Failure("Lockdown file is not a property-list dictionary.")
        }
        let required = ["HostID", "SystemBUID", "HostCertificate", "HostPrivateKey", "RootCertificate", "RootPrivateKey", "DeviceCertificate"]
        let missing = required.filter { plist[$0] == nil }
        guard missing.isEmpty else {
            throw RPPairingFileCheck.Failure("Lockdown pairing record is missing: \(missing.joined(separator: ", ")).")
        }
        try data.write(to: lockdownURL, options: [.atomic])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: lockdownURL.path)
    }
}

/// Local structural + key-consistency check of an RPPairing plist.
enum RPPairingFileCheck {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func validate(_ data: Data, requireAltIRK: Bool = true) throws {
        guard data.count <= 1_048_576,
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let publicKey = plist["public_key"] as? Data,
              let privateKey = plist["private_key"] as? Data,
              let identifier = plist["identifier"] as? String,
              publicKey.count == 32, privateKey.count == 32,
              UUID(uuidString: identifier) != nil else {
            throw Failure("RPPairing plist is malformed or misses valid public_key/private_key/identifier.")
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        guard key.publicKey.rawRepresentation == publicKey else {
            throw Failure("The RPPairing public key does not match its private key.")
        }
        if let altIRK = plist["alt_irk"] as? Data {
            guard altIRK.count == 16 else { throw Failure("alt_irk must contain 16 bytes.") }
        } else if requireAltIRK {
            throw Failure("alt_irk (16 bytes) is missing.")
        }
    }
}

// MARK: - FFI glue

private final class MuxRunContext {
    let run: UInt64
    init(run: UInt64) { self.run = run }
}

private struct MuxOutcome {
    var rc: Int32
    var error: String
    var path: String
    var endpoint: String
    var osVersion: String

    init(rc: Int32, result: GassPairResult) {
        self.rc = rc
        error = muxString(result.error)
        path = muxString(result.pairing_file_path)
        endpoint = muxString(result.endpoint)
        osVersion = muxString(result.os_version)
    }
}

private func muxString(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr else { return "" }
    return String(cString: ptr)
}

/// The message pointer is only valid during the callback: copy it first.
private let muxStatusCallback: GassPairStatusCb = { ctx, code, message in
    guard let ctx else { return }
    let run = Unmanaged<MuxRunContext>.fromOpaque(ctx).takeUnretainedValue().run
    let text = message.map { String(cString: $0) } ?? ""
    onMainQueue {
        IntegratedUsbmuxdCompanion.shared.handleStatus(run: run, code: code, message: text)
    }
}
