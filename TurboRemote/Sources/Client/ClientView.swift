import SwiftUI
import MetalKit
import Network

struct ClientView: View {
    @StateObject private var clientManager = ClientManager()
    @State private var hostAddress = ""

    var body: some View {
        Group {
            if clientManager.isConnected {
                streamView
            } else {
                connectionView
            }
        }
    }

    // MARK: - Connection Screen

    private var connectionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("Turbo Remote Client")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Host Address")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("192.168.1.x or hostname", text: $hostAddress)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .onSubmit { connect() }
            }

            // Bonjour discovered hosts
            if !clientManager.discoveredHosts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Discovered Hosts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(clientManager.discoveredHosts, id: \.name) { host in
                        Button {
                            clientManager.selectedEndpoint = host.endpoint
                            hostAddress = host.name
                        } label: {
                            HStack {
                                Image(systemName: "wifi")
                                Text(host.name)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(clientManager.selectedEndpoint == host.endpoint ? Color.blue.opacity(0.2) : Color.clear)
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 250, alignment: .leading)
            }

            if clientManager.isConnecting {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(clientManager.connectionStatus)
                        .font(.caption)
                }
            }

            if let error = clientManager.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .frame(width: 250)
            }

            Button("Connect") { connect() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(hostAddress.isEmpty || clientManager.isConnecting)
        }
        .padding(30)
        .frame(width: 350, height: 450)
        .onAppear { clientManager.startDiscovery() }
        .onDisappear { clientManager.stopDiscovery() }
    }

    // MARK: - Stream View

    private var streamView: some View {
        ZStack(alignment: .top) {
            MetalStreamView(renderer: clientManager.renderer, mtkView: $clientManager.mtkView)

            VStack {
                HStack(alignment: .top) {
                    qualityBadge
                    Spacer()
                    hudStats
                }
                .padding(12)

                Spacer()

                VStack(spacing: 8) {
                    if clientManager.connectionMode == .lowBandwidth {
                        Text("Low Bandwidth Mode — not suitable for colour decisions")
                            .font(.caption.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.red.opacity(0.85))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }

                    if clientManager.connectionMode == .mobile && clientManager.currentQuality == .quality {
                        Text("Motion — pause before colour decisions")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.orange.opacity(0.85))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }

                    HStack(spacing: 12) {
                        modePicker
                        Spacer()
                        Button("Disconnect") { clientManager.disconnect() }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.4))
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: - HUD Components

    @ViewBuilder
    private var qualityBadge: some View {
        let q = clientManager.currentQuality
        let c = q.badgeColor
        HStack(spacing: 6) {
            Text(q.label)
                .font(.caption.bold())
            Text(clientManager.connectionMode.label)
                .font(.system(size: 9))
                .opacity(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(red: c.r, green: c.g, blue: c.b).opacity(0.85))
        .foregroundColor(.white)
        .cornerRadius(4)
    }

    @ViewBuilder
    private var hudStats: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Frames: \(clientManager.framesDecoded)")
            Text(clientManager.resolutionString)
            Text("Delta: \(clientManager.deltaPercent)%")
            Text(clientManager.colourTransformString)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.5))
        .foregroundColor(.white)
        .cornerRadius(4)
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(ConnectionMode.allCases, id: \.rawValue) { mode in
                Button {
                    clientManager.setMode(mode)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 10))
                        Text(mode.label)
                            .font(.system(size: 8, weight: .medium))
                    }
                    .frame(width: 56, height: 32)
                    .background(clientManager.connectionMode == mode ? Color.white.opacity(0.25) : Color.clear)
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.black.opacity(0.3))
        .cornerRadius(6)
    }

    private func connect() {
        guard !hostAddress.isEmpty else { return }
        if let endpoint = clientManager.selectedEndpoint {
            clientManager.connect(endpoint: endpoint)
        } else {
            clientManager.connect(to: hostAddress)
        }
    }
}

// MARK: - Client Manager

@MainActor
final class ClientManager: ObservableObject {
    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var errorMessage: String?
    @Published var connectionStatus = "Connecting..."
    @Published var framesDecoded = 0
    @Published var resolutionString = "—"
    @Published var connectionMode: ConnectionMode = .studio
    @Published var currentQuality: QualityLevel = .lossless
    @Published var deltaPercent: UInt8 = 0
    @Published var mtkView = MTKView()
    @Published var discoveredHosts = [BonjourBrowser.DiscoveredHost]()
    @Published var selectedEndpoint: NWEndpoint?
    @Published var colourTransformString = "—"

    private(set) var renderer: MetalRenderer?
    private let client = StreamClient()
    private let decoder = H265Decoder()
    private let browser = BonjourBrowser()

    init() {
        renderer = MetalRenderer(mtkView: mtkView)
        if let r = renderer {
            colourTransformString = r.colourManager.transformDescription
        }

        decoder.onDecodedFrame = { [weak self] pixelBuffer in
            guard let self = self else { return }
            self.renderer?.updatePixelBuffer(pixelBuffer)
            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)
            Task { @MainActor in
                self.framesDecoded += 1
                self.resolutionString = "\(w)x\(h)"
            }
        }

        client.onPacketReceived = { [weak self] packet in
            guard let self = self else { return }
            Task { @MainActor in
                self.currentQuality = packet.qualityLevel
                self.deltaPercent = packet.deltaPercent
            }
            self.decoder.decode(packet: packet)
        }

        client.onAuthResult = { [weak self] success in
            Task { @MainActor in
                if !success {
                    self?.errorMessage = "Authentication failed — wrong PIN"
                    self?.isConnecting = false
                }
            }
        }

        client.onConnected = { [weak self] in
            Task { @MainActor in
                self?.isConnecting = false
                self?.isConnected = true
                self?.errorMessage = nil
                self?.client.sendModeChange(self?.connectionMode ?? .studio)
            }
        }

        client.onDisconnected = { [weak self] error in
            Task { @MainActor in
                self?.isConnecting = false
                self?.isConnected = false
                if let error = error {
                    self?.errorMessage = error
                }
            }
        }

        client.onReconnecting = { [weak self] attempt in
            Task { @MainActor in
                self?.connectionStatus = "Reconnecting (\(attempt))..."
            }
        }

        browser.onHostsUpdated = { [weak self] hosts in
            Task { @MainActor in
                self?.discoveredHosts = hosts
            }
        }
    }

    func startDiscovery() {
        browser.startBrowsing()
    }

    func stopDiscovery() {
        browser.stopBrowsing()
    }

    func connect(to host: String) {
        isConnecting = true
        connectionStatus = "Connecting..."
        errorMessage = nil
        client.connect(host: host)
    }

    func connect(endpoint: NWEndpoint) {
        isConnecting = true
        connectionStatus = "Connecting..."
        errorMessage = nil
        client.connect(endpoint: endpoint)
    }

    func setMode(_ mode: ConnectionMode) {
        connectionMode = mode
        client.sendModeChange(mode)
    }

    func disconnect() {
        client.disconnect()
        decoder.teardown()
        isConnected = false
        isConnecting = false
        framesDecoded = 0
        currentQuality = .lossless
        deltaPercent = 0
    }
}
