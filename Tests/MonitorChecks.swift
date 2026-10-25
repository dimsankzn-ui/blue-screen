import AppKit

@main struct MonitorChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        setbuf(stdout,nil)
        Task { @MainActor in
            do { try await checks(); print("PASS: monitor profiles, max-mode selection, geometry, three independent displays, cleanup"); exit(0) }
            catch { fputs("FAIL: \(error)\n",stderr); exit(1) }
        }
        NSApp.run()
    }
    @MainActor static func checks() async throws {
        let hd = DisplayMode(width:1280,height:720,fpsMilli:60000)
        let full = DisplayMode(width:1920,height:1080,fpsMilli:59940)
        let uhd = DisplayMode(width:3840,height:2160,fpsMilli:30000)
        assert(DisplayMode.sorted([hd,full,uhd,full]).first == uhd)
        assert(!DisplayMode(width:99999,height:1080,fpsMilli:60000).valid)
        let p = MonitorProfile(name:"Test",host:"10.0.0.1",side:.left,mode:full)
        let restored = try JSONDecoder().decode(MonitorProfile.self,from:JSONEncoder().encode(p))
        assert(restored.id == p.id && restored.serial == p.serial && restored.mode == full)
        let base = CGRect(x:0,y:0,width:1512,height:982)
        let ids = (0..<4).map { _ in UUID() }
        let origins = screenOrigins(base:base,items:[(ids[0],.left,hd),(ids[1],.right,full),(ids[2],.above,full),(ids[3],.below,hd)])
        assert(origins[ids[0]] == CGPoint(x:-1280,y:0))
        assert(origins[ids[1]] == CGPoint(x:1512,y:0))
        assert(origins[ids[2]] == CGPoint(x:0,y:-1080))
        assert(origins[ids[3]] == CGPoint(x:0,y:982))
        let chain = screenOrigins(base:base,items:ids.prefix(3).map { ($0,.right,hd) })
        assert(chain[ids[2]] == CGPoint(x:4072,y:0))
        let suite = "local.bluescreen.tests.\(UUID())"
        let preferences = UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        let library = MonitorLibrary(preferences:preferences)
        for n in 1...4 { assert(library.add(name:"Screen \(n)",host:"10.0.0.\(n)")) }
        assert(!library.add(name:"Duplicate",host:"10.0.0.1"))
        for item in library.monitors.prefix(3) { item.working = true }
        assert(!library.canConnect(library.monitors[3]))
        for item in library.monitors { item.working = false }
        assert(MonitorLibrary(preferences:preferences).monitors.count == 4)
        let before = Set(inspectMac().displays.map(\.id))
        let screens = (0..<3).map { _ in SecondScreen() }
        let modes = [hd,full,hd]
        do {
            for n in 0..<3 {
                let points = [CGPoint(x:1512,y:0),CGPoint(x:2792,y:0),CGPoint(x:0,y:-720)]
                let point = points[n]
                await screens[n].start(mode:modes[n],serial:UInt32(8001+n),name:"Test \(n+1)",origin:point)
                guard let id = screens[n].displayID else { throw failure(screens[n].status) }
                guard CGDisplayBounds(id).origin == point else { throw failure("Screen \(n): origin \(CGDisplayBounds(id).origin), expected \(point)") }
                assert(CGDisplayBounds(id).width == Double(modes[n].width))
                assert(abs((CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0) - modes[n].fps) < 0.2)
            }
            let live = screens.compactMap(\.displayID)
            assert(Set(live).count == 3)
            assert(inspectMac().displays.count == before.count + 3)
            screens[0].move(to:CGPoint(x:-1280,y:0))
            assert(CGDisplayBounds(live[0]).minX == -1280)
        } catch {
            for screen in screens { await screen.stop() }
            throw error
        }
        for screen in screens { await screen.stop() }
        assert(Set(inspectMac().displays.map(\.id)) == before)
    }
    static func failure(_ text:String) -> NSError { NSError(domain:"Tests",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
}
