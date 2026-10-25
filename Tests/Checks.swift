import AppKit

@main struct Checks {
    static func main() async throws {
        let left = DisplayInfo(id: 1, name: "Mac", builtIn: true, mirrored: false,
            bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let right = DisplayInfo(id: 2, name: "TV", builtIn: false, mirrored: false,
            bounds: CGRect(x: 1000, y: 0, width: 1920, height: 1080))
        assert(displayForWindow(CGRect(x: 100, y: 50, width: 800, height: 600), displays: [left, right]) == 1)
        assert(displayForWindow(CGRect(x: 900, y: 50, width: 800, height: 600), displays: [left, right]) == 2)
        assert(displayForWindow(CGRect(x: -900, y: 50, width: 800, height: 600), displays: [left, right]) == nil)
        assert(displayForWindow(CGRect(x: 0, y: 0, width: 0, height: 0), displays: [left]) == nil)
        let above = DisplayInfo(id: 3, name: "Above", builtIn: false, mirrored: false,
            bounds: CGRect(x: 0, y: -800, width: 1000, height: 800))
        assert(displayForWindow(CGRect(x: 50, y: -700, width: 800, height: 600), displays: [left, above]) == 3)
        let windows = [WindowInfo(id: 1, pid: 10, application: "Browser", displayID: 1),
            WindowInfo(id: 2, pid: 10, application: "Browser", displayID: 2),
            WindowInfo(id: 3, pid: 11, application: "Other", displayID: 1)]
        assert(applicationsAcrossDisplays(windows) == ["Browser"])
        assert(applicationsAcrossDisplays([windows[0], windows[0]]).isEmpty)
        for invalid in ["example.com", "127.0.0.1", "8.8.8.8", "192.168.1.999", "192.168.1.100/path", "192.168..1"] {
            do { _ = try await inspectReceiver(host: invalid); fatalError("Accepted invalid host: \(invalid)") }
            catch { /* Expected: validation fails before networking. */ }
        }
        let live = inspectMac()
        assert(!live.displays.isEmpty, "Mac must have an active display for this integration check")
        print("PASS: display geometry, split-window detection, address validation; live Mac: \(live.displays.count) displays, \(live.windows.count) windows, \(live.audioProcesses.count) audio processes")
        if let host = ProcessInfo.processInfo.environment["BLUESCREEN_TEST_HOST"] {
            let receiver = try await inspectReceiver(host: host)
            print("PASS: real receiver responds: \(receiver.name ?? "unnamed") / \(receiver.device_info?.model_name ?? "unknown")")
        }
    }
}
