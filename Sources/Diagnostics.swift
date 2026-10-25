import AppKit
import CoreAudio

struct DisplayInfo: Codable, Identifiable {
    let id: UInt32
    let name: String
    let builtIn: Bool
    let mirrored: Bool
    let bounds: CGRect
}

struct WindowInfo: Codable, Identifiable {
    let id: UInt32
    let pid: Int32
    let application: String
    let displayID: UInt32?
}

struct AudioProcess: Codable, Identifiable {
    let id: UInt32
    let pid: Int32
    let application: String
    let outputActive: Bool
}

struct Snapshot: Codable {
    let displays: [DisplayInfo]
    let windows: [WindowInfo]
    let audioProcesses: [AudioProcess]
    let screenPermission: Bool
    let warnings: [String]
}

// Geometry is in Quartz coordinates for both displays and windows.
func displayForWindow(_ bounds: CGRect, displays: [DisplayInfo]) -> UInt32? {
    var bestID: UInt32?
    var bestArea: CGFloat = 0
    for display in displays {
        let intersection = bounds.intersection(display.bounds)
        let area = intersection.isNull ? 0 : intersection.width * intersection.height
        if area > bestArea {
            bestArea = area
            bestID = display.id
        }
    }
    return bestID
}

func applicationsAcrossDisplays(_ windows: [WindowInfo]) -> [String] {
    Dictionary(grouping: windows, by: \.pid).values.compactMap { group in
        Set(group.compactMap(\.displayID)).count > 1 ? group.first?.application : nil
    }.sorted()
}

func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    guard status == noErr else { throw NSError(domain: "CoreAudio", code: Int(status)) }
    return value
}

@MainActor func inspectMac() -> Snapshot {
    let displays = NSScreen.screens.compactMap { screen -> DisplayInfo? in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = number.uint32Value
        return DisplayInfo(id: id, name: screen.localizedName, builtIn: CGDisplayIsBuiltin(id) != 0,
            mirrored: CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay, bounds: CGDisplayBounds(id))
    }
    let screenPermission = CGPreflightScreenCaptureAccess()
    var warnings: [String] = []
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]
    if raw == nil { warnings.append("Не удалось получить список окон.") }
    let windows = (raw ?? []).compactMap { row -> WindowInfo? in
        guard (row[kCGWindowLayer as String] as? Int) == 0,
            let rect = row[kCGWindowBounds as String] as? NSDictionary,
            let bounds = CGRect(dictionaryRepresentation: rect), bounds.width > 40, bounds.height > 40,
            (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
            let pid = row[kCGWindowOwnerPID as String] as? Int32,
            let id = row[kCGWindowNumber as String] as? UInt32 else { return nil }
        return WindowInfo(id: id, pid: pid,
            application: row[kCGWindowOwnerName as String] as? String ?? "PID \(pid)",
            displayID: displayForWindow(bounds, displays: displays))
    }
    var audio: [AudioProcess] = []
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    var status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
    if status == noErr && size > 0 {
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        status = objects.withUnsafeMutableBytes { pointer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, pointer.baseAddress!)
        }
        if status == noErr {
            var staleCount = 0
            for object in objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
                do {
                    let pid = Int32(bitPattern: try readUInt32(object, kAudioProcessPropertyPID))
                    let active = try readUInt32(object, kAudioProcessPropertyIsRunningOutput) != 0
                    let application = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "PID \(pid)"
                    audio.append(AudioProcess(id: object, pid: pid, application: application, outputActive: active))
                } catch { staleCount += 1 }
            }
            if staleCount > 0 { warnings.append("\(staleCount) звуковых процессов изменились во время проверки; обновите список.") }
        }
    }
    if status != noErr { warnings.append("Список звуковых процессов недоступен: \(status).") }
    if !screenPermission { warnings.append("Доступ к записи экрана не выдан. Список окон может быть неполным; захват изображения недоступен.") }
    return Snapshot(displays: displays, windows: windows,
        audioProcesses: audio.sorted { $0.pid < $1.pid }, screenPermission: screenPermission, warnings: warnings)
}

struct ReceiverInfo: Decodable {
    let name: String?
    let device_info: Device?
    struct Device: Decodable { let model_name: String? }
}

func validatedLocalAddress(_ host: String) throws -> String {
    // Only literal local IPv4 addresses: no credentials, paths, or public endpoints.
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt8($0) != nil }) else {
        throw NSError(domain: "BlueScreen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Укажите локальный IPv4-адрес, например 192.168.1.100."])
    }
    let octets = parts.map { Int($0)! }
    guard octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) ||
        (octets[0] == 172 && (16...31).contains(octets[1])) else {
        throw NSError(domain: "BlueScreen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Нужен адрес устройства в домашней сети."])
    }
    return octets.map(String.init).joined(separator: ".")
}

func inspectReceiver(host: String) async throws -> ReceiverInfo {
    let host = try validatedLocalAddress(host)
    var request = URLRequest(url: URL(string: "http://\(host):8008/setup/eureka_info")!)
    request.timeoutInterval = 4
    let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw NSError(domain: "BlueScreen", code: 3, userInfo: [NSLocalizedDescriptionKey: "Приёмник не ответил на запрос диагностики."])
    }
    guard data.count <= 128_000 else { throw URLError(.dataLengthExceedsMaximum) }
    let info = try JSONDecoder().decode(ReceiverInfo.self, from: data)
    guard info.name != nil || info.device_info?.model_name != nil else { throw URLError(.cannotParseResponse) }
    return info
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
