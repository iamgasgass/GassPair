import SwiftUI
import UniformTypeIdentifiers

/// usbmuxd (integrated): no Mac and nothing to type (no address, pin, token or UDID).
/// Import the Lockdown.plist once; everything else runs on its own.
/// Entirely built from glass cards: native Liquid Glass on iOS 26+.
struct IntegratedUsbmuxdCompanionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var companion = IntegratedUsbmuxdCompanion.shared

    private enum Importer { case lockdown, rpPairing }
    @State private var importer: Importer = .lockdown
    @State private var showingImporter = false
    @State private var lockdownMessage: (text: String, ok: Bool)?
    @State private var rpMessage: (text: String, ok: Bool)?
    @State private var showingLog = false
    @State private var refreshToken = 0 // re-reads file-backed state after imports

    var body: some View {
        ScrollView {
            GlassGroup(spacing: 20) {
                VStack(spacing: 20) {
                    header
                    statusCard
                    if let device = companion.device { deviceCard(device) }
                    lockdownCard
                    existingRecordCard
                    optionsCard
                    if !companion.log.isEmpty { detailsCard }
                    macFallbackCard
                }
                .frame(maxWidth: 520)
                .padding()
                .frame(maxWidth: .infinity)
            }
        }
        .animation(.default, value: companion.phase)
        .animation(.default, value: companion.device)
        .navigationTitle("usbmuxd (integrated)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.propertyList, .xml, .data],
                      allowsMultipleSelection: false) { result in
            switch importer {
            case .lockdown: importLockdown(result)
            case .rpPairing: importRPPairing(result)
            }
        }
        .onAppear { companion.viewAppeared() }
        .onDisappear { companion.viewDisappeared() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: companion.statusSymbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(companion.statusTint)
                .frame(width: 72, height: 72)
                .glassCircle()
            Text("usbmuxd (integrated)")
                .font(.title2.bold())
            Text("The usbmuxd companion runs inside GassPair. No Mac, no cable, nothing to configure.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch companion.phase {
            case .needsLockdown:
                Label("Import the Lockdown.plist to begin", systemImage: "doc.badge.arrow.up")
                    .font(.headline)
                Text("That's the only step: the companion then finds the device and creates the record on its own.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                primaryButton("Import Lockdown.plist", systemImage: "doc.badge.arrow.up") {
                    present(.lockdown)
                }

            case .ready:
                Label("Ready", systemImage: "cable.connector")
                    .font(.headline)
                Text(companion.automatic
                     ? "Starting automatically…"
                     : "Automatic mode is off. Start when you're ready.")
                    .font(.footnote).foregroundStyle(.secondary)
                primaryButton("Create RPPairing", systemImage: "key.horizontal") {
                    companion.start(.create)
                }

            case .searching(let endpoint):
                progressRow(title: "Looking for the device…", detail: endpoint, monospaced: true)
                secondaryButton("Cancel", systemImage: "xmark") { companion.cancel() }

            case .waitingForRoute(let reason, let retryIn):
                Label("Device not reachable yet", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(retryIn > 0
                     ? "Turn LocalDevVPN on (or join the same Wi-Fi). Retrying automatically in \(retryIn) s…"
                     : "Turn LocalDevVPN on (or join the same Wi-Fi), then retry.")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Text(reason)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
                primaryButton("Retry now", systemImage: "arrow.clockwise") { companion.start(.create) }

            case .working(let stage):
                progressRow(title: "Pairing…", detail: stage, monospaced: false)
                Text("Keep GassPair open until it finishes (up to a few minutes).")
                    .font(.caption).foregroundStyle(.secondary)
                secondaryButton("Cancel", systemImage: "xmark") { companion.cancel() }

            case .succeeded(let file, let message):
                Label("Verified RPPairing ready", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text(message)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ShareLink(item: file) {
                    Label("Export \(file.lastPathComponent)", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
                .prominentPillButton()
                .controlSize(.large)
                Text("Also in Files › On My iPhone › GassPair.")
                    .font(.caption).foregroundStyle(.secondary)
                secondaryButton("Create a new record", systemImage: "arrow.clockwise") {
                    companion.start(.create)
                }

            case .failed(let message):
                Label("Stopped", systemImage: "xmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("No RPPairing file was saved.")
                    .font(.caption).foregroundStyle(.secondary)
                primaryButton("Try again", systemImage: "arrow.clockwise") { companion.start(.create) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 24)
    }

    // MARK: - Cards

    private func deviceCard(_ device: IntegratedUsbmuxdCompanion.Device) -> some View {
        GlassSection("Device", systemImage: "iphone") {
            GlassInfoRow(title: "Name", value: device.name.isEmpty ? "—" : device.name)
            if !device.productType.isEmpty { GlassInfoRow(title: "Model", value: device.productType) }
            GlassInfoRow(title: "iOS", value: device.iosVersion)
            GlassInfoRow(title: "UDID", value: device.udid, monospaced: true)
            GlassInfoRow(title: "Reached via",
                         value: device.endpoint == "10.7.0.1" ? "LocalDevVPN (10.7.0.1)" : device.endpoint)
        }
    }

    private var lockdownCard: some View {
        GlassSection("Lockdown trust", systemImage: "lock.shield",
                     footer: "Use the Lockdown pairing record already trusted by this iPhone/iPad. It stays on the device, protected, and is never sent anywhere.") {
            let _ = refreshToken
            if companion.hasLockdown {
                Label("Lockdown.plist imported", systemImage: "checkmark.shield.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
            secondaryButton(companion.hasLockdown ? "Replace Lockdown.plist" : "Import Lockdown.plist",
                            systemImage: "doc.badge.arrow.up") {
                present(.lockdown)
            }
            .disabled(companion.isBusy)
            if let lockdownMessage {
                Text(lockdownMessage.text)
                    .font(.caption)
                    .foregroundStyle(lockdownMessage.ok ? .green : .orange)
                    .textSelection(.enabled)
            }
        }
    }

    private var existingRecordCard: some View {
        GlassSection("Existing RPPairing", systemImage: "doc.badge.gearshape",
                     footer: "Checks an RPPairing file you already have against the live device with pair-verify only: no PIN, no new pairing. A verified copy is saved next to it.") {
            let _ = refreshToken
            if companion.hasImportedRP {
                Label("RPPairing file imported", systemImage: "checkmark.shield.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            }
            secondaryButton(companion.hasImportedRP ? "Replace RPPairing file" : "Import RPPairing file",
                            systemImage: "doc.badge.arrow.up") {
                present(.rpPairing)
            }
            .disabled(companion.isBusy)
            if companion.hasImportedRP {
                secondaryButton("Verify on the device", systemImage: "checkmark.shield") {
                    companion.start(.verifyImported)
                }
                .disabled(companion.isBusy || !companion.hasLockdown)
            }
            if let rpMessage {
                Text(rpMessage.text)
                    .font(.caption)
                    .foregroundStyle(rpMessage.ok ? .green : .orange)
                    .textSelection(.enabled)
            }
        }
    }

    private var optionsCard: some View {
        GlassSection("Options", systemImage: "gearshape",
                     footer: "Automatic: as soon as the Lockdown.plist is available GassPair finds the device (LocalDevVPN 10.7.0.1 first, then Wi-Fi), creates the record, verifies it on a fresh connection and saves it. If the device can't be reached it keeps retrying — just switch LocalDevVPN on.") {
            Toggle("Automatic", isOn: $companion.automatic)
                .font(.subheadline)
            TextField("Extra device address (optional)", text: $companion.extraEndpoints)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .font(.subheadline)
                .glassField()
                .disabled(companion.isBusy)
        }
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation { showingLog.toggle() }
            } label: {
                HStack {
                    Label("Details (\(companion.log.count))", systemImage: "list.bullet.rectangle")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showingLog ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showingLog {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(companion.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }

    private var macFallbackCard: some View {
        GlassSection("Mac companion", systemImage: "desktopcomputer",
                     footer: "Optional fallback, only if iOS refuses to open remotepairingdeviced over the network and you want to go through a Mac with a USB cable.") {
            NavigationLink {
                MacUsbmuxdCompanionView(initialLockdownFileURL: companion.hasLockdown ? IntegratedUsbmuxdCompanion.lockdownURL : nil)
            } label: {
                Label("Open Mac companion", systemImage: "arrow.right.circle")
                    .frame(maxWidth: .infinity)
            }
            .pillButton()
            .disabled(companion.isBusy)
        }
    }

    // MARK: - Pieces

    private func progressRow(title: String, detail: String, monospaced: Bool) -> some View {
        HStack(spacing: 14) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(monospaced ? .caption.monospaced() : .caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func primaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .prominentPillButton()
        .controlSize(.large)
    }

    private func secondaryButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .pillButton()
    }

    // MARK: - Imports

    private func present(_ kind: Importer) {
        importer = kind
        showingImporter = true
    }

    private func readPicked(_ result: Result<[URL], Error>) throws -> Data? {
        guard let source = try result.get().first else { return nil }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: source, options: [.mappedIfSafe])
    }

    private func importLockdown(_ result: Result<[URL], Error>) {
        do {
            guard let data = try readPicked(result) else { return }
            try IntegratedUsbmuxdCompanion.storeLockdown(data)
            lockdownMessage = ("Lockdown.plist imported.", true)
            refreshToken += 1
            companion.lockdownImported()
        } catch {
            lockdownMessage = (error.localizedDescription, false)
        }
    }

    private func importRPPairing(_ result: Result<[URL], Error>) {
        do {
            guard let data = try readPicked(result) else { return }
            try IntegratedUsbmuxdCompanion.storeImportedRP(data)
            rpMessage = ("Structure and key pair are valid. Tap Verify on the device to run pair-verify.", true)
            refreshToken += 1
        } catch {
            rpMessage = (error.localizedDescription, false)
        }
    }
}
