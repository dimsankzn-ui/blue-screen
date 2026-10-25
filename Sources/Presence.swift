import Foundation
import Network

// Bounded read-only advertisement. Authentication and final mode validation remain inside pinned TLS.
final class PresenceProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.bluescreen.presence")
    private let connection: NWConnection
    private var result: CheckedContinuation<DisplayCapabilities?, Never>?
    private var bytes = Data()
    private init(_ host: String) { connection = NWConnection(host: NWEndpoint.Host(host), port: 8846, using: .tcp) }
    static func read(_ host: String) async -> DisplayCapabilities? {
        guard let target = try? validatedLocalAddress(host) else { return nil }
        return await withCheckedContinuation { continuation in
            let probe = PresenceProbe(target)
            probe.queue.async {
                probe.result = continuation
                probe.connection.stateUpdateHandler = { state in
                    switch state { case .ready: probe.receive(); case .failed, .cancelled: probe.finish(nil); default: break }
                }
                probe.queue.asyncAfter(deadline: .now() + 2) { probe.finish(nil) }
                probe.connection.start(queue: probe.queue)
            }
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, done, error in
            if let data { self.bytes.append(data) }
            guard error == nil, self.bytes.count <= 16384 else { self.finish(nil); return }
            if done {
                let caps = try? JSONDecoder().decode(DisplayCapabilities.self, from: self.bytes)
                self.finish(caps?.protocolVersion == 4 ? caps : nil)
            } else { self.receive() }
        }
    }
    private func finish(_ value: DisplayCapabilities?) {
        guard let result else { return }
        self.result = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        result.resume(returning: value)
    }
}
