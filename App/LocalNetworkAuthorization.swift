import Foundation
import Network

/// Triggers (and waits for) the Local Network permission by advertising and
/// browsing a throwaway Bonjour service: once we can see our own service, access
/// has been granted.
@MainActor
final class LocalNetworkAuthorization {
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var generation = 0
    private var granted = false

    private let probeType = "_gasspairprobe._tcp"

    func request(timeout: TimeInterval = 60) async -> Bool {
        if granted { return true }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            waiters.append(cont)
            guard waiters.count == 1 else { return } // a probe is already running
            startProbe(timeout: timeout)
        }
    }

    private func startProbe(timeout: TimeInterval) {
        generation += 1
        let current = generation

        let params = NWParameters.tcp
        params.includePeerToPeer = false

        let listener = try? NWListener(using: params)
        listener?.service = NWListener.Service(name: "GassPairProbe-\(UUID().uuidString.prefix(8))", type: probeType)
        listener?.newConnectionHandler = { $0.cancel() }
        listener?.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                onMainQueue { self?.finish(false, generation: current) }
            }
        }
        self.listener = listener

        let browser = NWBrowser(for: .bonjour(type: probeType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                onMainQueue { self?.finish(false, generation: current) }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            if !results.isEmpty {
                onMainQueue { self?.finish(true, generation: current) }
            }
        }
        self.browser = browser

        listener?.start(queue: .main)
        browser.start(queue: .main)

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            onMainQueue { self?.finish(false, generation: current) }
        }
    }

    private func finish(_ authorized: Bool, generation: Int) {
        // Ignore late events from an older probe (e.g. its timeout firing).
        guard generation == self.generation, !waiters.isEmpty else { return }
        if authorized { granted = true }
        let pending = waiters
        waiters.removeAll()
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        pending.forEach { $0.resume(returning: authorized) }
    }
}
