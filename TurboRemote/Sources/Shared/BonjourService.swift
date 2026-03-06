import Foundation
import Network

final class BonjourBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.turboremote.bonjour-browser")

    struct DiscoveredHost: Hashable, Sendable {
        let name: String
        let endpoint: NWEndpoint
    }

    var onHostsUpdated: (([DiscoveredHost]) -> Void)?
    private var hosts = [DiscoveredHost]()

    func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: "_turboremote._tcp", domain: nil), using: params)

        browser?.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            self.hosts = results.compactMap { result -> DiscoveredHost? in
                switch result.endpoint {
                case .service(let name, _, _, _):
                    return DiscoveredHost(name: name, endpoint: result.endpoint)
                default:
                    return nil
                }
            }
            self.onHostsUpdated?(self.hosts)
        }

        browser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[Bonjour] Browser ready")
            case .failed(let error):
                print("[Bonjour] Browser failed: \(error)")
            default:
                break
            }
        }

        browser?.start(queue: queue)
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        hosts.removeAll()
    }

    deinit { stopBrowsing() }
}
