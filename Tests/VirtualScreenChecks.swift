import AppKit

@main struct VirtualScreenChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        setbuf(stdout, nil)
        Task { @MainActor in
            do { try await check(); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func check() async throws {
        let before = inspectMac().displays.map(\.id)
        let screen = SecondScreen()
        await screen.start()
        guard let id = screen.displayID else { fatalError(screen.status) }
        guard CGDisplayIsOnline(id) != 0, CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { fatalError("No independent desktop") }
        let bounds = CGDisplayBounds(id)
        assert(bounds.width == 1920 && bounds.height == 1080)
        assert(inspectMac().displays.count == before.count + 1)
        screen.showTestWindow()
        try await Task.sleep(nanoseconds: 600_000_000)
        let ownWindows = inspectMac().windows.filter { $0.pid == ProcessInfo.processInfo.processIdentifier }
        guard ownWindows.contains(where: { $0.displayID == id }) else {
            await screen.stop()
            throw NSError(domain: "Checks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test window not detected on virtual screen; own windows: \(ownWindows)"])
        }
        print("PASS: independent desktop \(id), bounds \(bounds), real test window assigned to it")
        await screen.stop()
        for _ in 0..<40 {
            if !SecondScreen.isAttached(id) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !SecondScreen.isAttached(id) else {
            throw NSError(domain: "Checks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Virtual display \(id) was not removed; current screens: \(inspectMac().displays)"])
        }
        assert(Set(inspectMac().displays.map(\.id)) == Set(before), "Original display set was not restored")
        print("PASS: stopped virtual screen; original display set restored")
    }
}
