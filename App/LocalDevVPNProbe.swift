import Combine
import Foundation
import Network
import SwiftUI

/// A diagnostic only: checks whether an address routed by LocalDevVPN reaches
/// lockdownd and answers the ordinary plist protocol on TCP/62078. It does not
/// send Pair/CUPairingCreate and never writes a pairing record.
@MainActor
final class LocalDevVPNProbeModel: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var title = "Not tested"
    @Published private(set) var details = "Enter the destination address routed by LocalDevVPN, then test TCP port 62078."
    @Published private(set) var isReachable: Bool?

    private var connection: NWConnection?
    private var generation: UInt64 = 0
    private var received = Data()
    private var expectedLength: Int?
    private var sentInitialRequest = false
    private var expectedReply: ReplyKind = .queryType

    private enum ReplyKind {
        case queryType
        case productVersion
    }

    private enum ProbeError: LocalizedError {
        case invalidFrameLength
        case invalidPropertyList
        case unexpectedReply(String)

        var errorDescription: String? {
            switch self {
            case .invalidFrameLength:
                return "lockdownd returned an invalid plist frame length."
            case .invalidPropertyList:
                return "TCP connected, but the response was not a valid plist."
            case .unexpectedReply(let message):
                return message
            }
        }
    }

    func test(host rawHost: String) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            title = "Address required"
            details = "Enter the VPN-routed IP address or hostname first."
            isReachable = false
            return
        }

        stopCurrentConnection()
        generation &+= 1
        let token = generation
        received.removeAll(keepingCapacity: true)
        expectedLength = nil
        sentInitialRequest = false
        expectedReply = .queryType
        isBusy = true
        isReachable = nil
        title = "Connecting…"
        details = "Opening \(host):62078 through the system network routes."

        guard let port = NWEndpoint.Port(rawValue: 62078) else {
            finish(token, title: "Invalid port", details: "TCP port 62078 could not be represented.", reachable: false)
            return
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isBusy else { return }
                switch state {
                case .ready:
                    guard !self.sentInitialRequest else { return }
                    self.sentInitialRequest = true
                    self.title = "TCP connected"
                    self.details = "The socket opened. Checking whether the service speaks Lockdown plist."
                    self.send(
                        ["Label": "GassPair LocalDevVPN diagnostic", "Request": "QueryType"],
                        expecting: .queryType,
                        on: connection,
                        token: token)
                case .waiting(let error):
                    self.details = "Waiting for the route to become usable: \(error.localizedDescription)"
                case .failed(let error):
                    self.finish(
                        token,
                        title: "Connection failed",
                        details: "Could not reach \(host):62078. \(error.localizedDescription) Check that LocalDevVPN is connected and that this is its routed destination address.",
                        reachable: false)
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))

        // Bound the probe so an unrouted destination cannot leave the UI spinning.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.isBusy else { return }
                self.finish(
                    token,
                    title: "Timed out",
                    details: "No complete Lockdown response arrived within 12 seconds. The route may not reach the device's lockdownd socket, or the endpoint may silently drop this traffic.",
                    reachable: false)
            }
        }
    }

    func cancel() {
        generation &+= 1
        stopCurrentConnection()
        isBusy = false
        title = "Test cancelled"
        details = "No pairing request was sent and no file was created."
        isReachable = nil
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
            guard body.count <= 2 * 1024 * 1024 else {
                finish(token, title: "Request too large", details: "The diagnostic plist exceeded its safety limit.", reachable: false)
                return
            }

            var length = UInt32(body.count).bigEndian
            var framed = Data()
            withUnsafeBytes(of: &length) { framed.append(contentsOf: $0) }
            framed.append(body)
            expectedReply = reply
            received.removeAll(keepingCapacity: true)
            expectedLength = nil

            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.isBusy else { return }
                    if let error {
                        self.finish(token, title: "Send failed", details: "The Lockdown request could not be sent: \(error.localizedDescription)", reachable: false)
                        return
                    }
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
                if let error {
                    self.finish(token, title: "Receive failed", details: "The Lockdown response could not be read: \(error.localizedDescription)", reachable: false)
                    return
                }
                if let data, !data.isEmpty {
                    self.received.append(data)
                }
                do {
                    if let frame = try self.extractFrame() {
                        self.handle(frame: frame, on: connection, token: token)
                    } else if isComplete {
                        self.finish(token, title: "Connection closed", details: "The endpoint closed before returning a complete Lockdown plist.", reachable: false)
                    } else {
                        self.receive(on: connection, token: token)
                    }
                } catch {
                    self.finish(token, title: "Invalid response", details: error.localizedDescription, reachable: false)
                }
            }
        }
    }

    private func extractFrame() throws -> Data? {
        if expectedLength == nil {
            guard received.count >= 4 else { return nil }
            let length = (Int(received[0]) << 24)
                | (Int(received[1]) << 16)
                | (Int(received[2]) << 8)
                | Int(received[3])
            guard length > 0, length <= 2 * 1024 * 1024 else {
                throw ProbeError.invalidFrameLength
            }
            expectedLength = length
            received.removeFirst(4)
        }

        guard let length = expectedLength, received.count >= length else { return nil }
        let frame = Data(received.prefix(length))
        received.removeFirst(length)
        expectedLength = nil
        return frame
    }

    private func handle(frame: Data, on connection: NWConnection, token: UInt64) {
        guard let object = try? PropertyListSerialization.propertyList(from: frame, options: [], format: nil),
              let response = object as? [String: Any] else {
            finish(token, title: "Not a Lockdown plist", details: ProbeError.invalidPropertyList.localizedDescription ?? "Invalid plist.", reachable: false)
            return
        }

        switch expectedReply {
        case .queryType:
            guard let type = response["Type"] as? String else {
                let error = response["Error"] as? String ?? "No Type field was returned."
                finish(token, title: "TCP open; Lockdown not confirmed", details: "The endpoint answered, but QueryType did not succeed: \(error)", reachable: false)
                return
            }
            guard type == "com.apple.mobile.lockdown" else {
                finish(token, title: "Unexpected service", details: "QueryType returned ‘\(type)’ rather than com.apple.mobile.lockdown.", reachable: false)
                return
            }
            title = "Lockdown identified"
            details = "QueryType succeeded. Requesting ProductVersion to confirm a complete plist round-trip."
            send(
                ["Label": "GassPair LocalDevVPN diagnostic", "Request": "GetValue", "Key": "ProductVersion"],
                expecting: .productVersion,
                on: connection,
                token: token)

        case .productVersion:
            let version = response["Value"] as? String ?? "unavailable"
            finish(
                token,
                title: "lockdownd is reachable",
                details: "QueryType succeeded and ProductVersion = \(version). This confirms TCP routing and the Lockdown plist protocol only. It does not prove that iOS accepts a self-pair request, and no pairing record was generated.",
                reachable: true)
        }
    }

    private func finish(_ token: UInt64, title: String, details: String, reachable: Bool?) {
        guard generation == token else { return }
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

struct LocalDevVPNProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LocalDevVPNProbeModel()
    @AppStorage("gasspair.localDevVPN.lockdownHost") private var host = ""

    var body: some View {
        Form {
            Section("Destination") {
                TextField("VPN-routed IP / hostname", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                LabeledContent("TCP port", value: "62078")
                Text("Enter the destination address you configured or route through LocalDevVPN. It is not safe to assume that 127.0.0.1, the VPN interface IP, and the peer IP are interchangeable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostic") {
                Button {
                    model.test(host: host)
                } label: {
                    if model.isBusy {
                        Label("Testing Lockdown…", systemImage: "hourglass")
                    } else {
                        Label("Test TCP + Lockdown plist", systemImage: "network")
                    }
                }
                .disabled(model.isBusy || host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if model.isBusy {
                    ProgressView()
                }

                Label(model.title, systemImage: model.isReachable == true ? "checkmark.circle.fill" : (model.isReachable == false ? "exclamationmark.triangle.fill" : "info.circle"))
                    .font(.headline)
                    .foregroundStyle(model.isReachable == true ? Color.green : (model.isReachable == false ? Color.orange : Color.primary))

                Text(model.details)
                    .font(.footnote)
                    .textSelection(.enabled)

                if model.isBusy {
                    Button("Cancel test", role: .cancel) { model.cancel() }
                }
            }

            Section("What this proves") {
                Text("A successful result proves that the entered endpoint answered QueryType and ProductVersion in the Lockdown plist protocol. It does not prove that Pair or CU/SRP pairing is allowed on iOS 26.1.")
                Text("The public libimobiledevice documentation describes the PIN-based CU/SRP flow used by idevicepair -w as an Apple TV capability. LocalDevVPN can change routing, but it cannot add a pairing protocol that lockdownd does not expose.")
            }

            Section("Safety") {
                Text("This screen sends only QueryType and GetValue(ProductVersion). It does not send Pair or CUPairingCreate, does not request trust, and never writes or exports a pairing file.")
            }
        }
        .navigationTitle("LocalDevVPN Probe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }
}
