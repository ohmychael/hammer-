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
    /// The monitor's EDID as macOS keeps it for this connection, if it gives it.
    func copyEDID() -> [UInt8]?
}

extension DDCBus {
    func copyEDID() -> [UInt8]? { nil }
}

/// The monitor's identity block (EDID): 128 bytes every monitor has, readable at
/// I²C address 0x50 on any display cable.
enum EDID {
    static let chip: UInt32 = 0x50
    static let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]

    /// Right header, and the 128 bytes add up to 0.
    static func isValid(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 128 && Array(bytes.prefix(8)) == header && bytes[0..<128].reduce(UInt8(0), &+) == 0
    }

    enum Input: Equatable { case hdmi, displayPort }

    /// Which of the monitor's inputs this EDID is for. An HDMI input lists HDMI's
    /// vendor block (OUI 00-0C-03, or the HDMI Forum's C4-5D-D8) in its CTA-861
    /// extension; EDID 1.4 can also name the interface in byte 20. nil: can't tell.
    static func input(_ bytes: [UInt8]) -> Input? {
        guard isValid(bytes) else { return nil }
        let version14 = bytes[18] == 1 && bytes[19] >= 4
        let interface = bytes[20] & 0x80 != 0 && version14 ? bytes[20] & 0x0F : 0
        if interface == 0x5 { return .displayPort }
        let extensions = Int(bytes[126])
        for index in stride(from: 1, through: extensions, by: 1) where bytes.count >= (index + 1) * 128 {
            let block = Array(bytes[(index * 128)..<((index + 1) * 128)])
            guard block[0] == 0x02, block[2] >= 4 else { continue }      // CTA-861 extension
            var at = 4
            let end = min(Int(block[2]), 127)
            while at < end {
                let tag = block[at] >> 5, length = Int(block[at] & 0x1F)
                if tag == 3, length >= 3, at + 3 < 128 {
                    let oui = (block[at + 1], block[at + 2], block[at + 3])
                    if oui == (0x03, 0x0C, 0x00) || oui == (0xD8, 0x5D, 0xC4) { return .hdmi }
                }
                at += length + 1
            }
        }
        if interface == 0x2 || interface == 0x3 { return .hdmi }
        return nil
    }

    /// The model name it gives, e.g. "DELL U3818DW". Printable ASCII only (the standard's
    /// character set), so a broken EDID can't put odd characters in the menu or the report.
    static func name(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 128 else { return nil }
        for start in stride(from: 54, through: 108, by: 18)
        where bytes[start] == 0 && bytes[start + 1] == 0 && bytes[start + 3] == 0xFC {
            let text = bytes[(start + 5)..<(start + 18)].prefix { $0 != 0x0A && $0 != 0x00 }
                .filter { (0x20...0x7E).contains($0) }
            let name = String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
        }
        return nil
    }
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
    var slowRead: UInt32 = 150_000       // the last try waits this long, after a single request
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
    var readErrors: [Int32: Int] = [:]   // every read error, and how many times
    var lastReply: [UInt8]?          // the last bytes read that weren't an answer
    var busy = false                 // the monitor said "nothing yet" at least once
    var interrupted = false          // stopped early (a slider moved), so this says nothing
    var slow = false                 // answered only when asked slowly (one request, long wait)
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
    private(set) var slow = false           // it answers only one request with a long wait
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

    /// Asks for a setting, trying each way until the monitor answers. Last, one slow
    /// try per address (a single request, a long wait), for monitors that want that;
    /// if that's what works, it's used from then on.
    /// `stop` is checked between tries: reads give way to a slider being moved.
    func read(code: UInt8, stop: () -> Bool = { false }) -> DDCRead {
        var result = DDCRead()
        var order = ways
        if let known = knownWay { order = [known] + ways.filter { $0 != known } }
        var refusedChips: [UInt32] = []
        var fallback: (way: DDCWay, current: UInt16, max: UInt16, slow: Bool)?
        let cycles = slow ? 1 : timing.writeCycles
        let wait = slow ? timing.slowRead : timing.beforeRead

        for way in order where !refusedChips.contains(way.chip) {
            let tries = way == knownWay ? timing.triesOnKnownWay : timing.triesPerWay
            var sentOnThisChip = false
            for attempt in 0..<max(1, tries) {
                if result.tries > 0 && stop() {
                    result.interrupted = true
                    return result
                }
                if attempt > 0 || result.tries > 0 { sleep(timing.betweenTries) }
                switch ask(way, code: code, cycles: cycles, wait: wait, into: &result) {
                case .notSent:
                    continue
                case .answered:
                    knownWay = way
                    return result
                case let .badChecksum(current, max):
                    sentOnThisChip = true
                    if fallback == nil { fallback = (way, current, max, slow) }
                case .noAnswer:
                    sentOnThisChip = true
                }
            }
            // Every request on this chip was refused: other ways on it won't do better.
            if !sentOnThisChip { refusedChips.append(way.chip) }
        }

        if !slow && result.sent && fallback == nil {
            var chips: [UInt32] = []
            for way in order where !refusedChips.contains(way.chip) && !chips.contains(way.chip) {
                chips.append(way.chip)
                if stop() {
                    result.interrupted = true
                    return result
                }
                sleep(timing.betweenTries)
                if case .answered = ask(way, code: code, cycles: 1, wait: timing.slowRead, into: &result) {
                    knownWay = way
                    slow = true
                    result.slow = true
                    return result
                }
            }
        }

        if let fallback {
            result.answer = .value(current: fallback.current, max: fallback.max)
            result.way = fallback.way
            result.checksumOK = false
            result.slow = fallback.slow
            knownWay = fallback.way
        }
        return result
    }

    private enum Asked { case notSent, answered, badChecksum(UInt16, UInt16), noAnswer }

    /// One try: send the request (`cycles` times), wait, read the answer.
    private func ask(_ way: DDCWay, code: UInt8, cycles: Int, wait: UInt32, into result: inout DDCRead) -> Asked {
        result.tries += 1
        let request = DDCPacket.get(code: code, seed: way.readSeed)
        var sent = false
        for _ in 0..<max(1, cycles) {
            sleep(timing.beforeWrite)
            let status = bus.write(chip: way.chip, offset: DDCWay.hostAddress, request)
            if status == 0 { sent = true } else { result.sendError = status }
        }
        guard sent else { return .notSent }
        result.sent = true

        sleep(wait)
        let (status, bytes) = bus.read(chip: way.chip, offset: way.readOffset, count: 11)
        guard status == 0 else {
            result.readError = status
            result.readErrors[status, default: 0] += 1
            return .noAnswer
        }
        switch DDCPacket.parseReply(bytes, code: code) {
        case let .value(current, max):
            result.answer = .value(current: current, max: max)
            result.way = way
            result.checksumOK = true
            return .answered
        case .unsupported:
            result.answer = .unsupported
            result.way = way
            return .answered
        case let .badChecksum(current, max):
            result.lastReply = bytes
            return .badChecksum(current, max)
        case .busy:
            result.busy = true
            result.lastReply = bytes
            return .noAnswer
        case .nothing, .garbage:
            result.lastReply = bytes
            return .noAnswer
        }
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
    var vendor: UInt32? = nil        // its maker's ID (CGDisplayVendorNumber); nil: unknown

    static let appleVendor: UInt32 = 0x610

    /// An Apple display (Studio Display, Pro Display XDR) on a cable: macOS sets its brightness
    /// itself (keys, Control Center), so Hammer leaves it alone: no DDC, never dimmed in software.
    /// Not a Sidecar iPad or an AirPlay screen, which can report Apple's ID too.
    var brightnessByMacOS: Bool { vendor == Self.appleVendor && direct != false }
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
    var monitorInput: EDID.Input?    // which of the monitor's inputs it's on (from its EDID)

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
    /// The monitor gets HDMI from one of the Mac's USB-C ports: a USB-C to HDMI
    /// cable, adapter or hub (or a USB-C to DisplayPort adapter with a DisplayPort
    /// to HDMI cable) converts it on the way, and most of those drop DDC.
    /// macOS calls such a link DisplayPort, or sometimes HDMI. Newer Macs' own HDMI
    /// ports are called HDMI too, so an HDMI link counts only on Macs whose own HDMI
    /// port (if any) is the M1-era one with the converter Hammer talks through.
    func throughHDMIAdapter(onMac model: String) -> Bool {
        monitorInput == .hdmi && !throughHDMIConverter && (!looksLikeHDMI || Self.hdmiLinkIsAdapter(onMac: model))
    }

    /// Macs with no HDMI port of their own, or only the M1-era one (with the converter):
    /// on these, an HDMI link without the converter can only come from a USB-C port.
    /// A Mac missing from this list just gets the general advice, never a wrong guess.
    static func hdmiLinkIsAdapter(onMac model: String) -> Bool {
        let noHDMIPort: Set<String> = [
            "MacBookPro17,1", "Mac14,7",                      // 13-inch MacBook Pro, M1 and M2
            "Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13",    // MacBook Air, M2 and M3
            "Mac16,12", "Mac16,13",                           // MacBook Air, M4
            "Mac15,4", "Mac15,5", "Mac16,2", "Mac16,3",       // iMac, M3 and M4
        ]
        return model.hasPrefix("MacBookPro18,")               // 14- and 16-inch M1 Pro/Max: HDMI has the converter
            || model.hasPrefix("MacBookAir") || model.hasPrefix("iMac") || noHDMIPort.contains(model)
    }
}

enum MonitorDiscovery {
    /// Each external connection, paired with the framebuffer listed just before it,
    /// the way m1ddc and AppleSiliconDDC pair them. Ports with a monitor come first.
    /// Which ports have a monitor: the screens macOS links to framebuffers decide,
    /// as in m1ddc. Only if it links none does the EDID left on a framebuffer count
    /// (it may still be there after the monitor is unplugged).
    static func ports(in entries: [RegistryEntry], screens: [MonitorScreen]) -> [MonitorPort] {
        let framebuffers = Set(entries.filter { $0.isFramebuffer }.map { $0.id })
        let external = screens.filter { !$0.builtIn }
        let linked = external.filter { $0.framebuffer.map(framebuffers.contains) ?? false }
        // The EDID counts only if Hammer can't tell otherwise: no screen list, or an
        // external screen (not a DisplayLink-style one) that isn't linked to a framebuffer.
        let trustEDID = screens.isEmpty
            || (linked.isEmpty && external.contains { $0.direct != false })
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
                attached: screen != nil || (trustEDID && (framebuffer?.hasDisplay ?? false)),
                throughHDMIConverter: entry.provider == "AppleDCPMCDP29XX",
                transport: framebuffer?.transport,
                label: shortLabel(entry.path)))
            framebuffer = nil                // one connection per framebuffer
        }
        return ports.filter { $0.attached } + ports.filter { !$0.attached }
    }

    /// Whether to also try macOS's default connection: only when a monitor seems
    /// to be plugged in, since without one it may be the built-in screen's.
    static func useDefault(ports: [MonitorPort], screens: [MonitorScreen]) -> Bool {
        ports.contains { $0.attached } || screens.contains { !$0.builtIn && $0.direct != false }
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
    private(set) var lastReadUnsupported = false   // a monitor said it has no such setting
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

    /// Where settings go: the monitors that answer, plus ports where a monitor is
    /// seen (it may take settings without answering). Until one answers, every
    /// connection, as Hammer always did (a connection without a monitor ignores it).
    var targets: [Member] {
        guard members.contains(where: { $0.answers == true }) else { return ordered }
        return ordered.filter { $0.answers == true || ($0.port.attached && !$0.port.isDefault) }
    }

    /// Asks each connection in turn until one gives a value.
    func read(code: UInt8, stop: () -> Bool = { false })
        -> (reading: (current: UInt16, max: UInt16), member: Member)? {
        lastReadInterrupted = false
        lastReadUnsupported = false
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
            if read.answer == .unsupported { lastReadUnsupported = true }
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

    /// Reading the monitor's EDID over the same wire (I²C address 0x50): if even
    /// that fails, nothing can be read over this connection.
    struct EDIDRead: Equatable {
        var status: Int32
        var valid: Bool
    }

    struct PortResult {
        var port: MonitorPort
        var noService = false        // macOS gave no way to talk to it
        var edidName: String?        // the monitor's name from the EDID macOS has for this connection
        var edidOverI2C: EDIDRead?   // tried only if the monitor doesn't answer
        var brightness = DDCRead()
        var contrast: DDCRead?
        var change: Change?
        var restored: Bool?          // brightness read back as it was after the test
    }

    enum Verdict: Equatable {
        case working
        case untested                // answers, but a change couldn't be tested
        case unsure                  // answered, then went quiet after the change
        case ignoresChanges          // answers, but brightness didn't move
        case noBrightness            // answers, but says it has no brightness setting
        case noMonitor               // macOS sees no external monitor
        case notDirect               // DisplayLink, AirPlay or Sidecar
        case notFound                // macOS shows it, Hammer can't find its connection
        case cantSend                // macOS refused every message
        case hdmiAdapter             // no answer, and it's on HDMI through a USB-C adapter
        case noAnswer                // sent, but the monitor never answered
        case macOSLacksCalls         // this macOS doesn't have the private calls Hammer talks through
    }

    /// The private calls Hammer can't reach a monitor without (IOAVServiceCopyEDID only adds detail;
    /// IOAVServiceCreate, macOS's default connection, matters only if no port has a connection).
    static let neededCalls: Set<String> = ["IOAVServiceCreateWithService", "IOAVServiceReadI2C", "IOAVServiceWriteI2C"]

    /// This macOS lacks a call Hammer needs to reach the monitor.
    var lacksCalls: Bool {
        missingCalls.contains(where: Self.neededCalls.contains)
            || (missingCalls.contains("IOAVServiceCreate") && !ports.contains { !$0.port.isDefault && !$0.noService })
    }

    var mac = Mac()
    var screens: [MonitorScreen] = []
    var ports: [PortResult] = []
    var otherConnections: [String] = []   // non-external connections, for the report
    /// What Hammer's dimming in software was doing at the time: the app fills it in
    /// (nil from Terminal, which can't tell).
    var softwareDim: SoftwareDimState?
    var softwareDimLevel = 100            // the Brightness slider's level, while dimming in software
    var missingCalls: [String] = []       // private macOS calls Hammer couldn't find (a later macOS may drop one)

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
        if let defaultBus, !check.ports.contains(where: { $0.brightness.reading != nil }),
           MonitorDiscovery.useDefault(ports: check.ports.map { $0.port }, screens: screens) {
            check.ports.append(test(.macDefault, bus: defaultBus, timing: timing, sleep: sleep))
        }
        return check
    }

    private static func test(_ port: MonitorPort, bus: DDCBus, timing: DDCTiming,
                             sleep: @escaping (UInt32) -> Void) -> PortResult {
        var result = PortResult(port: port)
        let edid = bus.copyEDID()
        result.edidName = edid.flatMap(EDID.name)
        if let edid { result.port.monitorInput = EDID.input(edid) }
        let link = DDCLink(bus: bus, ways: port.ways, timing: timing, sleep: sleep)
        result.brightness = link.read(code: DDCCode.brightness)

        if !result.brightness.answered && result.brightness.sent && !port.throughHDMIConverter {
            // Can anything be read over this connection? Every monitor's ID info (EDID)
            // answers at 0x50: a read, with offset 0 to start at the beginning. Not
            // through the M1 HDMI converter, where 0x50 may not reach the monitor.
            let (status, bytes) = bus.read(chip: EDID.chip, offset: 0, count: 128)
            result.edidOverI2C = EDIDRead(status: status, valid: status == 0 && EDID.isValid(bytes))
        }
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
            result.restored = now.map { close($0, current) }      // nil: it didn't say
            if result.restored != false { break }
        }
        if let readBack {
            result.change = close(readBack, target)
                ? .confirmed(from: current, to: target)
                : .unconfirmed(from: current, to: target, readBack: readBack)
        } else {
            result.change = .noReadBack(from: current, to: target)
        }
        return result
    }

    /// Within 2: some monitors round.
    private static func close(_ a: UInt16, _ b: UInt16) -> Bool { a.distance(to: b).magnitude <= 2 }

    var externalScreens: [MonitorScreen] { screens.filter { !$0.builtIn } }

    /// The connection the result is about: the best one that answered.
    var answering: PortResult? {
        func rank(_ result: PortResult) -> Int {
            switch result.change {
            case .confirmed?: return 0
            case nil: return 1
            case .noReadBack?: return 2
            case .unconfirmed?: return 3
            }
        }
        return ports.filter { $0.brightness.reading != nil }.min { rank($0) < rank($1) }
            ?? ports.first { $0.brightness.answer == .unsupported }
    }

    var verdict: Verdict {
        if let best = answering {
            if best.brightness.answer == .unsupported { return .noBrightness }
            switch best.change {
            case .confirmed?: return .working
            case nil: return .untested
            case .noReadBack?: return .unsure
            case .unconfirmed?: return .ignoresChanges
            }
        }
        let attached = ports.filter { $0.port.attached }
        if attached.isEmpty {
            if externalScreens.isEmpty { return .noMonitor }
            if externalScreens.allSatisfy({ $0.direct == false }) { return .notDirect }
        }
        if lacksCalls { return .macOSLacksCalls }
        // Nothing known to have a monitor: every connection is a candidate.
        let candidates = attached.isEmpty ? ports : attached
        if candidates.allSatisfy({ $0.port.isDefault }) { return .notFound }   // only macOS's guess was left
        if candidates.contains(where: { $0.port.throughHDMIAdapter(onMac: mac.model) }) { return .hdmiAdapter }
        if candidates.allSatisfy({ $0.noService || !$0.brightness.sent }) { return .cantSend }
        return .noAnswer
    }

    /// Whether anything can be read over the monitor's connection (its EDID at
    /// 0x50 came back): nil if that wasn't tried.
    var wireReads: Bool? {
        let probes = ports.filter { $0.port.attached || ports.allSatisfy { !$0.port.attached } }
            .compactMap { $0.edidOverI2C }
        if probes.contains(where: { $0.valid }) { return true }
        if !probes.isEmpty && probes.allSatisfy({ $0.status != 0 }) { return false }
        return nil                   // not tried, or something came back that wasn't an EDID
    }

    /// The monitor's name for messages: "the DELL U3818DW", or "the monitor".
    var monitorName: String {
        let name = answering?.port.name
            ?? ports.first(where: { $0.port.attached && $0.port.name != nil })?.port.name
            ?? externalScreens.first(where: { $0.direct != false })?.name
            ?? externalScreens.first?.name
        return name.map { "the \($0)" } ?? "the monitor"
    }

    /// For the window after the check: what the change test did to the screen.
    var testNote: String? {
        let tested = ports.filter {
            if case .unconfirmed? = $0.change { return false }
            return $0.change != nil
        }
        guard !tested.isEmpty else { return nil }
        if tested.contains(where: { $0.restored == false }) {
            return "Hammer changed the brightness for a moment to test it, but it didn't go back exactly. "
                + "Set it with Hammer's Brightness slider."
        }
        return "Hammer changed the brightness for a moment to test it, and put it back."
    }

    /// The whole report, for Copy Report and Terminal: the result, what to do, then the details.
    var text: String {
        (["Hammer monitor check", "", "Result: " + title] + advice + ["", details]).joined(separator: "\n")
    }

    /// What the check found, step by step: the box in the check's window, under the result and
    /// the advice (which it doesn't repeat).
    var details: String {
        var lines: [String] = []
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
        if !missingCalls.isEmpty { lines.append("Not in this macOS: " + missingCalls.joined(separator: ", ")) }
        if let line = softwareDimLine { lines.append(line) }

        var shown: [[String]] = []
        for result in ports {
            lines.append("")
            let port = result.port
            let title = port.isDefault ? "Tried last" : port.name ?? (port.attached ? "Monitor" : "No monitor seen here")
            let parts = [port.label, port.transport, port.throughHDMIConverter ? "HDMI converter" : nil]
                .compactMap { $0 }
            let heading = title + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
            let body = portLines(result)
            // macOS's default connection is usually one of the ports again: one line if it says the same.
            if port.isDefault && shown.contains(body) {
                lines.append(heading + ": the same as above")
                continue
            }
            shown.append(body)
            lines.append(heading)
            lines.append(contentsOf: body)
        }
        return lines.joined(separator: "\n")
    }

    private func portLines(_ result: PortResult) -> [String] {
        if result.noService { return ["  macOS gave Hammer no way to talk to it"] }
        let port = result.port
        var lines: [String] = []
        if let name = result.edidName {
            let input = port.monitorInput.map { $0 == .hdmi ? ", on its HDMI input" : ", on its DisplayPort/USB-C input" } ?? ""
            lines.append("  Its ID info (EDID), from macOS: \(name)\(input)")
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
        if let way = b.way {
            lines.append("  Answered on: \(way)" + (b.slow ? ", only when asked slowly (one request, 150 ms wait)" : ""))
        }
        if !b.answered, let reply = b.lastReply {
            lines.append("  Last reply: " + reply.map { String(format: "%02X", $0) }.joined(separator: " "))
        }
        if !b.answered, !b.readErrors.isEmpty {
            lines.append("  Read errors: " + Self.describe(b.readErrors))
        }
        // Behind a USB-C to HDMI adapter the EDID usually reads fine and says nothing new.
        if let probe = result.edidOverI2C, verdict != .hdmiAdapter {
            lines.append("  Its ID info (EDID) over the same wire: " + (probe.valid ? "read fine"
                : probe.status != 0 ? "failed (error \(Self.hex(probe.status)))" : "came back, but not as expected"))
        }
        return lines
    }

    private var softwareDimLine: String? {
        switch softwareDim {
        case nil: return nil
        case .off?: return "Software dimming: off"
        case .on?: return "Software dimming: on, at \(softwareDimLevel)%"
        case .paused?: return "Software dimming: paused (another app keeps changing the colors)"
        case .cantDim?: return "Software dimming: needed, but another app is changing the colors"
        case .adjusted?: return "Software dimming: needed, but the screen's colors are already adjusted"
        case .unsupported?: return "Software dimming: needed, but this screen's colors can't be changed"
        }
    }

    /// The result in a few words: the title of the check's window.
    var title: String {
        let name = monitorName
        let Name = name.prefix(1).uppercased() + name.dropFirst()
        switch verdict {
        case .working: return "\(Name) works with Hammer"
        case .untested: return "\(Name) answers Hammer"
        case .unsure: return "\(Name) went quiet after a change"
        case .ignoresChanges: return "\(Name) ignores brightness changes"
        case .noBrightness: return "\(Name) says it has no brightness setting"
        case .noMonitor: return "No external monitor found"
        case .notDirect: return "\(Name) is on DisplayLink, AirPlay or Sidecar"
        case .notFound: return "Hammer can't find \(name)'s connection"
        case .cantSend: return "macOS won't let Hammer reach \(name)"
        case .hdmiAdapter: return "\(Name) is on HDMI through a USB-C adapter"
        case .noAnswer: return "\(Name) doesn't answer Hammer"
        case .macOSLacksCalls: return "This version of macOS doesn't have what Hammer uses to reach monitors"
        }
    }

    /// What to do, in two or three short lines (and whether Hammer dims in software meanwhile).
    var advice: [String] {
        var lines = steps
        if softwareDim == .on && answering == nil {
            lines.append(softwareDimLevel < 100 ? "Meanwhile Hammer dims the picture in software (\(softwareDimLevel)%)."
                         : "Meanwhile Hammer's Brightness slider dims the picture in software.")
        }
        return lines
    }

    private var steps: [String] {
        // On HDMI, unless the monitor itself says it's on its DisplayPort input.
        let hdmi = ports.contains { $0.port.attached && $0.port.looksLikeHDMI && $0.port.monitorInput != .displayPort }
        let macHDMI = ports.contains { $0.port.attached && $0.port.throughHDMIConverter }
        let direct = "Plug it straight into the Mac, not through a hub, dock or adapter."
            + (hdmi ? " Use USB-C rather than HDMI." : "")
        switch verdict {
        case .working:
            return ["Hammer can read and change its brightness."]
        case .untested:
            return ["Hammer can read its brightness, but couldn't test changing it.",
                    "Move the Brightness slider and watch the screen."]
        case .unsure:
            return ["Did the screen get brighter or dimmer for a moment during the check? Then it works.",
                    "The sliders may just not always start at the right place."]
        case .ignoresChanges, .noBrightness:
            return ["The monitor has probably locked it (its own Brightness item is then grayed out).",
                    "On the Dell: Display → Uniformity Compensation → Off, and Display → Dynamic Contrast → Off.",
                    "Use Color → Preset Modes → Standard, then check again."]
        case .noMonitor:
            return ["Check the cable at both ends.",
                    "On the monitor, choose the right input: Menu → Input Source."]
        case .notDirect:
            return ["Those can't carry brightness control.",
                    "Plug its USB-C or DisplayPort cable straight into the Mac."]
        case .notFound:
            return ["Plug its USB-C cable straight into the Mac, then check again.",
                    "If that doesn't help, send this report along."]
        case .cantSend:
            if macHDMI {
                return ["This Mac's HDMI port doesn't pass monitor control.",
                        "Plug the monitor's USB-C or DisplayPort cable straight into the Mac instead, then check again."]
            }
            if hdmi {
                return ["HDMI doesn't pass monitor control here.",
                        "Connect to the monitor's DisplayPort or USB-C port instead (not HDMI), then check again."]
            }
            return ["Plug its USB-C cable straight into the Mac (not through a hub, dock or adapter).",
                    "Then check again."]
        case .hdmiAdapter:
            return ["USB-C to HDMI, in a cable, adapter or hub, drops brightness control.",
                    "Use the monitor's USB-C or DisplayPort port instead, not HDMI: "
                        + "a USB-C to USB-C cable, or USB-C to DisplayPort.",
                    "Then choose Menu → Input Source → USB Type-C (or DP), and check again."]
        case .noAnswer where wireReads == true:
            return ["Its ID info (EDID) reads fine, but its control channel (DDC/CI) doesn't answer.",
                    "On the monitor: Menu → Others → DDC/CI → On. Then unplug its power cord for 10 seconds.",
                    "Still nothing? " + direct]
        case .noAnswer where wireReads == false:
            return ["Nothing comes back over this connection, not even its ID info (EDID).",
                    "Use a USB-C cable straight into the monitor's USB-C port, or another USB-C port on the Mac.",
                    "Also check Menu → Others → DDC/CI → On."]
        case .noAnswer:
            return ["On the monitor: Menu → Others → DDC/CI → On. Then switch it off and on.",
                    "Still nothing? " + direct]
        case .macOSLacksCalls:
            return ["Send this report along, so Hammer can be updated for it."]
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

    /// [e0114103: 6] → "e0114103 ×6".
    static func describe(_ errors: [Int32: Int]) -> String {
        errors.sorted { $0.key < $1.key }.map { "\(hex($0.key)) ×\($0.value)" }.joined(separator: ", ")
    }

    static func hex(_ status: Int32) -> String { String(format: "%08x", UInt32(bitPattern: status)) }
}

// MARK: - The monitor's part of the menu

/// What dimming the picture in software can do right now (the app works it out, see SoftwareDim).
enum SoftwareDimState: Equatable {
    case off            // not needed: the monitor's own controls (or it hasn't been asked yet)
    case on             // the Brightness slider dims the picture
    case paused         // dimming, but stopped: another app keeps changing the screen's colors
    case cantDim        // needed, but another app has been changing the screen's colors (f.lux?)
    case adjusted       // needed, but the screen's colors are already adjusted (another app, a calibration)
    case unsupported    // needed, but this screen's colors can't be changed
}

struct MonitorMenu: Equatable {
    var title: String?               // shown instead of the sliders
    var sliders = false
    var contrast = true              // the Contrast slider too (not when dimming in software)
    var hints: [String] = []
    var offerCheck = false

    /// `connections`: external DDC connections found (not counting macOS's default);
    /// `hasDefault`: macOS's default connection is being tried too; `attached`: ports
    /// with a monitor seen; `answers`: whether one gave a value when last asked.
    /// `software`: whether the monitor can't be told to dim itself, so the Brightness
    /// slider dims the picture instead (SoftwareDim), and whether that can work.
    static func make(connections: Int, hasDefault: Bool = false, attached: Int, screens: [MonitorScreen],
                     answers: Bool?, hdmiAdapter: Bool = false, software: SoftwareDimState = .off) -> MonitorMenu {
        let external = screens.filter { !$0.builtIn }
        let virtualOnly = !external.isEmpty && external.allSatisfy { $0.direct == false }
        if attached == 0 && external.isEmpty {
            return MonitorMenu(title: "Dell not connected", hints: ["Plug it in with USB-C or DisplayPort."],
                               offerCheck: true)
        }
        if !external.isEmpty && external.allSatisfy(\.brightnessByMacOS) {
            return MonitorMenu(title: "Apple display connected", hints: ["macOS sets its brightness: keys or Control Center."])
        }
        if connections == 0 && virtualOnly {
            return MonitorMenu(title: "Dell connected through DisplayLink or AirPlay",
                               hints: ["Brightness control needs a direct cable:",
                                       "USB-C or DisplayPort straight into the Mac."],
                               offerCheck: true)
        }
        // Dimming in software: one Brightness slider and one line saying why (true at any level,
        // 100 included), or just the line.
        switch software {
        case .off:
            break
        case .on, .paused:
            let why = software == .paused ? "Paused: another app keeps changing the colors"
                : hdmiAdapter ? "Software dimming: the HDMI adapter blocks control"
                : connections == 0 && !hasDefault ? "Software dimming: can't find the Dell's connection"
                : "Software dimming: the Dell isn't answering"
            return MonitorMenu(sliders: true, contrast: false, hints: [why], offerCheck: true)
        case .cantDim:
            return MonitorMenu(hints: ["Can't dim: another app is changing the colors"], offerCheck: true)
        case .adjusted:
            return MonitorMenu(hints: ["Can't dim: the screen's colors are already adjusted"], offerCheck: true)
        case .unsupported:
            return MonitorMenu(hints: ["Can't dim this screen in software"], offerCheck: true)
        }
        if connections == 0 && !hasDefault {
            return MonitorMenu(title: "Can't find the Dell's connection", offerCheck: true)
        }
        var menu = MonitorMenu(sliders: true, offerCheck: true)
        if connections == 0 && answers != true {
            menu.hints.append("Can't find the Dell's port; trying the Mac's default.")
        } else if answers == false && hdmiAdapter {
            menu.hints += ["The Dell is on HDMI from USB-C, which usually",
                           "blocks control. Use its DisplayPort or USB-C port."]
        } else if answers == false {
            menu.hints.append("The Dell isn't answering Hammer.")
        }
        if attached == 0 && virtualOnly {
            menu.hints.append("It may be on DisplayLink or AirPlay, which block control.")
        }
        return menu
    }

    /// A monitor slider's value, shown next to its name: "40%". Empty until it's known.
    static func readout(current: UInt16, max: UInt16) -> String {
        guard max > 0 else { return "" }
        return "\(Int((Double(Swift.min(current, max)) * 100 / Double(max)).rounded()))%"
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

// MARK: - Dimming the picture in software

/// When the monitor can't be told to dim itself (an HDMI adapter, DDC/CI off, no
/// connection found), Hammer dims the picture instead, by scaling the screen's color
/// curves (the way f.lux adjusts them). It can only go darker than the monitor's own
/// setting, and the backlight stays as it is. MonitorMac.swift applies it; macOS
/// undoes it when Hammer quits, so nothing can leave a screen dark.
enum SoftwareDim {
    /// Never darker than this: 15% of the signal. A screen turns signal into light on
    /// a curve (gamma about 2.2), so that's only about 1.5% of the light: very dim, but
    /// never fully dark.
    static let floor = 0.15

    /// The Brightness slider's 0–100 as how much of the signal is kept, from the floor
    /// up to all of it. The light falls faster than the signal: 50 keeps about 30% of it.
    static func factor(level: Int) -> Double {
        let clamped = Double(min(100, max(0, level)))
        return floor + (1 - floor) * clamped / 100
    }

    /// A color curve scaled down, kept between 0 and 1. The factor is held between the
    /// floor and 1 (NaN counts as 1, not dimmed), so a bad number can't black out a screen.
    static func scaled(_ table: [Float], by factor: Double) -> [Float] {
        let f = Float(factor.isNaN ? 1 : min(1, max(floor, factor)))
        return table.map { min(1, max(0, $0 * f)) }
    }

    /// The saved level for a monitor (the same monitor gets a new display number
    /// when it's plugged in again; its maker, model and serial don't change).
    static func key(vendor: UInt32, model: UInt32, serial: UInt32) -> String {
        "softwareDim." + [vendor, model, serial].map { String($0, radix: 16) }.joined(separator: "-")
    }

    /// Dim in software only once the monitor is known not to answer: at once if
    /// it's behind an HDMI adapter or Hammer has no connection to it at all,
    /// otherwise after two reads in a row (one miss can be a slow monitor).
    /// `wasDimming`: it already was (before a wake, a replug or a restart), so one
    /// miss is enough to carry on.
    static func applies(answers: Bool?, misses: Int, hdmiAdapter: Bool, noConnection: Bool = false,
                        wasDimming: Bool = false) -> Bool {
        answers == false && (hdmiAdapter || noConnection || wasDimming || misses >= 2)
    }

    /// Which Brightness slider the menu shows: before the monitor has been asked
    /// again (just after a wake or a replug), whatever was in use.
    static func showing(answers: Bool?, misses: Int, hdmiAdapter: Bool, noConnection: Bool = false,
                        wasDimming: Bool) -> Bool {
        answers == nil ? wasDimming : applies(answers: answers, misses: misses, hdmiAdapter: hdmiAdapter,
                                              noConnection: noConnection, wasDimming: wasDimming)
    }

    /// What to dim from. The screen's curves as they are now, unless they're the
    /// ones Hammer wrote (then the original it kept), or don't look like a
    /// screen's own (another app has changed them: keep the original, if any).
    /// This way a new color profile, or macOS resetting the curves, is picked up,
    /// and dimming never stacks on top of dimming.
    static func base(live: GammaCurves?, written: GammaCurves?, previous: GammaCurves?) -> GammaCurves? {
        guard let live else { return previous }
        if let written, live.matches(written) { return previous }
        return live.isScreensOwn ? live : previous
    }
}

/// Watches one screen's curves while Hammer dims it (every 10 seconds), so it puts
/// its dimming back when macOS resets them, but doesn't fight another app (f.lux,
/// another dimmer) that keeps changing them.
struct DimWatch: Equatable {
    static let giveUpAfter = 3       // changed by something else this many times in a row: stop
    static let resumeAfter = 3       // the other app's curves gone for this many checks in a row: dim again

    enum Action: Equatable {
        case leave                   // leave the screen as it is
        case dim                     // put Hammer's dimming (back) on it
    }

    private(set) var resets = 0      // checks in a row that found another app's curves
    private(set) var gaveUp = false
    private(set) var rival: GammaCurves?     // what was on the screen when Hammer gave up
    private(set) var calm = 0        // since then: checks in a row with steady curves of the screen's own
    private(set) var own: GammaCurves?       // the screen's own curves, as they were while all was well
    private var seen: GammaCurves?

    /// One check. `now`: the screen's curves (nil: unreadable); `written`: what Hammer last put
    /// there; `original`: the curves Hammer dims from. The screen's own curves coming back
    /// (macOS resetting them, another app restoring them, a write lost while the display slept)
    /// are never another app's: Hammer just dims again, every time.
    mutating func check(now: GammaCurves?, written: GammaCurves?, original: GammaCurves? = nil) -> Action {
        if gaveUp {
            // Look, don't touch. Dim again only once the other app has let go: the screen's own
            // curves, not the other app's (some look much like a screen's own), steady for a while.
            guard let now, now.isScreensOwn, !(rival.map(now.matches) ?? false) else {
                calm = 0
                seen = nil
                return .leave
            }
            calm = seen.map(now.matches) == true ? calm + 1 : 1
            seen = now
            guard calm >= Self.resumeAfter else { return .leave }
            self = DimWatch(own: own)
            return .dim
        }
        guard let written else { return .dim }               // never got to write yet: not anyone's fault
        if let now, now.matches(written) {
            resets = 0
            own = original ?? own        // what it dims from while all is well (not curves adopted mid-fight)
            return .leave
        }
        if let now, let own = own ?? original, now.matches(own) { return .dim }
        if own == nil { own = original }   // before dimming again from the other app's curves, if they look like a screen's own
        resets += 1
        guard resets > Self.giveUpAfter else { return .dim }
        gaveUp = true
        rival = now
        return .leave
    }

    /// Another app is changing the curves under Hammer: twice in a row or more (a new color
    /// profile changes them once), or Hammer gave up. Not any more once all is well again.
    var otherAppAtWork: Bool { gaveUp || resets >= 2 }

    private init(own: GammaCurves?) { self.own = own }

    init() {}
}

/// The app's side of dimming in software: whether it's on, and what to do as things happen
/// (a read of the monitor, launch or a replug, the 10-second check). The app keeps one and
/// does what it says; it's here so it can be tested.
struct SoftwareDimming: Equatable {
    var on = false                   // dimming in software, as last applied

    enum Change: Equatable {
        case fadeIn                  // starting: ease into the saved level
        case fadeOut                 // stopping: ease back to the screen's own colors
        case reapply                 // carrying on: put the saved level back
        case undo                    // still not dimming: make sure nothing of it is left
    }

    struct Plan: Equatable {
        var change: Change
        var remember: Bool?          // save (or clear) "dimmed in software" for the monitor; nil: leave it
        var askAgain: Bool           // read the monitor once more in 10 seconds
    }

    /// At launch (after an update too), or when screens change: a monitor that was dimmed in
    /// software is dimmed again at once, not left at full brightness until it's asked.
    /// True: it just went on (put the dimming back, and watch it).
    mutating func resume(wasActive: Bool) -> Bool {
        guard !on && wasActive else { return false }
        on = true
        return true
    }

    /// After each read of the monitor. `screens`: there's a screen to dim (external, on a
    /// direct cable, and not one whose brightness macOS sets itself).
    mutating func afterRead(answers: Bool, misses: Int, hdmiAdapter: Bool, noConnection: Bool = false,
                            wasActive: Bool = false, screens: Bool = true) -> Plan {
        let was = on
        on = screens && SoftwareDim.applies(answers: answers, misses: misses, hdmiAdapter: hdmiAdapter,
                                            noConnection: noConnection, wasDimming: was || wasActive)
        let change: Change = was ? (on ? .reapply : .fadeOut) : (on ? .fadeIn : .undo)
        // A first miss can be a slow monitor (also one dimmed before a restart that answers now):
        // ask again soon, unless nothing it could say would change anything.
        return Plan(change: change, remember: on ? true : answers ? false : nil,
                    askAgain: !answers && misses == 1 && !hdmiAdapter && !noConnection)
    }

    /// Whether the 10-second check may put the dimming back: only while dimming, so a check
    /// queued just before the monitor answered can't dim it again (or stop the fade-out).
    var keepsApplied: Bool { on }
}

/// Fading the dimming in or out: a few steps over about a quarter of a second. Anything
/// else that sets a screen meanwhile (the slider, a wake, an undo) interrupts the fade
/// and has the last word.
struct DimFade: Equatable {
    static let steps = 5
    static let pause: UInt64 = 60_000_000            // between steps, in nanoseconds
    private(set) var current = 0

    /// Starts a fade: its number, to check before each step.
    mutating func start() -> Int {
        current += 1
        return current
    }

    /// Something else set a screen: any fade under way stops.
    mutating func interrupt() { current += 1 }

    func goesOn(_ fade: Int) -> Bool { fade == current }

    /// How much of the signal step `step` (of `steps`) keeps, on the way from `from` to `to`.
    static func factor(step: Int, from: Double, to: Double) -> Double {
        from + (to - from) * Double(min(max(step, 0), steps)) / Double(steps)
    }
}

/// A screen's three color curves (red, green, blue), each from dark (0) to light (1).
struct GammaCurves: Equatable {
    var r: [Float]
    var g: [Float]
    var b: [Float]

    /// Looks like a screen's own (from its color profile): every color starts near
    /// dark, the brightest reaches (nearly) full light, and none is held far down (a
    /// warm white point is fine). A dimmed curve, a color-shifting app's, or one
    /// zeroed by a glitch, doesn't. Hammer's own dimming passes only at 97–99 (less
    /// than 3% off the original), so even taken for the original it can't stack visibly.
    var isScreensOwn: Bool {
        let curves = [r, g, b]
        guard curves.allSatisfy({ $0.count > 1 && ($0.first ?? 1) <= 0.1 }) else { return false }
        let tops = curves.compactMap(\.last)
        return (tops.max() ?? 0) >= 0.97 && (tops.min() ?? 0) >= 0.6
    }

    func scaled(by factor: Double) -> GammaCurves {
        GammaCurves(r: SoftwareDim.scaled(r, by: factor), g: SoftwareDim.scaled(g, by: factor),
                    b: SoftwareDim.scaled(b, by: factor))
    }

    /// The same curves, allowing for macOS handing them back with a different
    /// number of steps: compared at the same points along the way.
    func matches(_ other: GammaCurves) -> Bool {
        func at(_ curve: [Float], _ p: Double) -> Float? {
            curve.isEmpty ? nil : curve[Int((Double(curve.count - 1) * p).rounded())]
        }
        let points = [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1]
        for (mine, theirs) in [(r, other.r), (g, other.g), (b, other.b)] {
            for p in points {
                guard let x = at(mine, p), let y = at(theirs, p), abs(x - y) < 0.01 else { return false }
            }
        }
        return true
    }
}
