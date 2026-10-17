// Monitor.swift — talking to the external monitor over DDC/CI (VESA MCCS), and
// working out why it isn't answering when it doesn't. Foundation only, so all
// of it is tested on any machine (Tests/main.swift). The few calls into macOS
// that find the monitor and move the bytes are in MonitorMac.swift.
//
// How a message travels on an Apple Silicon Mac: macOS lists one "DCPAVServiceProxy"
// per display connection. Hammer hands it bytes for I²C address 0x37 (the
// monitor), and the Mac's display chip sends them over the cable. The built-in
// HDMI port of M1-era Macs goes through a converter chip (MCDP29xx) that only
// passes DDC on address 0xB7 instead.
//
// Checked against the tools known to work on Apple Silicon: m1ddc, MonitorControl
// and BetterDisplay's AppleSiliconDDC library.

import Foundation

// MARK: - Messages

enum DDCPacket {
    /// Every "set" in those tools is seeded with both bus addresses: the monitor's
    /// (0x37 << 1 = 0x6E) and the Mac's (0x51).
    static let writeSeed: UInt8 = 0x6E ^ 0x51

    /// For "get", all three seed with 0x6E alone, and that's what monitors have
    /// been tested against most. MCCS on paper includes 0x51 here too, so that's
    /// the second choice.
    static let readSeeds: [UInt8] = [0x6E, 0x6E ^ 0x51]

    static func checksum(_ bytes: ArraySlice<UInt8>, seed: UInt8) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    /// "Set VCP Feature": 0x84 = four bytes follow, 0x03 = set.
    static func set(code: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(packet[0..<5], seed: writeSeed)
        return packet
    }

    /// "Get VCP Feature": 0x82 = two bytes follow, 0x01 = get.
    static func get(code: UInt8, seed: UInt8 = readSeeds[0]) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, code, 0]
        packet[3] = checksum(packet[0..<3], seed: seed)
        return packet
    }

    /// The monitor's answer: 6E 88 02 result code type maxHi maxLo curHi curLo checksum,
    /// with the checksum seeded with 0x50.
    static func parseReply(_ reply: [UInt8], code: UInt8) -> DDCReply {
        if reply.isEmpty || reply.allSatisfy({ $0 == 0x00 }) || reply.allSatisfy({ $0 == 0xFF }) {
            return .nothing
        }
        // "Null message" (6E 80 BE): the monitor heard us but has nothing to say yet.
        if reply.count >= 2, reply[0] == 0x6E, reply[1] == 0x80 { return .busy }
        guard reply.count >= 11, reply[2] == 0x02, reply[4] == code else { return .garbage }

        let checksumOK = checksum(reply[0..<10], seed: 0x50) == reply[10]
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        switch reply[3] {
        case 0x00 where checksumOK:
            return .value(current: current, max: max)
        case 0x00 where reply[1] == 0x88:
            // Right shape, wrong checksum. m1ddc doesn't check at all, so some
            // monitors may get this wrong; it's used only if no clean answer comes.
            return .badChecksum(current: current, max: max)
        case 0x01 where checksumOK:
            return .unsupported
        default:
            return .garbage
        }
    }
}

enum DDCReply: Equatable {
    case value(current: UInt16, max: UInt16)
    case badChecksum(current: UInt16, max: UInt16)
    case unsupported        // the monitor says it has no such setting
    case busy               // heard, nothing to say yet
    case nothing            // silence: all zeros or all ones
    case garbage
}

enum DDCCode {
    static let brightness: UInt8 = 0x10
    static let contrast: UInt8 = 0x12
    static let volume: UInt8 = 0x62
    static let named: [String: UInt8] = ["brightness": brightness, "contrast": contrast, "volume": volume]

    /// "brightness", "10", "0x10" → 0x10.
    static func parse(_ text: String) -> UInt8? {
        let lower = text.lowercased()
        if let code = named[lower] { return code }
        let hex = lower.hasPrefix("0x") ? String(lower.dropFirst(2)) : lower
        return hex.isEmpty ? nil : UInt8(hex, radix: 16)
    }
}

// MARK: - Talking to one connection

/// Moves bytes over one display connection. On the Mac it's IOAVService;
/// tests use stand-in monitors. Statuses are IOReturn: 0 means sent.
protocol DDCBus: AnyObject {
    func write(chip: UInt32, offset: UInt32, _ bytes: [UInt8]) -> Int32
    func read(chip: UInt32, offset: UInt32, count: Int) -> (status: Int32, bytes: [UInt8])
}

/// One combination of address and request details. Monitors and ports differ
/// in which they answer, so Hammer tries them in order and remembers what worked.
struct DDCWay: Equatable, CustomStringConvertible {
    static let monitorChip: UInt32 = 0x37
    static let hdmiConverterChip: UInt32 = 0xB7      // M1-era built-in HDMI ports (MCDP29xx)
    static let hostAddress: UInt32 = 0x51

    var chip: UInt32
    var readSeed: UInt8 = DDCPacket.readSeeds[0]
    var readOffset: UInt32 = hostAddress           // m1ddc and AppleSiliconDDC; MonitorControl reads at 0

    /// The ways to try on a chip, most widely used first.
    static func all(chip: UInt32) -> [DDCWay] {
        [DDCWay(chip: chip),
         DDCWay(chip: chip, readSeed: DDCPacket.readSeeds[1]),
         DDCWay(chip: chip, readOffset: 0)]
    }

    var description: String {
        String(format: "address %02X, checksum %02X, read at %02X", chip, UInt32(readSeed), readOffset)
    }
}

struct DDCTiming {
    var beforeWrite: UInt32 = 10_000     // µs; the same as the reference tools
    var beforeRead: UInt32 = 50_000      // DDC/CI gives the monitor 40 ms to prepare an answer
    var betweenTries: UInt32 = 20_000
    var writeCycles = 2                  // many monitors miss the odd message, so each is sent twice
    var triesPerWay = 2
    var triesOnKnownWay = 3
}

/// What one read found out.
struct DDCRead: Equatable {
    enum Answer: Equatable {
        case value(current: UInt16, max: UInt16)
        case unsupported
        case none
    }
    var answer: Answer = .none
    var way: DDCWay?                 // the way that got the answer
    var checksumOK = true            // false: only a reply with a wrong checksum came
    var sent = false                 // at least one request went out without an error
    var sendError: Int32?            // the last error sending, if any
    var readError: Int32?            // the last error reading, if any
    var lastReply: [UInt8]?          // the last bytes read that weren't an answer
    var busy = false                 // the monitor said "nothing yet" at least once
    var interrupted = false          // stopped early (a slider moved), so this says nothing
    var tries = 0

    var answered: Bool { answer != .none }
    var reading: (current: UInt16, max: UInt16)? {
        if case let .value(current, max) = answer { return (current, max) }
        return nil
    }
}

/// One display connection: sends settings and reads them back.
/// Not thread-safe: use each link from one queue (the app's monitor queue).
final class DDCLink: @unchecked Sendable {
    let bus: DDCBus
    let ways: [DDCWay]
    var timing: DDCTiming
    private(set) var knownWay: DDCWay?      // the way the monitor last answered on
    private let sleep: (UInt32) -> Void

    init(bus: DDCBus, ways: [DDCWay], timing: DDCTiming = DDCTiming(),
         sleep: @escaping (UInt32) -> Void = { usleep($0) }) {
        self.bus = bus
        self.ways = ways.isEmpty ? DDCWay.all(chip: DDCWay.monitorChip) : ways
        self.timing = timing
        self.sleep = sleep
    }

    /// Where settings go: where the monitor last answered; until then, every
    /// address this connection might use (a wrong one is ignored or refused).
    var writeChips: [UInt32] {
        if let known = knownWay { return [known.chip] }
        var chips: [UInt32] = []
        for way in ways where !chips.contains(way.chip) { chips.append(way.chip) }
        return chips
    }

    /// Sends a setting. Returns 0 if it went out, or the error.
    /// Going out doesn't prove the monitor took it; only a read can tell.
    @discardableResult
    func write(code: UInt8, value: UInt16) -> Int32 {
        let packet = DDCPacket.set(code: code, value: value)
        var lastError: Int32 = -1
        var sent = false
        for chip in writeChips {
            for _ in 0..<max(1, timing.writeCycles) {
                sleep(timing.beforeWrite)
                let status = bus.write(chip: chip, offset: DDCWay.hostAddress, packet)
                if status == 0 { sent = true } else { lastError = status }
            }
        }
        return sent ? 0 : lastError
    }

    /// Asks for a setting, trying each way until the monitor answers.
    /// `stop` is checked between tries: reads give way to a slider being moved.
    func read(code: UInt8, stop: () -> Bool = { false }) -> DDCRead {
        var result = DDCRead()
        var order = ways
        if let known = knownWay { order = [known] + ways.filter { $0 != known } }
        var refusedChips: [UInt32] = []
        var fallback: (way: DDCWay, current: UInt16, max: UInt16)?

        for way in order where !refusedChips.contains(way.chip) {
            let tries = way == knownWay ? timing.triesOnKnownWay : timing.triesPerWay
            var sentOnThisChip = false
            for attempt in 0..<max(1, tries) {
                if result.tries > 0 && stop() {
                    result.interrupted = true
                    return result
                }
                if attempt > 0 || result.tries > 0 { sleep(timing.betweenTries) }
                result.tries += 1
                let request = DDCPacket.get(code: code, seed: way.readSeed)
                var sent = false
                for _ in 0..<max(1, timing.writeCycles) {
                    sleep(timing.beforeWrite)
                    let status = bus.write(chip: way.chip, offset: DDCWay.hostAddress, request)
                    if status == 0 { sent = true } else { result.sendError = status }
                }
                guard sent else { continue }
                sentOnThisChip = true
                result.sent = true

                sleep(timing.beforeRead)
                let (status, bytes) = bus.read(chip: way.chip, offset: way.readOffset, count: 11)
                guard status == 0 else { result.readError = status; continue }
                switch DDCPacket.parseReply(bytes, code: code) {
                case let .value(current, max):
                    result.answer = .value(current: current, max: max)
                    result.way = way
                    result.checksumOK = true
                    knownWay = way
                    return result
                case .unsupported:
                    result.answer = .unsupported
                    result.way = way
                    knownWay = way
                    return result
                case let .badChecksum(current, max):
                    if fallback == nil { fallback = (way, current, max) }
                    result.lastReply = bytes
                case .busy:
                    result.busy = true
                    result.lastReply = bytes
                case .nothing, .garbage:
                    result.lastReply = bytes
                }
            }
            // Every request on this chip was refused: other ways on it won't do better.
            if !sentOnThisChip { refusedChips.append(way.chip) }
        }

        if let fallback {
            result.answer = .value(current: fallback.current, max: fallback.max)
            result.way = fallback.way
            result.checksumOK = false
            knownWay = fallback.way
        }
        return result
    }
}

// MARK: - Finding the monitor

/// The registry entries that matter, in the order macOS lists them: display
/// framebuffers, and the DDC connection ("DCPAVServiceProxy") that follows each.
struct RegistryEntry: Equatable {
    var id: UInt64
    var name: String
    var isFramebuffer = false
    var path = ""
    // Connections:
    var location: String?            // "External" or "Embedded"
    var provider: String?            // the parent's EPICProviderClass
    // Framebuffers:
    var productName: String?         // from the EDID, e.g. "DELL U3818DW"
    var hasDisplay = false           // a monitor is plugged in here
    var transport: String?           // e.g. "DP → HDMI"

    var isConnection: Bool { name == "DCPAVServiceProxy" }
}

/// A screen macOS shows.
struct MonitorScreen: Equatable {
    var id: UInt32
    var name: String
    var builtIn: Bool
    var framebuffer: UInt64?         // registry ID of the framebuffer it's on
    var direct: Bool?                // false: DisplayLink, AirPlay, Sidecar (no framebuffer); nil: unknown
}

/// One external DDC connection.
struct MonitorPort: Equatable {
    var connection: UInt64           // registry ID of its DCPAVServiceProxy
    var framebuffer: UInt64?
    var name: String?                // the monitor plugged in here, if any
    var attached: Bool               // a monitor is plugged in here
    var throughHDMIConverter: Bool
    var transport: String?
    var label: String?               // e.g. "dcpext0"
    var isDefault = false            // macOS's default connection (IOAVServiceCreate), as plain m1ddc uses

    /// m1ddc's last resort: the connection macOS picks by itself.
    static let macDefault = MonitorPort(connection: 0, framebuffer: nil, name: nil, attached: false,
                                        throughHDMIConverter: false, transport: nil,
                                        label: "macOS default connection", isDefault: true)

    var ways: [DDCWay] {
        throughHDMIConverter
            ? DDCWay.all(chip: DDCWay.hdmiConverterChip) + DDCWay.all(chip: DDCWay.monitorChip)
            : DDCWay.all(chip: DDCWay.monitorChip)
    }
    var looksLikeHDMI: Bool {
        throughHDMIConverter || (transport?.uppercased().contains("HDMI") ?? false)
    }
}

enum MonitorDiscovery {
    /// Each external connection, paired with the framebuffer listed just before it,
    /// the way m1ddc and AppleSiliconDDC pair them. Ports with a monitor come first.
    /// Which ports have a monitor: the screens macOS links to framebuffers decide,
    /// as in m1ddc. Only if it links none does the EDID left on a framebuffer count
    /// (it may still be there after the monitor is unplugged).
    static func ports(in entries: [RegistryEntry], screens: [MonitorScreen]) -> [MonitorPort] {
        let linked = screens.contains { !$0.builtIn && $0.framebuffer != nil }
        var ports: [MonitorPort] = []
        var framebuffer: RegistryEntry?
        for entry in entries {
            if entry.isFramebuffer {
                framebuffer = entry
                continue
            }
            guard entry.isConnection, entry.location == "External" else { continue }
            var screen = framebuffer.flatMap { fb in screens.first { $0.framebuffer == fb.id } }
            if screen?.builtIn == true {     // never pair an external connection with the built-in screen
                screen = nil
                framebuffer = nil
            }
            ports.append(MonitorPort(
                connection: entry.id,
                framebuffer: framebuffer?.id,
                name: screen?.name ?? framebuffer?.productName,
                attached: screen != nil || (!linked && (framebuffer?.hasDisplay ?? false)),
                throughHDMIConverter: entry.provider == "AppleDCPMCDP29XX",
                transport: framebuffer?.transport,
                label: shortLabel(entry.path)))
            framebuffer = nil                // one connection per framebuffer
        }
        return ports.filter { $0.attached } + ports.filter { !$0.attached }
    }

    /// "IOService:/AppleARMPE/arm-io@10F00000/AppleT600xIO/dcpext0@…/…" → "dcpext0".
    static func shortLabel(_ path: String) -> String? {
        for part in path.split(separator: "/") {
            let name = part.split(separator: "@").first.map(String.init) ?? ""
            if name.lowercased().hasPrefix("dcp") { return name }
        }
        return nil
    }
}

/// The external monitors Hammer can reach, and what it has learned about each.
/// Not thread-safe: the app uses it from its monitor queue only.
final class MonitorSet: @unchecked Sendable {
    final class Member: @unchecked Sendable {
        let port: MonitorPort
        let link: DDCLink
        var answers: Bool?           // gave a value when last asked; nil until asked
        init(port: MonitorPort, link: DDCLink) { self.port = port; self.link = link }
    }

    let members: [Member]
    private(set) var lastReadInterrupted = false
    init(_ members: [Member]) { self.members = members }

    /// Likeliest first: those that answer, then ports with a monitor, the rest,
    /// and macOS's default connection last.
    var ordered: [Member] {
        let answering = members.filter { $0.answers == true }
        let others = members.filter { $0.answers != true }
        return answering
            + others.filter { $0.port.attached && !$0.port.isDefault }
            + others.filter { !$0.port.attached && !$0.port.isDefault }
            + others.filter { $0.port.isDefault }
    }

    /// Where settings go: the monitors that answer. Until one does, every
    /// connection, as Hammer always did (a connection without a monitor ignores it).
    var targets: [Member] {
        let answering = members.filter { $0.answers == true }
        return answering.isEmpty ? ordered : answering
    }

    /// Asks each connection in turn until one gives a value.
    func read(code: UInt8, stop: () -> Bool = { false })
        -> (reading: (current: UInt16, max: UInt16), member: Member)? {
        lastReadInterrupted = false
        for (index, member) in ordered.enumerated() {
            if index > 0 && stop() {
                lastReadInterrupted = true
                return nil
            }
            let read = member.link.read(code: code, stop: stop)
            if read.interrupted {
                lastReadInterrupted = true
                return nil
            }
            member.answers = read.reading != nil
            if let reading = read.reading { return (reading, member) }
        }
        return nil
    }

    /// Sends a setting to the targets. False if none of them took it.
    @discardableResult
    func write(code: UInt8, value: UInt16) -> Bool {
        var sent = false
        for member in targets {
            if member.link.write(code: code, value: value) == 0 { sent = true }
        }
        return sent
    }

    var anyAnswers: Bool { members.contains { $0.answers == true } }
}

// MARK: - Monitor check

/// Tests each step from "does macOS see the monitor" to "did the brightness
/// actually change", and says what to do about the first one that fails.
struct MonitorCheck {
    struct Mac: Equatable {
        var model = ""               // e.g. "Mac14,6"
        var chip = ""                // e.g. "Apple M2 Max"
        var system = ""              // e.g. "Version 15.1 (Build 24B83)"
    }

    /// Hammer moves brightness by a fifth of its range, reads it back, and puts it back.
    enum Change: Equatable {
        case confirmed(from: UInt16, to: UInt16)
        case unconfirmed(from: UInt16, to: UInt16, readBack: UInt16)   // read back unchanged or different
        case noReadBack(from: UInt16, to: UInt16)                      // went quiet after the change
    }

    struct PortResult {
        var port: MonitorPort
        var noService = false        // macOS gave no way to talk to it
        var brightness = DDCRead()
        var contrast: DDCRead?
        var change: Change?
        var restored: Bool?          // brightness read back as it was after the test
    }

    enum Verdict: Equatable {
        case working
        case unsure                  // answered, then went quiet after the change
        case ignoresChanges          // answers, but brightness didn't move
        case noBrightness            // answers, but says it has no brightness setting
        case noMonitor               // macOS sees no external monitor
        case notDirect               // DisplayLink, AirPlay or Sidecar
        case notFound                // macOS shows it, Hammer can't find its connection
        case cantSend                // macOS refused every message
        case noAnswer                // sent, but the monitor never answered
    }

    var mac = Mac()
    var screens: [MonitorScreen] = []
    var ports: [PortResult] = []
    var otherConnections: [String] = []   // non-external connections, for the report

    /// Runs the check. `bus` gives the connection for a registry ID (nil if macOS gives none);
    /// `defaultBus` is macOS's default connection, tried last if no port answers.
    static func run(mac: Mac, screens: [MonitorScreen], entries: [RegistryEntry],
                    bus: (UInt64) -> DDCBus?, defaultBus: DDCBus? = nil, timing: DDCTiming = DDCTiming(),
                    sleep: @escaping (UInt32) -> Void = { usleep($0) }) -> MonitorCheck {
        var check = MonitorCheck(mac: mac, screens: screens)
        check.otherConnections = entries.filter { $0.isConnection && $0.location != "External" }.map {
            "\(MonitorDiscovery.shortLabel($0.path) ?? $0.name) (\($0.location ?? "no location"))"
        }
        for port in MonitorDiscovery.ports(in: entries, screens: screens) {
            guard let bus = bus(port.connection) else {
                check.ports.append(PortResult(port: port, noService: true))
                continue
            }
            check.ports.append(test(port, bus: bus, timing: timing, sleep: sleep))
        }
        if let defaultBus, !check.ports.contains(where: { $0.brightness.reading != nil }) {
            check.ports.append(test(.macDefault, bus: defaultBus, timing: timing, sleep: sleep))
        }
        return check
    }

    private static func test(_ port: MonitorPort, bus: DDCBus, timing: DDCTiming,
                             sleep: @escaping (UInt32) -> Void) -> PortResult {
        var result = PortResult(port: port)
        let link = DDCLink(bus: bus, ways: port.ways, timing: timing, sleep: sleep)
        result.brightness = link.read(code: DDCCode.brightness)
        guard result.brightness.answered else { return result }
        result.contrast = link.read(code: DDCCode.contrast)

        // Only with a clean reading: it's the value put back afterwards.
        guard case let (current, max)? = result.brightness.reading, max > 0, result.brightness.checksumOK
        else { return result }
        let step = Swift.max(UInt16(1), max / 5)
        let target = current >= max / 2 ? current - Swift.min(step, current) : Swift.min(max, current + step)
        guard target != current else { return result }
        link.write(code: DDCCode.brightness, value: target)
        sleep(500_000)
        let readBack = link.read(code: DDCCode.brightness).reading?.current

        // Put it back, and make sure.
        for _ in 0..<2 {
            link.write(code: DDCCode.brightness, value: current)
            sleep(300_000)
            let now = link.read(code: DDCCode.brightness).reading?.current
            result.restored = now.map { $0 == current }      // nil: it didn't say
            if now == current || now == nil { break }
        }
        if let readBack {
            result.change = readBack.distance(to: target).magnitude <= 2
                ? .confirmed(from: current, to: target)
                : .unconfirmed(from: current, to: target, readBack: readBack)
        } else {
            result.change = .noReadBack(from: current, to: target)
        }
        return result
    }

    var externalScreens: [MonitorScreen] { screens.filter { !$0.builtIn } }

    var verdict: Verdict {
        let valued = ports.filter { $0.brightness.reading != nil }
        if !valued.isEmpty {
            func has(_ test: (Change) -> Bool) -> Bool { valued.contains { $0.change.map(test) ?? false } }
            if has({ if case .confirmed = $0 { return true }; return false }) { return .working }
            if valued.contains(where: { $0.change == nil }) { return .working }    // nothing to test with
            if has({ if case .noReadBack = $0 { return true }; return false }) { return .unsure }
            return .ignoresChanges
        }
        if ports.contains(where: { $0.brightness.answer == .unsupported }) { return .noBrightness }

        let attached = ports.filter { $0.port.attached }
        if attached.isEmpty {
            if externalScreens.isEmpty { return .noMonitor }
            if externalScreens.allSatisfy({ $0.direct == false }) { return .notDirect }
        }
        // Nothing known to have a monitor: every connection is a candidate.
        let candidates = attached.isEmpty ? ports : attached
        if candidates.isEmpty { return .notFound }
        if candidates.allSatisfy({ $0.noService || !$0.brightness.sent }) { return .cantSend }
        return .noAnswer
    }

    /// The monitor's name for messages: "the DELL U3818DW", or "the monitor".
    var monitorName: String {
        let name = ports.first(where: { $0.port.attached && $0.port.name != nil })?.port.name
            ?? externalScreens.first(where: { $0.direct != false })?.name
            ?? externalScreens.first?.name
        return name.map { "the \($0)" } ?? "the monitor"
    }

    var text: String {
        var lines = ["Hammer monitor check", ""]
        lines.append("Mac: " + [mac.model, mac.chip, mac.system.isEmpty ? "" : "macOS \(mac.system)"]
            .filter { !$0.isEmpty }.joined(separator: " · "))
        let screenList = screens.map { screen -> String in
            if screen.builtIn { return "\(screen.name) (built in)" }
            if screen.direct == false { return "\(screen.name) (through DisplayLink, AirPlay or Sidecar)" }
            return screen.name
        }
        lines.append("Screens: " + (screenList.isEmpty ? "none" : screenList.joined(separator: ", ")))
        let external = ports.filter { !$0.port.isDefault }.count
        lines.append("External connections: \(external)"
                     + (otherConnections.isEmpty ? "" : " · also \(otherConnections.joined(separator: ", "))"))

        for result in ports {
            lines.append("")
            let port = result.port
            let title = port.isDefault ? "Tried last" : port.name ?? (port.attached ? "Monitor" : "No monitor seen here")
            let details = [port.label, port.transport, port.throughHDMIConverter ? "HDMI converter" : nil]
                .compactMap { $0 }
            lines.append(title + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"))
            if result.noService {
                lines.append("  macOS gave Hammer no way to talk to it")
                continue
            }
            let b = result.brightness
            lines.append("  Sent: " + (b.sent ? "yes" : "no" + (b.sendError.map { " (error \(Self.hex($0)))" } ?? "")))
            lines.append("  Brightness: " + Self.describe(b))
            if let contrast = result.contrast { lines.append("  Contrast: " + Self.describe(contrast)) }
            let back: String
            switch result.restored {
            case true?: back = ", put back"
            case false?: back = ", put back (but it reads differently now)"
            case nil: back = ", put back (couldn't confirm)"
            }
            switch result.change {
            case let .confirmed(from, to)?:
                lines.append("  Change test: \(from) → \(to), read back \(to)\(back) ✓")
            case let .unconfirmed(from, to, readBack)?:
                lines.append("  Change test: \(from) → \(to), read back \(readBack)\(back) ✗")
            case let .noReadBack(from, to)?:
                lines.append("  Change test: \(from) → \(to), then it didn't answer\(back) ?")
            case nil:
                break
            }
            if let way = b.way { lines.append("  Answered on: \(way)") }
            if !b.answered, let reply = b.lastReply {
                lines.append("  Last reply: " + reply.map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            if !b.answered, let error = b.readError { lines.append("  Read error: \(Self.hex(error))") }
        }

        lines.append("")
        lines.append(contentsOf: advice)
        return lines.joined(separator: "\n")
    }

    /// What it means, and what to do.
    var advice: [String] {
        let name = monitorName
        let Name = name.prefix(1).uppercased() + name.dropFirst()
        let hdmi = ports.contains { $0.port.attached && $0.port.looksLikeHDMI }
        switch verdict {
        case .working:
            return ["Result: Working. Hammer can read and change \(name)'s brightness."]
        case .unsure:
            return ["Result: \(Name) answered Hammer, but went quiet after Hammer changed its brightness.",
                    "Did the screen get brighter or dimmer for a moment during the check? If so, it works:",
                    "Hammer's sliders will change it, they just may not always start at the right place."]
        case .ignoresChanges:
            return ["Result: \(Name) answers Hammer, but its brightness didn't change.",
                    "On the monitor, choose Menu → Preset Modes → Standard (some modes lock brightness), then check again."]
        case .noBrightness:
            return ["Result: \(Name) answers Hammer, but says it has no brightness setting the Mac can change.",
                    "On the monitor, choose Menu → Preset Modes → Standard, then check again."]
        case .noMonitor:
            return ["Result: macOS doesn't see an external monitor.",
                    "Check the cable at both ends, and that the monitor is on the right input (Menu → Input Source)."]
        case .notDirect:
            return ["Result: \(Name) is connected through DisplayLink, AirPlay or Sidecar,",
                    "which can't carry brightness control. Plug its USB-C (or DisplayPort) cable straight into the Mac."]
        case .notFound:
            return ["Result: macOS shows \(name), but Hammer can't find the connection it's on.",
                    "Plug its USB-C cable straight into the Mac, then check again.",
                    "If that doesn't help, send this report along."]
        case .cantSend:
            return ["Result: macOS wouldn't let Hammer send anything to \(name).",
                    hdmi ? "This Mac's HDMI port doesn't pass monitor control. Plug the monitor's USB-C (or DisplayPort) cable straight into the Mac instead."
                         : "Plug its USB-C cable straight into the Mac (not through a hub, dock or adapter), then check again."]
        case .noAnswer:
            return ["Result: Hammer sent messages to \(name), but it didn't answer.",
                    "Try these, checking again after each:",
                    "  1. On the monitor: Menu → Others → DDC/CI → On. Then switch it off and on with its power button.",
                    "  2. Plug its USB-C cable straight into the Mac, not through a hub, dock or adapter."
                        + (hdmi ? " Use USB-C rather than HDMI." : ""),
                    "  3. Move Hammer's Brightness slider and watch the screen: some monitors take changes without answering.",
                    "If it still doesn't work, send this report along."]
        }
    }

    static func describe(_ read: DDCRead) -> String {
        switch read.answer {
        case let .value(current, max):
            return "\(current) of \(max)" + (read.checksumOK ? "" : " (reply had a wrong checksum)")
        case .unsupported:
            return "the monitor says it has no such setting"
        case .none:
            if !read.sent { return "not asked (couldn't send)" }
            return "no answer after \(read.tries) tries" + (read.busy ? " (it said it was busy)" : "")
        }
    }

    static func hex(_ status: Int32) -> String { String(format: "%08x", UInt32(bitPattern: status)) }
}

// MARK: - The monitor's part of the menu

struct MonitorMenu: Equatable {
    var title: String?               // shown instead of the sliders
    var sliders = false
    var hints: [String] = []
    var offerCheck = false

    /// `connections`: external DDC connections found; `attached`: of those, with a
    /// monitor seen; `answers`: whether one gave a value when last asked.
    static func make(connections: Int, attached: Int, screens: [MonitorScreen], answers: Bool?) -> MonitorMenu {
        let external = screens.filter { !$0.builtIn }
        let virtualOnly = !external.isEmpty && external.allSatisfy { $0.direct == false }
        if attached == 0 && external.isEmpty {
            return MonitorMenu(title: "Dell not connected",
                               hints: ["Plug it in with USB-C or DisplayPort.",
                                       "Hammer picks it up automatically.",
                                       "Not a DisplayLink dock — those block control."])
        }
        if connections == 0 && virtualOnly {
            return MonitorMenu(title: "Dell connected through DisplayLink or AirPlay",
                               hints: ["Brightness control needs a direct cable:",
                                       "USB-C or DisplayPort straight into the Mac."],
                               offerCheck: true)
        }
        if connections == 0 {
            return MonitorMenu(title: "Can't find the Dell's connection", offerCheck: true)
        }
        var menu = MonitorMenu(sliders: true, offerCheck: true)
        if answers == false { menu.hints.append("The Dell isn't answering Hammer.") }
        if attached == 0 && virtualOnly {
            menu.hints.append("It may be on DisplayLink or AirPlay, which block control.")
        }
        return menu
    }
}

/// When a slider last moved, readable from any queue, so a slow read in the
/// background can stop and let the new setting through.
final class SliderMoves: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast

    func moved(at date: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        last = Swift.max(last, date)
    }

    func movedSince(_ date: Date) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return last > date
    }
}
