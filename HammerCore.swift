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
///   ago doesn't suddenly happen when the bulb frees up. A packet can be given its
///   own, longer time (`keepFor`): the sleep timer and Turn On At wait 5 minutes.
struct CommandQueue {
    struct Item: Equatable {
        let key: UInt16              // header byte + command byte
        let packet: [UInt8]
        let at: Date
        var keepFor: TimeInterval? = nil     // nil: the queue's `freshFor`
    }

    let freshFor: TimeInterval
    private(set) var items: [Item] = []

    init(freshFor: TimeInterval = 15) { self.freshFor = freshFor }

    var isEmpty: Bool { items.isEmpty }
    var first: [UInt8]? { items.first?.packet }

    mutating func add(_ packet: [UInt8], at time: Date = Date(), keepFor: TimeInterval? = nil) {
        guard packet.count >= 2 else { return }
        let key = UInt16(packet[0]) << 8 | UInt16(packet[1])
        items.removeAll { $0.key == key }
        items.append(Item(key: key, packet: packet, at: time, keepFor: keepFor))
    }

    /// Drops what has waited too long, and returns it (so Hammer can say a command didn't go out).
    @discardableResult
    mutating func dropStale(now: Date = Date()) -> [Item] {
        let isStale = { (item: Item) in now.timeIntervalSince(item.at) >= (item.keepFor ?? freshFor) }
        let stale = items.filter(isStale)
        items.removeAll(where: isStale)
        return stale
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
    /// The model in an advertised name, e.g. "ihoment_H6006_0FC3" → "H6006". It has to
    /// be a part of its own between underscores (or spaces), so "BATH6006" isn't one.
    static func model(in name: String) -> String? {
        for part in name.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" }) {
            if part.count == 5, part.first == "H" || part.first == "h",
               part.dropFirst().allSatisfy({ $0.isHexDigit }) {
                return part.uppercased()
            }
        }
        return nil
    }

    /// "ihoment_H6006_0FC3" → "H6006 bulb 0FC3"; with no code at the end → "H6006 bulb".
    static func displayName(model: String, advertised: String) -> String {
        let parts = advertised.split(separator: "_")
        guard parts.count >= 3, let code = parts.last, !code.isEmpty else { return "\(model) bulb" }
        return "\(model) bulb \(code)"
    }

    /// The bulb's own code back from its display name ("H6006 bulb 0FC3" → "0FC3"): the
    /// end of its Bluetooth address. Nil for anything else, such as a placeholder name.
    static func code(inDisplayName name: String, model: String) -> String? {
        guard !model.isEmpty, name.hasPrefix("\(model) bulb ") else { return nil }
        let code = String(name.dropFirst(model.count + 6))
        guard code.count == 4, code.allSatisfy({ $0.isHexDigit }) else { return nil }
        return code.uppercased()
    }

    /// Roughly how far away a bulb is, from its signal strength in dBm.
    static func distance(dBm: Int) -> String {
        if dBm >= -60 { return "very close" }
        if dBm >= -75 { return "nearby" }
        return "far away"
    }
}

// MARK: - Govee lights: the list in the menu

struct GoveeLight {
    let id: String          // Govee device ID (looks like a MAC address), or a Bluetooth bulb's UUID
    let sku: String         // model number, e.g. H6159
    var name: String
    var lanIP: String?      // set when the light answered on the local network
    var bluetoothID: UUID? = nil     // set when the light was found over Bluetooth
    var bluetoothCode: String? = nil // the end of its Bluetooth name ("ihoment_H6006_0FC3" → "0FC3")
    var inAccount = false            // listed in your Govee account (cloud API key)

    enum Route { case lan, bluetooth, cloud }

    /// Route order: local network, then Bluetooth, then the Govee cloud.
    var route: Route { lanIP != nil ? .lan : bluetoothID != nil ? .bluetooth : .cloud }
}

enum LightList {
    /// Puts the bulbs found nearby over Bluetooth together with the lights from your
    /// Govee account and Wi-Fi. A Bluetooth bulb and a cloud light are the same bulb
    /// only on a positive match: the same model, and the code at the end of the bulb's
    /// Bluetooth name is the end of the cloud's device ID (both come from its address),
    /// with exactly one candidate each way. Everything else stays separate (a nearby
    /// bulb then waits under Other Lights until you add it). Never matched by counting:
    /// your cloud bulb out of range plus a neighbor's in range must not become one.
    static func merge(network: [GoveeLight], nearby: [GoveeLight]) -> [GoveeLight] {
        var result = network
        let cloudOnly = result.indices.filter { result[$0].lanIP == nil && result[$0].bluetoothID == nil }
        func matches(_ cloud: Int, _ bulb: Int) -> Bool {
            guard let code = nearby[bulb].bluetoothCode, nearby[bulb].sku == result[cloud].sku else { return false }
            return sameBulb(deviceID: result[cloud].id, code: code)
        }
        var merged = Set<Int>()
        for cloud in cloudOnly {
            let bulbs = nearby.indices.filter { matches(cloud, $0) }
            guard bulbs.count == 1, cloudOnly.filter({ matches($0, bulbs[0]) }) == [cloud] else { continue }
            result[cloud].bluetoothID = nearby[bulbs[0]].bluetoothID
            result[cloud].bluetoothCode = nearby[bulbs[0]].bluetoothCode
            merged.insert(bulbs[0])
        }
        result += nearby.indices.filter { !merged.contains($0) }.map { nearby[$0] }
        return result
    }

    /// Whether a Govee device ID ("C3:12:A4:C1:38:9B:0F:C3") ends with a bulb's 4-digit code ("0FC3").
    static func sameBulb(deviceID: String, code: String) -> Bool {
        let digits = deviceID.uppercased().filter { $0.isHexDigit }
        let code = code.uppercased()
        guard code.count == 4, code.allSatisfy({ $0.isHexDigit }), digits.count >= 8 else { return false }
        return digits.hasSuffix(code)
    }

    /// Lights in your Govee account are yours unless you remove them. Anything found
    /// only nearby, over Bluetooth (it reaches through walls) or on a shared Wi-Fi
    /// (dorms, offices), could be anyone's: it's yours once you add it.
    static func isMine(_ light: GoveeLight, added: Set<String>, hidden: Set<String>) -> Bool {
        light.inAccount ? !hidden.contains(light.id) : added.contains(light.id)
    }

    /// The lights you've added. Until the first add, any light you'd renamed counts.
    static func added(saved: [String]?, renamed: [String: String]) -> Set<String> {
        saved.map(Set.init) ?? Set(renamed.keys)
    }

    // Your Govee account's lights are saved after each answer from the cloud, so a
    // cloud that doesn't answer (at login before Wi-Fi is up, or down for a while)
    // doesn't turn your lights into Other Lights.

    static func saved(_ account: [GoveeLight]) -> [[String: String]] {
        account.map { ["id": $0.id, "sku": $0.sku, "name": $0.name] }
    }

    static func account(from saved: [[String: String]]) -> [GoveeLight] {
        saved.compactMap { entry in
            guard let id = entry["id"], !id.isEmpty, let sku = entry["sku"] else { return nil }
            return GoveeLight(id: id, sku: sku, name: entry["name"] ?? sku, lanIP: nil, inAccount: true)
        }
    }

    /// The account's lights: what the cloud said, or (no answer) what it said last time.
    static func account(fetched: [GoveeLight]?, saved: [GoveeLight]) -> [GoveeLight] {
        fetched ?? saved
    }

    /// The lights on the local network together with your account's: one light each,
    /// the fast local route, the name from the Govee app, and in your account.
    static func combine(local: [GoveeLight], account: [GoveeLight]) -> [GoveeLight] {
        var byID: [String: GoveeLight] = [:]
        for light in local { byID[light.id.uppercased()] = light }
        for light in account {
            let id = light.id.uppercased()
            if var known = byID[id] {
                known.name = light.name
                known.inAccount = true
                byID[id] = known
            } else {
                var light = light
                light.inAccount = true
                byID[id] = light
            }
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Before lights found only on the local network had to be added, they were yours
/// unless you removed them. Once, after updating, the ones you'd set up (renamed, or
/// given a color or white) are added for you, so they don't move to Other Lights.
/// It happens at the first scan that reaches the local network, whatever it finds
/// (Wi-Fi may be off at login: it waits up to 3 days for one), and never again, so a
/// later scan at an office or a friend's never adopts their lights.
struct LANMigration {
    static let window: TimeInterval = 3 * 86_400

    var startedAt: Date
    var done = false

    /// Settings an older Hammer leaves once it has been used (none of them is written
    /// just by starting up), so a new install doesn't take in a dorm's lights.
    static let usedBefore: Set<String> = [
        "lightNames", "lightModes", "hiddenLights", "myBluetoothLights", "lightsOffAt", "turnOnNext",
        "turnOnHour", "turnOnMinute", "turnOnRepeats", "turnOnWakesMac", "playerCommandY", "youTubeInEdge",
        "deliverySource", "deliveryEmail", "deliveryScriptURL", "askedForNotifications",
    ]

    static func updating(settings: Set<String>) -> Bool { !settings.isDisjoint(with: usedBefore) }

    /// One scan: the lights to add. `reachedNetwork` says the scan went out on the local
    /// network (it can't when Wi-Fi is off); `setUp` is the lights with names or colors
    /// saved by the older Hammer.
    mutating func scanned(found: [GoveeLight], reachedNetwork: Bool, hidden: Set<String>, setUp: Set<String>,
                          now: Date) -> Set<String> {
        guard !done else { return [] }
        guard now.timeIntervalSince(startedAt) < Self.window else { done = true; return [] }
        guard reachedNetwork else { return [] }
        done = true
        return Set(found.filter { $0.lanIP != nil && !$0.inAccount && !hidden.contains($0.id) && setUp.contains($0.id) }
            .map { $0.id })
    }
}

// MARK: - Govee replies (local network and cloud)

enum GoveeReplies {
    /// A light answering the local-network scan. Its address is where the reply came
    /// from, not what the reply says (anyone on the network can claim any address).
    static func scanReply(_ data: Data, from senderIP: String) -> GoveeLight? {
        guard !senderIP.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["msg"] as? [String: Any], msg["cmd"] as? String == "scan",
              let body = msg["data"] as? [String: Any],
              let id = body["device"] as? String, !id.isEmpty else { return nil }
        let sku = body["sku"] as? String ?? "Govee"
        return GoveeLight(id: id, sku: sku, name: "\(sku) (\(senderIP))", lanIP: senderIP)
    }

    /// On or off from a local-network "devStatus" reply.
    static func lanPower(in data: Data) -> Bool? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["msg"] as? [String: Any], msg["cmd"] as? String == "devStatus",
              let body = msg["data"] as? [String: Any], let value = body["onOff"] as? Int else { return nil }
        return value != 0
    }

    /// The lights in your Govee account (plugs, heaters and other non-lights are
    /// skipped); nil if that isn't what the cloud answered.
    static func cloudLights(in data: Data) -> [GoveeLight]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["data"] as? [[String: Any]] else { return nil }
        return devices.compactMap { device -> GoveeLight? in
            guard let id = device["device"] as? String, let sku = device["sku"] as? String,
                  let capabilities = device["capabilities"] as? [[String: Any]],
                  capabilities.contains(where: { $0["instance"] as? String == "brightness" })
            else { return nil }
            return GoveeLight(id: id, sku: sku, name: device["deviceName"] as? String ?? sku, lanIP: nil,
                              inAccount: true)
        }
    }

    /// Whether the cloud took a command: HTTP 200, and Govee's own code (if any) is 200.
    static func cloudSucceeded(status: Int, body: Data?) -> Bool {
        guard status == 200 else { return false }
        guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let code = json["code"] as? Int else { return true }
        return code == 200
    }

    /// On or off from the cloud's device state.
    static func cloudPower(in data: Data) -> Bool? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let capabilities = payload["capabilities"] as? [[String: Any]],
              let power = capabilities.first(where: { $0["instance"] as? String == "powerSwitch" }),
              let state = power["state"] as? [String: Any], let value = state["value"] as? Int else { return nil }
        return value != 0
    }
}

// MARK: - Blink to Identify

enum Blink {
    /// Two flashes that end the way the light was. If Hammer couldn't tell, someone
    /// else's light ends off, and one of yours ends on.
    static func steps(wasOn: Bool?, mine: Bool) -> [Bool] {
        let end = wasOn ?? mine
        return [!end, end, !end, end]
    }

    /// Blinks a light: asks it whether it's on, then flashes it. Stops as soon as
    /// `interrupted` says something newer was sent to the light (a tap during the
    /// blink wins, and isn't undone). Blocks: call off the main thread. Returns the
    /// on/off steps it sent.
    @discardableResult
    static func run(mine: Bool, readPower: () -> Bool?, setPower: (Bool) -> Void,
                    interrupted: () -> Bool, pause: () -> Void) -> [Bool] {
        let wasOn = readPower()
        var sent: [Bool] = []
        for on in steps(wasOn: wasOn, mine: mine) {
            guard !interrupted() else { break }
            setPower(on)
            sent.append(on)
            pause()
        }
        return sent
    }
}

/// When Hammer last sent each light a command of yours (or a scheduled one), so a
/// blink can tell it was overtaken. Used from several threads (hence the lock).
final class LightActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [String: Date] = [:]

    func touched(_ id: String, at time: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        last[id] = time
    }

    func touched(_ id: String, since time: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (last[id] ?? .distantPast) > time
    }
}

// MARK: - The color picker

enum ColorPick {
    /// The color panel's pick as a bulb color: its hue and saturation at full strength
    /// (brightness stays on Hammer's own slider). Nil for black or nearly: there's no
    /// color in it, so the pick is ignored rather than turning the lights white or off.
    /// Components are sRGB, 0 to 1.
    static func vivid(red: Double, green: Double, blue: Double) -> (Int, Int, Int)? {
        let top = max(red, green, blue)
        guard top >= 0.04 else { return nil }
        // Same hue and saturation at full value: scale so the strongest component is full.
        func byte(_ component: Double) -> Int { min(max(Int((component / top * 255).rounded()), 0), 255) }
        return (byte(red), byte(green), byte(blue))
    }
}

// MARK: - What lights said back

/// What Hammer waits to hear about each light, per kind of command, so one result
/// only settles what it's about: a brightness change landing doesn't move the color
/// checkmark, and a tap's result doesn't replace a scheduled command's.
struct LightResults {
    enum Kind: Hashable {
        case power, brightness, look

        /// The kind of a Bluetooth packet (header and command byte), if it's a command.
        init?(packetKey: UInt16) {
            switch packetKey {
            case 0x3301: self = .power
            case 0x3304: self = .brightness
            case 0x3305: self = .look
            default: return nil
            }
        }
    }

    struct Waiting: Equatable {
        var mode: String? = nil              // the checkmark to move once it lands
        var failNote: String? = nil          // nil: "Couldn't reach <name>"
        var scheduled = false                // the sleep timer or Turn On At
    }

    private(set) var waiting: [String: [Kind: Waiting]] = [:]

    /// A newer command of the same kind replaces what was waited for.
    mutating func expect(_ id: String, _ kind: Kind, _ what: Waiting) {
        waiting[id, default: [:]][kind] = what
    }

    /// One command's result: what was waited for, if anything. `scheduled` says whose
    /// result it is (nil: can't tell, as over Bluetooth, where a tap replaces a waiting
    /// scheduled command), so a tap's result doesn't settle a scheduled command.
    mutating func result(_ id: String, _ kind: Kind, scheduled: Bool? = nil) -> Waiting? {
        guard let what = waiting[id]?[kind] else { return nil }
        if let scheduled, what.scheduled != scheduled { return nil }
        waiting[id]?[kind] = nil
        if waiting[id]?.isEmpty == true { waiting[id] = nil }
        return what
    }
}

// MARK: - Why a bulb can't be reached

/// The error from each bulb's last failed connection attempt, for the menu's hint.
/// A bulb your phone holds doesn't fail (the attempt just waits), so no error means
/// "something else has it"; any sign of life clears the error.
struct LinkErrors {
    enum Reason: Equatable { case busy, tooManyDevices, refused }

    private(set) var codes: [UUID: Int] = [:]

    mutating func failed(_ id: UUID, code: Int) { codes[id] = code }

    /// It connected, got ready, answered, or isn't yours any more: whatever failed before is over.
    @discardableResult
    mutating func cleared(_ id: UUID) -> Bool { codes.removeValue(forKey: id) != nil }

    mutating func clearAll() { codes = [:] }

    func code(_ id: UUID) -> Int? { codes[id] }

    /// CBError connectionLimitReached (11) and tooManyLEPairedDevices (16) mean the Mac has
    /// too many devices; any other failure, that the connection was refused.
    func reason(_ id: UUID) -> Reason {
        guard let code = codes[id] else { return .busy }
        return [11, 16].contains(code) ? .tooManyDevices : .refused
    }
}

/// Short lines at the top of the lights in the menu when something didn't land.
struct LightNotes {
    struct Note: Equatable {
        var text: String
        var until: Date
        var scheduled: Bool          // a missed sleep timer or Turn On At (kept 12 hours)
    }

    static let reachFor: TimeInterval = 600
    static let scheduledFor: TimeInterval = 12 * 3600

    private(set) var notes: [String: Note] = [:]

    /// A short "Couldn't reach" never replaces a missed schedule that's still showing.
    mutating func failed(_ id: String, _ text: String, scheduled: Bool, now: Date) {
        if !scheduled, let current = notes[id], current.scheduled, current.until > now { return }
        notes[id] = Note(text: text, until: now.addingTimeInterval(scheduled ? Self.scheduledFor : Self.reachFor),
                         scheduled: scheduled)
    }

    /// The light answered or took a command: its "Couldn't reach" goes (a missed
    /// schedule stays: it still happened). True if a line went.
    @discardableResult
    mutating func reached(_ id: String) -> Bool {
        guard let note = notes[id], !note.scheduled else { return false }
        notes[id] = nil
        return true
    }

    /// The lines to show: missed schedules first, then lights that couldn't be
    /// reached; at most three, with several unreachable lights counted on one line.
    mutating func lines(now: Date) -> [String] {
        notes = notes.filter { $0.value.until > now }
        let missed = notes.values.filter { $0.scheduled }.map { $0.text }.sorted()
        let reach = notes.values.filter { !$0.scheduled }.map { $0.text }.sorted()
        if missed.count + reach.count <= 3 { return missed + reach }
        let shown = Array(missed.prefix(reach.isEmpty ? 3 : 2))
        if reach.isEmpty { return shown }
        return shown + [reach.count == 1 ? reach[0] : "Couldn't reach \(reach.count) lights"]
    }
}

// MARK: - Remembering Bluetooth bulbs

enum BulbMemory {
    /// Bulbs that aren't yours and haven't been seen for this long are forgotten.
    static let forgetAfter: TimeInterval = 30 * 86_400

    /// `saved` is ID → "model|name", `seen` is ID → when last seen. A bulb with no
    /// date yet starts counting now. Yours (`keep`) are never forgotten.
    static func prune(saved: [String: String], seen: [String: Date], keep: Set<String>, now: Date)
        -> (saved: [String: String], seen: [String: Date]) {
        var keptSaved: [String: String] = [:], keptSeen: [String: Date] = [:]
        for (id, value) in saved {
            let last = seen[id] ?? now
            guard keep.contains(id) || now.timeIntervalSince(last) < forgetAfter else { continue }
            keptSaved[id] = value
            keptSeen[id] = last
        }
        return (keptSaved, keptSeen)
    }
}

// MARK: - Sleep timer and Turn On At

enum LightSchedule {
    enum Action: Equatable { case on, off }

    /// A sleep timer that ran out more than an hour ago (the Mac was asleep, or Hammer
    /// wasn't running) is dropped without turning anything off.
    static let timerLateBy: TimeInterval = 3600
    /// A Turn On At more than 30 minutes late is skipped.
    static let turnOnLateBy: TimeInterval = 30 * 60
    /// Scheduled commands wait this long for a busy bulb (taps wait 15 seconds).
    static let keepFor: TimeInterval = 300

    struct Decision: Equatable {
        var send: Action? = nil
        var scheduledFor: Date? = nil
        var timerDone = false           // the sleep timer came due: clear it
        var turnOnDone = false          // Turn On At came due: move on to the next one
    }

    /// What to do now. When both came due (e.g. while the Mac slept), only the one
    /// scheduled later counts: last night's timer doesn't undo this morning's Turn On.
    /// That one is sent unless it's too late; the earlier one is never sent instead
    /// (a skipped 7:15 Turn On doesn't let a 7:00 timer turn the lights off at 7:50).
    static func decide(timerEnd: Date?, turnOnAt: Date?, now: Date) -> Decision {
        var decision = Decision()
        var due: [(action: Action, at: Date)] = []
        if let end = timerEnd, now >= end {
            decision.timerDone = true
            due.append((.off, end))
        }
        if let on = turnOnAt, now >= on {
            decision.turnOnDone = true
            due.append((.on, on))
        }
        guard let latest = due.max(by: { $0.at < $1.at || ($0.at == $1.at && $0.action == .off) })   // a tie: on
        else { return decision }
        let late = now.timeIntervalSince(latest.at)
        if latest.action == .off ? (late <= timerLateBy) : (late < turnOnLateBy) {
            decision.send = latest.action
            decision.scheduledFor = latest.at
        }
        return decision
    }

    /// Right after Hammer starts the lights aren't known yet: a due command waits for
    /// the first scan, and for your lights to show up, but not more than 2 minutes.
    static let waitForLights: TimeInterval = 120
    static func shouldWait(scanned: Bool, haveLights: Bool, dueSince: Date, now: Date) -> Bool {
        (!scanned || !haveLights) && now.timeIntervalSince(dueSince) < waitForLights
    }

    /// Keep the Mac from idle sleep this long before a Turn On (it may have just woken for it).
    static let holdBefore: TimeInterval = 120
    static func turnOnSoon(_ turnOnAt: Date?, now: Date) -> Bool {
        guard let at = turnOnAt else { return false }
        let left = at.timeIntervalSince(now)
        return left >= 0 && left <= holdBefore
    }
}

/// A scheduled on or off on its way: the Mac stays awake until every light has taken
/// it or given up, at most `keepFor` (a bulb gets 5 minutes to free up).
struct ScheduledDelivery {
    private(set) var waiting: Set<String> = []
    private(set) var until: Date? = nil

    func holding(now: Date) -> Bool {
        guard let until, !waiting.isEmpty else { return false }
        return now < until
    }

    mutating func start(_ ids: [String], now: Date, keepFor: TimeInterval = LightSchedule.keepFor + 10) {
        waiting.formUnion(ids)
        until = max(until ?? now, now.addingTimeInterval(keepFor))
    }

    /// A light took it, or gave up on it.
    mutating func finished(_ id: String) {
        waiting.remove(id)
        if waiting.isEmpty { until = nil }
    }

    mutating func expire(now: Date) {
        guard let until, now >= until else { return }
        waiting = []
        self.until = nil
    }
}

enum TurnOnClock {
    /// The first time after `now` that the clock shows hour:minute. On the day the
    /// clocks go forward past it, the moment they jump.
    static func next(hour: Int, minute: Int, after now: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                          matchingPolicy: .nextTime)
    }

    /// After a daily Turn On came due at `due`: the same time on a later day (and after
    /// `now`). Never the same day twice, as when the clocks go back and 1:30 comes round again.
    static func following(_ due: Date, hour: Int, minute: Int, now: Date, calendar: Calendar) -> Date? {
        // (Where the clocks jump at midnight, a day can start at 1:00; the next one still starts at 0:00.)
        guard let later = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: due)) else { return nil }
        let nextDay = calendar.startOfDay(for: later)
        return next(hour: hour, minute: minute, after: max(now, nextDay.addingTimeInterval(-1)), calendar: calendar)
    }
}

// MARK: - Waking the Mac for Turn On At (pmset)

enum MacWake {
    /// A wake Hammer asked macOS for, saved so it can cancel exactly that one later.
    enum Event: Equatable {
        case daily(String)          // "HH:mm:ss", every day (pmset repeat)
        case once(String)           // "MM/dd/yy HH:mm:ss" (pmset schedule)

        var saved: String {
            switch self {
            case .daily(let time): return "daily \(time)"
            case .once(let stamp): return "once \(stamp)"
            }
        }

        /// Only a well-formed saved value comes back; anything else is nil (and never
        /// reaches pmset).
        init?(saved: String) {
            if saved.hasPrefix("daily "), case let time = String(saved.dropFirst(6)), MacWake.isTime(time) {
                self = .daily(time)
            } else if saved.hasPrefix("once "), case let stamp = String(saved.dropFirst(5)), MacWake.isStamp(stamp) {
                self = .once(stamp)
            } else {
                return nil
            }
        }

        var isValid: Bool {
            switch self {
            case .daily(let time): return MacWake.isTime(time)
            case .once(let stamp): return MacWake.isStamp(stamp)
            }
        }
    }

    static let timePattern = "([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]"
    static let stampPattern = "(0[1-9]|1[0-2])/(0[1-9]|[12][0-9]|3[01])/[0-9]{2} " + timePattern

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: "^(" + pattern + ")\\z", options: .regularExpression) != nil     // \z: not even a newline after
    }

    /// "06:59:00"
    static func isTime(_ text: String) -> Bool { matches(text, timePattern) }
    /// "11/01/26 06:59:00"
    static func isStamp(_ text: String) -> Bool { matches(text, stampPattern) }

    static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// The wake a minute before `date`.
    static func event(before date: Date, everyDay: Bool, timeZone: TimeZone = .current) -> Event {
        let wakeAt = date.addingTimeInterval(-60)
        return everyDay ? .daily(formatter("HH:mm:ss", timeZone).string(from: wakeAt))
                        : .once(formatter("MM/dd/yy HH:mm:ss", timeZone).string(from: wakeAt))
    }

    /// The lines under "Repeating power events:" in `pmset -g sched`.
    static func repeating(in schedule: String) -> [String] {
        var lines: [String] = [], inside = false
        for line in schedule.components(separatedBy: .newlines) {
            if line.lowercased().hasPrefix("repeating power events") { inside = true; continue }
            guard inside else { continue }
            guard line.first == " " || line.first == "\t" else { if !line.isEmpty { inside = false }; continue }
            let event = line.trimmingCharacters(in: .whitespaces)
            if !event.isEmpty { lines.append(event) }
        }
        return lines
    }

    /// Whether a repeating line ("wakepoweron at 6:59PM every day") is a wake at `time`
    /// ("18:59:00"). Anything Hammer can't read for certain (a malformed `time`, a line
    /// with no time) isn't, so Hammer never cancels or replaces a schedule it can't be
    /// sure is its own.
    static func isWake(_ line: String, at time: String) -> Bool {
        guard isTime(time), line.lowercased().contains("wake") else { return false }
        let wanted = time.split(separator: ":").compactMap { Int($0) }
        guard wanted.count == 3,
              let range = line.range(of: "[0-9]{1,2}:[0-9]{2}(:[0-9]{2})? ?([AaPp][Mm])?", options: .regularExpression)
        else { return false }
        let found = line[range].lowercased()
        let numbers = found.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2 else { return false }
        var hour = numbers[0]
        if found.hasSuffix("am") || found.hasSuffix("pm") {
            guard (1...12).contains(hour) else { return false }
            hour = hour % 12 + (found.hasSuffix("pm") ? 12 : 0)      // 12:05AM is 0:05, 12:05PM is 12:05
        }
        return hour == wanted[0] && numbers[1] == wanted[1]
    }

    struct Plan: Equatable {
        var commands: [String] = []     // to run as one administrator command, joined with " && "
        var result: Event? = nil        // what Hammer has set once they've run
        var blocked = false             // a daily wake was wanted, but the Mac has another repeating schedule
    }

    /// How to get from the wake Hammer set before (`current`) to the one wanted now.
    /// - A one-time wake is cancelled by its exact date.
    /// - `pmset repeat cancel` clears the Mac's whole repeating schedule, not just
    ///   Hammer's wake, so it's only used while that schedule is Hammer's wake alone.
    /// - Likewise `pmset repeat wake` replaces the whole repeating schedule, so a daily
    ///   wake is only set when there's no other repeating event; otherwise it's `blocked`.
    /// - A malformed event (not from Hammer) is treated as none.
    static func plan(current: Event?, wanted: Event?, schedule: String, now: Date,
                     timeZone: TimeZone = .current) -> Plan {
        let current = current?.isValid == true ? current : nil
        let wanted = wanted?.isValid == true ? wanted : nil
        let repeats = repeating(in: schedule)
        var ownsRepeat = false
        if case .daily(let time)? = current { ownsRepeat = repeats.count == 1 && isWake(repeats[0], at: time) }
        if wanted == current {
            var stillSet = true
            if case .daily? = current { stillSet = ownsRepeat }     // gone or changed since: set it again
            if stillSet { return Plan(result: current) }
        }

        var plan = Plan()
        switch current {
        case .once(let stamp)?:
            if let at = formatter("MM/dd/yy HH:mm:ss", timeZone).date(from: stamp), at > now {
                plan.commands.append("/usr/bin/pmset schedule cancel wake '\(stamp)' || true")
            }
        case .daily?:
            var replacing = false
            if case .daily? = wanted { replacing = true }
            // `repeat cancel` is global: only while the repeating schedule is Hammer's wake alone.
            if ownsRepeat && !replacing { plan.commands.append("/usr/bin/pmset repeat cancel") }
        case nil:
            break
        }
        switch wanted {
        case .daily(let time)?:
            if repeats.isEmpty || ownsRepeat {
                plan.commands.append("/usr/bin/pmset repeat wake MTWRFSU \(time)")
                plan.result = wanted
            } else {
                plan.blocked = true
            }
        case .once(let stamp)?:
            plan.commands.append("/usr/bin/pmset schedule wake '\(stamp)'")
            plan.result = wanted
        case nil:
            break
        }
        return plan
    }

    /// The only commands that ever run as administrator, word for word.
    static let allowed = [
        "/usr/bin/pmset repeat cancel",
        "/usr/bin/pmset repeat wake MTWRFSU " + timePattern,
        "/usr/bin/pmset schedule wake '" + stampPattern + "'",
        "/usr/bin/pmset schedule cancel wake '" + stampPattern + "' \\|\\| true",
    ]

    /// `text` as an AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The AppleScript for osascript that runs `commands` as administrator, with
    /// macOS's password prompt saying why. Nil if any command isn't one of `allowed`.
    static func adminScript(_ commands: [String], wakes: Bool) -> String? {
        guard !commands.isEmpty,
              commands.allSatisfy({ command in allowed.contains { matches(command, $0) } }) else { return nil }
        let why = wakes ? "Hammer needs your password to wake your Mac for Turn On At."
                        : "Hammer needs your password to stop waking your Mac for Turn On At."
        return "do shell script \(quoted(commands.joined(separator: " && "))) with prompt \(quoted(why))"
            + " with administrator privileges"
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
///   version  the newest version, once it's known
///   message  a short line for the menu ("Up to date")
///   detail   a sentence for the notification
struct UpdateStatus: Equatable {
    var state: String
    var time: Date
    var version = ""
    var message: String
    var detail: String

    init(state: String, time: Date, version: String = "", message: String, detail: String) {
        self.state = state
        self.time = time
        self.version = version
        self.message = message
        self.detail = detail
    }

    static func parse(_ text: String) -> UpdateStatus? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        guard let state = fields["state"], !state.isEmpty,
              let seconds = fields["time"].flatMap(TimeInterval.init) else { return nil }
        return UpdateStatus(state: state, time: Date(timeIntervalSince1970: seconds), version: fields["version"] ?? "",
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
    /// With the version: the same problem with a newer version is news again.
    var noticeKey: String { state + "|" + version + "|" + message }
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
