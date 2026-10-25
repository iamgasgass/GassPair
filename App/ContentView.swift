import SwiftUI
import UIKit
import CryptoKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var controller = PairingController.shared
    @State private var appleTVPin = ""
    @FocusState private var pinFieldFocused: Bool
    @State private var showingRPFileImporter = false
    @State private var rpImportMessage: String?
    @State private var rpImportSucceeded = false
    @State private var rpEndpointHost = "10.7.0.1"
    @State private var rpEndpointPort = "49152"
    @State private var rpEndpointPIN = ""
    @State private var rpRemoteBusy = false
    @State private var rpRemoteMessage: String?
    @State private var rpRemoteSucceeded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                appIcon
                    .padding(.top, 40)

                Text("GassPair")
                    .font(.largeTitle.bold())

                content
                    .frame(maxWidth: 340)

                if let status = controller.statusLine, showsStatusLine {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                        .transition(.opacity)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .animation(.default, value: controller.phase)
        .animation(.default, value: controller.statusLine)
        .fileImporter(isPresented: $showingRPFileImporter,
                      allowedContentTypes: [.propertyList, .xml, .data],
                      allowsMultipleSelection: false) { result in
            importAndValidateRPFile(result)
        }
    }

    private var showsStatusLine: Bool {
        switch controller.phase {
        case .idle, .success, .failed: return false
        default: return true
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            VStack(spacing: 20) {
                Button {
                    controller.startDevicePairing()
                } label: {
                    Label("Pair iPhone or iPad", systemImage: "iphone")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .pillButton()
                .controlSize(.large)

                Button {
                    controller.browseForAppleTVs()
                } label: {
                    Label("Pair Apple TV", systemImage: "appletv")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .pillButton()
                .controlSize(.large)

                if !PairingController.thisDeviceCanSelfPair {
                    selfPairNotice
                }

                Button {
                    showingRPFileImporter = true
                } label: {
                    Label("Import / Validate RP Pairing File", systemImage: "doc.badge.gearshape")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .pillButton()
                .controlSize(.large)

                if let rpImportMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(rpImportSucceeded ? "RP file validated locally" : "RP file not accepted",
                              systemImage: rpImportSucceeded ? "checkmark.shield" : "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(rpImportSucceeded ? .green : .orange)
                        Text(rpImportMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 16)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Remote RPPairing endpoint")
                        .font(.headline)
                    Text("Enter the actual RPPairing service address advertised by the target. LocalDevVPN's Lockdown port 62078 is not an RPPairing endpoint.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Host / IP", text: $rpEndpointHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    TextField("RPPairing port", text: $rpEndpointPort)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    SecureField("6-digit pairing PIN", text: $rpEndpointPIN)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        .onChange(of: rpEndpointPIN) { value in
                            rpEndpointPIN = String(value.filter(\.isNumber).prefix(6))
                        }
                    Button {
                        createRemoteRPPairing()
                    } label: {
                        if rpRemoteBusy { ProgressView().frame(maxWidth: .infinity) }
                        else { Label("Create + pair-verify + save", systemImage: "key.horizontal").frame(maxWidth: .infinity) }
                    }
                    .pillButton().disabled(rpRemoteBusy || rpEndpointHost.trimmingCharacters(in: .whitespaces).isEmpty || Int(rpEndpointPort) == nil || rpEndpointPIN.count != 6)
                    Button {
                        verifyImportedRPPairing()
                    } label: {
                        Label("Verify imported record against endpoint", systemImage: "checkmark.shield").frame(maxWidth: .infinity)
                    }
                    .pillButton().disabled(rpRemoteBusy || rpEndpointHost.trimmingCharacters(in: .whitespaces).isEmpty || Int(rpEndpointPort) == nil)
                    if let rpRemoteMessage {
                        Text(rpRemoteMessage).font(.caption).textSelection(.enabled)
                            .foregroundStyle(rpRemoteSucceeded ? .green : .orange)
                    }
                }
                .padding().glassCard(cornerRadius: 16)

                if let last = controller.lastPairing {
                    lastPairingCard(last)
                }

                keepAliveOptions
            }

        case .preparing:
            VStack(spacing: 16) {
                ProgressView()
                Text("Getting ready…")
                    .foregroundStyle(.secondary)
                Text("Allow **Local Network** and **Notifications** if asked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                cancelButton
            }

        case .waiting:
            VStack(spacing: 16) {
                ProgressView()
                Text(PairingController.thisDeviceCanSelfPair
                     ? "Waiting for this device to connect…"
                     : "Waiting for a device to connect…")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text(PairingController.thisDeviceCanSelfPair
                         ? "On this device:"
                         : "On the iPhone/iPad to pair (iOS 27 or later):")
                        .font(.subheadline.weight(.semibold))
                    guideStep(1, "Open the **Settings** app")
                    guideStep(2, "Go to **Privacy & Security**")
                    guideStep(3, "Tap **Developer Mode**")
                    guideStep(4, "Scroll down and tap **Pair with GassPair**")
                    guideStep(5, PairingController.thisDeviceCanSelfPair
                              ? "Enter the code from the GassPair notification (it's also on your clipboard)"
                              : "Enter the code shown here in GassPair")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 20)

                Text("If **Pair with GassPair** doesn't show up, leave Developer Mode and open it again, or tap Restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button("Restart") {
                        controller.cancel()
                        controller.startDevicePairing()
                    }
                    .pillButton()
                    cancelButton
                }
            }

        case .showPin(let pin):
            VStack(spacing: 16) {
                Text("Enter this code on your device")
                    .font(.headline)
                Text(pin)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(8)
                    .textSelection(.enabled)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .glassCapsule()
                Text("Settings › Privacy & Security › Developer Mode › Pair with GassPair")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView()
                cancelButton
            }

        case .browsingAppleTV:
            VStack(spacing: 16) {
                Text("Choose an Apple TV")
                    .font(.headline)
                Text("On Apple TV, open **Settings › Remotes and Devices › Remote App and Devices** and keep that screen open.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if controller.appleTVs.isEmpty {
                    ProgressView("Looking for Apple TVs…")
                } else {
                    ForEach(controller.appleTVs) { device in
                        Button {
                            appleTVPin = ""
                            controller.pairAppleTV(device)
                        } label: {
                            Label(device.name, systemImage: "appletv")
                                .frame(maxWidth: .infinity)
                        }
                        .pillButton()
                        .controlSize(.large)
                    }
                }

                HStack(spacing: 12) {
                    Button("Refresh") { controller.refreshAppleTVs() }
                        .pillButton()
                    cancelButton
                }
            }

        case .enteringAppleTVPin(let device, let attempt):
            VStack(spacing: 16) {
                Text("Pair with \(device.name)")
                    .font(.headline)
                Text(attempt > 1
                     ? LocalizedStringKey("That code didn't work. Enter the **new** code shown on your Apple TV.")
                     : LocalizedStringKey("Enter the six-digit code shown on your Apple TV."))
                    .font(.subheadline)
                    .foregroundStyle(attempt > 1 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .multilineTextAlignment(.center)
                TextField("000000", text: $appleTVPin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .focused($pinFieldFocused)
                    .onChange(of: appleTVPin) { value in
                        let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        if digits != value { appleTVPin = digits }
                        if digits.count == 6 { controller.submitAppleTVPin(digits) }
                    }
                    .padding()
                    .glassCard(cornerRadius: 16)
                Button("Pair") {
                    controller.submitAppleTVPin(appleTVPin)
                }
                .pillButton()
                .controlSize(.large)
                .disabled(appleTVPin.count != 6)
                cancelButton
            }
            .onAppear {
                appleTVPin = ""
                pinFieldFocused = true
            }
            .id(attempt) // fresh field (and onAppear) for every new attempt

        case .pairingAppleTV(let text):
            VStack(spacing: 16) {
                ProgressView()
                Text(text)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                cancelButton
            }

        case .success(let device):
            VStack(spacing: 12) {
                Label("Paired", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title3.bold())
                if !device.name.isEmpty {
                    Text(device.model.isEmpty ? device.name : "\(device.name) · \(device.model)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if device.kind == .appleTV {
                    Label(device.verified ? "Connection verified" : "Saved (couldn't verify — pair again if it doesn't work)",
                          systemImage: device.verified ? "checkmark.shield" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(device.verified ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.center)
                }
                exportButton(for: device)
                    .padding(.top, 4)
                Text("Also available in **Files › On My iPhone › GassPair**.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Done") { controller.reset() }
                    .pillButton()
            }

        case .failed(let message):
            VStack(spacing: 10) {
                Label("Failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.title3.bold())
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again") { controller.reset() }
                    .pillButton()
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
    }

    private func createRemoteRPPairing() {
        guard let port = UInt16(rpEndpointPort), rpEndpointPIN.count == 6 else { return }
        rpRemoteBusy = true; rpRemoteMessage = "Connecting to the RPPairing service…"; rpRemoteSucceeded = false
        let host = rpEndpointHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let pin = rpEndpointPIN
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rp_pairing_file_remote_verified.plist").path
        DispatchQueue.global(qos: .userInitiated).async {
            var result = GassPairResult()
            let rc = host.withCString { h in
                "GassPair".withCString { n in pin.withCString { p in output.withCString { o in
                    gasspair_create_rp_endpoint(h, port, n, p, o, &result)
                } } }
            }
            let message: String
            if rc == 0 {
                message = "Pair-setup and pair-verify succeeded. Verified RPPairing record saved to Documents/rp_pairing_file_remote_verified.plist."
            } else if let error = result.error {
                message = String(cString: error)
            } else {
                message = "RPPairing creation failed (code \(rc))."
            }
            DispatchQueue.main.async {
                rpRemoteBusy = false; rpRemoteSucceeded = rc == 0; rpRemoteMessage = message
                if rc == 0 { rpEndpointPIN = "" }
            }
            gasspair_result_free(&result)
        }
    }

    private func verifyImportedRPPairing() {
        guard let port = UInt16(rpEndpointPort) else { return }
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rp_pairing_file_imported.plist").path
        guard FileManager.default.fileExists(atPath: file) else {
            rpRemoteSucceeded = false; rpRemoteMessage = "Import an RPPairing file first."; return
        }
        rpRemoteBusy = true; rpRemoteMessage = "Performing real pair-verify…"; rpRemoteSucceeded = false
        let host = rpEndpointHost.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            var result = GassPairResult()
            let rc = host.withCString { h in "GassPair".withCString { n in file.withCString { f in
                gasspair_verify_rp_endpoint(h, port, n, f, &result)
            } } }
            let message: String
            if rc == 0 { message = "Remote pair-verify succeeded." }
            else if let error = result.error { message = String(cString: error) }
            else { message = "Remote pair-verify failed (code \\(rc))." }
            DispatchQueue.main.async { rpRemoteBusy = false; rpRemoteSucceeded = rc == 0; rpRemoteMessage = message }
            gasspair_result_free(&result)
        }
    }

    /// Imports an existing RPPairing plist without inventing credentials.
    /// This is a local structural/key-consistency check, NOT network pair-verify.
    private func importAndValidateRPFile(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: source, options: [.mappedIfSafe])
            guard data.count <= 1_048_576 else {
                throw RPImportError.invalid("The selected file is larger than 1 MiB.")
            }
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw RPImportError.invalid("The file is not a property-list dictionary.")
            }
            guard let publicKey = plist["public_key"] as? Data,
                  let privateKey = plist["private_key"] as? Data,
                  let identifier = plist["identifier"] as? String,
                  let altIRK = plist["alt_irk"] as? Data else {
                throw RPImportError.invalid("Required fields are missing: public_key, private_key, identifier, alt_irk.")
            }
            guard publicKey.count == 32, privateKey.count == 32 else {
                throw RPImportError.invalid("public_key and private_key must each contain 32 bytes.")
            }
            guard altIRK.count == 16 else {
                throw RPImportError.invalid("alt_irk must contain 16 bytes.")
            }
            guard UUID(uuidString: identifier) != nil else {
                throw RPImportError.invalid("identifier is not a valid UUID.")
            }
            let privateKeyObject = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
            guard privateKeyObject.publicKey.rawRepresentation == publicKey else {
                throw RPImportError.invalid("public_key does not match the public key derived from private_key.")
            }

            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("rp_pairing_file_imported.plist")
            let temporary = destination.appendingPathExtension("tmp")
            try data.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            rpImportSucceeded = true
            rpImportMessage = "The plist structure, key lengths, UUID, 16-byte alt_irk, and Ed25519 public/private key consistency passed. Imported as rp_pairing_file_imported.plist. This does not prove the remote peer accepts it: network pair-verify must be run against the actual RPPairing service endpoint."
        } catch {
            rpImportSucceeded = false
            rpImportMessage = error.localizedDescription
        }
    }

    private enum RPImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return "Invalid RPPairing file."
        }
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) { controller.cancel() }
            .pillButton()
    }

    private func exportButton(for device: PairingController.PairedDevice) -> some View {
        ShareLink(item: URL(fileURLWithPath: device.pairingFilePath)) {
            Label("Export Pairing File", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .pillButton()
        .controlSize(.large)
    }

    private func lastPairingCard(_ device: PairingController.PairedDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last pairing")
                .font(.subheadline.weight(.semibold))
            Text("\(device.name.isEmpty ? "Device" : device.name) · \(device.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            exportButton(for: device)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }

    private var selfPairNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This iPhone runs iOS \(UIDevice.current.systemVersion)", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
            Text("Apple added **Pair with…** in Developer Mode only in iOS 27, so this device can't pair to itself. From here you can pair an **Apple TV**, or host pairing for **another iPhone/iPad on iOS 27+** on the same Wi-Fi.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }

    private var keepAliveOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Background keep-alive")
                .font(.subheadline.weight(.semibold))
            Toggle("Silent audio", isOn: $controller.keepAliveAudio)
            Toggle("Location", isOn: $controller.keepAliveLocation)
            Text("Keeps GassPair running while you enter the code in Settings. Silent audio is recommended.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }

    private var appIcon: some View {
        Image("AppLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 116, height: 116)
    }

    private func guideStep(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.tint, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    ContentView()
}

// MARK: - iOS 16-compatible styling (Liquid Glass on iOS 26+)

extension View {
    @ViewBuilder
    func pillButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func glassCard(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
