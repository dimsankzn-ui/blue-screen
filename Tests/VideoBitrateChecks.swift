import Foundation

@main enum VideoBitrateChecks {
    static func main() {
        assert(VideoBitrate.target(for: .fullHD) == 10_000_000)
        assert(VideoBitrate.target(for: DisplayMode(width:1280,height:720,fpsMilli:60000)) < 5_000_000)
        let fourK=VideoBitrate.target(for:DisplayMode(width:3840,height:2160,fpsMilli:60000,codec:"hevc"))
        assert(fourK == 24_000_000)
        assert(VideoBitrate.target(for:DisplayMode(width:1920,height:1080,fpsMilli:30000)) == 5_000_000)
        print("PASS: Full HD 10 Mbps, 720p/4K and frame-rate scaling")
    }
}
