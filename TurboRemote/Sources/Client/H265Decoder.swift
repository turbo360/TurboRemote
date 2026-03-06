import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class H265Decoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    var onDecodedFrame: ((CVPixelBuffer) -> Void)?

    func decode(packet: FramePacket) {
        // Update format description on keyframes
        if packet.isKeyframe, let paramSets = packet.parameterSets, !paramSets.isEmpty {
            createFormatDescription(from: paramSets)
        }

        guard let formatDesc = formatDescription else {
            print("[Decoder] No format description — waiting for keyframe")
            return
        }

        // Ensure session exists
        if session == nil {
            createSession(formatDescription: formatDesc)
        }

        guard let session = session else { return }

        // Create CMBlockBuffer from encoded data
        let frameData = packet.frameData
        var blockBuffer: CMBlockBuffer?
        let status = frameData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            // CMBlockBuffer needs a mutable copy
            let mutableData = UnsafeMutableRawPointer(mutating: baseAddress)
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: nil,
                memoryBlock: nil,
                blockLength: frameData.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: frameData.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
        }

        guard status == noErr, let block = blockBuffer else {
            print("[Decoder] Failed to create block buffer: \(status)")
            return
        }

        // Copy data into block buffer
        let copyStatus = frameData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: frameData.count
            )
        }

        guard copyStatus == noErr else {
            print("[Decoder] Failed to copy data to block buffer")
            return
        }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = frameData.count
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(packet.timestamp), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )

        let sampleStatus = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: block,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sample = sampleBuffer else {
            print("[Decoder] Failed to create sample buffer: \(sampleStatus)")
            return
        }

        // Decode
        var flagsOut = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flagsOut
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let pixelBuffer = imageBuffer else {
                if status != noErr {
                    print("[Decoder] Decode frame error: \(status)")
                }
                return
            }
            self?.onDecodedFrame?(pixelBuffer)
        }

        if decodeStatus != noErr {
            print("[Decoder] DecodeFrame call error: \(decodeStatus)")
        }
    }

    private func createFormatDescription(from parameterSets: [Data]) {
        let pointers = parameterSets.map { data -> UnsafePointer<UInt8> in
            data.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
        }
        let sizes = parameterSets.map { $0.count }

        // We need to keep the data alive during the call
        var formatDesc: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { pointersBuffer in
            sizes.withUnsafeBufferPointer { sizesBuffer in
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil,
                    parameterSetCount: parameterSets.count,
                    parameterSetPointers: pointersBuffer.baseAddress!,
                    parameterSetSizes: sizesBuffer.baseAddress!,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &formatDesc
                )
            }
        }

        if status == noErr, let desc = formatDesc {
            // Check if format description changed
            if let existing = formatDescription, CMVideoFormatDescriptionMatchesImageBuffer(existing, imageBuffer: desc as! CVImageBuffer) == false {
                // Format changed — recreate session
                teardownSession()
            }
            formatDescription = desc
            // Recreate session with new format
            teardownSession()
            print("[Decoder] Format description created from \(parameterSets.count) parameter sets")
        } else {
            print("[Decoder] Failed to create format description: \(status)")
        }
    }

    private func createSession(formatDescription: CMVideoFormatDescription) {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let newSession = session else {
            print("[Decoder] Failed to create decompression session: \(status)")
            return
        }

        self.session = newSession
        print("[Decoder] Decompression session created")
    }

    private func teardownSession() {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    func teardown() {
        teardownSession()
        formatDescription = nil
    }

    deinit {
        teardown()
    }
}
