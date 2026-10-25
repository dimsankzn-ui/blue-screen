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
    @StateObject private var library = MonitorLibrary()
    @State private var adding = false
    @State private var name = ""
    @State private var host = ""
    @State private var screenAllowed = CGPreflightScreenCaptureAccess()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 32, height: 32)
                Text("Голубой экран").font(.title2.bold())
                Spacer()
                Button { adding = true } label: { Label("Добавить экран", systemImage: "plus") }
            }.padding(20)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(library.monitors) { monitor in
                            MonitorListRow(monitor: monitor, selected: library.selected == monitor.id)
                                .contentShape(Rectangle()).onTapGesture { library.selected = monitor.id }
                        }
                    }.padding(12)
                }.frame(width: 235)
                Divider()
                if let monitor = library.monitors.first(where: { $0.id == library.selected }) {
                    MonitorEditor(monitor: monitor, library: library, screenAllowed: screenAllowed)
                        .id(monitor.id).frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "tv").font(.system(size: 72)).foregroundStyle(.blue)
                        Text("Добавьте телевизор или монитор").font(.title3)
                        Text("Можно подключить до трёх экранов одновременно.").foregroundStyle(.secondary)
                        Button("Добавить экран") { adding = true }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text("До 3 экранов одновременно · Звук пока остаётся на Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !screenAllowed {
                    Button("Разрешить запись экрана") {
                        _ = CGRequestScreenCaptureAccess()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }.font(.caption)
                }
            }.padding(14)
        }.frame(width: 820, height: 620)
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Добавить экран").font(.title2.bold())
                TextField("Название", text: $name).accessibilityLabel("Название нового экрана")
                TextField("IP-адрес", text: $host).accessibilityLabel("IP нового экрана")
                Text("Откройте «Голубой экран TV» на телевизоре. Его IP указан на экране.").font(.callout).foregroundStyle(.secondary)
                if !library.error.isEmpty { Text(library.error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Button("Отмена") { adding = false; library.error = "" }
                    Spacer()
                    Button("Добавить") {
                        if library.add(name: name, host: host) { adding = false; name = ""; host = "" }
                    }.buttonStyle(.borderedProminent).disabled(host.isEmpty)
                }
            }.textFieldStyle(.roundedBorder).padding(24).frame(width: 390)
        }
        .task {
            while !Task.isCancelled {
                await library.refreshPresence()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in screenAllowed = CGPreflightScreenCaptureAccess() }
        .onDisappear { library.shutdown() }
    }
}

struct MonitorListRow: View {
    @ObservedObject var monitor: MonitorSession
    let selected: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: monitor.tv.connected ? "tv.fill" : "tv")
                .font(.title2).foregroundStyle(monitor.online == true ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(monitor.profile.name.isEmpty ? "Экран" : monitor.profile.name).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(monitor.online == true ? Color.green : Color.gray).frame(width: 6, height: 6)
                    Text(monitor.online == nil ? "Проверяю…" : (monitor.online == true ? "В сети" : "Оффлайн"))
                }.font(.caption).foregroundStyle(.secondary)
                if monitor.tv.connected { Text("Подключён").font(.caption).foregroundStyle(.blue) }
            }
            Spacer(minLength: 0)
        }.padding(12).background(selected ? Color.blue.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct MonitorEditor: View {
    @ObservedObject var monitor: MonitorSession
    @ObservedObject var library: MonitorLibrary
    let screenAllowed: Bool
    @State private var code = ""
    private var pairing: Bool { !monitor.tv.fingerprint.isEmpty && !monitor.tv.connected && !monitor.tv.busy && !monitor.working }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: monitor.tv.connected ? "tv.fill" : "tv").font(.system(size: 42)).foregroundStyle(.blue)
                    Text(monitor.profile.name.isEmpty ? "Экран" : monitor.profile.name).font(.title2.bold())
                    Spacer()
                    Menu {
                        Button("Забыть подключение") {
                            do { try monitor.tv.forget(monitor.profile.host); monitor.message = "При следующем подключении введите код с TV." }
                            catch { monitor.message = error.localizedDescription }
                        }
                        Button("Удалить из списка", role: .destructive) { library.remove(monitor) }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().disabled(monitor.locked)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Название").font(.caption).foregroundStyle(.secondary)
                    TextField("Название экрана", text: $monitor.profile.name).accessibilityLabel("Название экрана")
                    Text("IP-адрес").font(.caption).foregroundStyle(.secondary)
                    TextField("IP-адрес", text: $monitor.profile.host).accessibilityLabel("IP-адрес экрана")
                }.textFieldStyle(.roundedBorder).disabled(monitor.locked)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Разрешение и частота").font(.headline)
                    Picker("Режим", selection: $monitor.profile.mode) {
                        Text("Автоматически · максимум экрана").tag(DisplayMode?.none)
                        ForEach(DisplayMode.sorted(monitor.profile.knownModes + (monitor.profile.mode.map { [$0] } ?? []))) { mode in
                            Text(mode.title).tag(Optional(mode))
                        }
                    }.labelsHidden().disabled(monitor.locked)
                    if let mode = monitor.profile.knownModes.first {
                        Text("Максимум: \(mode.title)").font(.caption).foregroundStyle(.secondary)
                    } else { Text("Режимы появятся, когда приёмник будет в сети.").font(.caption).foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Расположение относительно MacBook").font(.headline)
                    Picker("Расположение", selection: $monitor.profile.side) {
                        ForEach(ScreenSide.allCases) { side in Text(side.title).tag(side) }
                    }.pickerStyle(.segmented).disabled(monitor.working)
                    Text("На одной стороне экраны выстраиваются друг за другом.").font(.caption).foregroundStyle(.secondary)
                }
                if pairing {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Первое подключение").font(.headline)
                        Text("Номер на TV: \(monitor.tv.fingerprint)").font(.callout)
                        TextField("6 цифр с телевизора", text: $code).textFieldStyle(.roundedBorder).accessibilityLabel("Код с телевизора")
                        Text("В следующий раз код не понадобится.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    if monitor.tv.connected { monitor.disconnect() }
                    else if library.monitors.contains(where: { $0.id != monitor.id && $0.profile.host == monitor.profile.host }) { monitor.message = "Этот IP уже указан у другого экрана." }
                    else { monitor.connect(in: library, code: pairing ? code : nil) }
                } label: {
                    HStack {
                        if monitor.working || monitor.tv.busy { ProgressView().controlSize(.small) }
                        Text(monitor.tv.connected ? "Отключиться" : (pairing ? "Подтвердить и подключиться" : "Подключиться")).frame(maxWidth: .infinity)
                    }.padding(.vertical, 5)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(monitor.working || monitor.tv.busy || (!monitor.tv.connected && (!screenAllowed || monitor.profile.host.isEmpty)) || (pairing && code.count != 6))
                if pairing { Button("Отмена") { monitor.disconnect(); code = "" } }
                if !monitor.message.isEmpty { Text(monitor.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                if !screenAllowed { Text("Для подключения разрешите запись экрана в macOS.").font(.caption).foregroundStyle(.secondary) }
            }.padding(24)
        }
        .onChange(of: monitor.profile.name) { _, _ in library.save() }
        .onChange(of: monitor.profile.host) { _, _ in monitor.online = nil; library.save() }
        .onChange(of: monitor.profile.mode) { _, _ in library.save() }
        .onChange(of: monitor.profile.side) { _, _ in library.save(); library.relayout() }
        .onChange(of: monitor.tv.connected) { _, connected in if connected { code = "" } }
    }
}
