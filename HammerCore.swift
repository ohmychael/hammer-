// HammerCore.swift — the parts of Hammer that need nothing but Foundation:
// packet formats, the Bluetooth command queue, name parsing and small
// formatting rules. They live here so they can be tested on their own.
//
// build.sh compiles Tests/main.swift against this file and runs it before every
// install. If any test fails, the update stops and the current Hammer keeps running.

import Foundation

// MARK: - Govee Bluetooth packets

/// 20 bytes: a header (0x33 for commands, 0xAA for status reads), a command
/// byte, the payload, zero padding, and the XOR of the first 19 bytes last.
enum GoveePacket {
    static func make(_ payload: [UInt8]) -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: 20)
        for (index, byte) in payload.prefix(19).enumerated() { packet[index] = byte }
        packet[19] = packet[0..<19].reduce(0) { $0 ^ $1 }
        return packet
    }

    /// "Are you on?" The bulb answers with a power-state reply.
    static let statusRead = make([0xAA, 0x01])

    static func isCommand(_ packet: [UInt8]) -> Bool { packet.first == 0x33 }

    /// Reads a power-state reply ("AA 01 xx"): true means on, nil means it isn't one.
    static func powerState(in reply: [UInt8]) -> Bool? {
        guard reply.count >= 3, reply[0] == 0xAA, reply[1] == 0x01 else { return nil }
        return reply[2] != 0
    }
}

// MARK: - Bluetooth command queue

/// Packets waiting to go to one bulb.
/// - Only the latest of each kind is kept: five brightness changes made while the
///   bulb is busy become just the last one.
/// - They go in the order they were last asked for.
/// - Anything waiting `freshFor` seconds or longer is dropped, so a tap from minutes
///   ago doesn't suddenly happen when the bulb frees up.
struct CommandQueue {
    struct Item: Equatable {
        let key: UInt16              // header byte + command byte
        let packet: [UInt8]
        let at: Date
    }

    let freshFor: TimeInterval
    private(set) var items: [Item] = []

    init(freshFor: TimeInterval = 15) { self.freshFor = freshFor }

    var isEmpty: Bool { items.isEmpty }
    var first: [UInt8]? { items.first?.packet }

    mutating func add(_ packet: [UInt8], at time: Date = Date()) {
        guard packet.count >= 2 else { return }
        let key = UInt16(packet[0]) << 8 | UInt16(packet[1])
        items.removeAll { $0.key == key }
        items.append(Item(key: key, packet: packet, at: time))
    }

    mutating func dropStale(now: Date = Date()) {
        items.removeAll { now.timeIntervalSince($0.at) >= freshFor }
    }

    mutating func removeFirst() {
        if !items.isEmpty { items.removeFirst() }
    }

    /// Puts back commands that were written but may not have arrived (the link died
    /// under them), ahead of anything queued since. A kind that has a newer command
    /// waiting stays with the newer one. They keep their original times, so they
    /// still expire `freshFor` after you asked.
    mutating func restore(_ lost: [Item]) {
        var latest: [UInt16: Item] = [:]
        for item in lost { latest[item.key] = item }               // only the last of each kind
        let back = lost.filter { item in
            latest[item.key] == item && !items.contains { $0.key == item.key }
        }
        items.insert(contentsOf: back, at: 0)
    }
}

// MARK: - Reconnect timing

/// When Hammer may try connecting to a bulb again after something went wrong.
/// The first failure is retried at once (it's usually a one-off, like your phone
/// grabbing the bulb); after that each failure in a row doubles the wait (3 s,
/// 6 s, 12 s … up to a minute), so a bulb that keeps refusing isn't flooded with
/// attempts. A lasting link resets it.
struct ConnectBackoff {
    static let first: TimeInterval = 3
    static let longest: TimeInterval = 60

    private(set) var failures: [UUID: Int] = [:]
    private(set) var notBefore: [UUID: Date] = [:]

    static func delay(afterFailures count: Int) -> TimeInterval {
        guard count > 1 else { return 0 }
        return min(first * pow(2, Double(min(count, 16) - 2)), longest)
    }

    func canTry(_ id: UUID, now: Date = Date()) -> Bool {
        now >= (notBefore[id] ?? .distantPast)
    }

    /// Seconds until the next try is allowed (0 if it already is).
    func wait(_ id: UUID, now: Date = Date()) -> TimeInterval {
        max(0, (notBefore[id] ?? now).timeIntervalSince(now))
    }

    /// Records one more failure in a row and returns the wait before the next try.
    @discardableResult
    mutating func failed(_ id: UUID, now: Date = Date()) -> TimeInterval {
        let count = (failures[id] ?? 0) + 1
        failures[id] = count
        let delay = Self.delay(afterFailures: count)
        notBefore[id] = now.addingTimeInterval(delay)
        return delay
    }

    /// Waits at least `seconds` before the next try (e.g. a bulb that can't take Hammer's commands).
    mutating func pause(_ id: UUID, for seconds: TimeInterval, now: Date = Date()) {
        let until = now.addingTimeInterval(seconds)
        notBefore[id] = max(notBefore[id] ?? until, until)
    }

    /// You just asked for this bulb, so try within `seconds` even if Hammer was waiting longer.
    mutating func hurry(_ id: UUID, within seconds: TimeInterval, now: Date = Date()) {
        guard let until = notBefore[id] else { return }
        notBefore[id] = min(until, now.addingTimeInterval(seconds))
    }

    /// The link lasted: start counting from scratch.
    mutating func succeeded(_ id: UUID) {
        failures[id] = nil
        notBefore[id] = nil
    }
}

// MARK: - Govee bulb names

enum GoveeName {
    /// The model in an advertised name, e.g. "ihoment_H6006_0FC3" → "H6006".
    static func model(in name: String) -> String? {
        guard let range = name.range(of: "H[0-9A-F]{4}", options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return name[range].uppercased()
    }

    /// "ihoment_H6006_0FC3" → "H6006 bulb 0FC3"; with no code at the end → "H6006 bulb".
    static func displayName(model: String, advertised: String) -> String {
        let parts = advertised.split(separator: "_")
        guard parts.count >= 3, let code = parts.last, !code.isEmpty else { return "\(model) bulb" }
        return "\(model) bulb \(code)"
    }

    /// Roughly how far away a bulb is, from its signal strength in dBm.
    static func distance(dBm: Int) -> String {
        if dBm >= -60 { return "very close" }
        if dBm >= -75 { return "nearby" }
        return "far away"
    }
}

// MARK: - Text

enum TimerText {
    /// 5 → "5 min", 60 → "1 hr", 90 → "1 hr 30 min".
    static func describe(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
}

// MARK: - Updates: what update.sh last did, and how Hammer was started

/// ~/Hammer/update-status, which update.sh (and build.sh) write: one `key=value` per line.
///   state    current, updated, updating, waiting, checking, offline, failed or retry
///   time     seconds since 1970
///   message  a short line for the menu ("Up to date")
///   detail   a sentence for the notification
struct UpdateStatus: Equatable {
    var state: String
    var time: Date
    var message: String
    var detail: String

    static func parse(_ text: String) -> UpdateStatus? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        guard let state = fields["state"], !state.isEmpty,
              let seconds = fields["time"].flatMap(TimeInterval.init) else { return nil }
        return UpdateStatus(state: state, time: Date(timeIntervalSince1970: seconds),
                            message: fields["message"] ?? "", detail: fields["detail"] ?? "")
    }

    /// Still going (checking, building, or waiting for you to finish).
    var inProgress: Bool { ["checking", "updating", "waiting"].contains(state) }

    /// A run that says it's still going after an hour was cut off.
    func isStale(now: Date) -> Bool { inProgress && now.timeIntervalSince(time) > 3600 }

    /// The menu line, e.g. "Up to date · checked 2:14 PM". `when` is the time, or the
    /// day if it wasn't today ("2:14 PM", "Oct 22").
    func menuLine(when: String) -> String {
        if inProgress { return message }
        return message + " · " + (state == "current" ? "checked " : "") + when
    }

    /// The notification for this status, or nil. `asked` is when you chose Check for
    /// Updates (then any result is shown); otherwise only news is: an update installed,
    /// or one that failed or can't happen, once per message.
    func notice(asked: Date?, lastNotice: String?, now: Date) -> (title: String, body: String)? {
        guard !inProgress else { return nil }
        let isAnswer = asked.map { time >= $0.addingTimeInterval(-2) } ?? false
        if !isAnswer {
            guard ["updated", "failed", "retry"].contains(state), noticeKey != lastNotice,
                  now.timeIntervalSince(time) < 900 else { return nil }
        }
        switch state {
        case "updated": return ("Hammer updated", detail.isEmpty ? message : detail)
        case "current": return ("Hammer is up to date", "")
        case "failed": return ("Hammer couldn't update", detail)
        default: return (message, detail)
        }
    }

    /// What was last notified, so the same news isn't shown twice (kept by Hammer).
    var noticeKey: String { state + "|" + message }
}

enum Launch {
    /// The menu bar app starts with no arguments (from Finder, Spotlight or `open`),
    /// with --login (the login item and updates, which don't pop the menu up), or with
    /// the -psn_… argument older macOS versions add. Anything else that isn't a
    /// command is a mistake, and gets the usage.
    static func startsMenuBarApp(_ args: [String]) -> Bool {
        args.allSatisfy { $0 == "--login" || $0.hasPrefix("-psn_") }
    }

    static func atLogin(_ args: [String]) -> Bool { args.contains("--login") }
}
