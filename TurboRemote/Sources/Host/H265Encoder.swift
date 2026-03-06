import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class H265Encoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private var sequenceNumber: UInt32 = 0
    private var currentQuality: QualityLevel = .lossless
    private var currentDeltaPercent: UInt8 = 0
    private var sessionWidth: Int32 = 0
    private var sessionHeight: Int32 = 0
    private var sessionQuality: QualityLevel?

    var onEncodedPacket: ((FramePacket) -> Void)?

    func setup(width: Int32, height: Int32, quality: QualityLevel = .lossless) {
        // Skip recreation if session already matches
        if session != nil && sessionWidth == width && sessionHeight == height && sessionQuality == quality {
            return
        }

        teardown()
        sessionWidth = width
        sessionHeight = height
        sessionQuality = quality

        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("[Encoder] Failed to create session: \(status)")
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)

        // Quality level
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality.vtQuality as CFNumber)

        // Bitrate limit for non-lossless modes
        if quality != .lossless {
            let bitsPerSecond: Int
            switch quality {
            case .highQuality: bitsPerSecond = 80_000_000
            case .quality:     bitsPerSecond = 40_000_000
            case .lowBW:       bitsPerSecond = 10_000_000
            default:           bitsPerSecond = 100_000_000
            }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitsPerSecond as CFNumber)
            // Data rate limit: 1.5x average over 1 second
            let limit = [bitsPerSecond * 3 / 2 / 8, 1] as [Int]
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limit as CFArray)
        }

        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[Encoder] Ready: \(width)x\(height) HEVC quality=\(quality.label)")
    }

    func setQualityForNextFrame(_ quality: QualityLevel, deltaPercent: UInt8) {
        currentQuality = quality
        currentDeltaPercent = deltaPercent

        // Recreate session if quality profile changed significantly
        if sessionWidth > 0 && sessionHeight > 0 {
            setup(width: sessionWidth, height: sessionHeight, quality: quality)
        }
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session = session else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let qualityAtEncode = currentQuality
        let deltaAtEncode = currentDeltaPercent

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, flags, encodedBuffer in
            guard status == noErr, let encodedBuffer = encodedBuffer else { return }
            self?.handleEncodedFrame(encodedBuffer, quality: qualityAtEncode, delta: deltaAtEncode)
        }

        if status != noErr {
            print("[Encoder] Encode error: \(status)")
        }
    }

    func forceKeyframe(_ sampleBuffer: CMSampleBuffer) {
        guard let session = session else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let props: [String: Any] = [
            kVTEncodeFrameOptionKey_ForceKeyFrame as String: true
        ]
        let qualityAtEncode = currentQuality
        let deltaAtEncode = currentDeltaPercent

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: props as CFDictionary,
            infoFlagsOut: nil
        ) { [weak self] status, _, encodedBuffer in
            guard status == noErr, let encodedBuffer = encodedBuffer else { return }
            self?.handleEncodedFrame(encodedBuffer, quality: qualityAtEncode, delta: deltaAtEncode)
        }
    }

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer, quality: QualityLevel, delta: UInt8) {
        let isKeyframe = isKeyFrame(sampleBuffer)
        var paramSets: [Data]?

        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            paramSets = extractParameterSets(from: formatDesc)
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let ptr = dataPointer, length > 0 else { return }
        let frameData = Data(bytes: ptr, count: length)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampUs = UInt64(CMTimeGetSeconds(pts) * 1_000_000)

        let seq = sequenceNumber
        sequenceNumber += 1

        let packet = FramePacket(
            sequenceNumber: seq,
            timestamp: timestampUs,
            isKeyframe: isKeyframe,
            qualityLevel: quality,
            deltaPercent: delta,
            parameterSets: paramSets,
            frameData: frameData
        )

        onEncodedPacket?(packet)
    }

    private func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !notSync
    }

    private func extractParameterSets(from formatDesc: CMFormatDescription) -> [Data] {
        var sets = [Data]()
        var paramSetCount: Int = 0
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDesc, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &paramSetCount, nalUnitHeaderLengthOut: nil
        )

        for i in 0..<paramSetCount {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDesc, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            if status == noErr, let ptr = ptr, size > 0 {
                sets.append(Data(bytes: ptr, count: size))
            }
        }
        return sets
    }

    func teardown() {
        if let session = session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        sequenceNumber = 0
        sessionWidth = 0
        sessionHeight = 0
        sessionQuality = nil
    }

    deinit {
        teardown()
    }
}
