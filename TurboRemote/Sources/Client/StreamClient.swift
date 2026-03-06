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
    private var lastEndpoint: NWEndpoint?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 10
    private var shouldReconnect = false

    var onPacketReceived: ((FramePacket) -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?
    var onAuthResult: ((Bool) -> Void)?
    var onReconnecting: ((Int) -> Void)?

    func connect(host: String, port: UInt16 = 7420) {
        lastHost = host
        lastPort = port
        lastEndpoint = nil
        shouldReconnect = true
        reconnectAttempts = 0
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        attemptConnection(endpoint: endpoint)
    }

    func connect(endpoint: NWEndpoint) {
        lastEndpoint = endpoint
        lastHost = nil
        shouldReconnect = true
        reconnectAttempts = 0
        attemptConnection(endpoint: endpoint)
    }

    private func attemptConnection(endpoint: NWEndpoint) {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = 10

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        connection = NWConnection(to: endpoint, using: params)

        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[Client] Connected")
                self?.reconnectAttempts = 0
                self?.startReceiving()
                self?.authenticate()
            case .failed(let error):
                print("[Client] Connection failed: \(error)")
                self?.attemptReconnect(error: error.localizedDescription)
            case .waiting(let error):
                print("[Client] Waiting: \(error)")
            case .cancelled:
                print("[Client] Disconnected")
            default:
                break
            }
        }

        connection?.start(queue: queue)
    }

    // MARK: - Authentication (uses app PIN automatically)

    private func authenticate() {
        let hash = PassphraseManager.hash(Secrets.appPin)
        let authData = ControlMessage.authData(passphraseHash: hash)
        connection?.send(content: authData, completion: .contentProcessed { error in
            if let error = error {
                print("[Client] Auth send error: \(error)")
            }
        })
    }

    // MARK: - Reconnection

    private func attemptReconnect(error: String?) {
        guard shouldReconnect, reconnectAttempts < maxReconnectAttempts else {
            onDisconnected?(error)
            return
        }

        reconnectAttempts += 1
        let delay = min(Double(reconnectAttempts) * 0.5, 5.0)
        onReconnecting?(reconnectAttempts)
        print("[Client] Reconnecting in \(delay)s (attempt \(reconnectAttempts))")

        // Clean up old connection
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        authenticated = false

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.shouldReconnect else { return }
            if let endpoint = self.lastEndpoint {
                self.attemptConnection(endpoint: endpoint)
            } else if let host = self.lastHost {
                let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: self.lastPort)!)
                self.attemptConnection(endpoint: ep)
            }
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

            guard packetSize > 0, packetSize <= 10_000_000 else {
                print("[Client] Invalid frame size \(packetSize), resetting buffer")
                receiveBuffer.removeAll()
                return
            }

            let totalNeeded = 4 + packetSize
            guard receiveBuffer.count >= totalNeeded else { return }

            let packetData = Data(receiveBuffer[receiveBuffer.startIndex + 4 ..< receiveBuffer.startIndex + totalNeeded])
            receiveBuffer.removeFirst(totalNeeded)

            if !authenticated {
                if let result = ControlMessage.parseAuthResult(from: packetData) {
                    authenticated = result
                    onAuthResult?(result)
                    if result {
                        onConnected?()
                    } else {
                        shouldReconnect = false
                        onDisconnected?("Authentication failed")
                        connection?.cancel()
                    }
                }
                continue
            }

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
