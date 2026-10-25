import Foundation
import CoreGraphics

struct DisplayMode: Codable, Hashable, Identifiable {
    let width: Int
    let height: Int
    let fpsMilli: Int
    let codec: String
    init(width: Int, height: Int, fpsMilli: Int, codec: String = "h264") {
        self.width=width; self.height=height; self.fpsMilli=fpsMilli; self.codec=codec
    }
    enum CodingKeys: String, CodingKey { case width, height, fpsMilli, codec }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width=try c.decode(Int.self,forKey:.width); height=try c.decode(Int.self,forKey:.height)
        fpsMilli=try c.decode(Int.self,forKey:.fpsMilli); codec=try c.decodeIfPresent(String.self,forKey:.codec) ?? "h264"
    }
    var id: String { "\(width)x\(height)@\(fpsMilli)-\(codec)" }
    var fps: Double { Double(fpsMilli) / 1000 }
    var title: String { "\(width) × \(height) · \(String(format: "%.2f", fps)) Гц" }
    var valid: Bool { (640...3840).contains(width) && (360...2160).contains(height) && width % 2 == 0 && height % 2 == 0 && (15000...120000).contains(fpsMilli) && ["h264","hevc"].contains(codec) }
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
    case left, above, right
    init(from decoder: Decoder) throws {
        let value=try decoder.singleValueContainer().decode(String.self)
        self=ScreenSide(rawValue:value) ?? .right
    }
    var id: String { rawValue }
    var title: String { switch self { case .left: return "Слева"; case .right: return "Справа"; case .above: return "Сверху" } }
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
    var result: [UUID: CGPoint] = [:]
    var occupied = Set<ScreenSide>()
    for (id, side, mode) in items {
        guard occupied.insert(side).inserted else { continue }
        switch side {
        case .left: result[id] = CGPoint(x: base.minX-Double(mode.width), y: base.minY)
        case .right: result[id] = CGPoint(x: base.maxX, y: base.minY)
        case .above: result[id] = CGPoint(x: base.minX, y: base.minY-Double(mode.height))
        }
    }
    return result
}
