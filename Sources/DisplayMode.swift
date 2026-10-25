import Foundation
import CoreGraphics

struct DisplayMode: Codable, Hashable, Identifiable {
    let width: Int
    let height: Int
    let fpsMilli: Int
    var id: String { "\(width)x\(height)@\(fpsMilli)" }
    var fps: Double { Double(fpsMilli) / 1000 }
    var title: String { "\(width) × \(height) · \(String(format: "%.2f", fps)) Гц" }
    var valid: Bool { (640...3840).contains(width) && (360...2160).contains(height) && width % 2 == 0 && height % 2 == 0 && (15000...120000).contains(fpsMilli) }
    static let fullHD = DisplayMode(width: 1920, height: 1080, fpsMilli: 60000)
    static func sorted(_ modes: [DisplayMode]) -> [DisplayMode] {
        Array(Set(modes.filter(\.valid))).sorted {
            if $0.width * $0.height != $1.width * $1.height { return $0.width * $0.height > $1.width * $1.height }
            return $0.fpsMilli > $1.fpsMilli
        }
    }
}
struct DisplayCapabilities: Codable {
    let protocolVersion: Int
    let modes: [DisplayMode]
    var available: [DisplayMode] { DisplayMode.sorted(modes) }
}
enum ScreenSide: String, Codable, CaseIterable, Identifiable {
    case left, right, above, below
    var id: String { rawValue }
    var title: String { switch self { case .left: return "Слева"; case .right: return "Справа"; case .above: return "Сверху"; case .below: return "Снизу" } }
}
struct MonitorProfile: Codable, Identifiable {
    var id = UUID()
    var name: String
    var host: String
    var side: ScreenSide = .right
    var mode: DisplayMode?
    var knownModes: [DisplayMode] = []
    var serial: UInt32 {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        return bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } | 1
    }
}
// Positions use CoreGraphics desktop coordinates: positive Y is below the Mac.
func screenOrigins(base: CGRect, items: [(UUID, ScreenSide, DisplayMode)]) -> [UUID: CGPoint] {
    var left = base.minX, right = base.maxX, above = base.minY, below = base.maxY
    var result: [UUID: CGPoint] = [:]
    for (id, side, mode) in items {
        switch side {
        case .left: left -= Double(mode.width); result[id] = CGPoint(x: left, y: base.minY)
        case .right: result[id] = CGPoint(x: right, y: base.minY); right += Double(mode.width)
        case .above: above -= Double(mode.height); result[id] = CGPoint(x: base.minX, y: above)
        case .below: result[id] = CGPoint(x: base.minX, y: below); below += Double(mode.height)
        }
    }
    return result
}
