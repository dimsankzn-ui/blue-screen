import AppKit
import Combine

@MainActor final class SecondScreen: ObservableObject {
    @Published private(set) var displayID: UInt32?
    @Published private(set) var busy = false
    @Published private(set) var status = "Второй экран выключен"
    private var helper: Process?
    private var lifetime: Pipe?
    private var helperID: UInt32?
    private var testWindow: NSWindow?

    func start(mode: DisplayMode = .fullHD, serial: UInt32 = 1, name: String = "BlueScreen TV", origin requestedOrigin: CGPoint? = nil) async {
        guard !busy, displayID == nil else { return }
        busy = true
        defer { busy = false }
        do {
            // Hot-plugging a virtual display can make macOS restore cached positions of existing displays.
            // Preserve their positions in the same transaction that places the new screen.
            let previousOrigins=Dictionary(uniqueKeysWithValues:NSScreen.screens.compactMap(Self.id).map { ($0,CGDisplayBounds($0).origin) })
            let process = Process()
            process.executableURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("VirtualDisplayHelper")
            guard mode.valid else { throw failure("Неподдерживаемый режим экрана.") }
            process.arguments = [String(mode.width), String(mode.height), String(mode.fps), String(serial), name]
            let output = Pipe()
            let input = Pipe()
            process.standardOutput = output
            process.standardInput = input
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8),
                    let id = UInt32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                Task { @MainActor in self?.helperID = id }
            }
            process.terminationHandler = { [weak self] ended in
                Task { @MainActor in
                    guard let self, self.helper === ended else { return }
                    self.helper = nil
                    self.displayID = nil
                    if !self.busy { self.status = "Второй экран отключён: процесс экрана завершился." }
                }
            }
            helperID = nil
            helper = process
            lifetime = input
            try process.run()
            input.fileHandleForReading.closeFile()
            for _ in 0..<40 {
                if helperID != nil || !process.isRunning { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            output.fileHandleForReading.readabilityHandler = nil
            guard let id = helperID, process.isRunning else { throw failure("Не удалось запустить процесс виртуального экрана.") }
            for _ in 0..<40 {
                if CGDisplayIsOnline(id) != 0 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard CGDisplayIsOnline(id) != 0 else { throw failure("Второй экран не появился в macOS.") }
            var ids = [CGDirectDisplayID](repeating: 0, count: 32)
            var count: UInt32 = 0
            guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { throw failure("Не удалось прочитать конфигурацию экранов.") }
            let rightEdge = ids.prefix(Int(count)).filter { $0 != id }.map { CGDisplayBounds($0).maxX }.max() ?? 0
            let target = requestedOrigin ?? CGPoint(x: rightEdge, y: 0)
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else {
                throw failure("Не удалось начать настройку второго экрана.")
            }
            for (existing,point) in previousOrigins where CGDisplayIsOnline(existing) != 0 && CGDisplayBounds(existing).origin != point {
                _ = CGConfigureDisplayOrigin(config,existing,Int32(point.x),Int32(point.y))
            }
            let mirror = CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
            let origin = CGConfigureDisplayOrigin(config, id, Int32(target.x), Int32(target.y))
            let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? []
            guard let fullHD = modes.filter({ $0.width == mode.width && $0.height == mode.height })
                .min(by: { abs($0.refreshRate - mode.fps) < abs($1.refreshRate - mode.fps) }),
                abs(fullHD.refreshRate - mode.fps) < 0.5 else {
                CGCancelDisplayConfiguration(config)
                throw failure("macOS не предоставила режим Full HD для второго экрана.")
            }
            let resolution = CGConfigureDisplayWithDisplayMode(config, id, fullHD, nil)
            guard mirror == .success, origin == .success, resolution == .success else {
                CGCancelDisplayConfiguration(config)
                throw failure("Не удалось расположить второй экран справа от Mac.")
            }
            guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
                throw failure("macOS не применила расширение рабочего стола.")
            }
            for _ in 0..<40 {
                if NSScreen.screens.contains(where: { Self.id($0) == id && CGDisplayBounds(id).origin == target && CGDisplayBounds(id).width == Double(mode.width) && CGDisplayBounds(id).height == Double(mode.height) }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay,
                CGDisplayBounds(id).origin == target,
                NSScreen.screens.contains(where: { Self.id($0) == id && CGDisplayBounds(id).width == Double(mode.width) && CGDisplayBounds(id).height == Double(mode.height) }) else {
                if ProcessInfo.processInfo.environment["BLUESCREEN_TEST_LOG"] == "1" {
                    fputs("Requested \(target) / \(mode.title), actual \(CGDisplayBounds(id)), mirror \(CGDisplayMirrorsDisplay(id))\n",stderr)
                }
                throw failure("Не удалось подтвердить независимый второй рабочий стол.")
            }
            displayID = id
            status = "Экран создан: \(mode.title)."
        } catch {
            lifetime?.fileHandleForWriting.closeFile()
            lifetime = nil
            if helper?.isRunning == true { helper?.terminate() }
            helper = nil
            status = error.localizedDescription
        }
    }

    func move(to origin: CGPoint) {
        guard let id = displayID else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        if CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y)) == .success {
            _ = CGCompleteDisplayConfiguration(config, .forSession)
        } else { CGCancelDisplayConfiguration(config) }
    }

    func stop() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let id = displayID
        testWindow?.close()
        testWindow = nil
        lifetime?.fileHandleForWriting.closeFile()
        lifetime = nil
        for step in 0..<40 {
            if id == nil || !Self.isAttached(id!) { break }
            if step == 10, helper?.isRunning == true { helper?.terminate() }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        helper = nil
        guard id == nil || !Self.isAttached(id!) else {
            status = "Отключение второго экрана не подтверждено macOS."
            return
        }
        displayID = nil
        status = "Второй экран выключен. Окна возвращаются на доступные экраны macOS."
    }

    deinit {
        lifetime?.fileHandleForWriting.closeFile()
        if helper?.isRunning == true { helper?.terminate() }
    }

    func showTestWindow() {
        guard let id = displayID, let screen = NSScreen.screens.first(where: { Self.id($0) == id }) else { return }
        if let window = testWindow { window.orderFront(nil); return }
        let rect = screen.visibleFrame.insetBy(dx: 80, dy: 80)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false, screen: screen)
        window.title = "BlueScreen • проверка второго рабочего стола"
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(calibratedRed: 0.03, green: 0.09, blue: 0.18, alpha: 1)
        let label = NSTextField(wrappingLabelWithString: "ВТОРОЙ РАБОЧИЙ СТОЛ\n\nBlueScreen TV • 1920 × 1080\n\nЭто отдельное окно Mac. Его можно перетащить обратно на экран ноутбука.\n\nПроверка изображения. Звук пока не передаётся.")
        label.textColor = .white
        label.font = .systemFont(ofSize: 28, weight: .medium)
        label.alignment = .center
        label.frame = window.contentView!.bounds.insetBy(dx: 50, dy: 50)
        label.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(label)
        window.contentView?.wantsLayer = true
        let stripe = CALayer()
        stripe.backgroundColor = NSColor.systemCyan.cgColor
        stripe.bounds = CGRect(x: 0, y: 0, width: 160, height: 24)
        stripe.position = CGPoint(x: 120, y: 35)
        window.contentView?.layer?.addSublayer(stripe)
        let movement = CABasicAnimation(keyPath: "position.x")
        movement.fromValue = 120
        movement.toValue = rect.width - 120
        movement.duration = 1
        movement.autoreverses = false
        movement.timingFunction = CAMediaTimingFunction(name: .linear)
        movement.repeatCount = .infinity
        stripe.add(movement, forKey: "smoothness-check")
        testWindow = window
        window.orderFront(nil)
        window.setFrame(rect, display: true)
    }

    static func id(_ screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func isAttached(_ id: UInt32) -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return true }
        return ids.prefix(Int(count)).contains(id)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "BlueScreen.SecondScreen", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
