import SwiftUI
import Combine

@main struct BlueScreenApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    init() {
        if CommandLine.arguments.contains("--diagnose") {
            let snapshot = inspectMac()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                FileHandle.standardOutput.write(try encoder.encode(snapshot))
                FileHandle.standardOutput.write(Data("\n".utf8))
                exit(0)
            } catch { fputs("\(error)\n", stderr); exit(1) }
        }
    }
    var body: some Scene {
        Window("Голубой экран", id: "main") { Dashboard() }
            .windowResizability(.contentSize)
    }
}

final class AppLifecycle: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct Dashboard: View {
    @StateObject private var secondScreen = SecondScreen()
    @StateObject private var preview = ScreenPreview()
    @StateObject private var tv = TVConnection()
    @AppStorage("device.name") private var name = "Мой телевизор"
    @AppStorage("device.host") private var host = ""
    @State private var code = ""
    @State private var working = false
    @State private var message = ""
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    private var pairing: Bool { !tv.fingerprint.isEmpty && !tv.connected && !tv.busy && !working }

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
                Text("Голубой экран").font(.title2.bold())
                Spacer()
                Menu {
                    Button("Забыть подключение") {
                        do { try tv.forget(host); message = "При следующем подключении введите код с телевизора." }
                        catch { message = error.localizedDescription }
                    }.disabled(tv.connected || working || tv.busy)
                } label: { Image(systemName: "ellipsis.circle").font(.title2) }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Настройки телевизора")
            }
            Image(systemName: tv.connected ? "tv.fill" : "tv")
                .font(.system(size: 86, weight: .light))
                .foregroundStyle(tv.connected ? Color.cyan : Color.blue)
                .accessibilityLabel("Телевизор")
            VStack(alignment: .leading, spacing: 12) {
                TextField("Название телевизора", text: $name).accessibilityLabel("Название телевизора")
                TextField("IP-адрес, например 192.168.1.100", text: $host).accessibilityLabel("IP-адрес телевизора")
            }.textFieldStyle(.roundedBorder).disabled(tv.connected || working || tv.busy || pairing)
            if pairing {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Первое подключение").font(.headline)
                    Text("Сверьте номер на TV: \(tv.fingerprint)").font(.callout)
                    TextField("6 цифр с экрана телевизора", text: $code)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Код с телевизора")
                        .onChange(of: code) { _, value in code = String(value.filter(\.isNumber).prefix(6)) }
                    Text("Устройства запомнят друг друга. В следующий раз код не понадобится.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16).background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            if !screenAllowed {
                VStack(spacing: 8) {
                    Text("Для второго экрана разрешите захват изображения в macOS.")
                        .font(.callout).multilineTextAlignment(.center)
                    Button("Разрешить запись экрана") {
                        _ = CGRequestScreenCaptureAccess()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            }
            Button(action: mainAction) {
                HStack {
                    if working || tv.busy { ProgressView().controlSize(.small) }
                    Text(tv.connected ? "Отключиться" : (pairing ? "Подтвердить и подключиться" : "Подключиться"))
                        .frame(maxWidth: .infinity)
                }.padding(.vertical, 7)
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(working || tv.busy || (!tv.connected && (host.isEmpty || !screenAllowed)) || (pairing && code.count != 6))
            if pairing {
                Button("Отмена") { tv.disconnect(); code = "" }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text(message.isEmpty ? (tv.connected ? "Подключено · Full HD" : "Откройте «Голубой экран TV» на телевизоре.") : message)
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            Text("Звук пока остаётся на Mac").font(.caption).foregroundStyle(.tertiary)
        }.padding(28).frame(width: 440)
        .onChange(of: tv.status) { _, status in
            if !working && !tv.connected { message = status }
        }
        .onChange(of: tv.connected) { wasConnected, isConnected in
            if wasConnected && !isConnected {
                preview.onVideoFrame = nil
                Task { await preview.stop(); await secondScreen.stop() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenAllowed = CGPreflightScreenCaptureAccess()
        }
        .onDisappear {
            tv.disconnect()
            preview.onVideoFrame = nil
            Task { await preview.stop(); await secondScreen.stop() }
        }
    }

    private func mainAction() {
        if tv.connected {
            working = true
            tv.disconnect()
            preview.onVideoFrame = nil
            Task { await preview.stop(); await secondScreen.stop(); working = false; message = "Отключено" }
            return
        }
        let confirming = pairing
        working = true
        message = "Подключаюсь…"
        Task {
            defer { working = false }
            let authenticated: Bool
            if confirming {
                authenticated = await tv.connect(pin: code)
            } else if let restored = await tv.reconnect(host) {
                authenticated = restored
            } else {
                tv.probe(host)
                message = "Проверяю телевизор…"
                return
            }
            guard authenticated else { message = tv.status; return }
            code = ""
            await secondScreen.start()
            guard tv.connected, let id = secondScreen.displayID else {
                message = secondScreen.status
                tv.disconnect()
                await secondScreen.stop()
                return
            }
            preview.onVideoFrame = tv.frameHandler()
            await preview.start(displayID: id)
            preview.sendLatestVideoFrame()
            guard preview.running else {
                let error = preview.status
                tv.disconnect()
                preview.onVideoFrame = nil
                await secondScreen.stop()
                message = error
                return
            }
            message = "Подключено · Full HD. Перенесите окно вправо на телевизор."
        }
    }
}
