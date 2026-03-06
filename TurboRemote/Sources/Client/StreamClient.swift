import Foundation
import Network

final class StreamClient: @unchecked Sendable {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.turboremote.client", qos: .userInteractive)
    private var receiveBuffer = Data()
    private var authenticated = false

    // Reconnection
    private var lastHost: String?
    private var lastPort: UInt16 = 7420
    private var lastPassphrase: String?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private var shouldReconnect = false

    var onPacketReceived: ((FramePacket) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?
    var onAuthResult: ((Bool) -> Void)?
    var onReconnecting: ((Int) -> Void)?

    func connect(host: String, port: UInt16 = 7420, passphrase: String) {
        lastHost = host
        lastPort = port
        lastPassphrase = passphrase
        shouldReconnect = true
        reconnectAttempts = 0
        attemptConnection(host: host, port: port)
    }

    private func attemptConnection(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)

        // Try QUIC first, then TLS+TCP, then plain TCP
        let params = createQUICParameters() ?? createTLSParameters() ?? NWParameters.tcp
        connection = NWConnection(to: endpoint, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[Client] Connected to \(host):\(port)")
                self?.reconnectAttempts = 0
                self?.startReceiving()
                self?.authenticate()
            case .failed(let error):
                print("[Client] Connection failed: \(error)")
                self?.attemptReconnect(error: error.localizedDescription)
            case .cancelled:
                print("[Client] Disconnected")
            default:
                break
            }
        }

        connection?.start(queue: queue)
    }

    /// Connect via Bonjour endpoint (mDNS discovery)
    func connect(endpoint: NWEndpoint, passphrase: String) {
        lastPassphrase = passphrase
        shouldReconnect = true
        reconnectAttempts = 0

        let params = createQUICParameters() ?? createTLSParameters() ?? NWParameters.tcp
        connection = NWConnection(to: endpoint, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[Client] Connected via Bonjour")
                self?.reconnectAttempts = 0
                self?.startReceiving()
                self?.authenticate()
            case .failed(let error):
                print("[Client] Connection failed: \(error)")
                self?.onDisconnected?(error.localizedDescription)
            case .cancelled:
                break
            default:
                break
            }
        }

        connection?.start(queue: queue)
    }

    // MARK: - QUIC / TLS Parameters

    private func createQUICParameters() -> NWParameters? {
        let quicOptions = NWProtocolQUIC.Options(alpn: ["turboremote"])
        let secOptions = quicOptions.securityProtocolOptions

        // Accept any server certificate (we authenticate via passphrase)
        sec_protocol_options_set_verify_block(secOptions, { _, _, completion in
            completion(true)
        }, queue)

        return NWParameters(quic: quicOptions)
    }

    private func createTLSParameters() -> NWParameters? {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, completion in
            completion(true)
        }, queue)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true

        return NWParameters(tls: tlsOptions, tcp: tcpOptions)
    }

    // MARK: - Authentication

    private func authenticate() {
        guard let passphrase = lastPassphrase else { return }
        let hash = PassphraseManager.hash(passphrase)
        let authData = ControlMessage.authData(passphraseHash: hash)
        connection?.send(content: authData, completion: .contentProcessed { error in
            if let error = error {
                print("[Client] Auth send error: \(error)")
            }
        })
    }

    // MARK: - Reconnection

    private func attemptReconnect(error: String?) {
        guard shouldReconnect,
              reconnectAttempts < maxReconnectAttempts,
              let host = lastHost else {
            onDisconnected?(error)
            return
        }

        reconnectAttempts += 1
        let delay = min(Double(reconnectAttempts) * 0.5, 5.0)
        onReconnecting?(reconnectAttempts)
        print("[Client] Reconnecting in \(delay)s (attempt \(reconnectAttempts))")

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.shouldReconnect else { return }
            self.attemptConnection(host: host, port: self.lastPort)
        }
    }

    // MARK: - Mode Change

    func sendModeChange(_ mode: ConnectionMode) {
        guard authenticated, let connection = connection else { return }
        let data = ControlMessage.modeChangeData(mode)
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[Client] Send mode change error: \(error)")
            }
        })
    }

    // MARK: - Receive

    private func startReceiving() {
        receiveLoop()
    }

    private func receiveLoop() {
        guard let connection = connection else { return }
        connection.receive(minimumIncompleteLength: 4, maximumLength: 1_048_576) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content {
                self.receiveBuffer.append(data)
                self.processBuffer()
            }

            if isComplete {
                self.attemptReconnect(error: nil)
                return
            }
            if let error = error {
                self.attemptReconnect(error: error.localizedDescription)
                return
            }

            self.receiveLoop()
        }
    }

    private func processBuffer() {
        while receiveBuffer.count >= 4 {
            let packetSize = Int(receiveBuffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard receiveBuffer.count >= 4 + packetSize else { return }

            let packetData = receiveBuffer.subdata(in: 4..<4+packetSize)
            receiveBuffer.removeFirst(4 + packetSize)

            // Check for auth result
            if !authenticated {
                if let result = ControlMessage.parseAuthResult(from: packetData) {
                    authenticated = result
                    onAuthResult?(result)
                    if result {
                        onConnected?()
                    } else {
                        shouldReconnect = false
                        onDisconnected?("Authentication failed — check passphrase")
                        connection?.cancel()
                    }
                }
                continue
            }

            // Regular frame packet
            if let packet = FramePacket.deserialize(from: packetData) {
                onPacketReceived?(packet)
            }
        }
    }

    func disconnect() {
        shouldReconnect = false
        authenticated = false
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
    }

    deinit { disconnect() }
}
