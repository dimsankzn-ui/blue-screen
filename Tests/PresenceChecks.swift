import Foundation

@main struct PresenceChecks {
    static func main() async {
        guard CommandLine.arguments.count == 3 else { fatalError("Need HOST online|offline") }
        let caps = await PresenceProbe.read(CommandLine.arguments[1])
        if CommandLine.arguments[2] == "online" {
            guard let caps, !caps.available.isEmpty else { fatalError("Receiver not online") }
            print("PASS: online; modes: \(caps.available.map(\.title))")
        } else {
            guard caps == nil else { fatalError("Offline receiver reported online") }
            print("PASS: offline timeout/refusal")
        }
    }
}
