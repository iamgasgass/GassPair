import Combine
import Foundation
import Network
import SwiftUI
import GassPairFFI

// MARK: - Probe model

enum LocalDevVPNProbeMode: String, CaseIterable, Identifiable {
    case tcpOnly
    case lockdown

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tcpOnly: return "TCP only"
        case .lockdown: return "TCP + Lockdown"
        }
    }
}

/// This is deliberately a probe, not a pairing implementation. It can prove
/// socket reachability and ordinary Lockdown plist behaviour, but never sends
/// Pair/CUPairingCreate and never writes a pairing record.
@MainActor
final class LocalDevVPNProbeModel: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var title = "Not tested"
    @Published private(set) var details = "Enter the LocalDevVPN Device/Peer IP without a route prefix, then test TCP port 62078."
    @Published private(set) var isReachable: Bool?
    @Published private(set) var normalizationNotice: String?
    @Published private(set) var trace: [String] = []
    @Published private(set) var testedHost = ""
    @Published private(set) var selectedMode: LocalDevVPNProbeMode = .tcpOnly

    private var connection: NWConnection?
    private var generation: UInt64 = 0
    private var received = Data()
    private var expectedLength: Int?
    private var sentInitialRequest = false
    private var connectionBecameReady = false
    private var requestWasSent = false
    private var activeRequestName = "QueryType"
    private var expectedReply: ReplyKind = .queryType
    private var startedAt = Date()
    private var lastNetworkState = "not started"
    private var lastWaitingError: String?
    private var totalBytesReceived = 0

    private let maxFrameBytes = 2 * 1024 * 1024
    private let tcpConnectTimeout: TimeInterval = 8
    private let lockdownRoundTripTimeout: TimeInterval = 12

    private enum ReplyKind: Equatable {
        case queryType
        case productVersion
    }

    private enum ProbeError: LocalizedError {
        case invalidFrameLength(Int)
        case invalidPropertyList
        case oversizedResponse

        var errorDescription: String? {
            switch self {
            case .invalidFrameLength(let value):
                return "lockdownd returned an invalid plist frame length (\(value) bytes)."
            case .invalidPropertyList:
                return "TCP connected, but the response body was not a valid plist dictionary."
            case .oversizedResponse:
                return "The peer exceeded the 2 MiB response safety limit."
            }
        }
    }

    /// Starts a test and returns the canonical host on success so the SwiftUI
    /// field can persist the corrected value (e.g. 10.7.0.1/32 -> 10.7.0.1).
    @discardableResult
    func test(host rawHost: String, mode: LocalDevVPNProbeMode) -> String? {
        selectedMode = mode
        let destination: LocalDevVPNDestination
        do {
            destination = try LocalDevVPNDestination.parse(rawHost)
        } catch {
            generation &+= 1
            stopCurrentConnection()
            isBusy = false
            isReachable = false
            normalizationNotice = nil
            title = "Invalid destination"
            details = error.localizedDescription
            trace = ["Validation failed: \(error.localizedDescription)"]
            testedHost = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            return nil
        }

        stopCurrentConnection()
        generation &+= 1
        let token = generation
        // Data can retain a non-zero startIndex after removeFirst(). Recreate it
        // instead of clearing in place, so a new Lockdown response starts at index 0.
        received = Data()
        expectedLength = nil
        sentInitialRequest = false
        connectionBecameReady = false
        requestWasSent = false
        activeRequestName = "QueryType"
        expectedReply = .queryType
        totalBytesReceived = 0
        startedAt = Date()
        lastNetworkState = "setup"
        lastWaitingError = nil
        trace.removeAll(keepingCapacity: true)
        selectedMode = mode
        testedHost = destination.host
        normalizationNotice = destination.normalizationNotice
        isBusy = true
        isReachable = nil
        title = mode == .tcpOnly ? "Opening TCP…" : "Connecting to Lockdown…"
        details = "Opening \(destination.host):62078 through the system network routes."
        record("Start \(mode.title) test for \(destination.host):62078")
        if let notice = destination.normalizationNotice {
            record("Input normalized: \(notice)")
        }
        record("TCP timeout: \(Int(tcpConnectTimeout)) s; Lockdown exchange timeout: \(Int(lockdownRoundTripTimeout)) s after TCP connects")

        guard let port = NWEndpoint.Port(rawValue: 62078) else {
            finish(token, title: "Invalid port", details: "TCP port 62078 could not be represented.", reachable: false)
            return nil
        }

        let connection = NWConnection(host: NWEndpoint.Host(destination.host), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isBusy else { return }
                self.lastNetworkState = self.describe(state)
                self.record("NWConnection state: \(self.lastNetworkState)")

                switch state {
                case .ready:
                    guard !self.sentInitialRequest else { return }
                    self.sentInitialRequest = true
                    self.connectionBecameReady = true
                    self.lastWaitingError = nil
                    self.title = "TCP connected"
                    self.details = "TCP handshake succeeded for \(destination.host):62078."
                    self.record("TCP handshake completed in \(self.elapsed) s")

                    if mode == .tcpOnly {
                        self.finish(
                            token,
                            title: "TCP port reachable",
                            details: "TCP to \(destination.host):62078 reached the ready state. This test sent no Lockdown plist and did not test pairing support.",
                            reachable: true)
                        return
                    }

                    self.details += " Sending Lockdown QueryType."
                    self.record("Preparing Lockdown QueryType plist")
                    self.scheduleLockdownTimeout(token: token, host: destination.host)
                    self.send(
                        ["Label": "GassPair LocalDevVPN diagnostic", "Request": "QueryType"],
                        expecting: .queryType,
                        on: connection,
                        token: token)

                case .waiting(let error):
                    self.lastWaitingError = error.localizedDescription
                    self.details = "The network stack is waiting for \(destination.host):62078: \(error.localizedDescription)"
                    self.record("NWConnection waiting: \(error.localizedDescription)")

                case .failed(let error):
                    self.finish(
                        token,
                        title: "TCP connection failed",
                        details: "Could not open TCP to \(destination.host):62078. Network.framework reported: \(error.localizedDescription). Last state: \(self.lastNetworkState). This is before any Lockdown request.",
                        reachable: false)

                case .cancelled:
                    self.record("NWConnection cancelled")

                default:
                    break
                }
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))

        DispatchQueue.main.asyncAfter(deadline: .now() + tcpConnectTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isBusy, !self.connectionBecameReady else { return }
                let waiting = self.lastWaitingError.map { " Last waiting error: \($0)." } ?? ""
                self.finish(
                    token,
                    title: "TCP connect timed out",
                    details: "NWConnection did not reach ready for \(destination.host):62078 within \(Int(self.tcpConnectTimeout)) seconds. Last observed state: \(self.lastNetworkState).\(waiting) No Lockdown request was sent. Verify the LocalDevVPN Device/Peer IP, that the tunnel is connected, and that Wi-Fi is actually joined to a network. A CIDR suffix, if present in the original entry, has already been removed.",
                    reachable: false)
            }
        }

        return destination.host
    }

    func cancel() {
        generation &+= 1
        record("User cancelled the test")
        stopCurrentConnection()
        isBusy = false
        title = "Test cancelled"
        details = "The diagnostic was cancelled. No Pair/CUPairingCreate request was sent and no pairing file was created."
        isReachable = nil
    }

    var diagnosticReport: String {
        var lines = [
            "GassPair LocalDevVPN diagnostic",
            "Result: \(title)",
            "Destination: \(testedHost.isEmpty ? "(none)" : testedHost):62078",
            "Mode: \(selectedMode.title)",
            "Reachable: \(isReachable.map { String(describing: $0) } ?? "unknown")",
            "Details: \(details)"
        ]
        if let normalizationNotice { lines.append("Normalization: \(normalizationNotice)") }
        lines.append("")
        lines.append(contentsOf: trace)
        lines.append("")
        lines.append("This diagnostic never sends Pair/CUPairingCreate and never writes a pairing record.")
        return lines.joined(separator: "\n")
    }

    private var elapsed: String {
        String(format: "%.2f", Date().timeIntervalSince(startedAt))
    }

    private func record(_ message: String) {
        trace.append("+\(elapsed)s  \(message)")
        // Keep the report bounded even if Network.framework emits repeated waiting states.
        if trace.count > 80 { trace.removeFirst(trace.count - 80) }
    }

    private func describe(_ state: NWConnection.State) -> String {
        switch state {
        case .setup: return "setup"
        case .waiting(let error): return "waiting (\(error.localizedDescription))"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case .failed(let error): return "failed (\(error.localizedDescription))"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown state"
        }
    }

    private func scheduleLockdownTimeout(token: UInt64, host: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + lockdownRoundTripTimeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isBusy, self.connectionBecameReady else { return }
                self.finish(
                    token,
                    title: "Lockdown response timed out",
                    details: self.lockdownTimeoutExplanation(host: host),
                    reachable: false)
            }
        }
    }

    private func lockdownTimeoutExplanation(host: String) -> String {
        guard requestWasSent else {
            return "TCP to \(host):62078 reached ready, but the \(activeRequestName) send did not complete within \(Int(lockdownRoundTripTimeout)) seconds. Last state: \(lastNetworkState). The socket opened, but the request was not confirmed sent."
        }
        guard !received.isEmpty else {
            return "TCP to \(host):62078 connected and \(activeRequestName) was sent, but zero response bytes arrived within \(Int(lockdownRoundTripTimeout)) seconds. This is no longer a TCP-connect failure: the route reached a listening TCP endpoint, but no Lockdown response was observed. Verify the destination alias and packet-swap route; the service may also ignore or filter the request."
        }
        if expectedLength == nil {
            return "TCP connected and \(activeRequestName) was sent. Received \(received.count) response byte(s), fewer than the 4 bytes required for Lockdown's length header, before the deadline. The peer may speak another protocol or the response may be truncated. Total bytes received: \(totalBytesReceived)."
        }
        let expected = expectedLength ?? 0
        return "TCP connected and \(activeRequestName) was sent. Received \(received.count) of \(expected) expected plist body bytes before the deadline. The peer started a framed response but did not finish it. Total bytes received: \(totalBytesReceived)."
    }

    private func send(
        _ request: [String: Any],
        expecting reply: ReplyKind,
        on connection: NWConnection,
        token: UInt64
    ) {
        do {
            let body = try PropertyListSerialization.data(
                fromPropertyList: request,
                format: .xml,
                options: 0)
            guard body.count <= maxFrameBytes, body.count <= Int(UInt32.max) else {
                finish(token, title: "Request too large", details: "The diagnostic plist exceeded its safety limit.", reachable: false)
                return
            }

            var length = UInt32(body.count).bigEndian
            var framed = Data()
            withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
            framed.append(body)
            expectedReply = reply
            activeRequestName = reply == .queryType ? "QueryType" : "GetValue(ProductVersion)"
            requestWasSent = false
            // Never reuse a Data whose indices may have advanced while decoding the
            // previous frame. The second Lockdown round-trip previously could subscript
            // received[0] with startIndex > 0 and crash the app.
            received = Data()
            expectedLength = nil
            record("Sending \(activeRequestName): \(body.count)-byte XML plist plus 4-byte big-endian length header")

            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.isBusy else { return }
                    if let error {
                        self.finish(
                            token,
                            title: "Lockdown send failed",
                            details: "The \(self.activeRequestName) request could not be sent: \(error.localizedDescription)",
                            reachable: false)
                        return
                    }
                    self.requestWasSent = true
                    self.record("\(self.activeRequestName) send completed")
                    self.details = "TCP connected; \(self.activeRequestName) sent. Waiting for a Lockdown plist response."
                    self.receive(on: connection, token: token)
                }
            })
        } catch {
            finish(token, title: "Could not build request", details: error.localizedDescription, reachable: false)
        }
    }

    private func receive(on connection: NWConnection, token: UInt64) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isBusy else { return }

                if let data, !data.isEmpty {
                    self.received.append(data)
                    self.totalBytesReceived += data.count
                    self.record("Received \(data.count) byte(s); current reply buffer = \(self.received.count) byte(s)")
                    guard self.received.count <= self.maxFrameBytes + 4 else {
                        self.finish(token, title: "Response too large", details: ProbeError.oversizedResponse.localizedDescription ?? "Oversized response.", reachable: false)
                        return
                    }
                }

                do {
                    if let frame = try self.extractFrame() {
                        self.handle(frame: frame, on: connection, token: token)
                        return
                    }
                } catch {
                    self.finish(token, title: "Invalid response frame", details: error.localizedDescription, reachable: false)
                    return
                }

                if let error {
                    self.finish(token, title: "Lockdown receive failed", details: "The \(self.activeRequestName) response could not be read: \(error.localizedDescription)", reachable: false)
                    return
                }
                if isComplete {
                    self.finish(token, title: "Connection closed", details: "The endpoint closed before returning a complete Lockdown plist for \(self.activeRequestName). Received \(self.received.count) unframed/body byte(s).", reachable: false)
                } else {
                    self.receive(on: connection, token: token)
                }
            }
        }
    }

    private func extractFrame() throws -> Data? {
        if expectedLength == nil {
            guard received.count >= 4 else { return nil }
            // Data is a Collection whose startIndex may be non-zero after removeFirst.
            // Index relative to its current start, never literal indices 0...3.
            let start = received.startIndex
            let b0 = Int(received[received.index(start, offsetBy: 0)])
            let b1 = Int(received[received.index(start, offsetBy: 1)])
            let b2 = Int(received[received.index(start, offsetBy: 2)])
            let b3 = Int(received[received.index(start, offsetBy: 3)])
            let length = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            guard length > 0, length <= maxFrameBytes else {
                throw ProbeError.invalidFrameLength(length)
            }
            expectedLength = length
            // Rebase indices to zero after dropping the prefix. This also makes the
            // remaining partial body safe for future appends and reads.
            received = Data(received.dropFirst(4))
            record("Lockdown frame header parsed; expected plist body = \(length) byte(s)")
        }

        guard let length = expectedLength, received.count >= length else { return nil }
        let frame = Data(received.prefix(length))
        // Explicitly rebase leftovers rather than retaining a shifted Data index.
        received = Data(received.dropFirst(length))
        expectedLength = nil
        return frame
    }

    private func handle(frame: Data, on connection: NWConnection, token: UInt64) {
        guard let object = try? PropertyListSerialization.propertyList(from: frame, options: [], format: nil),
              let response = object as? [String: Any] else {
            finish(token, title: "Not a Lockdown plist", details: ProbeError.invalidPropertyList.localizedDescription ?? "Invalid plist.", reachable: false)
            return
        }
        record("Parsed plist dictionary for \(activeRequestName)")

        if let errorName = response["Error"] as? String {
            let lockdownWasIdentified = expectedReply == .productVersion
            finish(
                token,
                title: "Lockdown returned an error",
                details: "The endpoint responded with a valid plist but returned Error = \(errorName) for \(activeRequestName). TCP and plist framing work; \(lockdownWasIdentified ? "QueryType had already confirmed Lockdown" : "the service type was not confirmed"). The requested operation did not succeed.",
                reachable: lockdownWasIdentified)
            return
        }

        switch expectedReply {
        case .queryType:
            guard let type = response["Type"] as? String else {
                finish(token, title: "Lockdown not confirmed", details: "QueryType returned a valid plist without a Type field. Keys received: \(response.keys.sorted().joined(separator: ", ")).", reachable: false)
                return
            }
            guard type == "com.apple.mobile.lockdown" else {
                finish(token, title: "Unexpected service", details: "QueryType returned ‘\(type)’ rather than com.apple.mobile.lockdown.", reachable: false)
                return
            }
            title = "Lockdown identified"
            details = "QueryType succeeded. Requesting ProductVersion to verify a second complete plist round-trip."
            record("QueryType confirmed service type com.apple.mobile.lockdown")
            send(
                ["Label": "GassPair LocalDevVPN diagnostic", "Request": "GetValue", "Key": "ProductVersion"],
                expecting: .productVersion,
                on: connection,
                token: token)

        case .productVersion:
            guard let version = response["Value"] as? String, !version.isEmpty else {
                finish(token, title: "Lockdown replied incompletely", details: "QueryType succeeded, but GetValue(ProductVersion) returned no non-empty Value. Keys received: \(response.keys.sorted().joined(separator: ", ")). Lockdown is reachable, but the diagnostic round-trip was incomplete.", reachable: true)
                return
            }
            finish(
                token,
                title: "Lockdown is reachable",
                details: "QueryType succeeded and ProductVersion = \(version). This confirms TCP routing and two Lockdown plist round-trips only. It does not prove that iOS accepts classic self-pairing, and no pairing record was generated.",
                reachable: true)
        }
    }

    private func finish(_ token: UInt64, title: String, details: String, reachable: Bool?) {
        guard generation == token else { return }
        record("Finished: \(title)")
        isBusy = false
        self.title = title
        self.details = details
        isReachable = reachable
        stopCurrentConnection()
    }

    private func stopCurrentConnection() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }
}

// MARK: - User interface

struct LocalDevVPNProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LocalDevVPNProbeModel()
    @AppStorage("gasspair.localDevVPN.lockdownHost") private var host = "10.7.0.1"
    @State private var mode: LocalDevVPNProbeMode = .tcpOnly
    @State private var showingClassicPairConfirmation = false
    @State private var classicPairBusy = false
    @State private var classicPairResult: String?

    var body: some View {
        Form {
            Section("Destination") {
                TextField("Device/Peer IP, e.g. 10.7.0.1", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .disabled(model.isBusy)

                LabeledContent("TCP port", value: "62078")
                Text("Use the destination/Device IP configured in LocalDevVPN, not its tunnel/interface IP. Enter a host address, not a subnet. GassPair automatically strips a full-host CIDR suffix such as /32 or /128.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("Test mode", selection: $mode) {
                    ForEach(LocalDevVPNProbeMode.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isBusy)

                Button {
                    if let normalized = model.test(host: host, mode: mode) {
                        host = normalized
                    }
                } label: {
                    if model.isBusy {
                        Label("Testing…", systemImage: "hourglass")
                    } else {
                        Label(mode == .tcpOnly ? "Test TCP reachability" : "Test Lockdown plist", systemImage: "network")
                    }
                }
                .disabled(model.isBusy || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if model.isBusy {
                    ProgressView()
                    Button("Cancel test", role: .cancel) { model.cancel() }
                }
            }

            if let notice = model.normalizationNotice {
                Section("Input corrected") {
                    Label(notice, systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Result") {
                Label(model.title, systemImage: model.isReachable == true ? "checkmark.circle.fill" : (model.isReachable == false ? "exclamationmark.triangle.fill" : "info.circle"))
                    .font(.headline)
                    .foregroundStyle(model.isReachable == true ? Color.green : (model.isReachable == false ? Color.orange : Color.primary))

                Text(model.details)
                    .font(.footnote)
                    .textSelection(.enabled)

                if !model.trace.isEmpty {
                    ShareLink(item: model.diagnosticReport) {
                        Label("Share diagnostic report", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if model.title == "Lockdown is reachable", model.isReachable == true {
                Section("Experimental classic Lockdown pairing") {
                    Text("This sends a real Request=Pair to the endpoint. iOS may reject self-pairing. A record is exported only if Pair succeeds and a new TLS session starts successfully. This is separate from RPPairing and is not the CU/SRP flow used by idevicepair -w.")
                        .font(.footnote)
                    Button {
                        showingClassicPairConfirmation = true
                    } label: {
                        if classicPairBusy {
                            Label("Attempting classic Pair…", systemImage: "hourglass")
                        } else {
                            Label("Attempt Classic Lockdown Pair…", systemImage: "lock.shield")
                        }
                    }
                    .disabled(classicPairBusy || model.isBusy)
                    if let classicPairResult {
                        Text(classicPairResult)
                            .font(.footnote)
                            .textSelection(.enabled)
                    }
                }
            }

            if !model.trace.isEmpty {
                Section("Diagnostic trace") {
                    Text(model.trace.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section("LocalDevVPN checklist") {
                Label("Connect LocalDevVPN and wait until its status is Connected.", systemImage: "1.circle")
                Label("Join an actual Wi-Fi network; Wi-Fi merely being enabled may not be enough.", systemImage: "2.circle")
                Label("Use the configured Device/Peer IP (the routed destination), without /32.", systemImage: "3.circle")
                Label("Run TCP only first. If it succeeds, run TCP + Lockdown.", systemImage: "4.circle")
                Text("GassPair cannot inspect or repair another app's Network Extension route. If TCP never reaches ready even with a normalized IP and joined Wi-Fi, the packet tunnel/routing path must be fixed before Lockdown pairing can be evaluated.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("What this proves") {
                Text("TCP only proves that a socket opened on port 62078. TCP + Lockdown additionally requires QueryType and GetValue(ProductVersion) to return valid Lockdown plists. Neither test sends Pair or CUPairingCreate, requests trust, nor generates a pairing file.")
                Text("The documented idevicepair -w CU/SRP flow is currently an Apple TV capability in public libimobiledevice documentation. A successful network test does not establish that iOS 26.1 supports classic Lockdown self-pairing over this route.")
            }
        }
        .navigationTitle("LocalDevVPN Probe")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Send a real Lockdown Pair request?", isPresented: $showingClassicPairConfirmation, titleVisibility: .visible) {
            Button("Attempt Pair", role: .destructive) { attemptClassicPair() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This changes pairing state on the destination device if accepted. GassPair will verify StartSession TLS and only then write a classic pairing plist. iOS may refuse this connection. Continue only if you own or are authorized to administer this device.")
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func attemptClassicPair() {
        guard !classicPairBusy else { return }
        let normalizedHost: String
        do {
            normalizedHost = try LocalDevVPNDestination.parse(host).host
        } catch {
            classicPairResult = "Invalid destination: \(error.localizedDescription)"
            return
        }
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            classicPairResult = "Could not locate the app Documents directory."
            return
        }
        let output = documents.appendingPathComponent("classic_lockdown_pairing_file.plist").path
        classicPairBusy = true
        classicPairResult = "Connecting to \(normalizedHost):62078. No result is assumed until Pair, StartSession TLS, and file read-back validation finish."
        DispatchQueue.global(qos: .userInitiated).async {
            var message: UnsafeMutablePointer<CChar>?
            let rc = normalizedHost.withCString { hostCString in
                output.withCString { pathCString in
                    gasspair_classic_lockdown_pair(hostCString, pathCString, &message)
                }
            }
            let text = message.map { String(cString: $0) } ?? (rc == 0 ? "Pairing verified." : "Classic Lockdown pairing failed without a diagnostic message.")
            if let message { gasspair_string_free(message) }
            DispatchQueue.main.async {
                classicPairBusy = false
                classicPairResult = "\(rc == 0 ? "SUCCESS" : "FAILED (code \(rc))")\n\(text)"
            }
        }
    }
}
