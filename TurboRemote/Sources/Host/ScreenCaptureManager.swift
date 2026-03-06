import Foundation
import ScreenCaptureKit
import CoreMedia
import AppKit
import CoreGraphics

@MainActor
final class ScreenCaptureManager: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var captureError: String?
    @Published var availableDisplays = [SCDisplay]()
    @Published var selectedDisplayIndex = 0

    private var stream: SCStream?
    private var streamOutput: StreamOutputHandler?

    /// Set from HostManager — called on background queue, NOT on MainActor
    nonisolated(unsafe) var onFrame: ((CMSampleBuffer) -> Void)?
    var onColourSpaceDetected: ((ColourSpaceInfo) -> Void)?

    func refreshDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableDisplays = content.displays
        } catch {
            print("[ScreenCapture] Failed to enumerate displays: \(error)")
        }
    }

    func startCapture(displayIndex: Int? = nil) async {
        // Preflight: check and request Screen Recording permission
        if !CGPreflightScreenCaptureAccess() {
            print("[ScreenCapture] Permission not granted, requesting...")
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                captureError = "Screen Recording permission not granted.\nOpen System Settings > Privacy & Security > Screen Recording, remove TurboRemote, re-add it, then click Retry."
                print("[ScreenCapture] Permission denied by system")
                return
            }
        }
        print("[ScreenCapture] Permission preflight passed")

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableDisplays = content.displays

            let index = displayIndex ?? selectedDisplayIndex
            guard index < content.displays.count else {
                captureError = "No display found"
                return
            }
            let display = content.displays[index]

            // Detect display colour space
            if let screen = NSScreen.screens.first(where: { Int($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0) == Int(display.displayID) }) {
                let csInfo = ColourSpaceInfo.fromScreen(screen)
                onColourSpaceDetected?(csInfo)
                print("[ScreenCapture] Display colour space: \(csInfo.name)")
            } else {
                onColourSpaceDetected?(ColourSpaceInfo(id: .sRGB, name: "sRGB (fallback)"))
            }

            // Exclude our own app windows from capture
            let ourBundleID = Bundle.main.bundleIdentifier ?? ""
            let excludedWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == ourBundleID }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()
            config.width = display.width * 2   // Retina
            config.height = display.height * 2
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            config.queueDepth = 3

            // Capture in display's native colour space
            config.colorSpaceName = CGColorSpace.displayP3 as CFString

            // Capture the onFrame closure directly to avoid MainActor hop
            let frameCallback = self.onFrame
            let handler = StreamOutputHandler { sampleBuffer in
                frameCallback?(sampleBuffer)
            }
            streamOutput = handler

            let newStream = SCStream(filter: filter, configuration: config, delegate: handler)
            try newStream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await newStream.startCapture()

            stream = newStream
            isCapturing = true
            captureError = nil
            print("[ScreenCapture] Started: \(display.width*2)x\(display.height*2)")
        } catch {
            captureError = error.localizedDescription
            print("[ScreenCapture] Error: \(error)")
        }
    }

    func stopCapture() async {
        do {
            try await stream?.stopCapture()
        } catch {
            print("[ScreenCapture] Stop error: \(error)")
        }
        stream = nil
        streamOutput = nil
        isCapturing = false
    }
}

private final class StreamOutputHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else { return }
        handler(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreenCapture] Stream stopped with error: \(error)")
    }
}
