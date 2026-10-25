import Foundation
import CryptoKit

@main struct PinningChecks {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: pinning-checks HOST ADB_SERIAL") }
        let host = CommandLine.arguments[1]
        let serial = CommandLine.arguments[2]
        let tv = TVConnection()
        tv.probe(host)
        for _ in 0..<80 {
            if !tv.fingerprint.isEmpty { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !tv.fingerprint.isEmpty else { fatalError("Initial discovery failed: \(tv.status)") }
        let before = tv.fingerprint
        try await Task.detached {
            _ = try adb(serial, ["shell", "am", "force-stop", "local.bluescreen.tv"])
            _ = try adb(serial, ["shell", "am", "start", "-W", "-n", "local.bluescreen.tv/.MainActivity"])
        }.value
        var changed = false
        for _ in 0..<30 {
            let cert = try await Task.detached {
                try adb(serial, ["exec-out", "run-as", "local.bluescreen.tv", "cat", "files/receiver-cert.der"])
            }.value
            let hash = SHA256.hash(data: cert).map { String(format: "%02X", $0) }.joined()
            if !cert.isEmpty && TVConnection.shortFingerprint(hash) != before { changed = true; break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        guard changed else { fatalError("Receiver certificate did not rotate; test is inconclusive") }
        try await Task.sleep(nanoseconds: 500_000_000)
        let connected = await tv.connect(pin: "000000")
        guard !connected, tv.framesSent == 0, tv.status.contains("Номер устройства изменился") else {
            fatalError("Expected certificate mismatch rejection, got: \(tv.status)")
        }
        print("PASS: production Mac sender rejected a changed receiver certificate before code/image transmission")
    }

    static func adb(_ serial: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["adb", "-s", serial] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "ADB", code: Int(process.terminationStatus)) }
        return data
    }
}
