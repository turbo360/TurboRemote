import Foundation
import Network

final class HostServer: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.turboremote.host-server", qos: .userInteractive)
    private var receiveBuffer = Data()
    private var authenticated = false
    private let pinHash: Data

    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    var onError: ((String) -> Void)?
    var onModeChange: ((ConnectionMode) -> Void)?

    init(port: UInt16 = 7420) {
        self.port = port
        self.pinHash = PassphraseManager.hash(Secrets.appPin)
    }

    func start() {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveInterval = 5
            tcpOptions.keepaliveIdle = 10

            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true

            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            onError?("Failed to create listener: \(error)")
            return
        }

        guard let listener = listener else { return }

        // Advertise via Bonjour
        listener.service = NWListener.Service(name: "TurboRemote", type: "_turboremote._tcp")

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[HostServer] Listening on port \(self?.port ?? 0)")
            case .failed(let error):
                self?.onError?("Listener failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] newConnection in
            guard let self = self else { return }
            if let existing = self.connection {
                existing.cancel()
            }
            self.connection = newConnection
            self.receiveBuffer.removeAll()
            self.authenticated = false
            self.setupConnection(newConnection)
        }

        listener.start(queue: queue)
    }

    // MARK: - Connection Handling

    private func setupConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[HostServer] Client connected: \(connection.endpoint)")
                self?.startReceiving()
            case .failed(let error):
                print("[HostServer] Connection failed: \(error)")
                self?.handleDisconnect()
            case .cancelled:
                print("[HostServer] Connection cancelled")
                self?.handleDisconnect()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func handleDisconnect() {
        authenticated = false
        onClientDisconnected?()
    }

    // MARK: - Receive

    private func startReceiving() {
        receiveLoop()
    }

    private func receiveLoop() {
        guard let connection = connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let data = content {
                self.receiveBuffer.append(data)
                self.processMessages()
            }

            if isComplete || error != nil {
                self.handleDisconnect()
                return
            }
            self.receiveLoop()
        }
    }

    private func processMessages() {
        while receiveBuffer.count >= 4 {
            let msgSize = Int(receiveBuffer.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            guard receiveBuffer.count >= 4 + msgSize else { return }

            let msgData = receiveBuffer.subdata(in: 4..<4+msgSize)
            receiveBuffer.removeFirst(4 + msgSize)

            if !authenticated {
                if let authHash = ControlMessage.parseAuth(from: msgData) {
                    if authHash == pinHash {
                        authenticated = true
                        print("[HostServer] Client authenticated")
                        sendAuthResult(true)
                        onClientConnected?()
                    } else {
                        print("[HostServer] Client auth failed")
                        sendAuthResult(false)
                        connection?.cancel()
                    }
                }
                continue
            }

            if let mode = ControlMessage.parseModeChange(from: msgData) {
                print("[HostServer] Mode change: \(mode.label)")
                onModeChange?(mode)
            }
        }
    }

    private func sendAuthResult(_ success: Bool) {
        let data = ControlMessage.authResultData(success)
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Send

    func send(_ data: Data) {
        guard authenticated, let connection = connection else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("[HostServer] Send error: \(error)")
            }
        })
    }

    var hasClient: Bool {
        authenticated && connection?.state == .ready
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        receiveBuffer.removeAll()
        authenticated = false
    }

    deinit { stop() }
}
