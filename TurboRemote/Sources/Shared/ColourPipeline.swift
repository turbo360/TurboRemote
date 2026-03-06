import Foundation
import AppKit
import CoreGraphics

struct ColourSpaceInfo: Sendable {
    enum ID: Int32, Sendable {
        case sRGB = 0
        case displayP3 = 1
        case rec2020 = 2
    }

    let id: ID
    let name: String

    static func detect(from cgColorSpace: CGColorSpace?) -> ColourSpaceInfo {
        guard let cs = cgColorSpace else {
            return ColourSpaceInfo(id: .sRGB, name: "sRGB (default)")
        }

        let name = cs.name as? String ?? "Unknown"

        if name.contains("P3") || name.contains("Display P3") {
            return ColourSpaceInfo(id: .displayP3, name: "Display P3")
        } else if name.contains("2020") || name.contains("Rec. 2020") {
            return ColourSpaceInfo(id: .rec2020, name: "Rec. 2020")
        } else {
            return ColourSpaceInfo(id: .sRGB, name: "sRGB")
        }
    }

    static func fromScreen(_ screen: NSScreen? = nil) -> ColourSpaceInfo {
        let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        return detect(from: screen?.colorSpace?.cgColorSpace)
    }
}

struct ColourParams {
    var sourceCS: Int32 = ColourSpaceInfo.ID.sRGB.rawValue
    var destCS: Int32 = ColourSpaceInfo.ID.sRGB.rawValue
    var edrHeadroom: Float = 1.0
}

final class ColourPipelineManager: @unchecked Sendable {
    private(set) var sourceColourSpace: ColourSpaceInfo = .init(id: .sRGB, name: "sRGB")
    private(set) var clientColourSpace: ColourSpaceInfo = .init(id: .sRGB, name: "sRGB")
    private(set) var edrHeadroom: Float = 1.0

    func updateSourceColourSpace(_ info: ColourSpaceInfo) {
        sourceColourSpace = info
    }

    func updateClientDisplay() {
        clientColourSpace = ColourSpaceInfo.fromScreen()
        updateEDRHeadroom()
    }

    private func updateEDRHeadroom() {
        if let screen = NSScreen.main {
            edrHeadroom = Float(screen.maximumExtendedDynamicRangeColorComponentValue)
            if edrHeadroom < 1.0 { edrHeadroom = 1.0 }
        }
    }

    var needsTransform: Bool {
        sourceColourSpace.id != clientColourSpace.id
    }

    var colourParams: ColourParams {
        ColourParams(
            sourceCS: sourceColourSpace.id.rawValue,
            destCS: clientColourSpace.id.rawValue,
            edrHeadroom: edrHeadroom
        )
    }

    var sourceDescription: String { sourceColourSpace.name }
    var clientDescription: String { clientColourSpace.name }
    var transformDescription: String {
        if needsTransform {
            return "\(sourceColourSpace.name) -> \(clientColourSpace.name)"
        }
        return "\(sourceColourSpace.name) (native)"
    }
}
