import SwiftUI
import UniformTypeIdentifiers

/// Integrated usbmuxd companion: no Mac and nothing to type (no address, pin, token or UDID).
/// Import the Lockdown.plist once; everything else runs on its own.
struct IntegratedUsbmuxdCompanionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var companion = IntegratedUsbmuxdCompanion.shared
    @State private var showingLockdownImporter = false
    @State private var importError: String?
    @State private var showingLog = false

    var body: some View {
        Form {
            statusSection

            if let device = companion.device {
                Section("Device") {
                    row("Name", device.name.isEmpty ? "—" : device.name)
                    if !device.productType.isEmpty { row("Model", device.productType) }
                    row("iOS", device.iosVersion)
                    row("UDID", device.udid, monospaced: true)
                    row("Reached via", device.endpoint == "10.7.0.1" ? "LocalDevVPN (10.7.0.1)" : device.endpoint)
                }
            }

            Section("Lockdown trust") {
                if companion.hasLockdown {
                    Label("Lockdown.plist imported", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                }
                Button {
                    showingLockdownImporter = true
                } label: {
                    Label(companion.hasLockdown ? "Replace Lockdown.plist" : "Import Lockdown.plist",
                          systemImage: "doc.badge.arrow.up")
                }
                .disabled(companion.isBusy)
                if let importError {
                    Text(importError).font(.caption).foregroundStyle(.orange)
                }
                Text("The record must be the Lockdown pairing record already trusted by this iPhone/iPad. It stays on the device, protected, and is never sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Automatic", isOn: $companion.automatic)
                TextField("Extra device address (optional)", text: $companion.extraEndpoints)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .disabled(companion.isBusy)
                if companion.hasImportedRP {
                    Button {
                        companion.start(.verifyImported)
                    } label: {
                        Label("Verify imported RPPairing on the device", systemImage: "checkmark.shield")
                    }
                    .disabled(companion.isBusy || !companion.hasLockdown)
                }
            } header: {
                Text("Options")
            } footer: {
                Text("Automatic: as soon as the Lockdown.plist is available GassPair finds the device (LocalDevVPN 10.7.0.1 first, then Wi-Fi), creates the RPPairing record, verifies it on a fresh connection and saves it. If the device can't be reached it keeps retrying by itself — just switch LocalDevVPN on.")
            }

            if !companion.log.isEmpty {
                Section {
                    DisclosureGroup("Details (\(companion.log.count))", isExpanded: $showingLog) {
                        ForEach(Array(companion.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    MacUsbmuxdCompanionView(initialLockdownFileURL: companion.hasLockdown ? IntegratedUsbmuxdCompanion.lockdownURL : nil)
                } label: {
                    Label("Mac companion (optional fallback)", systemImage: "desktopcomputer")
                }
                .disabled(companion.isBusy)
            } footer: {
                Text("Only needed if iOS refuses to open remotepairingdeviced over the network and you want to go through a Mac with a USB cable.")
            }
        }
        .navigationTitle("usbmuxd (integrated)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(isPresented: $showingLockdownImporter,
                      allowedContentTypes: [.propertyList, .xml, .data],
                      allowsMultipleSelection: false) { result in
            importLockdown(result)
        }
        .onAppear { companion.viewAppeared() }
        .onDisappear { companion.viewDisappeared() }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        Section {
            switch companion.phase {
            case .needsLockdown:
                Label("Import the Lockdown.plist to begin", systemImage: "doc.badge.arrow.up")
                    .font(.headline)
                Text("That's the only step: the companion then finds the device and creates the record on its own.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Import Lockdown.plist") { showingLockdownImporter = true }

            case .ready:
                Label("Ready", systemImage: "cable.connector")
                    .font(.headline)
                Button {
                    companion.start(.create)
                } label: {
                    Label("Create RPPairing", systemImage: "key.horizontal")
                }

            case .searching(let endpoint):
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading) {
                        Text("Looking for the device…").font(.headline)
                        Text(endpoint).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Button("Cancel", role: .cancel) { companion.cancel() }

            case .waitingForRoute(let reason, let retryIn):
                Label("Device not reachable yet", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(retryIn > 0
                     ? "Turn LocalDevVPN on (or join the same Wi-Fi). Retrying automatically in \(retryIn) s…"
                     : "Turn LocalDevVPN on (or join the same Wi-Fi), then retry.")
                    .font(.footnote)
                Text(reason).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button {
                    companion.start(.create)
                } label: {
                    Label("Retry now", systemImage: "arrow.clockwise")
                }

            case .working(let stage):
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pairing…").font(.headline)
                        Text(stage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Keep GassPair open until it finishes (up to a few minutes).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { companion.cancel() }

            case .succeeded(let file, let message):
                Label("Verified RPPairing ready", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text(message).font(.footnote).foregroundStyle(.secondary)
                ShareLink(item: file) {
                    Label("Export \(file.lastPathComponent)", systemImage: "square.and.arrow.up")
                }
                Text("Also in Files › On My iPhone › GassPair.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    companion.start(.create)
                } label: {
                    Label("Create a new record", systemImage: "arrow.clockwise")
                }
                .font(.footnote)

            case .failed(let message):
                Label("Stopped", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message).font(.footnote).textSelection(.enabled)
                Text("No RPPairing file was saved.").font(.caption).foregroundStyle(.secondary)
                Button {
                    companion.start(.create)
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text("Integrated usbmuxd companion")
        }
    }

    private func row(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func importLockdown(_ result: Result<[URL], Error>) {
        do {
            guard let source = try result.get().first else { return }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: source, options: [.mappedIfSafe])
            try IntegratedUsbmuxdCompanion.storeLockdown(data)
            importError = nil
            companion.lockdownImported()
        } catch {
            importError = error.localizedDescription
        }
    }
}
