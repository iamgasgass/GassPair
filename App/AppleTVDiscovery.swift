import Darwin
import Foundation

struct AppleTVDevice: Identifiable, Equatable {
    let id: String
    let name: String
    /// mDNS hostname, e.g. `Living-Room.local.`
    let host: String
    /// Numeric addresses resolved by mDNS (IPv4 first).
    let addresses: [String]
    let port: Int

    /// Everything worth trying, best first: IPv4, the mDNS hostname, IPv6.
    var connectCandidates: [String] {
        var seen = Set<String>()
        let v4 = addresses.filter { !$0.contains(":") }
        let v6 = addresses.filter { $0.contains(":") }
        return (v4 + [host] + v6).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Browses for Apple TVs that are showing the
/// Settings › Remotes and Devices › Remote App and Devices screen.
@MainActor
final class AppleTVDiscovery: NSObject, ObservableObject {
    @Published private(set) var devices: [AppleTVDevice] = []

    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]

    func start() {
        guard browser == nil else { return }
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.includesPeerToPeer = false
        self.browser = browser
        browser.searchForServices(ofType: "_remotepairing-manual-pairing._tcp.", inDomain: "local.")
    }

    func stop() {
        browser?.delegate = nil
        browser?.stop()
        browser = nil
        for service in services.values {
            service.delegate = nil
            service.stop()
        }
        services.removeAll()
        devices.removeAll()
    }

    func restart() {
        stop()
        start()
    }

    private func identifier(for service: NetService) -> String {
        "\(service.name).\(service.type)\(service.domain)"
    }

    private func update(_ service: NetService) {
        let id = identifier(for: service)
        guard services[id] != nil, service.port > 0 else { return }
        let addresses = Self.numericAddresses(service.addresses ?? [])
        let host = service.hostName ?? ""
        guard !host.isEmpty || !addresses.isEmpty else { return }

        let txt = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        let advertisedName = txt["name"].flatMap { String(data: $0, encoding: .utf8) }
        let displayName = advertisedName.flatMap { $0.isEmpty ? nil : $0 } ?? service.name
        let device = AppleTVDevice(
            id: id,
            name: displayName,
            host: host,
            addresses: addresses,
            port: service.port)
        devices.removeAll { $0.id == id }
        devices.append(device)
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func numericAddresses(_ data: [Data]) -> [String] {
        var v4: [String] = []
        var v6: [String] = []
        for entry in data {
            entry.withUnsafeBytes { raw in
                guard let base = raw.baseAddress, raw.count >= MemoryLayout<sockaddr>.size else { return }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sa, socklen_t(raw.count), &buffer, socklen_t(buffer.count),
                                  nil, 0, NI_NUMERICHOST) == 0 else { return }
                let text = String(cString: buffer)
                switch Int32(sa.pointee.sa_family) {
                case AF_INET:
                    v4.append(text)
                case AF_INET6:
                    // Link-local addresses are only usable with a scope (fe80::1%en0).
                    if !text.lowercased().hasPrefix("fe80") || text.contains("%") {
                        v6.append(text)
                    }
                default:
                    break
                }
            }
        }
        return v4 + v6
    }
}

extension AppleTVDiscovery: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        onMainQueue { [self] in
            let id = identifier(for: service)
            services[id]?.stop()
            services[id] = service
            service.delegate = self
            service.resolve(withTimeout: 10)
            service.startMonitoring()
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        onMainQueue { [self] in
            let id = identifier(for: service)
            services[id]?.stop()
            services.removeValue(forKey: id)
            devices.removeAll { $0.id == id }
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        onMainQueue { [self] in
            guard browser === self.browser else { return }
            // Try again shortly (e.g. the network was changing).
            self.browser = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                onMainQueue { self?.start() }
            }
        }
    }
}

extension AppleTVDiscovery: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        onMainQueue { [self] in update(sender) }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        onMainQueue { [self] in
            // Retry resolution once more while the service is still listed.
            guard services[identifier(for: sender)] != nil else { return }
            sender.resolve(withTimeout: 10)
        }
    }

    nonisolated func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        onMainQueue { [self] in update(sender) }
    }
}
