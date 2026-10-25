import AppKit
import Combine

@MainActor final class MonitorSession: ObservableObject, Identifiable {
    @Published var profile: MonitorProfile
    @Published var online: Bool?
    @Published var working = false
    @Published var message = ""
    let tv = TVConnection()
    let screen = SecondScreen()
    let capture = ScreenPreview()
    nonisolated let id: UUID
    var locked: Bool { working || tv.busy || tv.connected || !tv.fingerprint.isEmpty }
    private var subscriptions = Set<AnyCancellable>()
    private var task: Task<Void, Never>?
    var changed: (() -> Void)?
    init(_ profile: MonitorProfile) {
        self.profile = profile
        self.id = profile.id
        tv.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        tv.$status.sink { [weak self] status in
            guard let self, !self.working, !self.tv.connected else { return }
            self.message = status
        }.store(in: &subscriptions)
        tv.$connected.removeDuplicates().dropFirst().sink { [weak self] connected in
            guard let self, !connected, !self.working else { return }
            self.working = true
            self.capture.onVideoFrame = nil
            Task {
                await self.capture.stop(); await self.screen.stop()
                self.message = self.tv.status
                self.working = false
            }
        }.store(in: &subscriptions)
        capture.$running.removeDuplicates().dropFirst().sink { [weak self] running in
            guard let self, !running, !self.working, self.tv.connected else { return }
            self.message = self.capture.status
            self.tv.disconnect()
        }.store(in: &subscriptions)
    }
    func connect(in library: MonitorLibrary, code: String? = nil) {
        guard !working, !tv.busy, !tv.connected else { return }
        do {
            let address = try validatedLocalAddress(profile.host.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !library.monitors.contains(where: { $0.id != id && (try? validatedLocalAddress($0.profile.host)) == address }) else { message = "Этот IP уже указан у другого экрана."; return }
            profile.host = address
            changed?()
        } catch { message = error.localizedDescription; return }
        guard library.canConnect(self) else { message = "Одновременно можно подключить до трёх экранов."; return }
        working = true
        message = "Подключаюсь…"
        task = Task {
            defer { working = false }
            tv.requestedMode = profile.mode
            let authenticated: Bool
            if let code { authenticated = await tv.connect(pin: code) }
            else if let restored = await tv.reconnect(profile.host) { authenticated = restored }
            else {
                guard !Task.isCancelled else { return }
                tv.probe(profile.host)
                message = "Проверяю экран…"
                return
            }
            guard authenticated, !Task.isCancelled else { message = tv.status; return }
            profile.knownModes = tv.capabilities?.available ?? []
            changed?()
            let mode = tv.selectedMode
            await screen.start(mode: mode, serial: profile.serial, name: profile.name, origin: library.origin(for: self))
            guard tv.connected, !Task.isCancelled, let id = screen.displayID else {
                message = screen.status; tv.disconnect(); await screen.stop(); return
            }
            library.relayout()
            capture.onVideoFrame = tv.frameHandler()
            await capture.start(displayID: id, mode: mode)
            capture.sendLatestVideoFrame()
            guard capture.running, !Task.isCancelled else {
                let error = capture.status; tv.disconnect(); capture.onVideoFrame = nil
                await capture.stop(); await screen.stop(); message = error; return
            }
            online = true
            message = "Подключено · \(mode.title)"
        }
    }
    func disconnect() {
        working = true
        task?.cancel()
        tv.disconnect()
        capture.onVideoFrame = nil
        task = Task { await capture.stop(); await screen.stop(); working = false; message = "Отключено" }
    }
}

@MainActor final class MonitorLibrary: ObservableObject {
    @Published var monitors: [MonitorSession] = []
    @Published var selected: UUID?
    @Published var error = ""
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        var profiles: [MonitorProfile] = []
        if let data = preferences.data(forKey: "monitors.v1"), let saved = try? JSONDecoder().decode([MonitorProfile].self, from: data) { profiles = saved }
        else if let host = preferences.string(forKey: "device.host"), !host.isEmpty {
            profiles = [MonitorProfile(name: preferences.string(forKey: "device.name") ?? "Телевизор", host: host)]
        }
        for profile in profiles { append(profile) }
        selected = monitors.first?.id
        save()
    }
    private func append(_ profile: MonitorProfile) {
        let session = MonitorSession(profile)
        session.changed = { [weak self] in self?.save() }
        monitors.append(session)
    }
    func save() { if let data = try? JSONEncoder().encode(monitors.map(\.profile)) { preferences.set(data, forKey: "monitors.v1") } }
    func add(name: String, host: String) -> Bool {
        do {
            let address = try validatedLocalAddress(host.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !monitors.contains(where: { $0.profile.host == address }) else { error = "Этот IP уже есть в списке."; return false }
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let profile = MonitorProfile(name: label.isEmpty ? "Телевизор" : String(label.prefix(80)), host: address)
            append(profile); selected = profile.id; save(); error = ""; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func remove(_ session: MonitorSession) {
        guard !session.locked else { return }
        monitors.removeAll { $0.id == session.id }
        if selected == session.id { selected = monitors.first?.id }
        save()
    }
    func canConnect(_ session: MonitorSession) -> Bool {
        monitors.filter { $0.id != session.id && ($0.working || $0.tv.busy || $0.tv.connected) }.count < 3
    }
    private func origins() -> [UUID: CGPoint] {
        let baseID = NSScreen.screens.compactMap(SecondScreen.id).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
        let items = monitors.filter { $0.tv.connected || $0.screen.displayID != nil }.map { ($0.id, $0.profile.side, $0.tv.selectedMode) }
        return screenOrigins(base: CGDisplayBounds(baseID), items: items)
    }
    func origin(for session: MonitorSession) -> CGPoint { origins()[session.id] ?? CGPoint(x: CGDisplayBounds(CGMainDisplayID()).maxX, y: 0) }
    func relayout() {
        let locations = origins()
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        for item in monitors {
            if let id = item.screen.displayID, let point = locations[item.id],
                CGConfigureDisplayOrigin(config, id, Int32(point.x), Int32(point.y)) != .success {
                CGCancelDisplayConfiguration(config); return
            }
        }
        _ = CGCompleteDisplayConfiguration(config, .forSession)
    }
    func refreshPresence() async {
        let targets = monitors.map { ($0.id, $0.profile.host) }
        await withTaskGroup(of: (UUID, DisplayCapabilities?).self) { group in
            for (id, host) in targets { group.addTask { (id, await PresenceProbe.read(host)) } }
            for await (id, caps) in group {
                guard let monitor = monitors.first(where: { $0.id == id }), let target = targets.first(where: { $0.0 == id }), monitor.profile.host == target.1 else { continue }
                monitor.online = monitor.tv.connected || caps != nil
                if let caps, caps.available != monitor.profile.knownModes {
                    monitor.profile.knownModes = caps.available
                    save()
                }
            }
        }
    }
    func shutdown() { for monitor in monitors { monitor.disconnect() } }
}
