import SwiftUI
import CoreMedia

struct HostView: View {
    @StateObject private var hostManager = HostManager()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "display")
                .font(.system(size: 40))
                .foregroundColor(hostManager.isStreaming ? .blue : .secondary)

            Text("Turbo Remote Host")
                .font(.title2.bold())

            statusView

            if let error = hostManager.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)

                Button("Retry Capture") {
                    Task { await hostManager.retryCapture() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            statsView

            Spacer()

            Text("Port: 7420")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .frame(width: 380, height: 480)
        .task {
            // Auto-start streaming when host view appears
            if !hostManager.isStreaming {
                await hostManager.startStreaming()
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.subheadline)
        }
    }

    private var statusColor: Color {
        if hostManager.isStreaming && hostManager.clientConnected {
            return .green
        } else if hostManager.isStreaming {
            return .blue
        }
        return .secondary
    }

    private var statusText: String {
        if hostManager.isStreaming && hostManager.clientConnected {
            return "Streaming to client"
        } else if hostManager.isStreaming {
            return "Waiting for client..."
        }
        return "Starting..."
    }

    @ViewBuilder
    private var statsView: some View {
        if hostManager.isStreaming {
            VStack(alignment: .leading, spacing: 5) {
                statRow("Resolution", hostManager.resolutionString)
                statRow("Colour space", hostManager.colourSpaceString)
                statRow("Quality", hostManager.currentQualityLabel)
                statRow("Frame delta", hostManager.deltaString)
                statRow("Bandwidth", hostManager.bandwidthString)
                statRow("Frames", "\(hostManager.framesEncoded) sent / \(hostManager.framesSkipped) skipped")
                statRow("Client mode", hostManager.clientModeLabel)
            }
            .font(.caption.monospacedDigit())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }
}

// MARK: - Profile Selection Logic

struct ProfileSelector {
    var connectionMode: ConnectionMode = .studio

    private var stableQuality: QualityLevel = .lossless
    private var candidateQuality: QualityLevel = .lossless
    private var candidateFrameCount: Int = 0
    private let hysteresisFrames = 3

    mutating func selectProfile(deltaFraction: Float) -> QualityLevel {
        let newQuality: QualityLevel

        switch connectionMode {
        case .studio:
            if deltaFraction < 0.001 { return .skipped }
            return .lossless

        case .broadband:
            if deltaFraction < 0.001 {
                newQuality = .skipped
            } else if deltaFraction < 0.02 {
                newQuality = .lossless
            } else if deltaFraction < 0.15 {
                newQuality = .highQuality
            } else {
                newQuality = .quality
            }

        case .mobile:
            if deltaFraction < 0.001 {
                newQuality = .skipped
            } else if deltaFraction < 0.02 {
                newQuality = .highQuality
            } else {
                newQuality = .quality
            }

        case .lowBandwidth:
            if deltaFraction < 0.001 {
                newQuality = .skipped
            } else {
                newQuality = .lowBW
            }
        }

        if newQuality == .skipped { return .skipped }

        if newQuality == candidateQuality {
            candidateFrameCount += 1
        } else {
            candidateQuality = newQuality
            candidateFrameCount = 1
        }

        if newQuality.rawValue > stableQuality.rawValue {
            stableQuality = newQuality
            return stableQuality
        }

        if candidateFrameCount >= hysteresisFrames {
            stableQuality = candidateQuality
        }

        return stableQuality
    }

    mutating func reset() {
        stableQuality = .lossless
        candidateQuality = .lossless
        candidateFrameCount = 0
    }
}

// MARK: - Host Manager

@MainActor
final class HostManager: ObservableObject {
    @Published var isStreaming = false
    @Published var clientConnected = false
    @Published var errorMessage: String?
    @Published var framesEncoded: Int = 0
    @Published var framesSkipped: Int = 0
    @Published var bandwidthString = "0 Mbps"
    @Published var resolutionString = "—"
    @Published var currentQualityLabel = "—"
    @Published var deltaString = "—"
    @Published var clientModeLabel = "Studio"
    @Published var colourSpaceString = "—"

    private let captureManager = ScreenCaptureManager()
    private let encoder = H265Encoder()
    private let server: HostServer
    private let deltaAnalyzer = FrameDeltaAnalyzer()
    private var profileSelector = ProfileSelector()

    private let _bytesSent = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private var bandwidthTimer: Timer?
    private var encoderReady = false

    init() {
        server = HostServer()
        _bytesSent.initialize(to: 0)

        server.onClientConnected = { [weak self] in
            Task { @MainActor in self?.clientConnected = true }
        }
        server.onClientDisconnected = { [weak self] in
            Task { @MainActor in self?.clientConnected = false }
        }
        server.onError = { [weak self] msg in
            Task { @MainActor in self?.errorMessage = msg }
        }
        server.onModeChange = { [weak self] mode in
            Task { @MainActor in
                self?.profileSelector.connectionMode = mode
                self?.clientModeLabel = mode.label
            }
        }

        captureManager.onColourSpaceDetected = { [weak self] csInfo in
            Task { @MainActor in
                self?.colourSpaceString = csInfo.name
            }
        }

        encoder.onEncodedPacket = { [weak self] packet in
            guard let self = self else { return }
            let data = packet.serialize()
            self.server.send(data)
            self._bytesSent.pointee += data.count
            Task { @MainActor in
                self.framesEncoded = Int(packet.sequenceNumber + 1)
                self.currentQualityLabel = packet.qualityLevel.label
            }
        }

        captureManager.onFrame = { [weak self] sampleBuffer in
            guard let self = self else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            if !self.encoderReady {
                let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
                let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
                self.encoder.setup(width: w, height: h)
                self.encoderReady = true
                Task { @MainActor in self.resolutionString = "\(w)x\(h)" }
            }

            let delta: Float
            if let analyzer = self.deltaAnalyzer {
                delta = analyzer.analyzeDelta(pixelBuffer: pixelBuffer)
            } else {
                delta = 1.0
            }

            let deltaPercent = UInt8(min(100, delta * 100))
            Task { @MainActor in
                self.deltaString = String(format: "%.1f%%", delta * 100)
            }

            let quality = self.profileSelector.selectProfile(deltaFraction: delta)

            if quality == .skipped {
                Task { @MainActor in
                    self.framesSkipped += 1
                    self.currentQualityLabel = QualityLevel.skipped.label
                }
                return
            }

            self.encoder.setQualityForNextFrame(quality, deltaPercent: deltaPercent)
            self.encoder.encode(sampleBuffer)
        }
    }

    func startStreaming() async {
        profileSelector.reset()
        server.start()
        await captureManager.startCapture()
        if let captureErr = captureManager.captureError {
            errorMessage = "Screen capture failed: \(captureErr)\nGrant Screen Recording permission in System Settings > Privacy & Security"
        }
        isStreaming = true
        framesSkipped = 0
        _bytesSent.pointee = 0
        startBandwidthMonitor()
    }

    func retryCapture() async {
        errorMessage = nil
        encoderReady = false
        await captureManager.stopCapture()
        await captureManager.startCapture()
        if let captureErr = captureManager.captureError {
            errorMessage = "Screen capture failed: \(captureErr)\nGrant Screen Recording permission in System Settings > Privacy & Security"
        }
    }

    func stopStreaming() async {
        await captureManager.stopCapture()
        encoder.teardown()
        server.stop()
        isStreaming = false
        clientConnected = false
        encoderReady = false
        bandwidthTimer?.invalidate()
        bandwidthTimer = nil
    }

    private func startBandwidthMonitor() {
        bandwidthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let mbps = Double(self._bytesSent.pointee * 8) / 1_000_000.0
            self._bytesSent.pointee = 0
            Task { @MainActor in
                self.bandwidthString = String(format: "%.1f Mbps", mbps)
            }
        }
    }

    deinit { _bytesSent.deallocate() }
}
