import Foundation

enum VideoBitrate {
    // Network-friendly targets. A 2.4 GHz link should not require sustained
    // 70+ Mbps for a desktop stream, especially with PCM audio sharing TLS.
    static func target(for mode: DisplayMode) -> Int {
        let pixels = Double(mode.width) * Double(mode.height)
        let scale = pixels / (1920.0 * 1080.0) * (mode.fps / 60.0)
        let codecEfficiency = mode.codec == "hevc" ? 0.65 : 1.0
        return min(24_000_000, max(2_000_000, Int(10_000_000 * scale * codecEfficiency)))
    }
}
