import AppKit
import Combine
import CryptoKit
import Network
import CoreVideo
import CoreMedia
import Security

@MainActor final class TVConnection: ObservableObject {
    @Published private(set) var status = "Откройте «Голубой экран TV» на телевизоре."
    @Published private(set) var fingerprint = ""
    @Published private(set) var busy = false
    @Published private(set) var connected = false
    @Published private(set) var framesSent = 0
    @Published private(set) var bytesSent = 0
    private var candidate: String?
    private var host: String?
    private var connection: NWConnection?
    private var completion: ((Bool) -> Void)?
    private var timeout: Task<Void, Never>?
    private var heartbeat: DispatchSourceTimer?
    private var inFlight = false
    private let video = VideoEncoder()
    private var pending: [(UInt32, () -> Void)] = []
    private var sentCount: UInt32 = 0
    private var acceptedCount: UInt32 = 0
    private var totalBytes = 0
    private var publishedAt: TimeInterval = 0
    @Published private(set) var renderedFrames = 0
    @Published private(set) var renderedFPS: Double = 0
    private let port: UInt16
    private var attempt = UUID()

    init(port: UInt16 = 8845) { self.port = port }
    var canEditHost: Bool { !busy && !connected && fingerprint.isEmpty }

    func probe(_ address: String) {
        disconnect()
        do {
            let target = try validatedLocalAddress(address.trimmingCharacters(in: .whitespacesAndNewlines))
            host = target
            busy = true
            status = "Проверяю устройство…"
            open(target, expected: nil, pin: nil)
        } catch { status = error.localizedDescription }
    }

    func connect(pin: String) async -> Bool {
        guard !busy, !connected, let host, let candidate else { return false }
        guard pin.utf8.count == 6, pin.utf8.allSatisfy({ (48...57).contains($0) }) else {
            status = "Введите шесть цифр с экрана телевизора."
            return false
        }
        return await withCheckedContinuation { continuation in
            busy = true
            status = "Подключаюсь к проверенному устройству…"
            completion = { continuation.resume(returning: $0) }
            open(host, expected: candidate, pin: pin)
        }
    }

    // nil means this TV has not been paired on this Mac yet.
    func reconnect(_ address: String) async -> Bool? {
        do {
            let target = try validatedLocalAddress(address.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let saved = try await Task.detached(operation: { try PairingStore.load(target) }).value else { return nil }
            disconnect()
            host = target
            candidate = saved.certificate
            fingerprint = Self.shortFingerprint(saved.certificate)
            return await withCheckedContinuation { continuation in
                busy = true
                status = "Подключаюсь…"
                completion = { continuation.resume(returning: $0) }
                open(target, expected: saved.certificate, pin: nil, token: saved.token)
            }
        } catch { status = error.localizedDescription; return false }
    }

    func forget(_ address: String) throws { try PairingStore.remove(address) }

    func disconnect() {
        attempt = UUID()
        timeout?.cancel()
        timeout = nil
        heartbeat?.cancel()
        heartbeat = nil
        connection?.cancel()
        connection = nil
        completion?(false)
        completion = nil
        busy = false
        connected = false
        inFlight = false
        for item in pending { item.1() }
        pending.removeAll()
        video.stop()
        candidate = nil
        host = nil
        fingerprint = ""
        status = "Подключение выключено."
    }

    private func open(_ target: String, expected: String?, pin: String?, token: Data? = nil) {
        connection?.cancel()
        let attempt = UUID()
        self.attempt = attempt
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, trust, accept in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(value) as? [SecCertificate], let cert = chain.first else {
                accept(false); return
            }
            let hash = SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02X", $0) }.joined()
            if let expected {
                let matches = hash == expected
                accept(matches) // Exact certificate pin; no global trust exceptions.
                if !matches {
                    Task { @MainActor in
                        guard let self, self.attempt == attempt else { return }
                        self.fail("Номер устройства изменился. Найдите приёмник заново и сверьте номер с телевизором.")
                    }
                }
            } else {
                Task { @MainActor in
                    guard let self, self.attempt == attempt else { return }
                    self.candidate = hash
                    self.fingerprint = Self.shortFingerprint(hash)
                    self.busy = false
                    self.timeout?.cancel()
                    self.status = "Сверьте номер устройства с телевизором. При совпадении введите код и подключитесь."
                }
                accept(false) // Discovery never sends a PIN or screen data.
            }
        }, .main)
        let session = NWConnection(host: NWEndpoint.Host(target), port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        connection = session
        session.stateUpdateHandler = { [weak self, weak session] state in
            Task { @MainActor in
                guard let self, let session, self.connection === session else { return }
                switch state {
                case .ready:
                    guard expected != nil, pin != nil || token?.count == 32 else { self.fail("Не удалось проверить устройство."); return }
                    var hello = Data("BLUSCR03".utf8)
                    hello.append(token == nil ? 0 : 1)
                    hello.append(Data(PairingStore.clientID.utf8))
                    hello.append(token ?? Data((pin ?? "").utf8))
                    session.send(content: hello, completion: .contentProcessed { [weak self] error in
                        Task { @MainActor in
                            guard let self, self.connection === session else { return }
                            if let error { self.fail(error.localizedDescription); return }
                            self.readAuthentication(session, target: target, certificate: expected!, remembered: token != nil)
                        }
                    })
                case .failed(let error):
                    if expected == nil && self.candidate != nil { return }
                    self.fail("Соединение не установлено: \(error.localizedDescription)")
                case .cancelled: break
                default: break
                }
            }
        }
        armTimeout(session, "Приёмник не ответил. Проверьте, что приложение открыто на TV, и указан его IP.")
        session.start(queue: .main)
    }

    private func readAuthentication(_ session: NWConnection, target: String, certificate: String, remembered: Bool) {
        session.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.connection === session else { return }
                guard error == nil, data == Data([1]) else {
                    self.fail(remembered ? "Телевизор забыл этот Mac. Нажмите «Забыть подключение» и свяжите устройства заново." : "Неверный код. Подключитесь заново и введите код с телевизора."); return
                }
                self.readPairingToken(session, target: target, certificate: certificate)
            }
        }
    }

    private func readPairingToken(_ session: NWConnection, target: String, certificate: String) {
        session.receive(minimumIncompleteLength: 32, maximumLength: 32) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.connection === session else { return }
                guard error == nil, let data, data.count == 32 else { self.fail("Не удалось сохранить подключение. Обновите приложение на телевизоре."); return }
                do {
                    try await Task.detached { try PairingStore.save(target, certificate: certificate, token: data) }.value
                } catch { self.fail("Не удалось запомнить телевизор: \(error.localizedDescription)"); return }
                guard self.connection === session else { return }
                self.timeout?.cancel()
                self.busy = false
                do {
                    try self.video.start(handler: { [weak self] packet in
                        Task { @MainActor in
                            guard let self else { packet.accepted(); return }
                            self.sendVideo(packet)
                        }
                    }, failure: { [weak self] message in
                        Task { @MainActor in self?.fail(message) }
                    })
                } catch { self.fail(error.localizedDescription); return }
                self.sentCount = 0
                self.acceptedCount = 0
                self.totalBytes = 0
                self.renderedFrames = 0
                self.renderedFPS = 0
                self.connected = true
                var setup = Data()
                for number: UInt32 in [1920, 1080, 60] {
                    var value = number.bigEndian
                    setup.append(withUnsafeBytes(of: &value) { Data($0) })
                }
                session.send(content: setup, completion: .contentProcessed { [weak self] error in
                    if let error { Task { @MainActor in self?.fail(error.localizedDescription) } }
                })
                self.readFeedback(session)
                self.framesSent = 0
                self.bytesSent = 0
                self.status = "Подключено по защищённому соединению. Ожидаю изображение второго экрана."
                self.startHeartbeat()
                let complete = self.completion
                self.completion = nil
                complete?(true)
            }
        }
    }

    func send(_ buffer: CVPixelBuffer, _ time: CMTime) {
        guard connected else { return }
        video.submit(buffer, time)
    }

    func frameHandler() -> (CVPixelBuffer, CMTime) -> Void {
        let video = video
        return { buffer, time in video.submit(buffer, time) }
    }

    private func sendVideo(_ packet: VideoPacket) {
        guard connected, let session = connection else { packet.accepted(); return }
        guard packet.data.count + 9 <= 2 * 1024 * 1024 else {
            packet.accepted(); fail("Видеопакет превышает допустимый размер."); return
        }
        var payload = Data([packet.configuration ? 1 : 2])
        var timestamp = packet.timestamp.bigEndian
        payload.append(withUnsafeBytes(of: &timestamp) { Data($0) })
        payload.append(packet.data)
        var length = UInt32(payload.count).bigEndian
        var bytes = withUnsafeBytes(of: &length) { Data($0) }
        bytes.append(payload)
        if !packet.configuration {
            sentCount += 1
            pending.append((sentCount, packet.accepted))
        }
        totalBytes += bytes.count
        session.send(content: bytes, completion: .contentProcessed { [weak self] error in
            if let error { Task { @MainActor in self?.fail(error.localizedDescription) } }
        })
    }

    private func readFeedback(_ session: NWConnection) {
        session.receive(minimumIncompleteLength: 12, maximumLength: 12) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self, self.connection === session else { return }
                guard error == nil, let data, data.count == 12 else {
                    self.fail("Телевизор прервал приём видео."); return
                }
                func number(_ index: Int) -> UInt32 {
                    data[index..<index+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                }
                let acknowledged = number(0)
                guard acknowledged >= self.acceptedCount, acknowledged <= self.sentCount else {
                    self.fail("Приёмник прислал неверное подтверждение видео."); return
                }
                self.acceptedCount = acknowledged
                while let first = self.pending.first, first.0 <= acknowledged {
                    self.pending.removeFirst().1()
                }
                self.armTimeout(session, "Телевизор перестал подтверждать видео.")
                let now = Date.timeIntervalSinceReferenceDate
                if now - self.publishedAt >= 0.25 {
                    self.publishedAt = now
                    self.framesSent = Int(acknowledged)
                    self.bytesSent = self.totalBytes
                    self.renderedFrames = Int(number(4))
                    self.renderedFPS = Double(number(8)) / 1000
                }
                if acknowledged > 0, self.status != "Передаётся видео Full HD. Звук пока не передаётся." {
                    self.status = "Передаётся видео Full HD. Звук пока не передаётся."
                }
                self.readFeedback(session)
            }
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.connected, let session = self.connection else { return }
                session.send(content: Data([0,0,0,0]), completion: .contentProcessed { [weak self] error in
                    if let error { Task { @MainActor in self?.fail(error.localizedDescription) } }
                })
            }
        }
        heartbeat = timer
        timer.resume()
    }

    private func armTimeout(_ session: NWConnection, _ message: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, self.connection === session else { return }
            self.fail(message)
        }
    }

    private func fail(_ message: String) {
        disconnect()
        status = message
    }

    static func shortFingerprint(_ hash: String) -> String {
        let short = Array(hash.prefix(12))
        guard short.count == 12 else { return "" }
        return stride(from: 0, to: 12, by: 4).map { String(short[$0..<($0 + 4)]) }.joined(separator: "-")
    }
}

// Secrets live in the login Keychain; preferences contain only the public client ID.
struct PairingStore {
    struct Saved: Codable { let certificate: String; let token: Data }
    static var clientID: String {
        if let value = UserDefaults.standard.string(forKey: "pairing.clientID") { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: "pairing.clientID")
        return value
    }
    private static func query(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.bluescreen.pairing.v1",
         kSecAttrAccount as String: host]
    }
    static func load(_ host: String) throws -> Saved? {
        var q = query(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else { throw failure(result) }
        let saved = try JSONDecoder().decode(Saved.self, from: data)
        guard saved.token.count == 32, saved.certificate.count == 64 else { throw failure(errSecDecode) }
        return saved
    }
    static func save(_ host: String, certificate: String, token: Data) throws {
        let data = try JSONEncoder().encode(Saved(certificate: certificate, token: token))
        let q = query(host)
        let result = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Голубой экран — телевизор"
            let inserted = SecItemAdd(add as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw failure(inserted) }
        } else if result != errSecSuccess { throw failure(result) }
    }
    static func remove(_ host: String) throws {
        let result = SecItemDelete(query(host) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw failure(result) }
    }
    private static func failure(_ code: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Связка ключей macOS недоступна (\(code))."])
    }
}
