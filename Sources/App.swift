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
        Window("Голубой экран", id: "main") { Dashboard().frame(minWidth: 760, minHeight: 600) }
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
    @State private var snapshot: Snapshot?
    @State private var host = ""
    @State private var receiver = "Связь ещё не проверена"
    @State private var checking = false
    @State private var pairingCode = ""
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable()
                        .frame(width: 64, height: 64).accessibilityLabel("Иконка Голубого экрана")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Голубой экран").font(.largeTitle.bold())
                        Text("Второй рабочий стол • экспериментальная версия").foregroundStyle(.secondary)
                    }
                }
                Text("Передача изображения на Android TV • экспериментальная версия. Раздельный звук пока не реализован.")
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                GroupBox("Второй рабочий стол Mac") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(secondScreen.status)
                        HStack {
                            if secondScreen.displayID == nil {
                                Button(secondScreen.busy ? "Создаю…" : "Создать второй экран") {
                                    Task { await secondScreen.start(); snapshot = inspectMac() }
                                }.disabled(secondScreen.busy)
                            } else {
                                Button("Показать тестовое окно") { secondScreen.showTestWindow() }
                                Button("Выключить второй экран") {
                                    Task { tv.disconnect(); preview.onVideoFrame = nil; await preview.stop(); await secondScreen.stop(); snapshot = inspectMac() }
                                }.disabled(secondScreen.busy || preview.busy)
                            }
                        }
                        Text("Экран создаётся справа от Mac на время работы приложения. Используется экспериментальный механизм macOS; совместимость с другими версиями ещё не проверена.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                }
                if let id = secondScreen.displayID {
                    GroupBox("Предпросмотр второго экрана") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(preview.status)
                            if let image = preview.image {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 260)
                                Text("Получено кадров: \(preview.frames)").font(.caption).foregroundStyle(.secondary)
                            }
                            if preview.running {
                                Button("Остановить захват") {
                                    Task { tv.disconnect(); preview.onVideoFrame = nil; await preview.stop() }
                                }
                            } else {
                                Button("Предпросмотр на Mac") { Task { await preview.start(displayID: id) } }
                                    .disabled(preview.busy || secondScreen.busy)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                }
                GroupBox("Передача на Android TV") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("IP-адрес телевизора", text: $host).textFieldStyle(.roundedBorder)
                                .disabled(!tv.canEditHost)
                            Button(tv.busy ? "Подключаюсь…" : "Найти приёмник") { tv.probe(host) }
                                .disabled(tv.busy || tv.connected || !tv.fingerprint.isEmpty)
                        }
                        Text(tv.status).textSelection(.enabled)
                        if !tv.fingerprint.isEmpty && !tv.connected {
                            Text("Номер устройства: \(tv.fingerprint)").font(.title3.monospaced().bold())
                            Text("Номер должен совпадать с надписью «Устройство» на телевизоре. При несовпадении отключитесь.")
                                .font(.caption).foregroundStyle(.secondary)
                            SecureField("Шесть цифр из строки «Код» на TV", text: $pairingCode)
                                .textFieldStyle(.roundedBorder).disabled(tv.busy)
                            Button("Номер совпадает — подключиться и передавать") { startTransmission() }
                                .disabled(tv.busy || pairingCode.utf8.count != 6)
                        }
                        if tv.connected { VStack(alignment: .leading) {
                                Text("Принято TV: \(tv.framesSent) • показано: \(tv.renderedFrames)")
                                Text(String(format: "Частота показа на TV: %.2f кадра/с", tv.renderedFPS))
                            }.monospacedDigit() }
                        if tv.connected || !tv.fingerprint.isEmpty || tv.busy {
                            Button("Отключиться") {
                                tv.disconnect()
                                preview.onVideoFrame = nil
                                pairingCode = ""
                                Task { await preview.stop(); await secondScreen.stop(); snapshot = inspectMac() }
                            }
                        }
                        Text("Откройте «Голубой экран TV» на телевизоре. Передаётся только созданный второй рабочий стол. Соединение шифруется; звук пока остаётся на Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
                GroupBox("Диагностика AirReceiver") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(host)
                            Button(checking ? "Проверяю…" : "Проверить связь") { checkReceiver() }.disabled(checking)
                        }
                        Text(receiver).textSelection(.enabled)
                        Button("Открыть разрешение на локальную сеть…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                        }.font(.caption)
                        Text("Проверяется ответ Cast/AirReceiver. Отсутствие ответа не означает несовместимость Android TV.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
                if let snapshot {
                    GroupBox("Экраны Mac • \(snapshot.displays.count)") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(snapshot.displays) { display in
                                Text("\(display.name) • \(Int(display.bounds.width)) × \(Int(display.bounds.height)) • \(display.builtIn ? "встроенный" : "внешний")\(display.mirrored ? " • дублирование" : "")")
                            }
                            if snapshot.displays.count == 1 { Text("Второй рабочий стол сейчас не обнаружен.").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                    GroupBox("Видимые окна • \(snapshot.windows.count)") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(snapshot.windows) { window in
                                HStack {
                                    Text(window.application)
                                    Spacer()
                                    Text(displayName(window.displayID, snapshot)).foregroundStyle(.secondary)
                                }
                            }
                            ForEach(applicationsAcrossDisplays(snapshot.windows), id: \.self) { name in
                                Text("\(name): окна на разных экранах. Разделение звука требует отдельной проверки.").foregroundStyle(.orange)
                            }
                        }.padding(4)
                    }
                    GroupBox("Звуковые процессы • \(snapshot.audioProcesses.filter(\.outputActive).count) с активным выходом") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(snapshot.audioProcesses.filter(\.outputActive)) { process in
                                Text("\(process.application) • PID \(process.pid)")
                            }
                            Text("Активный выход не обязательно означает слышимый звук. Связь звукового процесса с отдельным окном пока не установлена.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
                    }
                    ForEach(snapshot.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    if !snapshot.screenPermission {
                        Button("Разрешить доступ к экрану…") { _ = CGRequestScreenCaptureAccess() }
                    }
                }
                Text("Диагностика обновляется каждые 3 секунды. Предпросмотр работает только после разрешения macOS. Изображение в файлы и звук не записываются.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
        .onAppear { snapshot = inspectMac() }
        .onReceive(timer) { _ in snapshot = inspectMac() }
        .onChange(of: tv.connected) { wasConnected, isConnected in
            if wasConnected && !isConnected {
                preview.onVideoFrame = nil
                Task { await preview.stop(); await secondScreen.stop(); snapshot = inspectMac() }
            }
        }
        .onDisappear {
            tv.disconnect()
            preview.onVideoFrame = nil
            Task { await preview.stop(); await secondScreen.stop() }
        }
    }

    private func displayName(_ id: UInt32?, _ snapshot: Snapshot) -> String {
        snapshot.displays.first { $0.id == id }?.name ?? "Вне видимых экранов"
    }
    private func startTransmission() {
        Task {
            guard await tv.connect(pin: pairingCode) else { return }
            pairingCode = ""
            if secondScreen.displayID == nil { await secondScreen.start() }
            guard tv.connected else { await secondScreen.stop(); return }
            guard let id = secondScreen.displayID else { tv.disconnect(); return }
            preview.onVideoFrame = tv.frameHandler()
            await preview.start(displayID: id)
            preview.sendLatestVideoFrame()
            if !preview.running {
                tv.disconnect()
                preview.onVideoFrame = nil
                await secondScreen.stop()
            }
            snapshot = inspectMac()
        }
    }
    private func checkReceiver() {
        checking = true
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { checking = false }
            do {
                let info = try await inspectReceiver(host: address)
                receiver = "Отвечает: \(info.name ?? "без имени") • \(info.device_info?.model_name ?? "тип не указан"). Это ещё не проверка трансляции."
            } catch {
                if (error as? URLError)?.code == .notConnectedToInternet {
                    receiver = "Сеть недоступна для приложения. Проверьте Wi-Fi и разрешение «Локальная сеть» в настройках macOS."
                } else {
                    receiver = "Связь не подтверждена: \(error.localizedDescription)"
                }
            }
        }
    }
}
