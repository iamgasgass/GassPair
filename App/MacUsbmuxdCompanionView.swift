import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import Foundation
import UIKit

/// Remote pairing flow backed by the Mac's real usbmuxd connection provider.
/// The iOS app never tries to open RemotePairingLockdownService via raw TCP.
struct MacUsbmuxdCompanionView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage("gasspair.usbmuxdCompanion.host") private var companionHost = "10.7.0.2"
    @AppStorage("gasspair.usbmuxdCompanion.port") private var companionPort = "47821"
    @AppStorage("gasspair.usbmuxdCompanion.fingerprint") private var companionFingerprint = ""
    @State private var companionToken = ""

    @State private var devices: [MacUsbmuxdDevice] = []
    @State private var selectedUDID = ""
    @State private var lockdownData: Data?
    @State private var lockdownName: String?
    @State private var rpData: Data?
    @State private var rpName: String?
    @State private var showingLockdownImporter = false
    @State private var showingRPImporter = false
    @State private var isBusy = false
    @State private var currentOperation = ""
    @State private var message: String?
    @State private var didVerifyRemote = false
    @State private var outputURL: URL?

    init(initialLockdownFileURL: URL? = nil) {
        self.initialLockdownFileURL = initialLockdownFileURL
    }

    private let initialLockdownFileURL: URL?

    var body: some View {
        ScrollView {
            GlassGroup(spacing: 20) {
                VStack(spacing: 20) {
                    connectionCard
                    targetCard
                    lockdownCard
                    createCard
                    verifyCard
                    if isBusy || message != nil { resultCard }
                    requirementsCard
                }
                .frame(maxWidth: 520)
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Mac companion")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
                    .disabled(isBusy)
            }
        }
        .fileImporter(isPresented: $showingLockdownImporter,
                      allowedContentTypes: [.propertyList, .xml, .data],
                      allowsMultipleSelection: false) { result in
            loadLockdownFile(result)
        }
        .fileImporter(isPresented: $showingRPImporter,
                      allowedContentTypes: [.propertyList, .xml, .data],
                      allowsMultipleSelection: false) { result in
            loadRPFile(result)
        }
        .onAppear(perform: loadInitialLockdownFile)
    }

    // MARK: - Glass cards

    private var connectionCard: some View {
        GlassSection("macOS usbmuxd companion", systemImage: "desktopcomputer",
                     footer: "On the Mac, start gasspair-usbmuxd-companion bound to its actual LocalDevVPN/LAN IP. Copy the displayed SHA-256 certificate fingerprint and the access token from the Mac's secure token file. Never disable certificate pinning.") {
            Text("Optional fallback. The Mac companion performs the private device-service open through macOS usbmuxd; the iPhone talks to it over pinned HTTPS.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Mac LocalDevVPN/LAN IP", text: $companionHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .glassField()
                .disabled(isBusy)
            TextField("Companion TCP port", text: $companionPort)
                .keyboardType(.numberPad)
                .glassField()
                .disabled(isBusy)
            TextField("TLS certificate SHA-256 fingerprint", text: $companionFingerprint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .glassField()
                .disabled(isBusy)
            SecureField("Companion access token", text: $companionToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .glassField()
                .disabled(isBusy)
            Button {
                Task { await refreshDevices() }
            } label: {
                Group {
                    if isBusy && currentOperation == "List devices" {
                        ProgressView(currentOperation)
                    } else {
                        Label("Connect securely and list usbmuxd devices", systemImage: "network")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .prominentPillButton()
            .disabled(isBusy || !connectionSettingsLookValid)
        }
    }

    private var targetCard: some View {
        GlassSection("Target device", systemImage: "iphone",
                     footer: "The selected iPhone must already be visible to the Mac's usbmuxd. This helper uses that native device provider and the imported Lockdown trust record.") {
            if devices.isEmpty {
                Text("No device list loaded. Connect to the Mac companion and refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Device UDID", selection: $selectedUDID) {
                    Text("Select a device").tag("")
                    ForEach(devices) { device in
                        Text("\(device.udid) · \(device.transport)").tag(device.udid)
                    }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 8)
                .glassCapsule()
                .disabled(isBusy)
            }
        }
    }

    private var lockdownCard: some View {
        GlassSection("Imported Lockdown trust", systemImage: "lock.shield") {
            Button {
                showingLockdownImporter = true
            } label: {
                Label(lockdownData == nil ? "Import Lockdown.plist" : "Replace Lockdown.plist (\(lockdownName ?? "imported"))", systemImage: "doc.badge.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .pillButton()
            .disabled(isBusy)
            if let lockdownData {
                Label("Lockdown trust loaded · \(ByteCountFormatter.string(fromByteCount: Int64(lockdownData.count), countStyle: .file))", systemImage: "checkmark.shield.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                Text("Kept in memory and sent only over TLS after certificate pinning and access-token authentication. The companion verifies that it opens an authenticated Lockdown session for the selected UDID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Import the genuine Lockdown pairing record already trusted for this exact iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var createCard: some View {
        GlassSection("Create a new RPPairing record", systemImage: "key.horizontal",
                     footer: "The Mac companion opens RemotePairingLockdownService through usbmuxd, creates the RpPairingFile, then runs attemptPairVerify + validatePairing on a fresh connection. No file is returned unless verification succeeds.") {
            Button {
                Task { await createRPPairing() }
            } label: {
                Group {
                    if isBusy && currentOperation == "Create RPPairing" {
                        ProgressView("Using usbmuxd · pair-setup · pair-verify…")
                    } else {
                        Label("Create + pair-verify + save via usbmuxd", systemImage: "key.horizontal")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .prominentPillButton()
            .disabled(isBusy || !connectionSettingsLookValid || lockdownData == nil || selectedUDID.isEmpty)
        }
    }

    private var verifyCard: some View {
        GlassSection("Verify an existing RPPairing file", systemImage: "checkmark.shield") {
            Button {
                showingRPImporter = true
            } label: {
                Label(rpData == nil ? "Import existing RPPairing.plist" : "Replace RPPairing.plist (\(rpName ?? "imported"))", systemImage: "doc.badge.gearshape")
                    .frame(maxWidth: .infinity)
            }
            .pillButton()
            .disabled(isBusy)
            Button {
                Task { await verifyImportedRPPairing() }
            } label: {
                Group {
                    if isBusy && currentOperation == "Verify RPPairing" {
                        ProgressView("Running remote pair-verify…")
                    } else {
                        Label("Verify imported record against the real device", systemImage: "checkmark.shield")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .pillButton()
            .disabled(isBusy || !connectionSettingsLookValid || lockdownData == nil || rpData == nil || selectedUDID.isEmpty)
        }
    }

    private var resultCard: some View {
        GlassSection("Operation result", systemImage: "info.circle") {
            if isBusy { ProgressView(currentOperation) }
            Text(message ?? "Preparing the operation…")
                .font(.footnote)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if isBusy {
                Text("The pairing plist contains private key material. Keep the app open and do not share screenshots or diagnostic text containing secrets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if didVerifyRemote, let outputURL {
                Label("Pairing verified against the live device", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                ShareLink(item: outputURL) {
                    Label("Export verified RPPairing plist", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .prominentPillButton()
            }
        }
    }

    private var requirementsCard: some View {
        GlassSection("Requirements / safety", systemImage: "checklist",
                     footer: "This helper runs the usbmuxd-backed part on macOS, then transfers the verified record to GassPair through pinned TLS plus an access token. If the device is not visible to macOS usbmuxd, the operation stops without creating a file.") {
            Label("Device appears in the Mac's usbmuxd device list", systemImage: "1.circle")
            Label("Imported Lockdown record starts TLS for the selected UDID", systemImage: "2.circle")
            Label("Mac companion certificate fingerprint matches exactly", systemImage: "3.circle")
            Label("RPPairing output is returned only after independent pair-verify", systemImage: "4.circle")
        }
        .font(.subheadline)
    }

    private var connectionSettingsLookValid: Bool {
        !companionHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        UInt16(companionPort) != nil &&
        companionFingerprint.filter(\.isHexDigit).count == 64 &&
        companionToken.trimmingCharacters(in: .whitespacesAndNewlines).count >= 48
    }

    private func makeClient() throws -> MacUsbmuxdCompanionClient {
        try MacUsbmuxdCompanionClient(host: companionHost, port: companionPort,
                                      fingerprint: companionFingerprint, token: companionToken)
    }

    private func refreshDevices() async {
        guard !isBusy else { return }
        isBusy = true
        currentOperation = "List devices"
        message = "Establishing pinned HTTPS session to the Mac companion…"
        didVerifyRemote = false
        outputURL = nil
        defer { isBusy = false }
        do {
            let response = try await makeClient().listDevices()
            devices = response
            if !devices.contains(where: { $0.udid == selectedUDID }) {
                selectedUDID = devices.first?.udid ?? ""
            }
            message = devices.isEmpty
                ? "The companion authenticated successfully, but no iPhone/iPad is currently visible to this Mac's usbmuxd. Pair the device to this Mac over Wi-Fi and try again."
                : "Secure companion connection succeeded. Found \(devices.count) usbmuxd device(s). Select the exact target UDID."
        } catch {
            devices = []
            selectedUDID = ""
            message = error.localizedDescription
        }
    }

    private func createRPPairing() async {
        guard !isBusy, let lockdownData, !selectedUDID.isEmpty else { return }
        isBusy = true
        currentOperation = "Create RPPairing"
        message = "Sending the imported Lockdown trust record over pinned TLS. The Mac helper will use its native usbmuxd provider; no direct TCP service-socket emulation is attempted on iOS."
        didVerifyRemote = false
        outputURL = nil
        defer { isBusy = false }
        do {
            let response = try await makeClient().createRPPairing(lockdownFile: lockdownData, udid: selectedUDID)
            guard response.verified, let encoded = response.pairingFileBase64,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else {
                throw MacUsbmuxdCompanionError.remote("The companion did not return a verified RPPairing plist. No output was saved.")
            }
            try validateRPPairingFile(bytes)
            let url = try saveVerifiedRPPairing(bytes, named: "rp_pairing_file_from_lockdown_verified.plist")
            outputURL = url
            didVerifyRemote = true
            message = "\(response.message) The iPhone re-read and validated the returned plist and saved it with complete file protection."
        } catch {
            message = error.localizedDescription + " No verified RPPairing file was saved on this iPhone."
        }
    }

    private func verifyImportedRPPairing() async {
        guard !isBusy, let lockdownData, let rpData, !selectedUDID.isEmpty else { return }
        isBusy = true
        currentOperation = "Verify RPPairing"
        message = "The companion will authenticate through usbmuxd, then run pair-verify only; this operation does not start a new pair-setup."
        didVerifyRemote = false
        outputURL = nil
        defer { isBusy = false }
        do {
            let response = try await makeClient().verifyRPPairing(lockdownFile: lockdownData, rpFile: rpData, udid: selectedUDID)
            guard response.verified else { throw MacUsbmuxdCompanionError.remote("The companion did not confirm pair-verify.") }
            let url = try saveVerifiedRPPairing(rpData, named: "rp_pairing_file_imported_usbmuxd_verified.plist")
            outputURL = url
            didVerifyRemote = true
            message = "\(response.message) A separate verified copy was written to Documents/\(url.lastPathComponent)."
        } catch {
            message = error.localizedDescription + " No verified copy was saved."
        }
    }

    private func loadLockdownFile(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: source, options: [.mappedIfSafe])
            guard data.count <= 2 * 1024 * 1024,
                  let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw MacUsbmuxdCompanionError.remote("Lockdown file exceeds 2 MiB or is not a plist dictionary.")
            }
            let required = ["HostID", "SystemBUID", "HostCertificate", "HostPrivateKey", "RootCertificate", "RootPrivateKey", "DeviceCertificate"]
            let missing = required.filter { plist[$0] == nil }
            guard missing.isEmpty else {
                throw MacUsbmuxdCompanionError.remote("Lockdown record missing required fields: \(missing.joined(separator: ", ")).")
            }
            lockdownData = data
            lockdownName = source.lastPathComponent
            message = "Imported \(source.lastPathComponent) locally. It has not yet been authenticated; the Mac helper will validate StartSession against the selected UDID before opening the RPPairing service."
            didVerifyRemote = false
            outputURL = nil
        } catch {
            lockdownData = nil
            lockdownName = nil
            message = error.localizedDescription
        }
    }


    private func loadRPFile(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: source, options: [.mappedIfSafe])
            try validateRPPairingFile(data)
            rpData = data
            rpName = source.lastPathComponent
            message = "Imported \(source.lastPathComponent). Local structure passed; live pair-verify has not been run yet."
            didVerifyRemote = false
            outputURL = nil
        } catch {
            rpData = nil
            rpName = nil
            message = error.localizedDescription
        }
    }

    private func validateRPPairingFile(_ data: Data) throws {
        guard data.count <= 1024 * 1024,
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let publicKey = plist["public_key"] as? Data,
              let privateKey = plist["private_key"] as? Data,
              let identifier = plist["identifier"] as? String,
              publicKey.count == 32, privateKey.count == 32,
              UUID(uuidString: identifier) != nil else {
            throw MacUsbmuxdCompanionError.remote("RPPairing plist is malformed, exceeds 1 MiB, or is missing valid public_key/private_key/identifier fields.")
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        guard key.publicKey.rawRepresentation == publicKey else {
            throw MacUsbmuxdCompanionError.remote("The imported RPPairing public key does not match the private key.")
        }
        if let altIRK = plist["alt_irk"] as? Data, altIRK.count != 16 {
            throw MacUsbmuxdCompanionError.remote("alt_irk must contain 16 bytes when present.")
        }
    }

    private func saveVerifiedRPPairing(_ data: Data, named fileName: String) throws -> URL {
        try validateRPPairingFile(data)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        let readBack = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard readBack == data else {
            try? FileManager.default.removeItem(at: url)
            throw MacUsbmuxdCompanionError.remote("Saved RPPairing bytes differ from the verified response; the output was deleted.")
        }
        return url
    }

    private func loadInitialLockdownFile() {
        guard lockdownData == nil, let url = initialLockdownFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return }
            let required = ["HostID", "SystemBUID", "HostCertificate", "HostPrivateKey", "RootCertificate", "RootPrivateKey", "DeviceCertificate"]
            guard required.allSatisfy({ plist[$0] != nil }) else { return }
            lockdownData = data
            lockdownName = url.lastPathComponent
            message = "Loaded the Lockdown.plist already imported into GassPair. Its trust still must be verified by the Mac usbmuxd companion."
        } catch {
            message = "Could not load the previously imported Lockdown.plist: \(error.localizedDescription)"
        }
    }
}
