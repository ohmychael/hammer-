// Tests for HammerCore.swift, Monitor.swift and Deliveries.swift. Run by build.sh before every install:
//   swiftc HammerCore.swift Monitor.swift Deliveries.swift Tests/main.swift -o hammer-tests && ./hammer-tests
// Exits with 1 if anything fails, which stops the update.

import Foundation

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(what)")
    }
}

func padded(_ bytes: [UInt8], checksum: UInt8) -> [UInt8] {
    bytes + [UInt8](repeating: 0, count: 19 - bytes.count) + [checksum]
}

// MARK: Govee packets — checked against packets traced from the Govee app

expect(GoveePacket.make([0x33, 0x04, 0x64]) == padded([0x33, 0x04, 0x64], checksum: 0x53),
       "full brightness packet matches the traced one")
expect(GoveePacket.make([0x33, 0x05, 0x0D, 0xFF, 0xFF, 0xFF, 0x0A, 0x8C, 0xFF, 0xAE, 0x54])
       == padded([0x33, 0x05, 0x0D, 0xFF, 0xFF, 0xFF, 0x0A, 0x8C, 0xFF, 0xAE, 0x54], checksum: 0x47),
       "2700 K packet matches the traced one")
expect(GoveePacket.make([0x33, 0x05, 0x0D, 0xFF, 0xFF, 0xFF, 0x19, 0x64, 0xFF, 0xF9, 0xFB])
       == padded([0x33, 0x05, 0x0D, 0xFF, 0xFF, 0xFF, 0x19, 0x64, 0xFF, 0xF9, 0xFB], checksum: 0x44),
       "6500 K packet matches the traced one")
expect(GoveePacket.make([0x33, 0x05, 0x0D, 0xFF, 0x00, 0x00]).last == 0xC4, "red color checksum")
expect(GoveePacket.make([0x33, 0x01, 0x01]).last == 0x33, "power on checksum")
expect(GoveePacket.make([0x33, 0x01, 0x00]).last == 0x32, "power off checksum")
expect(GoveePacket.statusRead == padded([0xAA, 0x01], checksum: 0xAB), "status read packet")

// Edge cases: size is always 20, long payloads are cut at 19 bytes, empty is all zeros.
expect(GoveePacket.make([]).count == 20 && GoveePacket.make([]).allSatisfy { $0 == 0 }, "empty payload")
let long = GoveePacket.make(Array(1...30))
expect(long.count == 20 && Array(long[0..<19]) == Array(1...19) && long[19] == 0x00,
       "payload longer than 19 bytes is cut, checksum covers the first 19")
expect(GoveePacket.isCommand(GoveePacket.make([0x33, 0x01, 0x01])), "0x33 is a command")
expect(!GoveePacket.isCommand(GoveePacket.statusRead), "a status read isn't a command")

// Power-state replies
expect(GoveePacket.powerState(in: [0xAA, 0x01, 0x01]) == true, "reply: on")
expect(GoveePacket.powerState(in: [0xAA, 0x01, 0x00]) == false, "reply: off")
expect(GoveePacket.powerState(in: padded([0xAA, 0x01, 0x01], checksum: 0xAA)) == true, "full 20-byte reply: on")
expect(GoveePacket.powerState(in: [0xAA, 0x05, 0x01]) == nil, "other status replies aren't power")
expect(GoveePacket.powerState(in: [0x33, 0x01, 0x01]) == nil, "an echoed command isn't a reply")
expect(GoveePacket.powerState(in: [0xAA, 0x01]) == nil, "too short")
expect(GoveePacket.powerState(in: []) == nil, "empty")

// MARK: Command queue

let start = Date(timeIntervalSince1970: 1_000_000)
func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
func kinds(_ queue: CommandQueue) -> [String] {
    queue.items.map { item -> String in
        switch item.key {
        case 0x3301: return item.packet[2] == 1 ? "on" : "off"
        case 0x3304: return "brightness \(item.packet[2])"
        case 0x3305: return "color"
        case 0xAA01: return "status"
        default: return "other"
        }
    }
}

// Five brightness changes, then off and on again, while the bulb is busy.
var queue = CommandQueue()
for (step, level) in [10, 30, 50, 70, 90].enumerated() {
    queue.add(GoveePacket.make([0x33, 0x04, UInt8(level)]), at: at(Double(step) * 0.2))
}
queue.add(GoveePacket.make([0x33, 0x01, 0x00]), at: at(1))
queue.add(GoveePacket.make([0x33, 0x01, 0x01]), at: at(1.1))
expect(kinds(queue) == ["brightness 90", "on"], "only the latest of each kind is kept: \(kinds(queue))")

// Order follows the last request of each kind.
queue = CommandQueue()
queue.add(GoveePacket.make([0x33, 0x01, 0x01]), at: at(0))
queue.add(GoveePacket.make([0x33, 0x05, 0x0D, 255, 0, 0]), at: at(0))
queue.add(GoveePacket.make([0x33, 0x04, 40]), at: at(0))
queue.add(GoveePacket.statusRead, at: at(0))
expect(kinds(queue) == ["on", "color", "brightness 40", "status"], "order kept: \(kinds(queue))")
queue.add(GoveePacket.make([0x33, 0x01, 0x00]), at: at(1))
expect(kinds(queue) == ["color", "brightness 40", "status", "off"], "a newer power command moves to the end")

// Stale commands are dropped; fresh ones stay.
queue = CommandQueue(freshFor: 15)
queue.add(GoveePacket.make([0x33, 0x01, 0x00]), at: at(0))
queue.add(GoveePacket.make([0x33, 0x04, 20]), at: at(5))
queue.dropStale(now: at(14.9))
expect(kinds(queue) == ["off", "brightness 20"], "nothing dropped before 15 s")
queue.dropStale(now: at(15))
expect(kinds(queue) == ["brightness 20"], "the 15 s old one is dropped")
queue.dropStale(now: at(60))
expect(queue.isEmpty && queue.first == nil, "everything dropped after a minute")

// first / removeFirst, and bad input.
queue = CommandQueue()
queue.add(GoveePacket.make([0x33, 0x01, 0x01]), at: at(0))
expect(queue.first == GoveePacket.make([0x33, 0x01, 0x01]), "first is the oldest")
queue.removeFirst()
queue.removeFirst()                                       // removing from an empty queue is harmless
expect(queue.isEmpty, "empty after removing")
queue.add([0x33], at: at(0))
queue.add([], at: at(0))
expect(queue.isEmpty, "packets shorter than 2 bytes are ignored")

// Restoring commands lost with a dying link.
func item(_ payload: [UInt8], _ seconds: Double) -> CommandQueue.Item {
    let packet = GoveePacket.make(payload)
    return CommandQueue.Item(key: UInt16(packet[0]) << 8 | UInt16(packet[1]), packet: packet, at: at(seconds))
}
queue = CommandQueue()
queue.add(GoveePacket.make([0x33, 0x04, 30]), at: at(5))                       // queued after the link died
queue.restore([item([0x33, 0x01, 0x00], 1), item([0x33, 0x04, 90], 2), item([0x33, 0x05, 0x0D, 255, 0, 0], 3)])
expect(kinds(queue) == ["off", "color", "brightness 30"],
       "lost commands go first; a newer brightness wins over the lost one: \(kinds(queue))")
queue = CommandQueue()
queue.restore([item([0x33, 0x01, 0x00], 1), item([0x33, 0x01, 0x01], 2)])
expect(kinds(queue) == ["on"], "only the last of each kind comes back: \(kinds(queue))")
queue = CommandQueue(freshFor: 15)
queue.restore([item([0x33, 0x01, 0x00], 0)])
queue.dropStale(now: at(16))
expect(queue.isEmpty, "restored commands still expire 15 s after they were asked for")
queue.restore([])
expect(queue.isEmpty, "restoring nothing is harmless")

// MARK: Reconnect timing

expect(ConnectBackoff.delay(afterFailures: 0) == 0, "no failures, no wait")
expect([1, 2, 3, 4, 5, 6, 7, 8].map { ConnectBackoff.delay(afterFailures: $0) } == [0, 3, 6, 12, 24, 48, 60, 60],
       "first retry at once, then waits double up to a minute")
expect(ConnectBackoff.delay(afterFailures: 10_000) == 60, "a huge failure count stays at a minute")
expect(ConnectBackoff.delay(afterFailures: -5) == 0, "a negative count is harmless")

let bulbA = UUID(), bulbB = UUID()
var backoff = ConnectBackoff()
expect(backoff.canTry(bulbA, now: at(0)) && backoff.wait(bulbA, now: at(0)) == 0, "a new bulb can be tried right away")
expect(backoff.failed(bulbA, now: at(0)) == 0 && backoff.canTry(bulbA, now: at(0)), "first failure: try again at once")
expect(backoff.failed(bulbA, now: at(0)) == 3, "second failure in a row waits 3 s")
expect(!backoff.canTry(bulbA, now: at(2.9)) && backoff.canTry(bulbA, now: at(3)), "allowed again after 3 s")
expect(abs(backoff.wait(bulbA, now: at(1)) - 2) < 0.001, "2 s left after 1 s")
expect(backoff.canTry(bulbB, now: at(0)), "one bulb's failures don't hold up another")
expect(backoff.failed(bulbA, now: at(3)) == 6, "third failure in a row waits 6 s")

// 200 quick failures (the old retry storm) end up a minute apart, not milliseconds.
var storm = ConnectBackoff()
var elapsed = 0.0, attempts = 0
while elapsed < 600 {
    if storm.canTry(bulbA, now: at(elapsed)) { attempts += 1; storm.failed(bulbA, now: at(elapsed)) }
    elapsed += 0.05
}
expect(attempts <= 15, "a bulb that always fails is tried at most ~15 times in 10 minutes: \(attempts)")

// Tapping a light while Hammer is waiting: try within 2 s, but never later than planned.
backoff = ConnectBackoff()
for _ in 1...7 { backoff.failed(bulbA, now: at(0)) }         // waiting a minute now
backoff.hurry(bulbA, within: 2, now: at(0))
expect(backoff.canTry(bulbA, now: at(2)) && !backoff.canTry(bulbA, now: at(1.9)), "a tap brings the next try forward to 2 s")
backoff.hurry(bulbA, within: 30, now: at(0))
expect(backoff.canTry(bulbA, now: at(2)), "hurrying never pushes a try later")
backoff.hurry(bulbB, within: 2, now: at(0))
expect(backoff.canTry(bulbB, now: at(0)), "hurrying a bulb that isn't waiting changes nothing")

// A pause for a bulb that doesn't take Hammer's commands, and a lasting link resetting everything.
backoff.pause(bulbA, for: 300, now: at(0))
expect(!backoff.canTry(bulbA, now: at(299)) && backoff.canTry(bulbA, now: at(300)), "5 minute pause")
backoff.pause(bulbA, for: 10, now: at(0))
expect(!backoff.canTry(bulbA, now: at(100)), "a shorter pause doesn't cut a longer one short")
backoff.succeeded(bulbA)
expect(backoff.canTry(bulbA, now: at(0)) && backoff.failures[bulbA] == nil, "success clears the wait")
expect(backoff.failed(bulbA, now: at(0)) == 0, "and the count starts over")

// MARK: Bulb names

expect(GoveeName.model(in: "ihoment_H6006_0FC3") == "H6006", "model from a Govee name")
expect(GoveeName.model(in: "ihoment_h6006_abcd") == "H6006", "lowercase names work")
expect(GoveeName.model(in: "Govee_H600D_1234") == "H600D", "hex digits in the model")
expect(GoveeName.model(in: "Magic Keyboard") == nil, "other devices are ignored")
expect(GoveeName.model(in: "") == nil, "empty name")
expect(GoveeName.displayName(model: "H6006", advertised: "ihoment_H6006_0FC3") == "H6006 bulb 0FC3",
       "name keeps the bulb's code")
expect(GoveeName.displayName(model: "H6006", advertised: "Govee_H6006") == "H6006 bulb", "no code")
expect(GoveeName.displayName(model: "H6006", advertised: "ihoment_H6006_") == "H6006 bulb", "empty code")
expect(GoveeName.distance(dBm: -50) == "very close" && GoveeName.distance(dBm: -60) == "very close",
       "strong signal")
expect(GoveeName.distance(dBm: -61) == "nearby" && GoveeName.distance(dBm: -75) == "nearby", "medium signal")
expect(GoveeName.distance(dBm: -76) == "far away" && GoveeName.distance(dBm: -100) == "far away", "weak signal")

// MARK: DDC/CI (monitor) packets

expect(DDCPacket.set(code: 0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A], "set brightness 50")
expect(DDCPacket.set(code: 0x12, value: 300) == [0x84, 0x03, 0x12, 0x01, 0x2C, 0x87], "values over 255 use both bytes")
expect(DDCPacket.get(code: 0x10) == [0x82, 0x01, 0x10, 0xFD], "get brightness, seeded like m1ddc and MonitorControl")
expect(DDCPacket.get(code: 0x10, seed: DDCPacket.readSeeds[1]) == [0x82, 0x01, 0x10, 0xAC],
       "get brightness, MCCS's textbook checksum")

let goodReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
expect(DDCPacket.parseReply(goodReply, code: 0x10) == .value(current: 50, max: 100), "reads current 50 of max 100")
var corrupt = goodReply
corrupt[9] = 0x33
expect(DDCPacket.parseReply(corrupt, code: 0x10) == .badChecksum(current: 51, max: 100),
       "a bad checksum is kept apart")
expect(DDCPacket.parseReply(goodReply, code: 0x12) == .garbage, "an answer about another setting is rejected")
var unsupported = goodReply
unsupported[3] = 0x01
unsupported[10] ^= 0x01                                    // keep the checksum valid
expect(DDCPacket.parseReply(unsupported, code: 0x10) == .unsupported, "\"unsupported\" is recognized")
expect(DDCPacket.parseReply(Array(goodReply.prefix(10)), code: 0x10) == .garbage, "too short")
expect(DDCPacket.parseReply([], code: 0x10) == .nothing, "empty")
expect(DDCPacket.parseReply([UInt8](repeating: 0, count: 11), code: 0x10) == .nothing, "silence (zeros)")
expect(DDCPacket.parseReply([UInt8](repeating: 0xFF, count: 11), code: 0x10) == .nothing, "silence (ones)")
expect(DDCPacket.parseReply([0x6E, 0x80, 0xBE] + [UInt8](repeating: 0, count: 8), code: 0x10) == .busy,
       "null message: busy")

// MARK: Monitor: talking over DDC/CI to stand-in monitors

/// A stand-in monitor on one connection. Behaves like a real one on the I²C level:
/// takes "set" and "get" messages, answers a "get" on the next read, and can be
/// made picky, silent, slow, broken or locked the ways real setups are.
final class FakeMonitor: DDCBus {
    var chip: UInt32 = 0x37                        // where it listens (0xB7: behind an M1 HDMI converter)
    var acceptedReadSeeds: Set<UInt8> = [0x6E, 0x3F]
    var acceptedReadOffsets: Set<UInt32> = [0x51, 0]
    var checksSetChecksum = true
    var ddcOn = true                               // off: hears nothing, says nothing
    var applySets = true                           // false: brightness locked by a preset
    var writeStatus: Int32 = 0                     // e.g. an error for a port that refuses
    var wrongChipStatus: Int32 = Int32(bitPattern: 0xE00002C0)
    var readStatus: Int32 = 0
    var missFirst = 0                              // ignore this many "get" requests first
    var busyFirst = 0                              // answer this many reads with "nothing yet"
    var corruptReplies = false
    var answerLimit = Int.max                      // goes quiet after this many answers
    var applyLimit = Int.max                       // takes this many sets, then ignores them
    var setSkew = 0                                // rounds what it's set to by this much
    var edid: [UInt8]? = makeEDID("DELL U3818DW")  // what macOS has for it
    var edidReadStatus: Int32 = 0                  // reading the EDID over I²C (0x50)
    var edidReadGarbage = false                    // ...gives back something else
    var oneRequestOnly = false                     // a second request before the read confuses it
    var supported: Set<UInt8> = [0x10, 0x12, 0x62]
    var values: [UInt8: (current: UInt16, max: UInt16)] = [0x10: (40, 100), 0x12: (75, 100), 0x62: (20, 100)]

    var writes: [(chip: UInt32, offset: UInt32, bytes: [UInt8])] = []
    var reads: [(chip: UInt32, offset: UInt32)] = []
    var sets: [(code: UInt8, value: UInt16)] = []
    private var pending: UInt8?
    var requestsLost = 0

    func write(chip: UInt32, offset: UInt32, _ bytes: [UInt8]) -> Int32 {
        writes.append((chip, offset, bytes))
        if writeStatus != 0 { return writeStatus }
        if chip != self.chip { return wrongChipStatus }
        guard ddcOn, offset == 0x51, bytes.count >= 4 else { return 0 }
        if bytes[0] == 0x84, bytes[1] == 0x03, bytes.count == 6 {
            if checksSetChecksum, DDCPacket.checksum(bytes[0..<5], seed: 0x6E ^ 0x51) != bytes[5] { return 0 }
            sets.append((bytes[2], UInt16(bytes[3]) << 8 | UInt16(bytes[4])))
            if applySets, sets.count <= applyLimit, let old = values[bytes[2]] {
                let asked = Int(UInt16(bytes[3]) << 8 | UInt16(bytes[4])) + setSkew
                values[bytes[2]] = (UInt16(Swift.max(0, Swift.min(asked, Int(old.max)))), old.max)
            }
        } else if bytes[0] == 0x82, bytes[1] == 0x01, bytes.count == 4 {
            let seed = bytes[3] ^ DDCPacket.checksum(bytes[0..<3], seed: 0)
            guard acceptedReadSeeds.contains(seed) else { return 0 }
            if missFirst > 0 { missFirst -= 1; return 0 }
            if oneRequestOnly, pending != nil { pending = nil; requestsLost += 1; return 0 }
            pending = bytes[2]
        }
        return 0
    }

    func copyEDID() -> [UInt8]? { edid }

    func read(chip: UInt32, offset: UInt32, count: Int) -> (status: Int32, bytes: [UInt8]) {
        reads.append((chip, offset))
        if chip == EDID.chip {
            if edidReadStatus != 0 { return (edidReadStatus, []) }
            if edidReadGarbage || offset != 0 { return (0, [UInt8](repeating: 0x5A, count: count)) }
            return (0, Array(((edid ?? []) + [UInt8](repeating: 0, count: count)).prefix(count)))
        }
        if readStatus != 0 { return (readStatus, []) }
        if chip != self.chip { return (wrongChipStatus, []) }
        let silence = [UInt8](repeating: 0, count: count)
        guard ddcOn, acceptedReadOffsets.contains(offset), let code = pending, answerLimit > 0 else { return (0, silence) }
        if busyFirst > 0 {
            busyFirst -= 1
            return (0, [0x6E, 0x80, 0xBE] + [UInt8](repeating: 0, count: count - 3))
        }
        pending = nil
        answerLimit -= 1
        let value = values[code] ?? (0, 0)
        var reply: [UInt8] = [0x6E, 0x88, 0x02, supported.contains(code) ? 0x00 : 0x01, code, 0x00,
                              UInt8(value.max >> 8), UInt8(value.max & 0xFF),
                              UInt8(value.current >> 8), UInt8(value.current & 0xFF), 0]
        reply[10] = DDCPacket.checksum(reply[0..<10], seed: 0x50) ^ (corruptReplies ? 0x01 : 0x00)
        return (0, Array((reply + silence).prefix(count)))
    }
}

/// An EDID with a model name and valid checksums: base block only, or with a
/// CTA-861 extension listing HDMI's vendor block (what a monitor's HDMI input gives).
func makeEDID(_ name: String, hdmi: Bool = false, hdmiForum: Bool = false, interface: UInt8? = nil) -> [UInt8] {
    var edid = [UInt8](repeating: 0, count: 128)
    edid.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    edid[8] = 0x10; edid[9] = 0xAC                                    // "DEL"
    let text = Array(name.utf8.prefix(13)) + (name.utf8.count < 13 ? [0x0A] : [])
    edid.replaceSubrange(72..<77, with: [0x00, 0x00, 0x00, 0xFC, 0x00])  // second descriptor: the name
    for (index, byte) in text.enumerated() { edid[77 + index] = byte }
    for index in (77 + text.count)..<90 { edid[index] = 0x20 }
    if let interface {                                                // EDID 1.4 names the input
        edid[18] = 1; edid[19] = 4; edid[20] = 0x80 | 0x20 | interface
    }
    if hdmi || hdmiForum { edid[126] = 1 }
    edid[127] = 0 &- edid[0..<127].reduce(UInt8(0), &+)
    guard hdmi || hdmiForum else { return edid }
    var cta = [UInt8](repeating: 0, count: 128)
    let oui: [UInt8] = hdmiForum ? [0xD8, 0x5D, 0xC4] : [0x03, 0x0C, 0x00]
    let blocks: [UInt8] = [0x42, 0x10, 0x04] + [0x65] + oui + [0x10, 0x00]   // a video block, then the vendor block
    cta.replaceSubrange(0..<4, with: [0x02, 0x03, UInt8(4 + blocks.count), 0x00])
    cta.replaceSubrange(4..<(4 + blocks.count), with: blocks)
    cta[127] = 0 &- cta[0..<127].reduce(UInt8(0), &+)
    return edid + cta
}

/// Counts the waiting a link does instead of doing it.
final class Clock { var slept: UInt64 = 0 }
func fastLink(_ bus: DDCBus, _ ways: [DDCWay], _ clock: Clock = Clock()) -> DDCLink {
    DDCLink(bus: bus, ways: ways, sleep: { clock.slept += UInt64($0) })
}
let usbC = DDCWay.all(chip: 0x37)
func dlScreenForDefault() -> MonitorScreen {
    MonitorScreen(id: 3, name: "DELL U3818DW", builtIn: false, framebuffer: nil, direct: false)
}
func viaConverterPort() -> MonitorPort {
    MonitorPort(connection: 7, framebuffer: nil, name: nil, attached: false,
                throughHDMIConverter: true, transport: nil, label: nil)
}
let viaConverter = MonitorPort(connection: 1, framebuffer: nil, name: nil, attached: true,
                               throughHDMIConverter: true, transport: nil, label: nil).ways

// An ordinary monitor answers the first way, first time.
var monitor = FakeMonitor()
var clock = Clock()
var link = fastLink(monitor, usbC, clock)
var read = link.read(code: 0x10)
expect(read.reading?.current == 40 && read.reading?.max == 100 && read.checksumOK, "reads 40 of 100")
expect(read.tries == 1 && read.way == usbC[0] && link.knownWay == usbC[0], "first way, first try")
expect(monitor.writes.count == 2 && monitor.writes.allSatisfy { $0.offset == 0x51 && $0.bytes == [0x82, 0x01, 0x10, 0xFD] },
       "the request goes out twice, like the reference tools")
expect(monitor.reads.count == 1 && monitor.reads[0].offset == 0x51, "read once, at 0x51")
expect(clock.slept == 70_000, "waits 10 + 10 ms before sending and 50 ms before reading")

// Setting a value.
monitor.writes = []
expect(link.write(code: 0x10, value: 65) == 0 && monitor.values[0x10]?.current == 65, "sets brightness")
expect(monitor.writes.count == 2 && monitor.writes[0].bytes == DDCPacket.set(code: 0x10, value: 65)
       && monitor.writes.allSatisfy { $0.chip == 0x37 && $0.offset == 0x51 }, "a set goes out twice to 0x37")
expect(link.read(code: 0x10).reading?.current == 65, "and reads back")

// A monitor that only takes the textbook checksum on requests.
monitor = FakeMonitor(); monitor.acceptedReadSeeds = [0x3F]
link = fastLink(monitor, usbC)
read = link.read(code: 0x10)
expect(read.reading?.current == 40 && read.way?.readSeed == 0x3F && read.tries == 3, "falls back to the textbook checksum")
read = link.read(code: 0x12)
expect(read.reading?.current == 75 && read.tries == 1, "and goes straight there next time")

// A monitor that only answers reads at offset 0 (MonitorControl's way).
monitor = FakeMonitor(); monitor.acceptedReadOffsets = [0]
link = fastLink(monitor, usbC)
read = link.read(code: 0x10)
expect(read.reading?.current == 40 && read.way?.readOffset == 0 && read.tries == 5, "falls back to reading at 0")

// The built-in HDMI port of M1-era Macs: the converter only passes 0xB7.
monitor = FakeMonitor(); monitor.chip = 0xB7
link = fastLink(monitor, usbC)
read = link.read(code: 0x10)
expect(!read.answered && !read.sent && read.sendError == Int32(bitPattern: 0xE00002C0) && read.tries == 2,
       "0x37 alone can't reach a monitor behind the converter (what Hammer did before)")
link = fastLink(monitor, viaConverter)
read = link.read(code: 0x10)
expect(read.reading?.current == 40 && read.way?.chip == 0xB7 && read.tries == 1, "0xB7 reaches it")
expect(link.write(code: 0x10, value: 10) == 0 && monitor.values[0x10]?.current == 10
       && monitor.writes.suffix(2).allSatisfy { $0.chip == 0xB7 }, "and sets go to 0xB7")

// Converter detected, but the monitor turns out to be on 0x37 after all.
monitor = FakeMonitor()
link = fastLink(monitor, viaConverter)
expect(link.writeChips == [0xB7, 0x37], "until it answers, sets go to the converter and 0x37")
expect(link.write(code: 0x10, value: 30) == 0 && monitor.values[0x10]?.current == 30,
       "a set refused on 0xB7 is sent on 0x37")
read = link.read(code: 0x10)
expect(read.reading?.current == 30 && read.way?.chip == 0x37 && read.tries == 3,
       "a refused chip is given up after its first way")
expect(link.writeChips == [0x37], "then sets go only where it answered")

// DDC/CI switched off: messages go out, nothing comes back.
monitor = FakeMonitor(); monitor.ddcOn = false
clock = Clock()
link = fastLink(monitor, usbC, clock)
read = link.read(code: 0x10)
expect(!read.answered && read.sent && read.tries == 7 && read.lastReply == [UInt8](repeating: 0, count: 11),
       "no answer after trying every way twice, and once slowly")
expect(clock.slept < 800_000, "gives up within 0.8 s (\(clock.slept) µs)")
expect(link.knownWay == nil, "nothing learned")
expect(link.write(code: 0x10, value: 50) == 0 && monitor.values[0x10]?.current == 40,
       "a set still goes out (it can't be confirmed)")

// A port that refuses everything (e.g. DisplayLink-style or an empty port).
monitor = FakeMonitor(); monitor.writeStatus = Int32(bitPattern: 0xE00002BC)
link = fastLink(monitor, usbC)
read = link.read(code: 0x10)
expect(!read.sent && read.sendError == Int32(bitPattern: 0xE00002BC) && read.tries == 2 && monitor.reads.isEmpty,
       "refused: nothing to read, other ways skipped")
expect(link.write(code: 0x10, value: 50) == Int32(bitPattern: 0xE00002BC), "the error comes back from a set")

// Reading fails at the I²C level.
monitor = FakeMonitor(); monitor.readStatus = Int32(bitPattern: 0xE00002D8)
read = fastLink(monitor, usbC).read(code: 0x10)
expect(!read.answered && read.sent && read.readError == Int32(bitPattern: 0xE00002D8), "read errors are kept")

// Busy, flaky and slightly broken monitors.
monitor = FakeMonitor(); monitor.busyFirst = 1
read = fastLink(monitor, usbC).read(code: 0x10)
expect(read.reading?.current == 40 && read.busy && read.tries == 2, "\"nothing yet\", then the answer")
monitor = FakeMonitor(); monitor.missFirst = 3          // each try sends the request twice
read = fastLink(monitor, usbC).read(code: 0x10)
expect(read.reading?.current == 40 && read.tries == 2, "keeps asking a monitor that misses requests")
monitor = FakeMonitor(); monitor.missFirst = 5
read = fastLink(monitor, usbC).read(code: 0x10)
expect(read.reading?.current == 40 && read.tries == 3 && read.way?.readSeed == 0x3F,
       "...even into the next way")
monitor = FakeMonitor(); monitor.corruptReplies = true
link = fastLink(monitor, usbC)
read = link.read(code: 0x10)
expect(read.reading?.current == 40 && !read.checksumOK && read.tries == 6 && link.knownWay == usbC[0],
       "a reply with a wrong checksum is used when nothing better comes")
monitor = FakeMonitor(); monitor.supported = [0x10]
read = fastLink(monitor, usbC).read(code: 0x12)
expect(read.answer == .unsupported && read.answered && read.tries == 1, "\"no such setting\" counts as an answer")
monitor = FakeMonitor(); monitor.values[0x10] = (300, 400)
read = fastLink(monitor, usbC).read(code: 0x10)
expect(read.reading?.current == 300 && read.reading?.max == 400, "values over 255")
monitor = FakeMonitor()
expect(DDCLink(bus: monitor, ways: []).ways == usbC, "no ways given: the usual ones")

// MARK: Monitor: finding which connection the monitor is on

func framebuffer(_ id: UInt64, _ name: String? = nil, display: Bool = false, transport: String? = nil,
                 path: String = "") -> RegistryEntry {
    RegistryEntry(id: id, name: "AppleCLCD2", isFramebuffer: true, path: path, productName: name,
                  hasDisplay: display, transport: transport)
}
func proxy(_ id: UInt64, _ location: String? = "External", provider: String? = nil,
                path: String = "") -> RegistryEntry {
    RegistryEntry(id: id, name: "DCPAVServiceProxy", path: path, location: location, provider: provider)
}
let builtIn = MonitorScreen(id: 1, name: "Built-in Retina Display", builtIn: true, framebuffer: 100, direct: true)

// MacBook Air: the Dell on USB-C.
var entries = [framebuffer(100, display: true), proxy(101, "Embedded"),
               framebuffer(200, "DELL U3818DW", display: true, transport: "DP → DP"),
               proxy(201, path: "IOService:/AppleARMPE/arm-io@10F00000/AppleT810xIO/dcpext@A8000000/AppleDCPExpert/DCPAVServiceProxy")]
var screens = [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 200, direct: true)]
var ports = MonitorDiscovery.ports(in: entries, screens: screens)
expect(ports.count == 1 && ports[0].connection == 201 && ports[0].attached && ports[0].name == "DELL U3818DW"
       && ports[0].label == "dcpext" && ports[0].ways == usbC, "MacBook Air: one port, the Dell's")

// 14" MacBook Pro with M1 Pro: an empty port listed first, the Dell on HDMI.
entries = [framebuffer(100, display: true), proxy(101, "Embedded"),
           framebuffer(300), proxy(301, path: "IOService:/x/dcpext0@1/y"),
           framebuffer(400, "DELL U3818DW", display: true, transport: "DP → HDMI"),
           proxy(401, provider: "AppleDCPMCDP29XX", path: "IOService:/x/dcpext1@2/y")]
screens = [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 400, direct: true)]
ports = MonitorDiscovery.ports(in: entries, screens: screens)
expect(ports.map(\.connection) == [401, 301], "the Dell's port comes first; the empty one (Hammer's old pick) last")
expect(ports[0].throughHDMIConverter && ports[0].ways.first?.chip == 0xB7 && ports[0].ways.count == 6
       && ports[0].looksLikeHDMI && ports[0].label == "dcpext1", "the Dell is behind the HDMI converter")
expect(!ports[1].attached && ports[1].name == nil && !ports[1].throughHDMIConverter, "the empty port")

// Without CoreDisplay (no screen ↔ framebuffer link), the EDID still tells.
ports = MonitorDiscovery.ports(in: entries, screens: [])
expect(ports.map(\.connection) == [401, 301] && ports[0].name == "DELL U3818DW", "found from the EDID alone")

// Odd orders never pair the Dell's connection with the wrong screen.
ports = MonitorDiscovery.ports(in: [proxy(1), framebuffer(2, "X", display: true)], screens: [])
expect(ports.count == 1 && ports[0].framebuffer == nil && !ports[0].attached, "connection before any framebuffer")
ports = MonitorDiscovery.ports(in: [framebuffer(100, display: true), proxy(5)], screens: [builtIn])
expect(ports.count == 1 && ports[0].name == nil && !ports[0].attached, "never paired with the built-in screen")
ports = MonitorDiscovery.ports(in: [framebuffer(2, "X", display: true), proxy(3), proxy(4)], screens: [])
expect(ports.map(\.connection) == [3, 4] && ports[0].attached && !ports[1].attached, "one connection per framebuffer")
expect(MonitorDiscovery.ports(in: [framebuffer(2, display: true), proxy(3, nil)], screens: []).isEmpty,
       "a connection without a location is skipped")
expect(MonitorDiscovery.shortLabel("IOService:/AppleARMPE/arm-io@10F00000/AppleT600xIO/dcpext0@A8000000/x") == "dcpext0"
       && MonitorDiscovery.shortLabel("") == nil && MonitorDiscovery.shortLabel("IOService:/a/b") == nil, "port labels")

// MARK: Monitor: the set the app uses

func member(_ port: MonitorPort, _ bus: FakeMonitor) -> MonitorSet.Member {
    MonitorSet.Member(port: port, link: fastLink(bus, port.ways))
}
let dellPort = MonitorPort(connection: 401, framebuffer: 400, name: "DELL U3818DW", attached: true,
                           throughHDMIConverter: false, transport: nil, label: nil)
let emptyPort = MonitorPort(connection: 301, framebuffer: 300, name: nil, attached: false,
                            throughHDMIConverter: false, transport: nil, label: nil)
var dell = FakeMonitor(), empty = FakeMonitor()
empty.writeStatus = Int32(bitPattern: 0xE00002C0)
var set = MonitorSet([member(emptyPort, empty), member(dellPort, dell)])
expect(set.targets.map(\.port.connection) == [401, 301], "before anyone answers: everywhere, the Dell's port first")
var found = set.read(code: 0x10)
expect(found?.reading.current == 40 && found?.member.port.connection == 401 && empty.writes.isEmpty,
       "reads the Dell first and never bothers the empty port")
set.write(code: 0x10, value: 70)
expect(dell.values[0x10]?.current == 70 && empty.writes.isEmpty, "sets go to the Dell only")

// Nothing tells which port has the monitor: ask them all, use the one that answers.
var blind = [emptyPort, dellPort].map { port -> MonitorPort in var p = port; p.attached = false; return p }
dell = FakeMonitor(); empty = FakeMonitor(); empty.ddcOn = false
set = MonitorSet([member(blind[0], empty), member(blind[1], dell)])
expect(set.targets.count == 2, "can't tell: settings go to every connection")
found = set.read(code: 0x10)
expect(found?.member.port.connection == 401 && set.members[0].answers == false && set.anyAnswers, "finds the one that answers")
expect(set.targets.map(\.port.connection) == [401], "then only to it")

// The monitor stops answering (e.g. DDC/CI switched off): back to sending everywhere.
dell.ddcOn = false
expect(set.read(code: 0x10) == nil && !set.anyAnswers && set.targets.count == 2, "stops answering")
expect(MonitorSet([]).read(code: 0x10) == nil && MonitorSet([]).targets.isEmpty, "no connections at all")

// MARK: Monitor: the check

let mac = MonitorCheck.Mac(model: "MacBookPro18,3", chip: "Apple M1 Pro", system: "Version 15.1 (Build 24B83)")
func runCheck(_ entries: [RegistryEntry], _ screens: [MonitorScreen], _ buses: [UInt64: FakeMonitor],
              on thisMac: MonitorCheck.Mac = mac) -> MonitorCheck {
    MonitorCheck.run(mac: thisMac, screens: screens, entries: entries, bus: { buses[$0] }, sleep: { _ in })
}
let airEntries = [framebuffer(100, display: true), proxy(101, "Embedded"),
                  framebuffer(200, "DELL U3818DW", display: true, transport: "DP → DP"), proxy(201)]
let airScreens = [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 200, direct: true)]

dell = FakeMonitor()
var check = runCheck(airEntries, airScreens, [201: dell])
expect(check.verdict == .working, "working Dell")
expect(check.ports[0].change == .confirmed(from: 40, to: 60) && dell.values[0x10]?.current == 40
       && dell.sets.map(\.value) == [60, 60, 40, 40] && check.ports[0].restored == true,
       "the change test moves brightness and puts it back")
expect(check.ports[0].contrast?.reading?.current == 75, "reads contrast too")
expect(check.text.contains("Result: Working. Hammer can read and change the DELL U3818DW's brightness.")
       && check.text.contains("Mac: MacBookPro18,3 · Apple M1 Pro · macOS Version 15.1 (Build 24B83)")
       && check.text.contains("Screens: Built-in Retina Display (built in), DELL U3818DW")
       && check.text.contains("also DCPAVServiceProxy (Embedded)")
       && check.text.contains("Change test: 40 → 60, read back 60, put back ✓"), "working report:\n\(check.text)")
dell = FakeMonitor(); dell.values[0x10] = (90, 100)
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.ports[0].change == .confirmed(from: 90, to: 70) && dell.values[0x10]?.current == 90, "bright screen: tests downward")

dell = FakeMonitor(); dell.values[0x10] = (10, 100)
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.ports[0].change == .confirmed(from: 10, to: 30) && dell.values[0x10]?.current == 10, "dim screen: tests upward")
dell = FakeMonitor(); dell.values[0x10] = (3, 3)
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.ports[0].change == .confirmed(from: 3, to: 2) && dell.values[0x10]?.current == 3, "tiny range")
dell = FakeMonitor(); dell.values[0x10] = (0, 0)
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.ports[0].change == nil && check.verdict == .untested && check.testNote == nil
       && check.advice[0].contains("couldn't test changing it"), "no range to test: says so")

dell = FakeMonitor(); dell.applySets = false
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.verdict == .ignoresChanges && check.advice.joined().contains("Display → Uniformity Compensation → Off")
       && check.advice.joined().contains("Display → Dynamic Contrast → Off") && check.testNote == nil
       && check.text.contains("read back 40, put back ✗"), "brightness locked")

dell = FakeMonitor(); dell.ddcOn = false
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.verdict == .noAnswer && check.ports[0].change == nil && dell.sets.isEmpty, "DDC/CI off: nothing set blindly")
expect(check.advice.joined(separator: "\n").contains("Menu → Others → DDC/CI → On")
       && !check.advice.joined().contains("HDMI") && check.text.contains("Last reply: 00 00 00"), "DDC/CI off: advice")

// M1 Pro, Dell on HDMI behind the converter, empty port listed first.
let proEntries = [framebuffer(100, display: true), proxy(101, "Embedded"),
                  framebuffer(300), proxy(301),
                  framebuffer(400, "DELL U3818DW", display: true, transport: "DP → HDMI"),
                  proxy(401, provider: "AppleDCPMCDP29XX", path: "IOService:/x/dcpext1@2/y")]
let proScreens = [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 400, direct: true)]
dell = FakeMonitor(); dell.chip = 0xB7
empty = FakeMonitor(); empty.writeStatus = Int32(bitPattern: 0xE00002C0)
check = runCheck(proEntries, proScreens, [301: empty, 401: dell])
expect(check.verdict == .working && check.ports[0].brightness.way?.chip == 0xB7, "M1 HDMI works through 0xB7")
expect(check.text.contains("DELL U3818DW (dcpext1, DP → HDMI, HDMI converter)")
       && check.text.contains("No monitor seen here") && check.text.contains("error e00002c0"), "HDMI report:\n\(check.text)")
dell.ddcOn = false
check = runCheck(proEntries, proScreens, [301: empty, 401: dell])
expect(check.verdict == .noAnswer && check.advice.joined().contains("Use USB-C rather than HDMI"), "silent over HDMI")

// Other setups.
let displayLink = [builtIn, MonitorScreen(id: 3, name: "DELL U3818DW", builtIn: false, framebuffer: nil, direct: false)]
let unplugged = FakeMonitor(); unplugged.writeStatus = Int32(bitPattern: 0xE00002C0)
check = runCheck([framebuffer(100, display: true), proxy(101, "Embedded"), framebuffer(300), proxy(301)],
                 displayLink, [301: unplugged])
expect(check.verdict == .notDirect && check.text.contains("DELL U3818DW (through DisplayLink, AirPlay or Sidecar)")
       && check.advice.joined().contains("straight into the Mac"), "DisplayLink")
check = runCheck([framebuffer(100, display: true), proxy(101, "Embedded"), framebuffer(300), proxy(301)],
                 [builtIn], [301: unplugged])
expect(check.verdict == .noMonitor && check.monitorName == "the monitor", "nothing plugged in")
check = runCheck([framebuffer(100, display: true), proxy(101, "Embedded")],
                 [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 900, direct: true)], [:])
expect(check.verdict == .notFound && check.text.contains("External connections: 0 · also DCPAVServiceProxy (Embedded)")
       && check.advice.first == "Result: macOS shows the DELL U3818DW, but Hammer can't find the connection it's on.",
       "shown but no connection found")
dell = FakeMonitor(); dell.writeStatus = Int32(bitPattern: 0xE00002BC)
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.verdict == .cantSend && check.text.contains("Sent: no (error e00002bc)")
       && check.advice.joined().contains("not through a hub"), "port refuses")
check = runCheck(proEntries, proScreens, [301: empty])
expect(check.verdict == .cantSend && check.text.contains("macOS gave Hammer no way to talk to it")
       && check.advice.joined().contains("HDMI port doesn't pass monitor control"), "no service for the Dell's port")
check = runCheck([], [], [:])
expect(check.verdict == .noMonitor && check.text.contains("Screens: none") && check.text.contains("Mac: MacBookPro18,3"),
       "empty everything")


// MARK: Monitor: more setups (from the review)

// A wrong address that's silently accepted, not refused: sets still reach the monitor.
monitor = FakeMonitor(); monitor.wrongChipStatus = 0
link = fastLink(monitor, viaConverter)
expect(link.write(code: 0x10, value: 33) == 0 && monitor.values[0x10]?.current == 33,
       "converter detected wrongly, wrong address silent: the set still arrives on 0x37")
read = link.read(code: 0x10)
expect(read.reading?.current == 33 && read.way?.chip == 0x37 && read.tries == 7, "and reads find 0x37 after the 0xB7 ways")

// A Dell that takes sets but never answers, with a stale EDID making an empty port look used.
let staleEntries = [framebuffer(100, display: true), proxy(101, "Embedded"),
                    framebuffer(300, display: true), proxy(301),          // stale: nothing plugged in
                    framebuffer(400, display: true), proxy(401)]          // the Dell, but not linked to a screen
ports = MonitorDiscovery.ports(in: staleEntries, screens: [builtIn])
expect(ports.map(\.attached) == [false, false], "only the built-in screen: a leftover EDID doesn't count")
ports = MonitorDiscovery.ports(in: staleEntries,
                               screens: [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: nil, direct: nil)])
expect(ports.map(\.attached) == [true, true], "an external screen macOS doesn't link: the EDID decides (both look used)")
ports = MonitorDiscovery.ports(in: staleEntries,
                               screens: [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 999, direct: true)])
expect(ports.map(\.attached) == [true, true], "a link to a framebuffer Hammer didn't list: the EDID decides")
ports = MonitorDiscovery.ports(in: staleEntries,
                               screens: [builtIn, MonitorScreen(id: 3, name: "iPad", builtIn: false, framebuffer: nil, direct: false)])
expect(ports.map(\.attached) == [false, false], "only a Sidecar screen: a leftover EDID doesn't count")
ports = MonitorDiscovery.ports(in: staleEntries,
                               screens: [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 400, direct: true)])
expect(ports.map(\.connection) == [401, 301] && ports.map(\.attached) == [true, false],
       "with a screen linked, a stale EDID doesn't count")
dell = FakeMonitor(); dell.acceptedReadOffsets = []                      // write-only
empty = FakeMonitor(); empty.ddcOn = false
var wrongFirst = emptyPort; wrongFirst.attached = true                   // stale: looks used
var dellUnseen = dellPort; dellUnseen.attached = false
set = MonitorSet([member(wrongFirst, empty), member(dellUnseen, dell)])
expect(set.read(code: 0x10) == nil && !set.anyAnswers, "nobody answers")
set.write(code: 0x10, value: 55)
expect(dell.values[0x10]?.current == 55, "the set still reaches the write-only Dell (as Hammer always did)")

// A connection listed before its framebuffer, on a Mac with several ports.
ports = MonitorDiscovery.ports(in: [framebuffer(100, display: true), proxy(101, "Embedded"), proxy(301),
                                    framebuffer(300), framebuffer(400, "DELL U3818DW", display: true), proxy(401)],
                               screens: [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 400, direct: true)])
expect(ports.map(\.connection) == [401, 301] && ports[1].name == nil && !ports[1].attached,
       "an early connection isn't given the built-in screen or the Dell")

// "No such setting" from one connection: keep looking, and it isn't a target.
let quietPort = MonitorPort(connection: 9, framebuffer: nil, name: "Other", attached: true,
                            throughHDMIConverter: false, transport: nil, label: nil)
let other = FakeMonitor(); other.supported = []
dell = FakeMonitor()
set = MonitorSet([member(quietPort, other), member(dellPort, dell)])
found = set.read(code: 0x10)
expect(found?.member.port.connection == 401 && set.members[0].answers == false && set.lastReadUnsupported
       && set.targets.map(\.port.connection) == [401, 9],
       "\"no such setting\": keep looking; the answering monitor first, the other still gets settings")

// macOS's default connection is asked last.
let defaultMonitor = FakeMonitor()
set = MonitorSet([member(.macDefault, defaultMonitor), member(emptyPort, FakeMonitor()), member(dellPort, FakeMonitor())])
expect(set.ordered.map(\.port.connection) == [401, 301, 0], "order: monitor seen, others, macOS default")

// Asking several silent connections: how long, and giving way to a slider.
let silent = (0..<3).map { _ -> FakeMonitor in let m = FakeMonitor(); m.ddcOn = false; return m }
clock = Clock()
set = MonitorSet([MonitorSet.Member(port: dellPort, link: fastLink(silent[0], dellPort.ways, clock)),
                  MonitorSet.Member(port: emptyPort, link: fastLink(silent[1], emptyPort.ways, clock)),
                  MonitorSet.Member(port: viaConverterPort(), link: fastLink(silent[2], viaConverter, clock))])
expect(set.read(code: 0x10) == nil && !set.lastReadInterrupted, "three silent connections")
expect(clock.slept < 3_200_000, "asked in under 3.2 s of waiting (\(clock.slept) µs)")
clock.slept = 0
var stopChecks = 0
set = MonitorSet([MonitorSet.Member(port: dellPort, link: fastLink(silent[0], dellPort.ways, clock)),
                  MonitorSet.Member(port: emptyPort, link: fastLink(silent[1], emptyPort.ways, clock))])
expect(set.read(code: 0x10, stop: { stopChecks += 1; return stopChecks > 1 }) == nil && set.lastReadInterrupted
       && clock.slept < 200_000 && set.members.allSatisfy { $0.answers == nil },
       "a moved slider stops the read within a try, and nothing is concluded")
let moves = SliderMoves()
let before = Date()
expect(!moves.movedSince(before), "no move yet")
moves.moved(at: before.addingTimeInterval(1))
expect(moves.movedSince(before) && !moves.movedSince(before.addingTimeInterval(2)), "moves are timed")

// The check: a monitor that goes quiet after the change, one that won't go back, a bad checksum.
dell = FakeMonitor(); dell.answerLimit = 2                               // brightness, contrast, then nothing
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.ports[0].change == .noReadBack(from: 40, to: 60) && check.verdict == .unsure
       && check.ports[0].restored == nil && dell.values[0x10]?.current == 40, "went quiet: unsure, still put back")
expect(check.advice.joined().contains("Did the screen get brighter or dimmer"), "asks what you saw")
dell = FakeMonitor(); dell.applyLimit = 2                                // takes the change, not the way back
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.ports[0].change == .confirmed(from: 40, to: 60) && check.ports[0].restored == false
       && dell.sets.map(\.value) == [60, 60, 40, 40, 40, 40], "tries twice to put it back")
expect(check.text.contains("put back (but it reads differently now) ✓")
       && check.testNote?.contains("didn't go back exactly") == true, "and says so")
dell = FakeMonitor(); dell.corruptReplies = true
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.verdict == .untested && check.ports[0].change == nil && dell.sets.isEmpty
       && check.text.contains("40 of 100 (reply had a wrong checksum)"), "a doubtful reading isn't used for the test")
dell = FakeMonitor(); dell.supported = [0x12]
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.verdict == .noBrightness && check.advice.joined().contains("no brightness setting"), "no brightness setting")

// The check falls back to macOS's default connection only if no port answered.
dell = FakeMonitor(); dell.ddcOn = false
let fallbackMonitor = FakeMonitor()
check = MonitorCheck.run(mac: mac, screens: airScreens, entries: airEntries, bus: { $0 == 201 ? dell : nil },
                         defaultBus: fallbackMonitor, sleep: { _ in })
expect(check.ports.count == 2 && check.ports[1].port.isDefault && check.verdict == .working
       && check.text.contains("Tried last (macOS default connection)") && check.text.contains("External connections: 1"),
       "the default connection, tried last, works:\n\(check.text)")
dell = FakeMonitor()
check = MonitorCheck.run(mac: mac, screens: airScreens, entries: airEntries, bus: { $0 == 201 ? dell : nil },
                         defaultBus: fallbackMonitor, sleep: { _ in })
expect(check.ports.count == 1, "not tried when the Dell's port answers")
check = MonitorCheck.run(mac: mac, screens: [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: nil, direct: true)],
                         entries: [framebuffer(100, display: true), proxy(101, "Embedded")], bus: { _ in nil },
                         defaultBus: fallbackMonitor, sleep: { _ in })
expect(check.verdict == .working, "no External connection listed at all: the default connection still works")

// A Sidecar iPad next to a directly cabled Dell doesn't make it "DisplayLink".
dell = FakeMonitor(); dell.ddcOn = false
let withIPad = airScreens + [MonitorScreen(id: 5, name: "Sidecar Display (AirPlay)", builtIn: false, framebuffer: nil, direct: false)]
check = runCheck(airEntries, withIPad, [201: dell])
expect(check.verdict == .noAnswer && check.monitorName == "the DELL U3818DW", "Sidecar alongside: still the Dell's problem")
check = runCheck([framebuffer(100, display: true), proxy(101, "Embedded"), framebuffer(300), proxy(301)],
                 [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: nil, direct: nil)],
                 [301: silent[0]])
expect(check.verdict == .noAnswer, "nothing seen attached, but connections sent fine: no answer, not \"can't find\"")

// The menu.
let dellScreen = MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 400, direct: true)
let dlScreen = MonitorScreen(id: 3, name: "DELL U3818DW", builtIn: false, framebuffer: nil, direct: false)
var state = MonitorMenu.make(connections: 2, attached: 0, screens: [builtIn], answers: nil)
expect(state.title == "Dell not connected" && !state.sliders && !state.offerCheck, "menu: nothing plugged in")
state = MonitorMenu.make(connections: 0, attached: 0, screens: [builtIn, dlScreen], answers: nil)
expect(state.title == "Dell connected through DisplayLink or AirPlay" && !state.sliders && state.offerCheck, "menu: DisplayLink")
state = MonitorMenu.make(connections: 0, attached: 0, screens: [builtIn, dellScreen], answers: nil)
expect(state.title == "Can't find the Dell's connection" && state.offerCheck, "menu: no connection")
state = MonitorMenu.make(connections: 2, attached: 1, screens: [builtIn, dellScreen], answers: true)
expect(state.title == nil && state.sliders && state.hints.isEmpty && state.offerCheck, "menu: working")
state = MonitorMenu.make(connections: 2, attached: 1, screens: [builtIn, dellScreen], answers: false)
expect(state.sliders && state.hints == ["The Dell isn't answering Hammer."], "menu: not answering")
state = MonitorMenu.make(connections: 2, attached: 0, screens: [builtIn, dlScreen], answers: false)
expect(state.sliders && state.hints.count == 2, "menu: connections found but the screen looks virtual: sliders and a warning")


// MARK: Monitor: second review

// A monitor that rounds by one: still a confirmed change and a clean put-back.
dell = FakeMonitor(); dell.setSkew = -1
check = runCheck(airEntries, airScreens, [201: dell])
expect(check.ports[0].change == .confirmed(from: 40, to: 60) && check.ports[0].restored == true
       && dell.sets.map(\.value) == [60, 60, 40, 40] && check.testNote == "Hammer changed the brightness for a moment to test it, and put it back.",
       "rounding by 1 counts")

// Two monitors: the silent Dell is listed first, another one answers.
let twoEntries = airEntries + [framebuffer(500, "LG HDR 4K", display: true), proxy(501)]
let twoScreens = airScreens + [MonitorScreen(id: 6, name: "LG HDR 4K", builtIn: false, framebuffer: 500, direct: true)]
dell = FakeMonitor(); dell.ddcOn = false
check = runCheck(twoEntries, twoScreens, [201: dell, 501: FakeMonitor()])
expect(check.verdict == .working && check.monitorName == "the LG HDR 4K", "names the monitor that answered")
let lgPort = MonitorPort(connection: 501, framebuffer: 500, name: "LG HDR 4K", attached: true,
                         throughHDMIConverter: false, transport: nil, label: nil)
dell = FakeMonitor(); dell.acceptedReadOffsets = []                      // takes sets, never answers
let lg = FakeMonitor()
set = MonitorSet([member(dellPort, dell), member(lgPort, lg)])
_ = set.read(code: 0x10)
set.write(code: 0x10, value: 66)
expect(lg.values[0x10]?.current == 66 && dell.values[0x10]?.current == 66,
       "the Dell that doesn't answer still gets settings once the other monitor answers")

// macOS's default connection: when to use it, and what it means if it's all there is.
expect(!MonitorDiscovery.useDefault(ports: [emptyPort], screens: [builtIn]), "default: not with nothing plugged in")
expect(!MonitorDiscovery.useDefault(ports: [], screens: [builtIn, dlScreenForDefault()]), "default: not for DisplayLink")
expect(MonitorDiscovery.useDefault(ports: [dellPort], screens: [builtIn]), "default: with a monitor seen on a port")
expect(MonitorDiscovery.useDefault(ports: [], screens: airScreens), "default: with an external screen")
let silentDefault = FakeMonitor(); silentDefault.ddcOn = false
check = MonitorCheck.run(mac: mac, screens: [builtIn, MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: nil, direct: true)],
                         entries: [framebuffer(100, display: true), proxy(101, "Embedded")], bus: { _ in nil },
                         defaultBus: silentDefault, sleep: { _ in })
expect(check.verdict == .notFound && check.ports.count == 1, "only macOS's default, silent: can't find the connection")
check = MonitorCheck.run(mac: mac, screens: [builtIn], entries: staleEntries,
                         bus: { _ in let m = FakeMonitor(); m.ddcOn = false; return m },
                         defaultBus: FakeMonitor(), sleep: { _ in })
expect(check.ports.allSatisfy { !$0.port.isDefault } && check.ports.allSatisfy { !$0.port.attached },
       "Dell unplugged: the default isn't tried")
let staleBuses: [UInt64: FakeMonitor] = [301: silent[1], 401: silent[2]]
check = runCheck(staleEntries, [builtIn], staleBuses)
expect(check.verdict == .noMonitor, "Dell unplugged, EDID left behind: \"doesn't see an external monitor\"")

// The menu with only macOS's default connection.
state = MonitorMenu.make(connections: 0, hasDefault: true, attached: 0, screens: [builtIn, dellScreen], answers: nil)
expect(state.sliders && state.hints == ["Can't find the Dell's port; trying the Mac's default."] && state.offerCheck,
       "menu: only the default connection")
state = MonitorMenu.make(connections: 0, hasDefault: true, attached: 0, screens: [builtIn, dellScreen], answers: true)
expect(state.sliders && state.hints.isEmpty, "menu: the default connection works")


// MARK: Monitor: reading the EDID, and the report from a MacBook Pro on macOS 26

let dellEDID = makeEDID("DELL U3818DW")
expect(EDID.isValid(dellEDID) && EDID.name(dellEDID) == "DELL U3818DW", "EDID: valid, with the model name")
var badEDID = dellEDID; badEDID[20] ^= 1
expect(!EDID.isValid(badEDID) && !EDID.isValid(Array(dellEDID.prefix(100))) && !EDID.isValid([UInt8](repeating: 0, count: 128)),
       "EDID: wrong checksum, too short, or zeros")
expect(EDID.name(makeEDID("LG HDR 4K")) == "LG HDR 4K" && EDID.name(makeEDID("ABCDEFGHIJKLMNOP")) == "ABCDEFGHIJKLM"
       && EDID.name([UInt8](repeating: 0, count: 128)) == nil && EDID.name([]) == nil, "EDID: names, long names, none")

// What the 16" MacBook Pro (M1 Pro, macOS 26) reported: sent fine, every read fails with e0114103.
let avError = Int32(bitPattern: 0xE0114103)
let proUSBC = [framebuffer(300, "DELL U3818DW", display: true, transport: "DP → DP"),
               proxy(301, path: "IOService:/x/dcpext0@1/y")]
let lidClosed = [MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 300, direct: true)]
dell = FakeMonitor(); dell.readStatus = avError
check = runCheck(proUSBC, lidClosed, [301: dell])
expect(check.verdict == .noAnswer && check.wireReads == true, "DDC reads fail, the EDID reads fine")
expect(check.text.contains("Its ID info (EDID), from macOS: DELL U3818DW") && check.text.contains("Read errors: e0114103 ×7")
       && check.text.contains("Brightness: no answer after 7 tries")
       && check.text.contains("Its ID info (EDID) over the same wire: read fine")
       && check.advice.joined().contains("its control channel (DDC/CI) doesn't answer")
       && check.advice.joined().contains("not through a hub, dock or adapter")
       && check.advice.joined().contains("Unplug the monitor's power cord for 10 seconds"), "the report says so:\n\(check.text)")
dell = FakeMonitor(); dell.readStatus = avError; dell.edidReadStatus = avError
check = runCheck(proUSBC, lidClosed, [301: dell])
expect(check.verdict == .noAnswer && check.wireReads == false
       && check.text.contains("Its ID info (EDID) over the same wire: failed (error e0114103)")
       && check.advice.first == "Result: Nothing comes back from the DELL U3818DW over this connection, not even its ID info (EDID)."
       && check.advice.joined().contains("Menu → Others → DDC/CI → On"),
       "nothing can be read back at all")
dell = FakeMonitor(); dell.readStatus = avError; dell.edid = nil
check = runCheck(proUSBC, lidClosed, [301: dell])
expect(!check.text.contains("from macOS"), "no EDID from macOS: not mentioned")
expect(!dell.writes.contains { $0.chip == EDID.chip } && dell.reads.contains { $0.chip == EDID.chip && $0.offset == 0 },
       "the EDID is only ever read, from the start, never written")
dell = FakeMonitor(); dell.readStatus = avError; dell.edidReadGarbage = true
check = runCheck(proUSBC, lidClosed, [301: dell])
expect(check.wireReads == nil && check.text.contains("over the same wire: came back, but not as expected")
       && check.advice.first == "Result: Hammer sent messages to the DELL U3818DW, but it didn't answer.",
       "something that isn't an EDID: inconclusive, the general advice")
let convEntries = [framebuffer(400, "DELL U3818DW", display: true, transport: "DP → HDMI"),
                   proxy(401, provider: "AppleDCPMCDP29XX")]
dell = FakeMonitor(); dell.chip = 0xB7; dell.readStatus = avError
check = runCheck(convEntries, [MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 400, direct: true)], [401: dell])
expect(check.ports[0].edidOverI2C == nil && check.verdict == .noAnswer && check.advice.joined().contains("1. On the monitor")
       && check.advice.joined().contains("Use USB-C rather than HDMI"), "through the M1 HDMI converter: no EDID probe")
expect(check.ports[0].brightness.tries == 9,
       "converter: 3 ways × 2 on 0xB7, 0x37 refused after 2, one slow try on 0xB7")

// A monitor confused by the request being sent twice: only the slow single request works.
dell = FakeMonitor(); dell.oneRequestOnly = true
check = runCheck(proUSBC, lidClosed, [301: dell])
expect(check.verdict == .working && check.ports[0].brightness.slow && dell.requestsLost > 0
       && check.text.contains("only when asked slowly (one request, 150 ms wait)") && dell.values[0x10]?.current == 40
       && check.ports[0].restored == true, "answers only a single request: found, tested and put back")
dell = FakeMonitor(); dell.oneRequestOnly = true
set = MonitorSet([member(dellPort, dell)])
expect(set.read(code: 0x10)?.reading.current == 40 && set.members[0].link.slow, "the app learns it too")
read = set.members[0].link.read(code: 0x12)
expect(read.reading?.current == 75 && read.tries == 1, "and asks slowly straight away next time")
dell = FakeMonitor()
check = runCheck(proUSBC, lidClosed, [301: dell])
expect(check.ports[0].edidOverI2C == nil && check.wireReads == nil && !check.ports[0].brightness.slow
       && !dell.reads.contains { $0.chip == EDID.chip }, "a working monitor isn't probed further")
dell = FakeMonitor(); dell.writeStatus = Int32(bitPattern: 0xE00002BC)
check = runCheck(proUSBC, lidClosed, [301: dell])
expect(check.ports[0].edidOverI2C == nil && check.ports[0].brightness.tries == 2, "nothing sent: no probing, no slow try")

// A real-looking EDID: timing first, then serial, the name padded with zeros, then range limits.
var realEDID = makeEDID("X")
realEDID.replaceSubrange(54..<72, with: [0x56, 0x5E] + [UInt8](repeating: 0x11, count: 16))      // a timing
realEDID.replaceSubrange(72..<90, with: [0, 0, 0, 0xFF, 0] + Array("ABC123".utf8) + [0x0A] + [UInt8](repeating: 0x20, count: 6))
realEDID.replaceSubrange(90..<108, with: [0, 0, 0, 0xFC, 0] + Array("DELL U3818DW".utf8) + [0x00])
realEDID.replaceSubrange(108..<126, with: [0, 0, 0, 0xFD, 0] + [UInt8](repeating: 0x30, count: 13))
realEDID[127] = 0 &- realEDID[0..<127].reduce(UInt8(0), &+)
expect(EDID.isValid(realEDID) && EDID.name(realEDID) == "DELL U3818DW", "EDID laid out like a real one, zero padding")
var twoNames = realEDID
twoNames.replaceSubrange(72..<90, with: [0, 0, 0, 0xFC, 0] + [UInt8](repeating: 0x20, count: 13))
expect(EDID.name(twoNames) == "DELL U3818DW", "an empty name descriptor is skipped")

// Which probes count: the port with the monitor.
dell = FakeMonitor(); dell.readStatus = avError
let deadEmpty = FakeMonitor(); deadEmpty.readStatus = avError; deadEmpty.edidReadStatus = avError
let mixEntries = [framebuffer(300, "DELL U3818DW", display: true), proxy(301), framebuffer(500), proxy(501)]
check = runCheck(mixEntries, [MonitorScreen(id: 2, name: "DELL U3818DW", builtIn: false, framebuffer: 300, direct: true)],
                 [301: dell, 501: deadEmpty])
expect(check.wireReads == true, "the empty port's failed probe doesn't count against the Dell's")


// MARK: Monitor: a USB-C to HDMI cable (what the user had)

expect(EDID.input(makeEDID("DELL U3818DW", hdmi: true)) == .hdmi, "EDID: HDMI vendor block → HDMI input")
expect(EDID.input(makeEDID("DELL U3818DW", hdmiForum: true)) == .hdmi, "EDID: HDMI Forum block → HDMI input")
expect(EDID.input(makeEDID("DELL U3818DW", interface: 0x5)) == .displayPort, "EDID 1.4: DisplayPort")
expect(EDID.input(makeEDID("DELL U3818DW", interface: 0x2)) == .hdmi, "EDID 1.4: HDMI-a")
expect(EDID.input(makeEDID("DELL U3818DW")) == nil, "plain EDID: can't tell")
var brokenCTA = makeEDID("DELL U3818DW", hdmi: true); brokenCTA[128 + 2] = 200
expect(EDID.input(brokenCTA) == nil || EDID.input(brokenCTA) == .hdmi, "a nonsense extension doesn't crash")
expect(EDID.input(Array(makeEDID("DELL U3818DW", hdmi: true).prefix(128))) == nil, "extension missing: can't tell")
expect(EDID.name(makeEDID("DELL U3818DW", hdmi: true)) == "DELL U3818DW", "name still found with an extension")

dell = FakeMonitor(); dell.readStatus = avError; dell.edid = makeEDID("DELL U3818DW", hdmi: true)
check = runCheck(proUSBC, lidClosed, [301: dell])
expect(check.verdict == .hdmiAdapter && check.ports[0].port.throughHDMIAdapter(onMac: mac.model)
       && check.text.contains("Its ID info (EDID), from macOS: DELL U3818DW, on its HDMI input")
       && check.advice.joined(separator: " ").contains("a USB-C to USB-C cable into the monitor's USB-C port")
       && check.advice.joined(separator: " ").contains("Input Source → USB Type-C"), "USB-C to HDMI cable:\n\(check.text)")
dell = FakeMonitor(); dell.edid = makeEDID("DELL U3818DW", hdmi: true)
check = runCheck(proUSBC, lidClosed, [301: dell])
expect(check.verdict == .working, "an adapter that does pass DDC: working")
dell = FakeMonitor(); dell.readStatus = avError; dell.edid = makeEDID("DELL U3818DW", interface: 0x5)
check = runCheck(proUSBC, lidClosed, [301: dell])
expect(check.verdict == .noAnswer && check.text.contains("on its DisplayPort/USB-C input"), "on DisplayPort: not the adapter")
dell = FakeMonitor(); dell.chip = 0xB7; dell.ddcOn = false; dell.edid = makeEDID("DELL U3818DW", hdmi: true)
empty = FakeMonitor(); empty.writeStatus = Int32(bitPattern: 0xE00002C0)
check = runCheck(proEntries, proScreens, [301: empty, 401: dell])
expect(check.verdict == .noAnswer && !check.ports[0].port.throughHDMIAdapter(onMac: mac.model), "the Mac's own HDMI port isn't \"an adapter\"")
state = MonitorMenu.make(connections: 1, attached: 1, screens: lidClosed, answers: false, hdmiAdapter: true)
expect(state.sliders && state.hints == ["The Dell is on HDMI from USB-C, which usually",
                                        "blocks control. Use its DisplayPort or USB-C port."], "menu: says to leave HDMI")
state = MonitorMenu.make(connections: 1, attached: 1, screens: lidClosed, answers: true, hdmiAdapter: true)
expect(state.hints.isEmpty, "menu: an adapter that works isn't mentioned")

// What the user had next: a USB-C to DisplayPort adapter, then HDMI into the Dell. macOS calls
// the link "DP → HDMI" (no M1 converter) and refuses to send (e0114000).
let belkinEntries = [framebuffer(300, "DELL U3818DW", display: true, transport: "DP → HDMI"),
                     proxy(301, path: "IOService:/x/dcpext0@1/y")]
dell = FakeMonitor(); dell.writeStatus = Int32(bitPattern: 0xE0114000); dell.edid = makeEDID("DELL U3818DW", hdmi: true)
check = runCheck(belkinEntries, lidClosed, [301: dell])
let belkinAdvice = check.advice.joined(separator: "\n")
expect(check.verdict == .hdmiAdapter && check.ports[0].port.throughHDMIAdapter(onMac: mac.model)
       && check.text.contains("DELL U3818DW (dcpext0, DP → HDMI)") && check.text.contains("Sent: no (error e0114000)"),
       "USB-C, then HDMI into the monitor, reported as DP → HDMI: the adapter case\n\(check.text)")
expect(belkinAdvice.contains("plugged into one of its HDMI ports") && belkinAdvice.contains("plus the DisplayPort cable from the Dell's box, into its DP port")
       && belkinAdvice.contains("Not a DisplayPort to HDMI cable") && !belkinAdvice.contains("This Mac's HDMI port")
       && !belkinAdvice.contains("\n    "), // no indented lines: the check's window doesn't use a fixed-width font
       "says to use the monitor's DP or USB-C port, not that the Mac's own HDMI port is the problem:\n\(belkinAdvice)")
// The same, but the monitor's ID info doesn't say which input: no guessing about adapters.
dell = FakeMonitor(); dell.writeStatus = Int32(bitPattern: 0xE0114000); dell.edid = makeEDID("DELL U3818DW")
check = runCheck(belkinEntries, lidClosed, [301: dell])
expect(check.verdict == .cantSend && check.advice.joined().contains("Connect to the monitor's DisplayPort or USB-C port instead (not HDMI)")
       && !check.advice.joined().contains("This Mac's HDMI port"), "HDMI link, input unknown: still points at DP or USB-C\n\(check.text)")

// A newer Mac's own HDMI port (no M1 converter) looks the same to macOS: no adapter claimed there.
let newerMac = MonitorCheck.Mac(model: "Mac14,6", chip: "Apple M2 Max", system: "Version 15.1 (Build 24B83)")
dell = FakeMonitor(); dell.ddcOn = false; dell.edid = makeEDID("DELL U3818DW", hdmi: true)
check = runCheck(belkinEntries, lidClosed, [301: dell], on: newerMac)
expect(check.verdict == .noAnswer && check.advice.joined().contains("Menu → Others → DDC/CI → On")
       && !check.advice.joined().contains("from a USB-C port on the Mac"), "a newer Mac's own HDMI port: the DDC/CI advice\n\(check.text)")
dell = FakeMonitor(); dell.writeStatus = Int32(bitPattern: 0xE0114000); dell.edid = makeEDID("DELL U3818DW", hdmi: true)
check = runCheck(belkinEntries, lidClosed, [301: dell], on: newerMac)
expect(check.verdict == .cantSend && check.advice.joined().contains("HDMI doesn't pass monitor control here")
       && !check.advice.joined().contains("This Mac's HDMI port"), "…and if nothing can be sent there: use DP or USB-C, no blame")
// The M1-era HDMI port (converter) refusing to send: the Mac's own port is named.
dell = FakeMonitor(); dell.chip = 0xB7; dell.writeStatus = Int32(bitPattern: 0xE0114000); dell.edid = makeEDID("DELL U3818DW", hdmi: true)
check = runCheck(proEntries, proScreens, [301: empty, 401: dell])
expect(check.verdict == .cantSend && check.advice.joined().contains("This Mac's HDMI port doesn't pass monitor control"),
       "M1 HDMI port refuses: says so\n\(check.text)")
// The monitor says it's on DisplayPort, though the link is called HDMI: never told to leave HDMI.
dell = FakeMonitor(); dell.writeStatus = Int32(bitPattern: 0xE0114000); dell.edid = makeEDID("DELL U3818DW", interface: 0x5)
check = runCheck(belkinEntries, lidClosed, [301: dell])
expect(check.verdict == .cantSend && !check.advice.joined().contains("HDMI"), "on its DisplayPort input: no HDMI advice\n\(check.text)")
// Which Macs can only mean an adapter.
expect(MonitorPort.hdmiLinkIsAdapter(onMac: "MacBookPro18,1") && MonitorPort.hdmiLinkIsAdapter(onMac: "MacBookAir10,1")
       && MonitorPort.hdmiLinkIsAdapter(onMac: "Mac15,13") && !MonitorPort.hdmiLinkIsAdapter(onMac: "Mac14,6")
       && !MonitorPort.hdmiLinkIsAdapter(onMac: "Mac16,10") && !MonitorPort.hdmiLinkIsAdapter(onMac: "")
       && !MonitorPort.hdmiLinkIsAdapter(onMac: "Macmini9,1"), "Macs whose HDMI links can only be adapters")


// MARK: Monitor: dimming the picture in software

expect(SoftwareDim.factor(level: 100) == 1 && SoftwareDim.factor(level: 0) == SoftwareDim.floor
       && abs(SoftwareDim.factor(level: 50) - 0.575) < 1e-9, "slider 0–100 → 15%–100% of the light")
expect(SoftwareDim.factor(level: -20) == SoftwareDim.floor && SoftwareDim.factor(level: 250) == 1, "out-of-range levels are clamped")
expect(SoftwareDim.floor >= 0.1, "never dark enough to lose the screen")
let dimCurve: [Float] = [0, 0.25, 0.5, 1]
expect(SoftwareDim.scaled(dimCurve, by: 0.5) == [0, 0.125, 0.25, 0.5], "the curve scales down")
expect(SoftwareDim.scaled(dimCurve, by: 1) == dimCurve, "100%: the curve as it was")
expect(SoftwareDim.scaled([1.2, -0.1], by: 2) == [1, 0], "never outside 0…1, whatever comes in")
expect(SoftwareDim.key(vendor: 0x10AC, model: 0xD0D1, serial: 0x4C4C) == "softwareDim.10ac-d0d1-4c4c", "saved per monitor")
expect(SoftwareDim.applies(answers: false, misses: 1, hdmiAdapter: true), "HDMI adapter, no answer: at once")
expect(!SoftwareDim.applies(answers: false, misses: 1, hdmiAdapter: false)
       && SoftwareDim.applies(answers: false, misses: 2, hdmiAdapter: false), "otherwise after two misses in a row")
expect(SoftwareDim.applies(answers: false, misses: 1, hdmiAdapter: false, wasDimming: true)
       && !SoftwareDim.applies(answers: true, misses: 0, hdmiAdapter: false, wasDimming: true),
       "already dimming before a wake or replug: carries on at the first miss, stops once it answers")
expect(!SoftwareDim.applies(answers: true, misses: 0, hdmiAdapter: true) && !SoftwareDim.applies(answers: nil, misses: 5, hdmiAdapter: true),
       "answers (or not asked yet): the monitor's own brightness")
state = MonitorMenu.make(connections: 1, attached: 1, screens: lidClosed, answers: false, hdmiAdapter: true, software: true)
expect(state.sliders && !state.contrast && state.offerCheck
       && state.hints == ["Dimming the picture: Hammer can't reach the", "Dell through a USB-C to HDMI adapter."],
       "menu, adapter: Brightness dims the picture, no Contrast, says why")
state = MonitorMenu.make(connections: 1, attached: 1, screens: lidClosed, answers: false, software: true)
expect(state.sliders && !state.contrast && state.hints == ["Dimming the picture: the Dell isn't answering Hammer."],
       "menu, no answer: the same")
state = MonitorMenu.make(connections: 1, attached: 1, screens: lidClosed, answers: true)
expect(state.sliders && state.contrast && state.hints.isEmpty, "menu, working: both sliders, no hint")

// Which slider shows: before the monitor is asked again (after a wake or replug), whatever was in use.
expect(SoftwareDim.showing(answers: nil, misses: 0, hdmiAdapter: false, wasDimming: true)
       && !SoftwareDim.showing(answers: nil, misses: 0, hdmiAdapter: true, wasDimming: false),
       "not asked yet: the slider that was in use")
expect(SoftwareDim.showing(answers: false, misses: 1, hdmiAdapter: true, wasDimming: false)
       && !SoftwareDim.showing(answers: true, misses: 0, hdmiAdapter: true, wasDimming: true), "asked: what it said")

// The curves to dim from.
func ramp(_ n: Int, top: Float = 1) -> [Float] { (0..<n).map { Float($0) / Float(n - 1) * top } }
let ownCurves = GammaCurves(r: ramp(256), g: ramp(256), b: ramp(256))
let profile2 = GammaCurves(r: ramp(256, top: 0.98), g: ramp(256, top: 0.97), b: ramp(256, top: 0.96))
let halfDim = ownCurves.scaled(by: SoftwareDim.factor(level: 50))
expect(ownCurves.isScreensOwn && profile2.isScreensOwn, "a screen's own curves look like its own")
expect(!halfDim.isScreensOwn && !ownCurves.scaled(by: 0.85).isScreensOwn, "a dimmed curve doesn't")
expect(GammaCurves(r: ramp(256), g: ramp(256, top: 0.93), b: ramp(256, top: 0.78)).isScreensOwn,
       "a calibrated profile with a warm white point is the screen's own")
expect(!GammaCurves(r: ramp(256), g: ramp(256, top: 0.8), b: ramp(256, top: 0.5)).isScreensOwn,
       "a color-shifting app's curves (blue held down) aren't")
expect(!GammaCurves(r: ramp(256), g: [Float](repeating: 0, count: 256), b: ramp(256)).isScreensOwn
       && !GammaCurves(r: [1], g: [1], b: [1]).isScreensOwn && !GammaCurves(r: [], g: [], b: []).isScreensOwn,
       "nor a zeroed or empty one")
let resampled = GammaCurves(r: ramp(1024), g: ramp(1024), b: ramp(1024)).scaled(by: SoftwareDim.factor(level: 50))
expect(halfDim.matches(resampled), "the same curves handed back with more steps still match")
expect(!halfDim.matches(ownCurves) && !halfDim.matches(ownCurves.scaled(by: 0.6)), "different curves don't")
expect(SoftwareDim.base(live: ownCurves, written: nil, previous: nil) == ownCurves, "first time: the screen's curves")
expect(SoftwareDim.base(live: resampled, written: halfDim, previous: ownCurves) == ownCurves,
       "the curves are Hammer's own dimming: the original, so dimming never stacks")
expect(SoftwareDim.base(live: profile2, written: halfDim, previous: ownCurves) == profile2,
       "macOS reset them or a new color profile: picked up")
let otherApp = ownCurves.scaled(by: 0.6)
expect(SoftwareDim.base(live: otherApp, written: halfDim, previous: ownCurves) == ownCurves
       && SoftwareDim.base(live: otherApp, written: nil, previous: nil) == nil,
       "another app dimmed them: never taken as the original (and with nothing known, no dimming)")
expect(SoftwareDim.base(live: nil, written: nil, previous: ownCurves) == ownCurves && SoftwareDim.base(live: nil, written: nil, previous: nil) == nil,
       "can't read them: the original kept, if any")
// Re-applying over and over (every wake, every 10 seconds) never darkens it further.
var dimScreen = ownCurves
var dimOriginal: GammaCurves?
var dimWritten: GammaCurves?
for _ in 0..<20 {
    dimOriginal = SoftwareDim.base(live: dimScreen, written: dimWritten, previous: dimOriginal)
    dimWritten = dimOriginal!.scaled(by: SoftwareDim.factor(level: 95))
    dimScreen = GammaCurves(r: ramp(1024, top: dimWritten!.r.last!), g: ramp(1024, top: dimWritten!.g.last!),
                            b: ramp(1024, top: dimWritten!.b.last!))      // as macOS hands it back
}
expect(abs(dimScreen.r.last! - Float(SoftwareDim.factor(level: 95))) < 0.001, "re-applied 20 times at 95%: still 95%, no stacking")

// MARK: YouTube player: links

func playerVideo(_ text: String) -> String? {
    YouTubeLink.video(in: text).map { "\($0.id)" + ($0.start.map { "@\($0)" } ?? "") }
}
expect(playerVideo("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "dQw4w9WgXcQ", "watch link")
expect(playerVideo("https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=1m30s") == "dQw4w9WgXcQ@90", "mobile link with a time")
expect(playerVideo("youtube.com/watch?feature=share&v=dQw4w9WgXcQ") == "dQw4w9WgXcQ", "no https, v not first")
expect(playerVideo("https://youtu.be/dQw4w9WgXcQ?si=abc&t=42") == "dQw4w9WgXcQ@42", "short link")
expect(playerVideo("https://www.youtube.com/shorts/dQw4w9WgXcQ") == "dQw4w9WgXcQ", "shorts")
expect(playerVideo("https://www.youtube.com/embed/dQw4w9WgXcQ?start=7") == "dQw4w9WgXcQ@7", "embed with start")
expect(playerVideo("https://www.youtube.com/live/dQw4w9WgXcQ") == "dQw4w9WgXcQ", "live")
expect(playerVideo("https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD") == "dQw4w9WgXcQ", "YouTube Music")
expect(playerVideo("  https://youtu.be/dQw4w9WgXcQ\n") == "dQw4w9WgXcQ", "spaces and a newline around it")
expect(playerVideo("https://www.youtube.com/watch?v=short") == nil, "an ID that isn't 11 characters")
expect(playerVideo("https://www.youtube.com/@channel") == nil && playerVideo("https://www.youtube.com/") == nil, "not a video")
expect(playerVideo("https://notyoutube.com/watch?v=dQw4w9WgXcQ") == nil, "a look-alike site")
expect(playerVideo("https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ") == nil, "youtube.com as a prefix")
expect(playerVideo("check this out https://youtu.be/dQw4w9WgXcQ") == nil, "a sentence isn't a link")
expect(playerVideo("") == nil && playerVideo(String(repeating: "a", count: 5000)) == nil, "empty, or far too long")
expect(playerVideo("https://www.youtube.com/watch?v=dQw4w9WgX!Q") == nil, "odd characters in the ID")
expect(YouTubeLink.parseTime("90") == 90 && YouTubeLink.parseTime("1h2m3s") == 3723 && YouTubeLink.parseTime("2m") == 120
       && YouTubeLink.parseTime("90s") == 90, "times")
expect(YouTubeLink.parseTime("") == nil && YouTubeLink.parseTime("1x") == nil && YouTubeLink.parseTime("1m30") == nil
       && YouTubeLink.parseTime("-5") == nil && YouTubeLink.parseTime("m") == nil, "bad times")
expect(YouTubeLink.parseTime("9999999999999999h") == nil && YouTubeLink.parseTime("99999999999999999999") == nil
       && YouTubeLink.parseTime("9999999h9999999m9999999s") == 9999999 * 3661 && YouTubeLink.parseTime("١٢") == nil,
       "absurd times give nil, never a crash")
expect(playerVideo("https://youtu.be/dQw4w9WgXcQ?t=9999999999999999h") == "dQw4w9WgXcQ", "a link with an absurd time still plays")
expect(YouTubeLink.watchURL(id: "dQw4w9WgXcQ").absoluteString == "https://m.youtube.com/watch?v=dQw4w9WgXcQ"
       && YouTubeLink.watchURL(id: "dQw4w9WgXcQ", start: 90).absoluteString == "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=90s",
       "watch URLs")
expect(YouTubeLink.searchURL("lofi & chill").absoluteString == "https://m.youtube.com/results?search_query=lofi%20%26%20chill",
       "search URL escapes the query")

// MARK: YouTube player: which pages stay inside it

func playerDecide(_ text: String, clicked: Bool = true) -> PlayerNavigation {
    PlayerNavigation.decide(URL(string: text)!, clicked: clicked)
}
expect(playerDecide("https://m.youtube.com/watch?v=x") == .stay && playerDecide("https://www.youtube.com/") == .stay
       && playerDecide("https://youtu.be/dQw4w9WgXcQ") == .stay && playerDecide("https://m.youtube.com/", clicked: false) == .stay,
       "YouTube stays")
expect(playerDecide("https://accounts.google.com/ServiceLogin") == .stay && playerDecide("https://consent.youtube.com/m") == .stay
       && playerDecide("https://accounts.google.co.uk/x") == .stay && playerDecide("https://accounts.google.de/x") == .stay
       && playerDecide("https://accounts.google.com.au/x") == .stay && playerDecide("https://gds.google.com/web/x") == .stay
       && playerDecide("https://accounts.youtube.com/x") == .stay, "signing in stays")
expect(playerDecide("https://accounts.google.evil.example/") == .openInBrowser
       && playerDecide("https://accounts.google.co.evil/") == .openInBrowser
       && playerDecide("https://accounts.google.c0m.au/") == .openInBrowser, "look-alike sign-in pages don't stay")
expect(playerDecide("about:blank") == .stay, "blank pages stay")
expect(playerDecide("https://example.com/merch") == .openInBrowser && playerDecide("https://www.youtube.com.evil.example/") == .openInBrowser
       && playerDecide("http://amzn.to/x") == .openInBrowser, "web links you click open in your browser")
expect(playerDecide("https://example.com/", clicked: false) == .block, "a page going elsewhere by itself is stopped")
expect(playerDecide("mailto:a@b.c") == .block && playerDecide("itms-apps://x") == .block && playerDecide("zoommtg://join") == .block
       && playerDecide("file:///etc/hosts") == .block && playerDecide("youtube://watch?v=x") == .block
       && playerDecide("x-apple.systempreferences:com.apple.preference") == .block, "links to other apps or files never open")

// MARK: YouTube player: where the windows go

let playerWideScreen = CGRect(x: 0, y: 0, width: 3840, height: 1575)          // visible frame: the menu bar is above
var playerDrop = PlayerGeometry.dropdown(visible: playerWideScreen)
expect(playerDrop == CGRect(x: 3080, y: 1115, width: 760, height: 460), "dropdown flush in the top-right corner, wide and short: \(playerDrop)")
expect(playerDrop.maxX == playerWideScreen.maxX && playerDrop.maxY == playerWideScreen.maxY, "no gap at the right or under the menu bar")
playerDrop = PlayerGeometry.dropdown(visible: CGRect(x: 0, y: 0, width: 300, height: 400))
expect(playerDrop == CGRect(x: 0, y: 0, width: 300, height: 400), "a small screen: shrunk to fit, still in the corner: \(playerDrop)")
playerDrop = PlayerGeometry.dropdown(size: CGSize(width: 900, height: 380), visible: playerWideScreen)
expect(playerDrop.size == CGSize(width: 900, height: 380) && playerDrop.maxX == 3840 && playerDrop.maxY == 1575, "your own size is kept, in the corner")
playerDrop = PlayerGeometry.dropdown(size: CGSize(width: 100, height: 50), visible: playerWideScreen)
expect(playerDrop.size == CGSize(width: 480, height: 300), "never smaller than 480 × 300")
playerDrop = PlayerGeometry.dropdown(size: CGSize(width: 9000, height: 9000), visible: playerWideScreen)
expect(playerDrop == playerWideScreen, "never bigger than the screen")
let playerSecond = CGRect(x: -1920, y: 200, width: 1920, height: 1055)  // a screen to the left
playerDrop = PlayerGeometry.dropdown(visible: playerSecond)
expect(playerSecond.contains(playerDrop) && playerDrop.maxX == 0 && playerDrop.maxY == 1255, "another screen: in its own top-right corner")

var playerMini = PlayerGeometry.miniDefault(visible: playerWideScreen)
expect(playerMini == CGRect(x: 3424, y: 16, width: 400, height: 225), "mini player: bottom right, 16:9: \(playerMini)")
playerMini = PlayerGeometry.miniDefault(visible: CGRect(x: 0, y: 0, width: 300, height: 400))
expect(playerMini.width == 240 && playerMini.height == 135, "never smaller than 240 wide")

let playerDragged = CGRect(x: 500, y: 1200, width: 400, height: 225)
expect(PlayerGeometry.snap(playerDragged, in: playerWideScreen) == CGRect(x: 16, y: 1334, width: 400, height: 225), "snaps top left")
expect(PlayerGeometry.snap(CGRect(x: 3000, y: 100, width: 400, height: 225), in: playerWideScreen)
       == CGRect(x: 3424, y: 16, width: 400, height: 225), "snaps bottom right")
expect(PlayerGeometry.snap(CGRect(x: -300, y: -100, width: 400, height: 225), in: playerWideScreen).origin == CGPoint(x: 16, y: 16),
       "playerDragged partly off screen: bottom left")
let playerHuge = PlayerGeometry.snap(CGRect(x: 0, y: 0, width: 8000, height: 4500), in: playerWideScreen)
expect(playerHuge.width <= playerWideScreen.width - 32 && playerHuge.height <= playerWideScreen.height - 32
       && abs(playerHuge.width / playerHuge.height - 16.0 / 9.0) < 0.01, "bigger than the screen: shrunk, still 16:9 (\(playerHuge))")
let playerLaptop = CGRect(x: 0, y: 0, width: 1512, height: 944)
let playerMoved = PlayerGeometry.clamp(CGRect(x: 3424, y: 16, width: 400, height: 225), in: playerLaptop)
expect(playerMoved == CGRect(x: 1112, y: 16, width: 400, height: 225), "the screen got smaller: brought back on")
expect(PlayerGeometry.clamp(CGRect(x: 10, y: 10, width: 100, height: 50), in: .zero) == CGRect(x: 10, y: 10, width: 100, height: 50),
       "no screen: left alone")

// MARK: YouTube in Microsoft Edge

expect(EdgeYouTube.watchURL(id: "jNQXAC9IVRw").absoluteString == "https://www.youtube.com/watch?v=jNQXAC9IVRw"
       && EdgeYouTube.watchURL(id: "jNQXAC9IVRw", start: 90).absoluteString == "https://www.youtube.com/watch?v=jNQXAC9IVRw&t=90s",
       "Edge gets the full YouTube site, with the start time")
expect(EdgeYouTube.launchArguments(EdgeYouTube.home) == ["--app=https://www.youtube.com/"], "an Edge app window")
expect(EdgeYouTube.matchPrefix(EdgeYouTube.home) == "https://www.youtube.com/"
       && EdgeYouTube.matchPrefix(EdgeYouTube.watchURL(id: "jNQXAC9IVRw", start: 90)) == "https://www.youtube.com/watch?v=jNQXAC9IVRw",
       "its window is known by its address, a video's without the start time")

// The menu bar is 25 points tall on a 3840 × 1600 main screen (visible frame: playerWideScreen).
var edgeBounds = EdgeYouTube.showBounds(current: nil, visible: playerWideScreen, mainScreenHeight: 1600)
expect(edgeBounds == [3080, 25, 3840, 485], "Edge's window: flush top-right, right under the menu bar: \(edgeBounds)")
edgeBounds = EdgeYouTube.showBounds(current: [100, 300, 1000, 800], visible: playerWideScreen, mainScreenHeight: 1600)
expect(edgeBounds == [2940, 25, 3840, 525], "the size you gave it is kept; it goes back to the corner: \(edgeBounds)")
edgeBounds = EdgeYouTube.showBounds(current: [0, 0, 9000, 9000], visible: playerWideScreen, mainScreenHeight: 1600)
expect(edgeBounds == [0, 25, 3840, 1600], "never bigger than the screen: \(edgeBounds)")
edgeBounds = EdgeYouTube.showBounds(current: [500, 500, 400, 400], visible: playerWideScreen, mainScreenHeight: 1600)
expect(edgeBounds == [3080, 25, 3840, 485], "nonsense bounds: the default size")
// A second screen to the left and lower down; the main screen's height sets where y starts.
edgeBounds = EdgeYouTube.showBounds(current: nil, visible: playerSecond, mainScreenHeight: 1600)
expect(edgeBounds == [-760, 345, 0, 805], "another screen: its own top-right corner: \(edgeBounds)")
expect(EdgeYouTube.size(ofBounds: [10, 20, 30]) == nil && EdgeYouTube.size(ofBounds: [10, 20, 10, 40]) == nil
       && EdgeYouTube.size(ofBounds: [10, 20, 110, 70]) == CGSize(width: 100, height: 50), "reads a window's size")

expect(EdgeYouTube.quoted("https://www.youtube.com/watch?v=a") == "\"https://www.youtube.com/watch?v=a\"", "plain text quoted")
expect(EdgeYouTube.quoted("say \"hi\" \\ bye") == "\"say \\\"hi\\\" \\\\ bye\"", "quotes and backslashes escaped")
expect(EdgeYouTube.quoted("a\"\ndo shell script \"x") == "\"a\\\"do shell script \\\"x\"", "a line break can't start a new command")
expect(EdgeYouTube.quoted("a\rb\tc\u{0}d\u{2028}e") == "\"abcde\"", "control characters dropped")

let edgeFind = EdgeYouTube.findScript(prefixes: ["https://www.youtube.com/"] + EdgeYouTube.detours)
expect(edgeFind.contains("tell application id \"com.microsoft.edgemac\"") && edgeFind.contains("mode of w is \"normal\"")
       && edgeFind.contains("(count of tabs of w) is 1")
       && edgeFind.contains("if (u starts with \"https://www.youtube.com/\") or (u starts with \"https://consent.youtube.com/\") then")
       && edgeFind.contains("set found to found & ((id of w) as text)") && !edgeFind.contains("& u"),
       "the find script: ordinary windows, one tab, Hammer's address (or YouTube's cookie question); only numbers come back")
expect(EdgeYouTube.findScript(prefixes: ["x\" & (do shell script \"y"]).contains("(u starts with \"x\\\" & (do shell script \\\"y\")"),
       "an address can't break out of the script")
expect(EdgeYouTube.findScript(prefixes: []).contains("if false then"), "no addresses: matches nothing")
expect(EdgeYouTube.parseIDs("57,58,\n") == [57, 58] && EdgeYouTube.parseIDs("") == [] && EdgeYouTube.parseIDs("x,3,,") == [3],
       "reads window numbers")
expect(EdgeYouTube.newWindow(after: [12, 57, 58], before: [12]) == 58 && EdgeYouTube.newWindow(after: [12], before: [12]) == nil
       && EdgeYouTube.newWindow(after: [57], before: []) == 57, "the newest window that wasn't there before")

let edgeState = EdgeYouTube.stateScript(id: 57)
expect(edgeState.contains("exists window id 57") && edgeState.contains("set w to window id 57")
       && edgeState.hasPrefix("set sep to \",\"") && edgeState.contains("(index of v) as text") && !edgeState.contains("URL"),
       "the state script: that window, and every window's place in line (no addresses)")
expect(EdgeYouTube.parseState("missing\n", id: 57) == .missing, "a closed window")
var edgeParsed = EdgeYouTube.parseState("false,3080,25,3840,485\n57,false,1\n12,false,2\n", id: 57)
expect(edgeParsed == .found(EdgeYouTube.State(id: 57, minimized: false, bounds: [3080, 25, 3840, 485],
                                              windows: [EdgeYouTube.Order(id: 57, minimized: false, index: 1),
                                                        EdgeYouTube.Order(id: 12, minimized: false, index: 2)])), "reads the window's state")
func edgeFront(_ text: String, _ id: Int = 57) -> Bool? {
    if case .found(let state) = EdgeYouTube.parseState(text, id: id) { return state.inFront }
    return nil
}
expect(edgeFront("false,0,0,1,1\n57,false,1\n12,false,2") == true, "first in line: in front")
expect(edgeFront("false,0,0,1,1\n12,false,0\n57,false,1") == false, "another Edge window ahead: not in front")
expect(edgeFront("false,0,0,1,1\n57,false,0\n12,false,1") == true, "Edge counting from 0: still in front")
expect(edgeFront("false,0,0,1,1\n12,false,1\n57,false,3") == false && edgeFront("false,0,0,1,1\n57,false,2\n12,false,3") == true,
       "a window Hammer can't see (picture in picture) in between: judged among Edge's windows")
expect(edgeFront("false,0,0,1,1\n12,true,0\n57,false,4") == true, "a minimized window ahead doesn't count")
expect(edgeFront("true,0,0,1,1\n57,true,9.22337203685478E+18\n12,false,1") == false, "minimized (index NSIntegerMax): not in front")
expect(edgeFront("false,0,0,1,1\n") == true && edgeFront("false,0,0,1,1\nnonsense\n57,false,x") == true,
       "no order given: not minimized counts as in front")
expect(EdgeYouTube.parseState("", id: 1) == .unreadable && EdgeYouTube.parseState("yes,0,0,1,1", id: 1) == .unreadable
       && EdgeYouTube.parseState("false,0,0,1", id: 1) == .unreadable && EdgeYouTube.parseState("false,0,0,nan,1", id: 1) == .unreadable
       && EdgeYouTube.parseState("missing value", id: 1) == .unreadable, "nonsense isn't read as a window")
edgeParsed = EdgeYouTube.parseState("true, -760.0, 345, 0, 805", id: 5)
expect(edgeParsed == .found(EdgeYouTube.State(id: 5, minimized: true, bounds: [-760, 345, 0, 805], windows: [])),
       "minimized, on another screen, decimals and spaces")

let edgeFrontState = EdgeYouTube.State(id: 1, minimized: false, bounds: [0, 0, 1, 1], windows: [EdgeYouTube.Order(id: 1, minimized: false, index: 0)])
expect(EdgeYouTube.decide(.found(edgeFrontState), edgeIsFrontApp: true) == .hide, "in front: the shortcut tucks it away")
expect(EdgeYouTube.decide(.found(edgeFrontState), edgeIsFrontApp: false) == .show, "Edge behind another app: brought forward")
expect(EdgeYouTube.decide(.found(EdgeYouTube.State(id: 1, minimized: true, bounds: [0, 0, 1, 1], windows: [])), edgeIsFrontApp: true) == .show,
       "minimized: brought back")
expect(EdgeYouTube.decide(.missing, edgeIsFrontApp: true) == .open, "closed: a new window")
expect(EdgeYouTube.decide(.unreadable, edgeIsFrontApp: true) == .show && EdgeYouTube.decide(.unreadable, edgeIsFrontApp: false) == .show,
       "there but answered oddly: shown, never a second window")

let edgeShow = EdgeYouTube.showScript(id: 57, bounds: [3080, 25, 3840, 485])
expect(edgeShow.contains("set bounds of w to {3080, 25, 3840, 485}") && edgeShow.contains("set index of w to 1")
       && edgeShow.contains("if wasMinimized then set minimized of w to false"), "the show script: corner, front, not minimized")
if let moved = edgeShow.range(of: "set bounds of w to"), let restored = edgeShow.range(of: "set minimized of w to false") {
    expect(moved.lowerBound < restored.lowerBound, "moved before it's un-minimized")
} else { expect(false, "the show script has both steps") }
expect(edgeShow.contains("delay 0.4") && edgeShow.contains("to set bounds of window id 57 to {3080, 25, 3840, 485}"),
       "…and moved again once it's back")
expect(EdgeYouTube.showScript(id: 1, bounds: [1, 2]).contains("{0, 0, 760, 460}"), "bad bounds never make a broken script")
expect(EdgeYouTube.hideScript(id: 57).contains("set minimized of window id 57 to true"), "the hide script minimizes")
let edgeGo = EdgeYouTube.goScript(id: 57, url: EdgeYouTube.watchURL(id: "jNQXAC9IVRw", start: 5))
expect(edgeGo.contains("set URL of active tab of window id 57 to \"https://www.youtube.com/watch?v=jNQXAC9IVRw&t=5s\""),
       "plays a link in the open window")
expect(EdgeYouTube.activateScript() == "tell application id \"com.microsoft.edgemac\" to activate", "Edge's own activate")
expect(EdgeYouTube.errorNumber("execution error: Not authorized to send Apple events to Microsoft Edge. (-1743)") == -1743
       && EdgeYouTube.errorNumber("27:40: execution error: Microsoft Edge got an error: Can’t get window id 5. (-1728)") == -1728
       && EdgeYouTube.errorNumber("no number here") == nil && EdgeYouTube.errorNumber(") (") == nil, "reads osascript's error numbers")
expect([nil, -600, -1728, -10000].allSatisfy { !EdgeYouTube.plainError($0).contains("execution error") && EdgeYouTube.plainError($0).hasSuffix(".") }
       && EdgeYouTube.plainError(-10000).contains("-10000"), "errors in plain words")

// MARK: YouTube in Microsoft Edge: the whole flow, against a stand-in Edge

/// Behaves like Edge answering Hammer's scripts: windows with IDs and a front-to-back
/// order (counting from 0, like AppKit, with minimized windows at the very end, and
/// an optional picture-in-picture window Hammer can't see), and like macOS's
/// Automation question.
final class FakeEdge: EdgeDriver {
    struct Win { var tabs: Int; var url: String; var minimized = false; var bounds = [100, 100, 900, 700]; var inPrivate = false }
    var installed = true
    var isRunning = false
    var run = 1                                // which run of Edge (changes when it restarts)
    var windows: [Int: Win] = [:]
    var order: [Int] = []                      // front to back
    var nextID = 1
    var inFront = false
    var pictureInPicture = false               // a floating video window in front of everything
    var answer = EdgePermission.allowed        // what you answer when macOS asks
    var asked = false
    var launchWorks = true
    var opensWindow = true                     // false: Edge starts but no window shows up
    var restores: [Win] = []                   // windows Edge brings back when it starts
    var failState: Int?                        // the state script fails with this error number
    var failFind: Int?                         // the find script fails with this error number
    var failShow: Int?
    var failHide: Int?
    var permissionOverride: EdgePermission?    // what macOS says, whatever the state
    var redirect: String?                      // where YouTube sends a new window
    var stateReply: String?                    // the state script answers this instead
    var log: [String] = []
    var saved: [String: String] = [:]
    var visible = CGRect(x: 0, y: 0, width: 3840, height: 1575)

    func running() -> String? { isRunning ? "edge-\(run)" : nil }
    func edgeInFront() -> Bool { inFront }
    func permission(ask: Bool) async -> EdgePermission {
        if let permissionOverride { return permissionOverride }
        guard isRunning else { return .notRunning }
        if !asked && ask { asked = true; log.append("asked") }
        return asked ? answer : .notAsked
    }
    func launch(_ arguments: [String]) async -> Bool {
        log.append("launch \(arguments.joined(separator: " "))")
        guard launchWorks else { return false }
        if !isRunning {
            isRunning = true
            for w in restores { add(w) }
        }
        if opensWindow, let app = arguments.first(where: { $0.hasPrefix("--app=") }) {
            add(Win(tabs: 1, url: redirect ?? String(app.dropFirst(6))))
        }
        return true
    }
    @discardableResult func add(_ w: Win) -> Int {
        let id = nextID
        nextID += 1
        windows[id] = w
        order.insert(id, at: 0)
        return id
    }
    func bringForward() async { inFront = true; log.append("forward") }
    func pause(_ seconds: Double) async {}
    func screen() -> (visible: CGRect, mainHeight: CGFloat) { (visible, 1600) }
    func remembered(_ key: String) -> String? { saved[key] }
    func remember(_ value: String?, _ key: String) { saved[key] = value }

    /// AppKit's order: 0 is the front, with picture in picture (if any) ahead of everything;
    /// minimized windows aren't in the list (NSIntegerMax).
    func index(_ id: Int) -> String {
        if windows[id]!.minimized { return "9.22337203685478E+18" }
        let shown = order.filter { !windows[$0]!.minimized }
        return "\(shown.firstIndex(of: id)! + (pictureInPicture ? 1 : 0))"
    }

    private func number(after marker: String, in script: String) -> Int? {
        guard let range = script.range(of: marker) else { return nil }
        return Int(script[range.upperBound...].prefix { $0.isNumber || $0 == "-" })
    }

    private func quotedText(after marker: String, in script: String) -> String? {
        guard let range = script.range(of: marker + "\"") else { return nil }
        return String(script[range.upperBound...].prefix { $0 != "\"" })
    }

    func run(_ script: String) async -> EdgeScriptResult {
        guard isRunning else { return .failed(number: -600, message: "Edge isn't running (-600)") }
        guard answer == .allowed && asked else { return .failed(number: -1743, message: "Not authorized (-1743)") }
        if script.contains("set found to") {
            log.append("find")
            if let failFind { return .failed(number: failFind, message: "error (\(failFind))") }
            var prefixes: [String] = []
            var rest = Substring(script)
            while let range = rest.range(of: "starts with \"") {
                let text = rest[range.upperBound...].prefix { $0 != "\"" }
                prefixes.append(String(text))
                rest = rest[range.upperBound...]
            }
            return .ok(order.filter { id in
                let w = windows[id]!
                return !w.inPrivate && w.tabs == 1 && prefixes.contains { w.url.hasPrefix($0) }
            }.map { "\($0)," }.joined())
        }
        if script.contains("return \"missing\"") {
            log.append("state")
            if let failState { return .failed(number: failState, message: "error (\(failState))") }
            if let stateReply { return .ok(stateReply) }
            guard let id = number(after: "exists window id ", in: script), let w = windows[id] else { return .ok("missing") }
            let b = w.bounds
            return .ok("\(w.minimized),\(b[0]),\(b[1]),\(b[2]),\(b[3])\n" + order.map { "\($0),\(windows[$0]!.minimized),\(index($0))\n" }.joined())
        }
        if script.contains("set index of w to 1") {
            if let failShow { return .failed(number: failShow, message: "error (\(failShow))") }
            guard let id = number(after: "set w to window id ", in: script), windows[id] != nil,
                  let range = script.range(of: "set bounds of w to {") else { return .failed(number: -1728, message: "no window (-1728)") }
            let b = script[range.upperBound...].prefix { $0 != "}" }.split(separator: ",").compactMap {
                Int($0.trimmingCharacters(in: .whitespaces)) }
            windows[id]!.minimized = false
            windows[id]!.bounds = b
            order.removeAll { $0 == id }
            order.insert(id, at: 0)
            log.append("show \(id) \(b)")
            return .ok("")
        }
        if script.contains("to true") && script.contains("set minimized of window id") {
            if let failHide { return .failed(number: failHide, message: "error (\(failHide))") }
            guard let id = number(after: "set minimized of window id ", in: script), windows[id] != nil else {
                return .failed(number: -1728, message: "no window (-1728)") }
            windows[id]!.minimized = true
            order.removeAll { $0 == id }
            order.append(id)
            inFront = false
            log.append("hide \(id)")
            return .ok("")
        }
        if script.contains("set URL of active tab of window id") {
            guard let id = number(after: "active tab of window id ", in: script), windows[id] != nil,
                  let url = quotedText(after: " to ", in: script) else { return .failed(number: -1728, message: "no window (-1728)") }
            windows[id]!.url = url
            log.append("go \(id)")
            return .ok("")
        }
        return .failed(number: -2741, message: "unknown script (-2741)")
    }
}

func edgeToggle(_ controller: EdgeController, play: URL? = nil) -> EdgeController.Outcome {
    final class Box { var outcome = EdgeController.Outcome.failed("didn't finish") }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        box.outcome = await controller.toggle(play: play)
        done.signal()
    }
    done.wait()
    return box.outcome
}

let fakeEdge = FakeEdge()
let edgeController = EdgeController(driver: fakeEdge)
fakeEdge.installed = false
expect(edgeToggle(edgeController) == .notInstalled && fakeEdge.log.isEmpty, "no Edge: says so, does nothing")
fakeEdge.installed = true

// Edge closed: starting it opens the YouTube window; macOS asks once Edge is running. Edge also
// brings back your windows, one of them a single YouTube tab, and an InPrivate one on YouTube.
fakeEdge.restores = [FakeEdge.Win(tabs: 4, url: "https://www.bing.com/"),
                     FakeEdge.Win(tabs: 1, url: "https://www.youtube.com/watch?v=abc"),
                     FakeEdge.Win(tabs: 1, url: "https://www.youtube.com/", inPrivate: true)]
var edgeOutcome = edgeToggle(edgeController)
expect(edgeOutcome == .opened, "Edge closed: opened (\(edgeOutcome))")
expect(fakeEdge.log.first == "launch --app=https://www.youtube.com/" && fakeEdge.log.contains("asked"),
       "started Edge with a YouTube app window, then asked to steer it: \(fakeEdge.log)")
expect(edgeController.savedWindow(for: "edge-1") == 4, "found its own window, not your windows: \(fakeEdge.saved)")
expect(fakeEdge.windows[4]!.bounds == [3080, 25, 3840, 485] && fakeEdge.order.first == 4 && fakeEdge.inFront,
       "in the top-right corner, in front: \(fakeEdge.windows[4]!.bounds)")

// The shortcut again, while it's in front: tucked away. Again: back in the corner, every time.
for round in 1...3 {
    fakeEdge.log = []
    edgeOutcome = edgeToggle(edgeController)
    expect(edgeOutcome == .hidden(othersShown: true) && fakeEdge.windows[4]!.minimized && fakeEdge.log == ["state", "hide 4"],
           "round \(round), in front: tucked away \(fakeEdge.log)")
    fakeEdge.log = []
    edgeOutcome = edgeToggle(edgeController)
    expect(edgeOutcome == .shown && !fakeEdge.windows[4]!.minimized && fakeEdge.inFront && fakeEdge.log.contains("forward"),
           "round \(round), tucked away: back (\(edgeOutcome)) \(fakeEdge.log)")
}
expect(fakeEdge.windows.count == 4 && !fakeEdge.log.contains { $0.hasPrefix("launch") }, "hiding and showing never opens a second window")

// A picture-in-picture window in front of it: still counts as in front among Edge's windows.
fakeEdge.pictureInPicture = true
expect(edgeToggle(edgeController) == .hidden(othersShown: true), "picture in picture in front: the shortcut still tucks it away")
expect(edgeToggle(edgeController) == .shown, "…and brings it back")
fakeEdge.pictureInPicture = false

// You resized it and moved it; another app is in front.
fakeEdge.windows[4]!.bounds = [200, 300, 1100, 820]
fakeEdge.inFront = false
edgeOutcome = edgeToggle(edgeController)
expect(edgeOutcome == .shown && fakeEdge.windows[4]!.bounds == [2940, 25, 3840, 545],
       "another app in front: brought back to the corner at your size: \(fakeEdge.windows[4]!.bounds)")
// Another Edge window in front of it.
fakeEdge.order.removeAll { $0 == 1 }
fakeEdge.order.insert(1, at: 0)
fakeEdge.inFront = true
expect(edgeToggle(edgeController) == .shown && fakeEdge.order.first == 4, "behind another Edge window: brought to the front")

// Edge answers oddly about a window that's there: shown, never a second window.
fakeEdge.stateReply = "false,0,0,1"
fakeEdge.log = []
expect(edgeToggle(edgeController) == .shown && !fakeEdge.log.contains { $0.hasPrefix("launch") }, "an odd answer: shown, not reopened")
fakeEdge.stateReply = nil

// A video to play: shown (never tucked away), and it plays there.
fakeEdge.inFront = true
fakeEdge.log = []
edgeOutcome = edgeToggle(edgeController, play: EdgeYouTube.watchURL(id: "jNQXAC9IVRw"))
expect(edgeOutcome == .shown && fakeEdge.windows[4]!.url == "https://www.youtube.com/watch?v=jNQXAC9IVRw"
       && fakeEdge.log.contains("go 4") && !fakeEdge.log.contains("hide 4"), "plays a link in the window: \(fakeEdge.log)")

// You closed it: a new one, at the size you last had.
_ = edgeToggle(edgeController)                                // tuck away (remembers 900 × 520)
fakeEdge.windows[4] = nil
fakeEdge.order.removeAll { $0 == 4 }
fakeEdge.inFront = false
fakeEdge.log = []
edgeOutcome = edgeToggle(edgeController)
let edgeNew = edgeController.savedWindow(for: "edge-1")
expect(edgeOutcome == .opened && edgeNew == 5, "closed: a new window (\(edgeOutcome), \(String(describing: edgeNew)))")
expect(fakeEdge.windows[5]?.bounds == [2940, 25, 3840, 545], "…at the size you last had, in the corner")
expect(fakeEdge.log.prefix(3) == ["state", "find", "launch --app=https://www.youtube.com/"], "looked before opening: \(fakeEdge.log)")

// A link to play with no window open: the window opens on that video, found by its address.
fakeEdge.windows[5] = nil
fakeEdge.order.removeAll { $0 == 5 }
fakeEdge.log = []
edgeOutcome = edgeToggle(edgeController, play: EdgeYouTube.watchURL(id: "jNQXAC9IVRw", start: 30))
expect(edgeOutcome == .opened && fakeEdge.log.contains("launch --app=https://www.youtube.com/watch?v=jNQXAC9IVRw&t=30s")
       && edgeController.savedWindow(for: "edge-1") == 6, "a link with no window: opened on it \(fakeEdge.log)")

// Edge restarted: window IDs start over, so an old ID never steers someone else's window.
let edgeOldID = edgeController.savedWindow(for: "edge-1")!
fakeEdge.run = 2
fakeEdge.windows = [:]
fakeEdge.order = []
fakeEdge.nextID = edgeOldID                                    // the new run hands out the same number to your window
let edgeTheirs = fakeEdge.add(FakeEdge.Win(tabs: 1, url: "https://www.youtube.com/"))
expect(edgeTheirs == edgeOldID, "(the stand-in reuses the old window ID)")
let edgeTheirsBefore = fakeEdge.windows[edgeTheirs]!.bounds
edgeOutcome = edgeToggle(edgeController)
expect(edgeOutcome == .opened && fakeEdge.windows[edgeTheirs]!.bounds == edgeTheirsBefore
       && edgeController.savedWindow(for: "edge-2") != edgeTheirs, "after Edge restarts: your own window is left alone")

// Script trouble.
fakeEdge.failState = -1728
var edgeCount = fakeEdge.windows.count
expect(edgeToggle(edgeController) == .opened && fakeEdge.windows.count == edgeCount + 1, "window gone mid-way: a new one")
fakeEdge.failState = -10000
expect(edgeToggle(edgeController) == .failed(EdgeYouTube.plainError(-10000)), "another error: said in plain words")
fakeEdge.failState = nil
fakeEdge.failShow = -10000
fakeEdge.inFront = false
expect(edgeToggle(edgeController) == .failed(EdgeYouTube.plainError(-10000)), "showing fails: said so")
fakeEdge.failShow = nil
fakeEdge.saved["edgeYouTubeWindow"] = nil
fakeEdge.failFind = -10000
edgeCount = fakeEdge.windows.count
expect(edgeToggle(edgeController) == .failed(EdgeYouTube.plainError(-10000)) && fakeEdge.windows.count == edgeCount,
       "can't look at Edge's windows first: no window opened blind")
fakeEdge.failFind = nil

// Edge quit between the check and the script.
let quittingEdge = FakeEdge()
quittingEdge.isRunning = true
quittingEdge.asked = true
quittingEdge.saved["edgeYouTubeWindow"] = "edge-1|1"
quittingEdge.failState = -600
expect(edgeToggle(EdgeController(driver: quittingEdge)) == .opened, "Edge quit meanwhile: started again with the window")

// You said no in Privacy & Security → Automation.
let deniedEdge = FakeEdge()
deniedEdge.isRunning = true
deniedEdge.answer = .denied
expect(edgeToggle(EdgeController(driver: deniedEdge)) == .notAllowed(openedAnyway: false) && !deniedEdge.log.contains { $0.hasPrefix("launch") },
       "not allowed, Edge open: says so; doesn't pile up windows it can't steer")
expect(edgeToggle(EdgeController(driver: deniedEdge), play: EdgeYouTube.watchURL(id: "jNQXAC9IVRw")) == .notAllowed(openedAnyway: true)
       && deniedEdge.log.contains("launch --app=https://www.youtube.com/watch?v=jNQXAC9IVRw"),
       "not allowed, a link to play: it still plays (Edge places the window)")
let deniedClosed = FakeEdge()
deniedClosed.answer = .denied
expect(edgeToggle(EdgeController(driver: deniedClosed)) == .notAllowed(openedAnyway: true) && deniedClosed.windows.count == 1,
       "not allowed, Edge closed: YouTube still opens (Edge places it)")

// Edge won't start, or its window never shows up.
let brokenEdge = FakeEdge()
brokenEdge.launchWorks = false
if case .failed(let text) = edgeToggle(EdgeController(driver: brokenEdge)), text.hasPrefix("Microsoft Edge didn't open") {} else {
    expect(false, "Edge won't start: says so")
}
let windowlessEdge = FakeEdge()
windowlessEdge.opensWindow = false
if case .failed = edgeToggle(EdgeController(driver: windowlessEdge)) {} else { expect(false, "no window: says so") }
expect(windowlessEdge.log.filter { $0 == "find" }.count == 60, "…after looking about 60 times")
let slowEdge = FakeEdge()
slowEdge.opensWindow = false
let slowController = EdgeController(driver: slowEdge)
slowController.findFor = 0
if case .failed = edgeToggle(slowController) {} else { expect(false, "out of time: says so") }
expect(!slowEdge.log.contains("find"), "…and stops looking when time's up")

// Only Hammer's window open in Edge: after tucking it away you go back to your app (others shown: no).
let loneEdge = FakeEdge()
let loneController = EdgeController(driver: loneEdge)
expect(edgeToggle(loneController) == .opened && edgeToggle(loneController) == .hidden(othersShown: false),
       "the only Edge window: tucked away, nothing else of Edge's showing")
loneEdge.add(FakeEdge.Win(tabs: 3, url: "https://www.bing.com/", minimized: true))
expect(edgeToggle(loneController) == .shown && edgeToggle(loneController) == .hidden(othersShown: false),
       "a minimized Edge window doesn't count as showing")

// YouTube sends the new window to its cookie question before Hammer looks: still found.
let consentEdge = FakeEdge()
consentEdge.redirect = "https://consent.youtube.com/m?continue=https%3A%2F%2Fwww.youtube.com%2F"
expect(edgeToggle(EdgeController(driver: consentEdge)) == .opened && EdgeController(driver: consentEdge).savedWindow(for: "edge-1") == 1,
       "redirected to YouTube's cookie question: still Hammer's window")
let elsewhereEdge = FakeEdge()
elsewhereEdge.redirect = "https://example.com/"
if case .failed = edgeToggle(EdgeController(driver: elsewhereEdge)) {} else { expect(false, "a window somewhere else entirely isn't taken") }

// macOS says Edge isn't running though it seemed to be (it just quit): started again.
let flickerEdge = FakeEdge()
flickerEdge.isRunning = true
flickerEdge.asked = true
flickerEdge.permissionOverride = .notRunning
flickerEdge.log = []
_ = edgeToggle(EdgeController(driver: flickerEdge))
expect(flickerEdge.log.first == "launch --app=https://www.youtube.com/", "Edge quit just then: opened again \(flickerEdge.log)")

// Tucking away fails: said so.
let stuckEdge = FakeEdge()
let stuckController = EdgeController(driver: stuckEdge)
_ = edgeToggle(stuckController)
stuckEdge.failHide = -10000
expect(edgeToggle(stuckController) == .failed(EdgeYouTube.plainError(-10000)), "hiding fails: said in plain words")

// A remembered window from a bad save is ignored.
let oddEdge = FakeEdge()
oddEdge.saved["edgeYouTubeWindow"] = "edge-1|x"
expect(EdgeController(driver: oddEdge).savedWindow(for: "edge-1") == nil, "a damaged saved window is ignored")
oddEdge.saved["edgeYouTubeWindow"] = "edge-1|7|8"
expect(EdgeController(driver: oddEdge).savedWindow(for: "edge-1") == nil, "…in any shape")

// MARK: Text

expect(TimerText.describe(minutes: 5) == "5 min", "5 min")
expect(TimerText.describe(minutes: 45) == "45 min", "45 min")
expect(TimerText.describe(minutes: 60) == "1 hr", "1 hr")
expect(TimerText.describe(minutes: 90) == "1 hr 30 min", "1 hr 30 min")
expect(TimerText.describe(minutes: 480) == "8 hr", "8 hr")

// MARK: Delivery emails: which subjects count

let deliveredSubjects = [
    #"Delivered: "Anker 735 Charger (Nano II 65W)" and 1 more item"#,
    "=?UTF-8?B?8J+TpiBZb3VyIHBhY2thZ2Ugd2FzIGRlbGl2ZXJlZA==?=",            // "📦 Your package was delivered"
    "Your package was delivered: Apple iPhone 15 Pro Max - 256GB - Black (Unlocked)",
    "UPS Update: Package Delivered",
    "USPS® Item Delivered, Front/Back Door/Porch 9400111899223344556677",
    "FedEx Shipment 771234567890 Delivered",
    "Your order has arrived!",
    "Your Walmart order was delivered",
    "=?utf-8?Q?Your_package_was_delivered_=E2=9C=85?=",
    "Your package was delivered earlier than expected",
    "Your package has been dropped off",
    "Your order from Target has arrived",
    "Your items have arrived",
]
for subject in deliveredSubjects {
    expect(DeliveryMail.kind(ofSubject: subject) == .delivered, "delivered: \(subject)")
}
// An item named in quotes is a parcel when a store Hammer knows names it (Amazon's template).
expect(DeliveryMail.kind(ofSubject: "DELIVERED: \"Phone case\"", from: "Amazon") == .delivered
       && DeliveryMail.kind(ofSubject: "DELIVERED: \"Phone case\"") == nil
       && DeliveryMail.kind(ofSubject: #"Out for delivery: "Anker 735 Charger""#, from: "Amazon") == .outForDelivery,
       "quoted items count from a known store only")
let problemSubjects = [
    "Your package couldn't be delivered",
    "Action needed: delivery exception for your order",
    "Your parcel is being returned to sender",
    "We were unable to deliver your package",
]
for subject in problemSubjects {
    expect(DeliveryMail.kind(ofSubject: subject) == .problem, "problem: \(subject)")
}
// "Delivery attempted" names no parcel: it's one when a carrier sends it.
for subject in ["Delivery attempted - we'll try again tomorrow", "UPS Update: Delivery Attempted"] {
    expect(DeliveryMail.kind(ofSubject: subject, from: "UPS") == .problem && DeliveryMail.kind(ofSubject: subject) == nil,
           "problem from a carrier, nothing from anyone else: \(subject)")
}
let outForDeliverySubjects = [
    "USPS® Item Out for Delivery, 9400111899223344556677",
    "UPS Update: Package Out for Delivery Today",
    "Your package is out for delivery",
]
for subject in outForDeliverySubjects {
    expect(DeliveryMail.kind(ofSubject: subject) == .outForDelivery, "out for delivery: \(subject)")
}
let otherSubjects = [
    "Fwd: Your package has been delivered",                // a forward: a conversation, not a notice
    "Your package will be out for delivery tomorrow",
    "Arriving today: Anker 735 Charger",
    "USPS® Expected Delivery on Saturday, October 17, 2026 arriving by 9:00pm",
    "Your package will be delivered tomorrow",
    #"Shipped: "Anker 735 Charger""#,
    "Get it delivered in 2 hours with Instacart",
    "Re: Package delivered",
    "RE: has the couch arrived?",
    "Sign-in attempted from a new device",
    "Your order is confirmed",
    "Free delivery on orders over $35",
    "Delivered fresh: 20% off this week",
    "The Delivered Collection: new arrivals",
    "lunch?",
    "",
    "=?UTF-8?B?invalid!!?=",
    // Marketing and bounces that look a bit like deliveries (found in review):
    "Your statement has arrived",
    "Fall has arrived: 30% off everything",
    "The new iPhone has arrived. Order now",
    "Delivered to your door in 30 minutes",
    "Undelivered Mail Returned to Sender",
    "Undeliverable: Lunch on Friday?",
    "Mail delivery failed: returning message to sender",
    "Fresh flowers delivered today",
]
for subject in otherSubjects {
    expect(DeliveryMail.kind(ofSubject: subject) == nil, "not a delivery: \(subject)")
}

// What was delivered, and from where
expect(DeliveryMail.item(in: #"Delivered: "Anker 735 Charger (Nano II 65W)" and 1 more item"#)
       == "Anker 735 Charger (Nano II 65W) +1 more", "Amazon item with more")
expect(DeliveryMail.item(in: "Delivered: “Phone case”") == "Phone case", "curly quotes")
expect(DeliveryMail.item(in: "Your package was delivered: Apple iPhone 15 Pro Max - 256GB")
       == "Apple iPhone 15 Pro Max - 256GB", "item after the colon")
expect(DeliveryMail.item(in: "UPS Update: Package Delivered") == nil, "no item in a carrier update")
expect(DeliveryMail.item(in: "Your package was delivered") == nil, "no item named")
expect(DeliveryMail.item(in: "Delivered: Your package") == nil, "'your package' isn't an item")
expect(DeliveryMail.item(in: "Delivered: " + String(repeating: "x", count: 200))?.count == 80, "long names are cut to 80")
expect(DeliveryMail.item(in: "Delivered: \"\"") == nil, "empty quotes")

expect(DeliveryMail.store(from: "\"eBay\" <ebay@ebay.com>") == "eBay", "eBay")
expect(DeliveryMail.store(from: "Amazon.com <shipment-tracking@amazon.com>") == "Amazon", "Amazon")
expect(DeliveryMail.store(from: "UPS <mcinfo@ups.com>") == "UPS", "UPS")
expect(DeliveryMail.store(from: "USPS Informed Delivery <USPSInformeddelivery@email.informeddelivery.usps.com>")
       == "USPS", "USPS on a subdomain")
expect(DeliveryMail.store(from: "Google Groups <noreply@groups.com>") == "groups.com", "groups.com isn't UPS")
expect(DeliveryMail.store(from: "Shop <no-reply@shop.app>") == "Shop", "Shop app")
expect(DeliveryMail.store(from: "=?UTF-8?Q?Caf=C3=A9_Store?= <orders@cafe-store.com>") == "cafe-store.com",
       "an unknown store shows its domain, not the name it gives itself")
expect(DeliveryMail.store(from: "orders@mail.weirdshop.co.uk") == "weirdshop.co.uk", "no name: the domain")
expect(DeliveryMail.store(from: "") == "Unknown sender", "nothing to go on")

expect(DeliveryMail.tidy("📦 Your package was delivered") == "Your package was delivered", "emoji removed")
expect(DeliveryMail.tidy("Fwd:   Your  order\thas arrived ") == "Your order has arrived", "prefix and spaces")
expect(HeaderText.decode("=?UTF-8?B?SGVs?= =?UTF-8?B?bG8=?= world") == "Hello world", "adjacent encoded words join")
expect(HeaderText.decode("=?ISO-8859-1?Q?Caf=E9?=") == "Café", "Latin-1")
expect(HeaderText.decode("plain text") == "plain text", "plain text unchanged")
expect(HeaderText.decode("=?UTF-8?B?8J+Tpg?=") == "📦", "unpadded base64")

let rawHeaders = Array("From: \"eBay\" <ebay@ebay.com>\r\nSubject: Your package\r\n was delivered\r\nDate: Sat, 17 Oct 2026 14:02:11 +0000\r\nMessage-ID: <a@b>\r\n\r\n".utf8)
let parsedHeaders = HeaderText.parse(rawHeaders)
expect(parsedHeaders["subject"] == "Your package was delivered", "folded subject joined: \(parsedHeaders["subject"] ?? "-")")
expect(parsedHeaders["from"] == "\"eBay\" <ebay@ebay.com>" && parsedHeaders["message-id"] == "<a@b>", "other headers")
expect(HeaderText.parse(Array("Subject: Caf\u{E9}\r\n".unicodeScalars.map { UInt8($0.value) }))["subject"] == "Café",
       "8-bit Latin-1 header")
expect(HeaderText.parse([]).isEmpty, "no headers")

expect(DeliveryMail.parseDate("Sat, 17 Oct 2026 14:02:11 +0000") == Date(timeIntervalSince1970: 1_792_245_731),
       "RFC 2822 date")
expect(DeliveryMail.parseDate("Sat, 17 Oct 2026 07:02:11 -0700 (PDT)") == Date(timeIntervalSince1970: 1_792_245_731),
       "date with zone comment")
expect(DeliveryMail.parseDate("17 Oct 2026 14:02:11 +0000") != nil, "date without weekday")
expect(DeliveryMail.parseDate("yesterday") == nil, "not a date")

let sample = DeliveryMail.classify(headers: parsedHeaders, uid: 9)
expect(sample?.title == "Delivered · eBay" && sample?.body == "Your package was delivered", "notification text")
expect(sample?.gmailLink(account: "you@gmail.com")?.absoluteString
       == "https://mail.google.com/mail/?authuser=you@gmail.com#search/rfc822msgid%3Aa@b", "link to the email")
expect(DeliveryMail.classify(headers: ["subject": "Undeliverable: Your order #123 update",
                                       "from": "Mail Delivery Subsystem <mailer-daemon@googlemail.com>"], uid: 1) == nil,
       "a bounce of your own email isn't a delivery problem")
expect(DeliveryMail.classify(headers: ["subject": "Undeliverable: Re: your order",
                                       "from": "postmaster@outlook.com"], uid: 1) == nil, "Outlook bounce")
// "Delivered" wording that isn't about a package: needs a known store/carrier or a package word.
func classified(_ subject: String, from: String) -> Delivery.Kind? {
    DeliveryMail.classify(headers: ["subject": subject, "from": from], uid: 1)?.kind
}
expect(classified("Your message was delivered", from: "Slack <no-reply@slack.com>") == nil, "a message, not a package")
expect(classified("Your report has been delivered", from: "Reports <reports@analytics.example.com>") == nil, "a report")
expect(classified("Delivered: Q3 results deck", from: "Sam <sam@company.com>") == nil, "a colleague's 'Delivered:'")
expect(classified("Your flowers were delivered", from: "Amazon <x@evil.example.com>") == nil,
       "calling yourself Amazon isn't enough; the domain counts")
expect(classified(#"Delivered: "Lamp""#, from: "Target <orders@target.com>") == .delivered, "known store, no package word")
expect(classified(#"Delivered: "Anker 735""#, from: "Amazon.com <shipment-tracking@amazon.com>") == .delivered, "Amazon")
expect(classified("Your package was delivered", from: "Tiny Shop <hello@tinyshop.co>") == .delivered,
       "unknown shop, but about a package")
expect(classified("Your order has been delivered", from: "orders@someshop.com") == .delivered, "unknown shop, an order")
expect(classified("USPS® Item Delivered, In/At Mailbox", from: "USPS <auto-reply@usps.com>") == .delivered, "USPS")
expect(classified(#"Delivered: "Lamp""#, from: "Tiny Shop <hello@tinyshop.co>") == nil,
       "trade-off: an unknown shop's 'Delivered: \"Lamp\"' is skipped")
expect(classified("UPS Update: Delivery Attempted", from: "someone@example.com") == nil,
       "'delivery' alone isn't a parcel: a delivery problem from someone else needs a package word")
expect(DeliveryMail.knownShipper(from: "\"eBay\" <ebay@ebay.com>") == "eBay"
       && DeliveryMail.knownShipper(from: "Google Groups <noreply@groups.com>") == nil
       && DeliveryMail.knownShipper(from: "ups") == nil, "known shippers by domain")
expect(DeliveryMail.mentionsAPackage("📦 Your package was delivered") && !DeliveryMail.mentionsAPackage("Your message was delivered")
       && !DeliveryMail.mentionsAPackage("Boxing day sale"), "package words, whole words only")

let problem = DeliveryMail.classify(headers: ["subject": "UPS Update: Delivery Attempted", "from": "UPS <mcinfo@ups.com>"], uid: 1)
expect(problem?.title == "Delivery problem · UPS" && problem?.item == nil, "problem text")

// Setup input
expect(DeliverySetup.isPlainEmail("you@gmail.com") && DeliverySetup.isPlainEmail("first.last+tag@googlemail.com"),
       "plain emails")
for bad in ["", "you", "you@", "@gmail.com", "you @gmail.com", "you@gmail", "a\"b@gmail.com", "you@gmail.com -w x"] {
    expect(!DeliverySetup.isPlainEmail(bad), "not an email: \(bad)")
}
expect(DeliverySetup.cleanPassword("abcd efgh ijkl mnop") == "abcdefghijklmnop", "spaces removed")
expect(DeliverySetup.cleanPassword(" abcdefghijklmnop\n") == "abcdefghijklmnop", "pasted with a newline")
for bad in ["", "abcdefghijklmno", "abcdefghijklmnopq", "abcd-efgh-ijkl-mnop", "My-Real-Password!", "abcdefghijklmnö1",
            "abcdefghijklmn\"x"] {
    expect(DeliverySetup.cleanPassword(bad) == nil, "not an app password: \(bad)")
}

// MARK: Delivery emails: realistic subjects (from the review), each with its verdict

// 58 subjects as stores and carriers send them, plus look-alikes: ads, returns,
// questions, parcels still in transit, a phishing email. Only English is understood.
let amazonFrom = "Amazon.com <shipment-tracking@amazon.com>", ebayFrom = "eBay <ebay@ebay.com>"
let upsFrom = "UPS <mcinfo@ups.com>", uspsFrom = "USPS <auto-reply@usps.com>", fedexFrom = "FedEx <TrackingUpdates@fedex.com>"
let realisticSubjects: [(subject: String, from: String, verdict: Delivery.Kind?)] = [
    (#"Delivered: "Anker 735 Charger (Nano II 65W)" and 1 more item"#, amazonFrom, .delivered),
    (#"Delivered: "Apple AirPods Pro (2nd..."#, amazonFrom, .delivered),                  // name cut short, no closing quote
    (#"Shipped: "Anker 735 Charger""#, amazonFrom, nil),
    (#"Out for delivery: "Anker 735 Charger""#, amazonFrom, .outForDelivery),
    (#"Arriving today: "Anker 735 Charger""#, amazonFrom, nil),
    ("Your Amazon.com order #112-1234567-1234567 has shipped", amazonFrom, nil),
    ("Your package may be delayed", amazonFrom, nil),
    (#"Delivery attempted: "Anker 735 Charger""#, amazonFrom, .problem),
    (#"Delivered: "Expected Value: The Book (Hardcover)""#, amazonFrom, .delivered),     // a not-yet word in the name
    (#"Delivered: "Oral-B iO Toothbrush - Free Delivery Edition""#, amazonFrom, .delivered),
    (#"Shipped: "Package Delivered Sign for Porch""#, amazonFrom, nil),                   // a delivered phrase in the name
    (#"Out for delivery: "Your Package Was Delivered Doormat""#, amazonFrom, .outForDelivery),
    ("Your return drop off is confirmed", amazonFrom, nil),
    ("Your return has been dropped off", amazonFrom, nil),                                 // a return you sent
    ("Was your package delivered as expected? Tell us", amazonFrom, nil),                 // a survey
    ("Never have a missed delivery again with Amazon Hub", amazonFrom, nil),              // an ad
    ("Your package was delivered: Apple iPhone 15 Pro Max - 256GB", ebayFrom, .delivered),
    ("📦 Your order is delivered!", ebayFrom, .delivered),
    ("Your item has shipped: Apple iPhone 15 Pro Max", ebayFrom, nil),
    ("Your return has been delivered to the seller", ebayFrom, nil),
    ("Item not delivered? Request a refund", ebayFrom, nil),                              // a help article
    ("UPS Update: Package Delivered", upsFrom, .delivered),
    ("UPS Update: Package Scheduled for Delivery Today", upsFrom, nil),
    ("UPS Update: Delivery Attempted", upsFrom, .problem),
    ("UPS Update: Your package has arrived at a UPS Access Point", upsFrom, .delivered),  // ready to pick up
    ("UPS My Choice: Your Package Has Been Delivered", upsFrom, .delivered),
    ("USPS® Item Delivered, In/At Mailbox 9400111899223344556677", uspsFrom, .delivered),
    ("USPS® Item Out for Delivery, 9400111899223344556677", uspsFrom, .outForDelivery),
    ("USPS® Delivery Attempt: Notice Left (No Authorized Recipient Available)", uspsFrom, .problem),
    ("USPS® Expected Delivery by Tuesday, October 20, 2026 arriving by 9:00pm", uspsFrom, nil),
    ("Your Informed Delivery® Daily Digest for Sat, 10/17",
     "USPS Informed Delivery <USPSInformeddelivery@email.informeddelivery.usps.com>", nil),
    ("USPS® Item Available for Pickup, 9400111899223344556677", uspsFrom, nil),
    ("FedEx Shipment 771234567890 Delivered", fedexFrom, .delivered),
    ("Your FedEx package has been delivered", fedexFrom, .delivered),
    ("FedEx Shipment 771234567890: Delivery exception", fedexFrom, .problem),
    ("Your package is scheduled for delivery today", fedexFrom, nil),
    ("DHL On Demand Delivery: Your shipment has been delivered", "DHL <noreply@dhl.com>", .delivered),
    ("Your DHL Shipment 1234567890: Delivered", "DHL <noreply@dhl.com>", .delivered),
    ("Your package has arrived at the destination country", "AliExpress <transaction@notice.aliexpress.com>", nil),
    ("Your order has arrived at the local sorting center", "Temu <orders@temu.com>", nil),
    ("Your parcel has arrived at the post office", "SHEIN <noreply@shein.com>", nil),
    ("Your package has been delivered to the carrier", "AliExpress <transaction@notice.aliexpress.com>", nil),
    ("Your Target order has been delivered", "Target <orders@oe.target.com>", .delivered),
    ("Delivered: Your Walmart order", "Walmart <help@walmart.com>", .delivered),
    ("Your Best Buy order has been delivered", "Best Buy <BestBuyInfo@emailinfo.bestbuy.com>", .delivered),
    ("Your Etsy order has been delivered", "Etsy <transaction@etsy.com>", .delivered),
    ("Your Chewy order has been delivered! 🐾", "Chewy <noreply@chewy.com>", .delivered),
    ("Your Instacart order has been delivered", "Instacart <orders@instacart.com>", .delivered),  // food alerts too
    ("New items have arrived in shops you follow", "Etsy <newsletter@etsy.com>", nil),
    ("Fresh new items have arrived! Shop now", "Old Navy <oldnavy@email.oldnavy.com>", nil),
    ("Your package hasn't been delivered yet? Here's what to do", "Shop <no-reply@shop.app>", nil),
    ("Your package was never delivered", "Tiny Shop <hello@tinyshop.co>", .problem),
    ("Your order has not yet been delivered", "orders@someshop.com", .problem),
    ("Order not yet delivered", "orders@someshop.com", .problem),
    ("USPS: Your package couldn't be delivered, pay $1.99 redelivery fee", "USPS <alert@usps-redeliver.top>", .problem),
    ("Zugestellt: \"Anker Ladegerät\"", "Amazon.de <versandbestaetigung@amazon.de>", nil),        // English only
    ("Livré : « Chargeur Anker »", "Amazon.fr <confirmation-commande@amazon.fr>", nil),
    ("Entregado: \"Cargador Anker\"", "Amazon.es <confirmar-envio@amazon.es>", nil),
]
expect(realisticSubjects.count == 58, "58 realistic subjects")
var realisticWrong: [String] = []
for c in realisticSubjects where classified(c.subject, from: c.from) != c.verdict {
    realisticWrong.append("\(c.subject) → \(classified(c.subject, from: c.from).map(\.rawValue) ?? "nil")")
}
expect(realisticWrong.isEmpty, "realistic subjects all get their verdict: \(realisticWrong)")
let phish = DeliveryMail.classify(headers: ["subject": "USPS: Your package couldn't be delivered, pay $1.99 redelivery fee",
                                            "from": "USPS <alert@usps-redeliver.top>"], uid: 1)
expect(phish?.title == "Delivery problem · usps-redeliver.top", "a look-alike sender shows its own domain: \(phish?.title ?? "-")")

// 128 subjects where the product name has delivery words in it: the start of the
// subject decides, never the name in quotes.
let trickyNames = ["Anker 735 Charger", "Package Delivered Sign for Porch", "Expected Value: A Novel",
                   "Scheduled Maintenance Log", "On the Way Baby Bodysuit", "Arriving Soon Card", "Free Delivery Mug",
                   "50% off Coupon Book", "Missed Delivery Notice Pad", "Return to Sender (Vinyl)", "Not Delivered Stamp",
                   "Order Pad", "Delivery Attempt Door Hanger", "Item Delivered Tag", "Has Arrived Banner",
                   "Box Was Delivered Poster"]
let nameTemplates: [(String, Delivery.Kind?)] = [
    (#"Shipped: "%@""#, nil), (#"Out for delivery: "%@""#, .outForDelivery), (#"Arriving today: "%@""#, nil),
    (#"Arriving tomorrow: "%@""#, nil), (#"Ordered: "%@""#, nil), (#"Your Amazon.com order of "%@" has shipped"#, nil),
    (#"Delivered: "%@""#, .delivered), (#"Delivered: "%@" and 1 more item"#, .delivered),
]
var nameCases = 0
var nameWrong: [String] = []
for name in trickyNames {
    for (template, verdict) in nameTemplates {
        let subject = template.replacingOccurrences(of: "%@", with: name)
        nameCases += 1
        let got = classified(subject, from: amazonFrom)
        if got != verdict { nameWrong.append("\(subject) → \(got.map(\.rawValue) ?? "nil")") }
    }
}
expect(nameCases == 128 && nameWrong.isEmpty, "product names never decide (\(nameCases) subjects): \(nameWrong)")
expect(DeliveryMail.item(in: #"Delivered: "Box Was Delivered Poster" and 1 more item"#) == "Box Was Delivered Poster +1 more",
       "and the name still shows")

// 107 more subjects a second reviewer collected, from stores and carriers in the US,
// UK, Canada and Australia, with the look-alikes around them.
let rAmazon = "Amazon.com <shipment-tracking@amazon.com>", rEbay = "eBay <ebay@ebay.com>", rUps = "UPS <mcinfo@ups.com>"
let rUsps = "USPS <USPSInformeddelivery@email.informeddelivery.usps.com>", rFedex = "FedEx <TrackingUpdates@fedex.com>"
let rDhl = "DHL <noreply@dhl.com>", rRoyal = "Royal Mail <no-reply@royalmail.com>", rEvri = "Evri <noreply@evri.com>"
let rDpd = "DPD <notifications@dpd.co.uk>", rAuspost = "Australia Post <noreply@notifications.auspost.com.au>"
let rShop = "Shop <no-reply@shop.app>", rApple = "Apple <noreply@email.apple.com>", rWalmart = "Walmart <help@walmart.com>"
let rTarget = "Target <orders@oe1.target.com>", rIkea = "IKEA <noreply@order.ikea.com>", rAllbirds = "Allbirds <hello@allbirds.com>"
let rDoordash = "DoorDash <no-reply@doordash.com>", rHello = "HelloFresh <hello@hellofresh.com>", rCanpost = "Canada Post <noreply@canadapost.ca>"
let rAli = "AliExpress <transaction@notice.aliexpress.com>", rFlowers = "1-800-Flowers <orders@1800flowers.com>"
let rFriend = "Pat <pat@gmail.com>", rWayfair = "Wayfair <shipping@wayfair.com>", rZara = "ZARA <noreply@zara.com>"

let freshSubjects: [(subject: String, from: String, verdict: Delivery.Kind?)] = [
    // delivered
    (#"Delivered: "Fire TV Stick 4K Max streaming..." and 2 more items"#, rAmazon, .delivered),
    ("Your Amazon Fresh order has been delivered", rAmazon, .delivered),
    ("ORDER DELIVERED: Logitech MX Master 3S Wireless Mouse", rEbay, .delivered),
    ("📦 Your package was delivered: Nintendo Switch OLED", rEbay, .delivered),
    ("UPS Update: Your Package Has Been Delivered", rUps, .delivered),
    ("UPS Delivery Notification, Tracking Number 1Z999AA10123456784", rUps, .delivered),
    ("USPS® Item Delivered, Left with Individual 9400111899223344556677", rUsps, .delivered),
    ("Delivered: Your FedEx shipment 771234567890", rFedex, .delivered),
    ("Your shipment 1234567890 has been delivered", rDhl, .delivered),
    ("Your Royal Mail parcel has been delivered", rRoyal, .delivered),
    ("Your parcel from ASOS has been delivered", rEvri, .delivered),
    ("Your DPD parcel has been delivered", rDpd, .delivered),
    ("Your parcel has been delivered", rAuspost, .delivered),
    ("Your item was delivered", rCanpost, .delivered),
    ("A shipment from order #1045 has been delivered", rAllbirds, .delivered),
    ("Your Allbirds order was delivered", rShop, .delivered),
    ("Your order has been delivered.", rApple, .delivered),
    ("Your Walmart order was delivered", rWalmart, .delivered),
    ("Your Target order is delivered!", rTarget, .delivered),
    ("Your IKEA order has been delivered", rIkea, .delivered),
    ("Your Wayfair order has been delivered!", rWayfair, .delivered),
    ("Your ZARA order has been delivered", rZara, .delivered),
    ("Order 8187654321098765: package delivered", rAli, .delivered),
    ("Your HelloFresh box has been delivered", rHello, .delivered),
    ("Package delivered to your parcel locker", rDpd, .delivered),
    ("We've delivered your parcel", rRoyal, .delivered),
    ("Good news! Your package has been delivered", rFedex, .delivered),
    ("Your package was delivered — see the photo", rAmazon, .delivered),
    ("Your package has been delivered to a pickup point", rDpd, .delivered),
    ("Delivered today: your order from Etsy", "Etsy <transaction@etsy.com>", .delivered),
    // not delivered / other
    ("Your package will be delivered today", rAmazon, nil),
    ("Your order is out for delivery", rWalmart, .outForDelivery),
    ("Out for Delivery: Your Walmart order", rWalmart, .outForDelivery),
    ("Your package is out for delivery and will arrive by 8 PM", rFedex, .outForDelivery),
    ("Your order will be out for delivery tomorrow", rTarget, nil),
    ("Delivery update: your package is running late", rAmazon, nil),
    ("Your delivery is scheduled for Tuesday", rUps, nil),
    ("How was your delivery?", rAmazon, nil),
    ("Rate your delivery experience with DoorDash", rDoordash, nil),
    ("Your package is delayed", rUps, nil),
    ("Track your package: 1Z999AA10123456784", rUps, nil),
    ("Get free delivery on orders over $35", rWalmart, nil),
    ("Your order has been dispatched", rZara, nil),
    ("Your parcel has been collected by our courier", rEvri, nil),
    ("Your return has been received", rAmazon, nil),
    ("Your Instacart order is being delivered by Maria", "Instacart <orders@instacart.com>", nil),
    ("Your DoorDash order is on its way", rDoordash, nil),
    ("Delivery date changed for your order", rTarget, nil),
    ("Your package was delayed and will be delivered tomorrow", rFedex, nil),
    ("Delivered: Q3 board deck (final)", rFriend, nil),
    ("Your flowers have been delivered!", rFlowers, nil),
    ("Your order was cancelled and will not be delivered", rWalmart, nil),
    ("Package available for pickup at your Post Office", rUsps, nil),
    ("Your order has been delivered to the courier", rAli, nil),
    ("Your order has arrived at the delivery station", rAmazon, nil),
    ("Your package is at the local delivery facility", rUps, nil),
    ("Delivered to you: our autumn catalogue", rWayfair, nil),
    ("Your Prime delivery day is here: deals delivered", rAmazon, nil),
    ("Smart lockers: never miss a delivery again", rUps, nil),
    ("Your package delivery was rescheduled", rAmazon, nil),
    // problems
    ("We tried to deliver your package", rFedex, .problem),
    ("Your package could not be delivered today — we'll try again tomorrow", rUps, .problem),
    ("Action required: delivery attempt failed", rDhl, .problem),
    ("We missed you! Your parcel couldn't be delivered", rRoyal, .problem),
    ("Delivery Exception: Package Delayed", rFedex, .problem),
    ("Missed delivery – reschedule now", rEvri, .problem),
    ("Your package is being returned to the sender", rUsps, .problem),

    ("FedEx: We couldn't deliver your package", rFedex, .problem),
    ("UPS Update: We Were Unable to Deliver Your Package", rUps, .problem),
    ("Delivery failed: we'll try again tomorrow", rUps, .problem),
    ("Delivery attempt unsuccessful", rDpd, .problem),
    ("Delivery complete: your Uber Eats order", "Uber Eats <uber@uber.com>", .delivered),
    ("Your Evri parcel is delivered", rEvri, .delivered),
    ("Delivered - Your order #W123456789", rWayfair, .delivered),
    ("Your parcel was delivered to your safe place", rRoyal, .delivered),
    ("Not home? Your package was delivered to a safe place", rAmazon, .delivered),
    ("Don't worry, your package has been delivered", rFedex, .delivered),
    ("Your order has arrived!", "Glossier <hello@glossier.com>", .delivered),
    ("Shipment delivered", rFedex, .delivered),
    ("Your Order From Best Buy Has Been Delivered", "Best Buy <BestBuyInfo@emailinfo.bestbuy.com>", .delivered),
    ("Your order was delivered (Order #12345)", "Store <orders@store.example>", .delivered),
    ("Part of your order has been delivered", rAmazon, .delivered),
    ("Your Etsy Purchase from WoodCraftCo Has Been Delivered", "Etsy <transaction@etsy.com>", .delivered),
    ("Amazon.com: Delivered: \"Kindle Paperwhite\"", rAmazon, .delivered),
    ("Your next order, delivered", rWalmart, nil),
    ("Your weekly groceries order, delivered free", "Ocado <hello@ocado.com>", nil),
    ("Fresh flowers delivered to your door", rFlowers, nil),
    ("Delivered by Friday: shop last-minute gifts", rTarget, nil),
    ("Order delivered? Leave a review", rEbay, nil),
    ("Your order has been delivered to our store and is ready for pickup", rTarget, nil),
    ("Item delivered - not as described? Open a case", rEbay, nil),
    ("Delivery driver feedback: how did we do?", rAmazon, nil),
    ("Your order is expected to be delivered on Friday", rAmazon, nil),
    ("Your package is being held at the Post Office", rUsps, nil),
    ("Reminder: your package will be returned to sender in 5 days", rUsps, .problem),
    ("Delivered: your password reset code", "Acme <no-reply@acme.io>", nil),
    ("Your order has been delivered to the carrier and is on its way", "Store <orders@store.example>", nil),
    ("Your 3 packages have been delivered", rAmazon, .delivered),
    ("Package delivered: front porch", rAmazon, .delivered),
    ("Your item was delivered to your mailbox", rUsps, .delivered),
    ("Your package from Amazon was delivered", "Ring <no-reply@ring.com>", .delivered),
    ("RE: Order #555 not delivered", "Support <support@shop.example>", nil),
    ("AW: Your package was delivered", rFriend, nil),
    ("Your package was delivered to a neighbor", rUps, .delivered),
    ("Your DHL Express shipment is out for delivery today", rDhl, .outForDelivery),
    ("Today: your parcel is out for delivery", rRoyal, .outForDelivery),
    ("Your order is out for delivery! Track your driver", "Instacart <orders@instacart.com>", .outForDelivery),
]
expect(freshSubjects.count == 107, "107 more subjects")
var freshWrong: [String] = []
for c in freshSubjects where classified(c.subject, from: c.from) != c.verdict {
    freshWrong.append("\(c.subject) → \(classified(c.subject, from: c.from).map(\.rawValue) ?? "nil")")
}
expect(freshWrong.isEmpty, "the second set all get their verdict: \(freshWrong)")
// The general rules behind some of them, in other words.
for (subject, verdict) in [("We were unable to deliver your parcel today", Delivery.Kind.problem),
                           ("Our driver couldn't deliver your order", .problem), ("We attempted to deliver your package", .problem),
                           ("Delivery unsuccessful: we'll try again", nil), ("We have delivered your order", .delivered),
                           ("Delivery complete: your Instacart order", .delivered), ("Shop update: Delivered", nil),
                           ("Order #A1234: Shipped", nil), ("Store update: Out for delivery", nil),
                           ("Store update: your order is out for delivery", .outForDelivery),
                           ("Your order has been canceled", nil), ("Cancellation: your order will not be delivered", nil),
                           ("Your parcel is ready to collect at the Post Office", nil), ("Ready for pickup: your order", nil),
                           ("Your next delivery, half price", nil), ("SV: Your package was delivered", nil),
                           ("Antw: Your package was delivered", nil), ("Package delivered? Rate your driver", nil),
                           ("Order delivered - wrong item? Contact us", nil), ("Mail delivery failed: returning message", nil),
                           ("Message delivery failed for your order update", nil)] {
    expect(classified(subject, from: "Store <orders@tinyshop.co>") == verdict,
           "general rule: \(subject) → \(verdict.map(\.rawValue) ?? "nil")")
}
expect(classified("Etsy: Delivered", from: "Etsy <transaction@etsy.com>") == nil
       && classified("OnTrac: Delivered", from: "OnTrac <noreply@ontrac.com>") == .delivered,
       "a bare 'Delivered' is about a parcel when a carrier sends it, not a store")

// Negatives and questions: a question isn't news; "wasn't delivered" is a problem.
for (subject, verdict) in [("Your package hasn't been delivered", Delivery.Kind.problem),
                           ("Your order was never delivered", .problem), ("Order not yet delivered", .problem),
                           ("Your parcel wasn’t delivered today", .problem)] {
    expect(classified(subject, from: "Shop <orders@tinyshop.co>") == verdict, "said it wasn't delivered: \(subject)")
}
for subject in ["Was your order delivered on time?", "Has your package been delivered?", "Did your order arrive?",
                "Your package hasn't been delivered yet? Here's what to do", "Was your message not delivered? Try again",
                "Your message was never delivered"] {
    expect(classified(subject, from: "Shop <orders@tinyshop.co>") == nil, "a question, or not a package: \(subject)")
}
expect(classified("Your package was delivered! How did we do?", from: upsFrom) == .delivered,
       "a statement followed by a question still counts")
expect(classified("Delivery attempted - can we try again tomorrow?", from: upsFrom) == .problem,
       "a problem followed by a question still counts")
// Not your parcel arriving: transit scans, ads, hand-offs, returns.
for subject in ["Your package has arrived at the sorting facility", "Your parcel has arrived in the destination country",
                "New arrivals have arrived", "Latest items have arrived in store", "Your order was delivered to the courier",
                "Your package has been handed over to the carrier", "Your return package was delivered",
                "Never miss a delivery again: no more missed deliveries with Hub", "Avoid a missed delivery: update your address"] {
    expect(classified(subject, from: amazonFrom) == nil, "not a delivery to you: \(subject)")
}
expect(DeliveryMail.kind(ofSubject: "[EXT] Re: Your package was delivered") == nil, "a tagged reply")
expect(DeliveryMail.kind(ofSubject: "Your package was deliv\u{200B}ered") == .delivered, "zero-width spaces don't hide words")
expect(DeliveryMail.kind(ofSubject: #"Delivered: 'Bob's Burgers DVD'"#, from: "Amazon") == .delivered
       && DeliveryMail.kind(ofSubject: #"Shipped: 'Package Delivered Sign'"#, from: "Amazon") == nil, "single quotes are quotes too")
expect(DeliveryMail.kind(ofSubject: "Shipped: “Item Delivered Tag”", from: "Amazon") == nil
       && DeliveryMail.kind(ofSubject: "Delivered: “Missed Delivery Pad”", from: "Amazon") == .delivered, "and curly ones")

// MARK: Delivery emails: the pipeline, step by step (third review)

let walmartFrom = "Walmart <help@walmart.com>"
// 1. Conversations: replies, forwards and read receipts, in many mail programs' words.
for prefix in ["Re:", "RE:", "re :", "Re[2]:", "Re(3):", "Fwd:", "FWD :", "FW:", "Fw:", "AW:", "WG:", "SV:", "VS:", "Antw:",
               "Antwort:", "R:", "I:", "RV:", "TR:", "Réf :", "REF:", "Read:", "Automatic reply:", "[EXT] Re:", "  Fwd:"] {
    expect(classified(prefix + " UPS Update: Package Delivered", from: upsFrom) == nil, "a conversation: \(prefix)")
}
expect(classified("Read the instructions: your package was delivered", from: upsFrom) == .delivered
       && classified("Ireland: your parcel was delivered", from: "An Post <x@anpost.ie>") == .delivered,
       "a word that merely starts like a prefix isn't one")
// 2. Not yet: "out for delivery" before anything else; scheduled and on its way ignored.
expect(classified("Delivery Notification: package 1Z999AA10123456784 out for delivery", from: upsFrom) == .outForDelivery,
       "a delivery notification that says out for delivery is that")
expect(classified("FedEx Delivery Notification 771234567890: estimated delivery Tuesday", from: fedexFrom) == nil,
       "…and one with an estimated delivery isn't Delivered")
expect(classified("UPS Delivery Notification, Tracking Number 1Z999AA10123456784", from: upsFrom) == .delivered,
       "UPS's own delivered notice still is")
expect(classified("Out for delivery today: order #1042 (order #1041 was delivered)", from: "Shop <s@shop.app>") == .outForDelivery,
       "out for delivery comes first")
expect(classified("Delivery attempted; redelivery scheduled for Monday", from: upsFrom) == nil,
       "scheduled comes before problems")
// 3. Not a parcel for you, before problems and delivered.
expect(classified("Your order was cancelled and will not be delivered", from: walmartFrom) == nil, "cancelled comes before problems")
expect(classified("Your Amazon.com eGift Card has been delivered", from: amazonFrom) == nil, "a gift card has nothing to deliver")
for (subject, from) in [("Back to school: delivered", "Amazon.com <store-news@amazon.com>"), ("Holiday gifts: Delivered!", walmartFrom),
                        ("Halloween costumes: delivered", "Target <target@em.target.com>"), ("Your next order: delivered", walmartFrom)] {
    expect(classified(subject, from: from) == nil, "an ad, not a parcel: \(subject)")
}
// Each veto decides on its own, even when there's a parcel word.
expect(classified("Your eGift card order was delivered to sam@example.com", from: amazonFrom) == nil,
       "a gift card order: nothing comes to the door")
expect(classified("Never have a missed delivery again: track your packages with UPS My Choice", from: upsFrom) == nil,
       "an ad about missed deliveries isn't a missed delivery")
expect(classified("Delivery notification for your order", from: "Shop <s@tinyshop.co>") == nil,
       "a 'delivery notification' only says delivered with a tracking number in it")
expect(DeliveryMail.trackingNumbers(in: "Ref 1234567890123456789012 / 12345678901234567890").isEmpty,
       "20 to 22 digits are USPS's only when they start with 9")
// 4. and 5. need a parcel: "delivery" alone isn't one.
for (subject, from) in [("Your fax delivery failed", "eFax <message@efax.com>"), ("SMS delivery failed", "Twilio <no-reply@twilio.com>"),
                        ("Webhook delivery failed", "GitHub <noreply@github.com>"),
                        ("Your Amazon.com eGift Card delivery failed", "Amazon.com <gc-orders@gc.email.amazon.com>"),
                        ("Report delivery complete", "Looker <noreply@looker.com>"), ("Delivery complete", amazonFrom)] {
    expect(classified(subject, from: from) == nil, "'delivery' alone isn't a parcel: \(subject)")
}
expect(classified("Delivery failed for your package", from: "Shop <s@tinyshop.co>") == .problem
       && classified("Delivery complete: your order #1042", from: "Shop <s@tinyshop.co>") == .delivered
       && classified("Delivery failed: tracking 1Z999AA10123456784", from: "Shop <s@tinyshop.co>") == .problem,
       "with a package word or a tracking number, they count")
expect(classified("Package delivered, then a missed delivery for the other one", from: upsFrom) == .problem,
       "problems come before delivered")
// Questions decide nothing; a help page (a real question, then what to do) is ignored.
expect(classified("UPS Update: Delivery Attempted - Questions? Contact Us", from: upsFrom) == .problem,
       "boilerplate 'Questions? Contact us' doesn't hide a problem")
expect(classified("Your package couldn't be delivered. Need help? Contact support", from: upsFrom) == .problem,
       "…nor 'Need help?'")
expect(classified("Your package was delivered! Questions? Contact us", from: upsFrom) == .delivered, "…nor a delivery")
expect(classified("Item delivered - not as described? Open a case", from: ebayFrom) == nil
       && classified("Order delivered - damaged? Request a refund", from: ebayFrom) == nil,
       "a real question followed by what to do is a help page")
expect(classified("Your package was delivered. Was everything OK?", from: upsFrom) == .delivered,
       "a question with nothing to do after it doesn't make a help page")

// Unverified senders: any domain, not just listed ones.
let fedexCA = checkedByGmail("Your FedEx package could not be delivered", from: "FedEx <alerts@fedex.ca>",
                             verdict: "mx.google.com; dkim=fail header.i=@fedex.ca")
expect(fedexCA == nil, "an unverified sender's delivery problem isn't shown, listed domain or not")
let shopCA = checkedByGmail("Your package was delivered", from: "Shop <orders@tinyshop.co>", verdict: "mx.google.com; dkim=none")
expect(shopCA?.store == "Unverified sender", "and any unverified sender shows as such, never by its claimed domain")
expect(checkedByGmail("Your package was delivered", from: "Shop <orders@tinyshop.co>",
                      verdict: "mx.google.com; dkim=pass header.i=@tinyshop.co")?.store == "tinyshop.co",
       "a verified unknown sender shows its domain")

// MARK: Delivery emails: the frozen hold-out set

// Written before the third round of classifier changes and never tuned against:
// carrier and store templates (UPS, USPS, FedEx, DHL, Amazon, eBay, Walmart, Target,
// Best Buy, Etsy, Shopify stores, food), and ordinary mail that uses the same words
// (marketing, gift cards, fax/SMS/webhook/report "delivery", bounces, newsletters,
// replies and forwards). The score is recorded, not forced to 100%: it may only go up.
let hUPS = "UPS <mcinfo@ups.com>", hUSPS = "USPS <auto-reply@usps.com>", hFedEx = "FedEx <TrackingUpdates@fedex.com>"
let hDHL = "DHL Express <noreply@dhl.com>", hAmazon = "Amazon.com <shipment-tracking@amazon.com>"
let hEBay = "eBay <ebay@ebay.com>", hWalmart = "Walmart <help@walmart.com>", hTarget = "Target <orders@oe1.target.com>"
let hBestBuy = "Best Buy <BestBuyInfo@emailinfo.bestbuy.com>", hEtsy = "Etsy <transaction@etsy.com>"
let hShop = "Maple & Co <store+61234@t.shopifyemail.com>", hFriend = "Sam Lee <sam.lee@gmail.com>"
let holdOut: [(subject: String, from: String, verdict: Delivery.Kind?)] = [
    ("UPS Update: Package Scheduled for Delivery Tomorrow", hUPS, nil),
    ("UPS Update: Delivery Attempt Made", hUPS, .problem),
    ("UPS Update: Package Delivered to UPS Access Point", hUPS, .delivered),
    ("UPS Ship Notification, Tracking Number 1Z999AA10123456784", hUPS, nil),
    ("UPS Delivery Change: Your Delivery Has Been Rescheduled", hUPS, nil),
    ("UPS Update: Your Package Has Been Delayed", hUPS, nil),
    ("UPS My Choice: Delivery Exception", hUPS, .problem),
    ("USPS® Item Delivered, Front Door/Porch 9405511899223344556677", hUSPS, .delivered),
    ("USPS® Delivery Attempted - No Access to Delivery Location 9400111899223344556699", hUSPS, .problem),
    ("USPS® Item Out for Delivery 9300111899223344556677", hUSPS, .outForDelivery),
    ("USPS® Expected Delivery on Monday, November 2, 2026 Between 10:30am and 2:30pm", hUSPS, nil),
    ("USPS® Item In Transit, Arriving Late 9400111899223344556677", hUSPS, nil),
    ("USPS® Delivery Attempted - Business Closed", hUSPS, .problem),
    ("USPS® Item Delivered, Parcel Locker", hUSPS, .delivered),
    ("USPS Informed Delivery® Daily Digest", "USPS Informed Delivery <USPSInformeddelivery@email.informeddelivery.usps.com>", nil),
    ("USPS® Item Being Returned to Sender, 9400111899223344556677", hUSPS, .problem),
    ("Your package is scheduled for delivery Monday, 11/2/2026", hFedEx, nil),
    ("Your FedEx shipment is on its way", hFedEx, nil),
    ("Your FedEx package is out for delivery today", hFedEx, .outForDelivery),
    ("Your package has been delivered to the front door", hFedEx, .delivered),
    ("FedEx delivery exception: Customer not available or business closed", hFedEx, .problem),
    ("FedEx Delivery Manager: Your delivery is confirmed for tomorrow", hFedEx, nil),
    ("We'll try to deliver your FedEx package again tomorrow", hFedEx, .problem),
    ("DHL On Demand Delivery: Your shipment 1234567890 is on its way", hDHL, nil),
    ("DHL Express shipment 1234567890 has been delivered", hDHL, .delivered),
    ("DHL: Delivery attempt for shipment 1234567890", hDHL, .problem),
    ("Your DHL shipment is out for delivery", hDHL, .outForDelivery),
    ("Delivered: Your Amazon.com order #113-2223334-4455667", hAmazon, .delivered),
    (#"Your Amazon.com order of "Echo Dot (5th Gen)" has shipped!"#, hAmazon, nil),
    (#"Arriving tomorrow: "Kindle Scribe""#, hAmazon, nil),
    (#"Out for delivery: "Ninja Air Fryer" and 2 more items"#, hAmazon, .outForDelivery),
    (#"Delivery attempted: "Ninja Air Fryer""#, hAmazon, .problem),
    ("Your Amazon.com eGift Card has been delivered", "Amazon.com <gc-orders@gc.email.amazon.com>", nil),
    ("Your Amazon.com order has been cancelled", "Amazon.com <auto-confirm@amazon.com>", nil),
    ("Your refund for Ninja Air Fryer", "Amazon.com <return@amazon.com>", nil),
    ("Amazon Fresh: Your groceries have been delivered", hAmazon, .delivered),
    ("Prime Day deals, delivered fast", "Amazon.com <store-news@amazon.com>", nil),
    ("Your Subscribe & Save delivery is coming soon", "Amazon.com <no-reply@amazon.com>", nil),
    ("Your eBay item was delivered: Sony WH-1000XM5", hEBay, .delivered),
    ("Order update: Your item is out for delivery", hEBay, .outForDelivery),
    ("Your item has shipped: Sony WH-1000XM5", hEBay, nil),
    ("Delivery update: your item is delayed", hEBay, nil),
    ("Re: Order #12-34567-89012 - item not delivered", "seller42 <seller42@members.ebay.com>", nil),
    ("Your eBay Bucks are here", hEBay, nil),
    ("Delivered: your Walmart.com order", hWalmart, .delivered),
    ("Your package is arriving today", hWalmart, nil),
    ("We weren't able to deliver your order", hWalmart, .problem),
    ("Your order is ready for pickup", hWalmart, nil),
    ("Rollbacks delivered right to your door", "Walmart <walmart@em.walmart.com>", nil),
    ("Your order was delivered!", hTarget, .delivered),
    ("Your Target order is on its way", hTarget, nil),
    ("Your Drive Up order is ready", hTarget, nil),
    ("Weekly Ad: deals delivered to your door", "Target <target@em.target.com>", nil),
    ("Your Best Buy package is out for delivery", hBestBuy, .outForDelivery),
    ("Your Best Buy order BBY01-806123456789 has been delivered", hBestBuy, .delivered),
    ("Your order BBY01-806123456789 is ready for store pickup", hBestBuy, nil),
    ("Delivery and installation appointment confirmed", hBestBuy, nil),
    ("Your Etsy order has shipped", hEtsy, nil),
    ("Your Etsy order from MapleLeafPrints was delivered", hEtsy, .delivered),
    ("Your Etsy purchase from MapleLeafPrints is out for delivery", hEtsy, .outForDelivery),
    ("A shipment from order #1042 is on the way", hShop, nil),
    ("A shipment from order #1042 is out for delivery", hShop, .outForDelivery),
    ("A shipment from order #1042 has been delivered", hShop, .delivered),
    ("Shipping update for order #1042", hShop, nil),
    ("Order #1042 has been canceled", hShop, nil),
    ("Your order #1042 is ready for pickup", hShop, nil),
    ("Your Uber Eats order has been delivered", "Uber Eats <noreply@uber.com>", .delivered),
    ("Your Uber Eats delivery is on its way", "Uber Eats <noreply@uber.com>", nil),
    ("Fax delivery failed to +1 555 0100", "eFax <message@inbound.efax.com>", nil),
    ("Your fax was delivered successfully", "eFax <message@inbound.efax.com>", nil),
    ("SMS delivery report: message delivered", "Twilio <no-reply@twilio.com>", nil),
    ("[GitHub] A webhook delivery to example.com failed", "GitHub <noreply@github.com>", nil),
    ("Delivery Status Notification (Failure)", "Mail Delivery Subsystem <mailer-daemon@googlemail.com>", nil),
    ("Undeliverable: Invoice 4471", "postmaster@contoso.com", nil),
    ("Your scheduled report has been delivered", "Looker <noreply@looker.com>", nil),
    ("Message delivered: Contract draft", "Mailtrack <notifications@mailtrack.io>", nil),
    ("The Morning: news delivered to your inbox", "The New York Times <nytdirect@nytimes.com>", nil),
    ("Your weekly digest has arrived", "Medium Daily Digest <noreply@medium.com>", nil),
    ("Read: Your package was delivered", hFriend, nil),
    ("Fwd: UPS Update: Package Delivered", hFriend, nil),
    ("FW: Your order has been delivered", hFriend, nil),
    ("Re[2]: Package delivered?", hFriend, nil),
    ("TR: Votre colis a été livré", hFriend, nil),
    ("WG: Ihr Paket wurde zugestellt", hFriend, nil),
    ("Flowers delivered: send a bouquet today", "1-800-Flowers <orders@1800flowers.com>", nil),
    ("Your eGift card delivery failed", "Target GiftCards <giftcards@target.com>", nil),
    ("Your package from Amazon has been delivered", "Ring <no-reply@ring.com>", .delivered),
    ("Your order is on hold", hWalmart, nil),
    ("Payment failed: your order couldn't be completed", hWalmart, nil),
    ("Your return has been received and your refund is on its way", hAmazon, nil),
    ("We missed you – your parcel is at your local post office", "Royal Mail <no-reply@royalmail.com>", .problem),
    ("Your Evri parcel is on its way", "Evri <noreply@evri.com>", nil),
    ("Your Canada Post package was delivered to your community mailbox", "Canada Post <noreply@canadapost.ca>", .delivered),
    ("Australia Post: Your parcel is awaiting collection", "Australia Post <noreply@notifications.auspost.com.au>", nil),
]
var holdOutRight = 0
var holdOutMisses: [String] = []
for c in holdOut {
    let got = classified(c.subject, from: c.from)
    if got == c.verdict { holdOutRight += 1 } else { holdOutMisses.append("\(c.subject) → \(got.map(\.rawValue) ?? "nil") (want \(c.verdict.map(\.rawValue) ?? "nil"))") }
}
print("hold-out: \(holdOutRight) of \(holdOut.count) right")
for miss in holdOutMisses { print("  hold-out miss: \(miss)") }
// Scores: 403a26e 86 of 94, 5e3209e 85 of 94, the third round 91 of 94. Later rounds may only do better.
expect(holdOut.count == 94 && holdOutRight >= 91, "the hold-out set doesn't get worse: \(holdOutRight) of \(holdOut.count)")

// MARK: Delivery emails: senders, Gmail's check, names, bodies, dates

// Known stores and carriers by their real domain, or a subdomain of it.
expect(DeliveryMail.knownShipper(from: "UPS <x@ups.com>") == "UPS"
       && DeliveryMail.knownShipper(from: "UPS <x@email.ups.com>") == "UPS", "UPS and its subdomains")
for spoof in ["UPS <x@ups.attacker.top>", "x@ups.com.attacker.net", "\"Amazon.com\" <ship@amazon.com.evil.io>",
              "Amazon <x@amazonses.com>", "x@notamazon.com", "x@groups.com", "\"x@ups.com\" <a@evil.io>",
              "x@amazon.com@evil.io", "Amazon <x@evil.io> (x@amazon.com)"] {
    expect(DeliveryMail.knownShipper(from: spoof) == nil, "not a known sender: \(spoof)")
}
expect(DeliveryMail.knownShipper(from: "x@mail.amazon.co.uk") == "Amazon" && DeliveryMail.knownShipper(from: "x@amazon.com.au") == "Amazon",
       "other Amazon domains")
// The address, never text around it: comments and quoted names are left out, and two senders are none.
for (from, domain) in [("evil@attacker.top (<mcinfo@ups.com>)", "attacker.top"),
                       ("\"Shipping <x@amazon.com>\" <x@evil.io>", "evil.io"),
                       ("\"UPS\" <mcinfo@ups.com> (via attacker.top)", "ups.com"),
                       ("UPS (\"<mcinfo@ups.com>\") <evil@attacker.top>", "attacker.top"),
                       ("\"a \\\" <x@ups.com>\" <evil@attacker.top>", "attacker.top"),
                       ("Amazon <x@evil.io> (x@amazon.com)", "evil.io"),
                       ("mcinfo@ups.com", "ups.com"), ("<mcinfo@ups.com>", "ups.com"),
                       ("\"x\" <evil@attacker.top>, <mcinfo@ups.com>", ""), ("<x@amazon.com> <x@evil.io>", ""),
                       ("x@amazon.com@evil.io", ""), ("Group: a@ups.com, b@evil.io;", ""), ("<mcinfo@ups.com> trailing", ""),
                       ("UPS <mcinfo@ups.com", ""), ("\"unclosed <x@ups.com>", ""), ("(unclosed <x@ups.com>", ""),
                       ("UPS <<mcinfo@ups.com>", ""), ("attacker.top, <mcinfo@ups.com>", ""), ("undisclosed-recipients:;", "")] {
    expect(DeliveryMail.domain(of: from) == domain, "the sender's domain: \(from) → '\(DeliveryMail.domain(of: from))'")
}
expect(DeliveryMail.classify(headers: ["from": "evil@attacker.top (<mcinfo@ups.com>)", "subject": "UPS Update: Package Delivered"],
                             uid: 0)?.store == "attacker.top", "script route: a comment doesn't make it UPS")
expect(DeliveryMail.classify(headers: ["from": "\"x\" <evil@attacker.top>, <mcinfo@ups.com>", "subject": "UPS Update: Package Delivered"],
                             uid: 0)?.store == "Unknown sender", "script route: two senders count as none")
// Sellers and shops: not the marketplace's own name.
expect(DeliveryMail.store(from: "Seller <abc123@marketplace.amazon.com>") == "Amazon seller"
       && DeliveryMail.knownShipper(from: "Seller <abc123@marketplace.amazon.com>") == nil
       && DeliveryMail.store(from: "x <m@members.ebay.com>") == "eBay seller", "a seller's message isn't Amazon's or eBay's")
expect(DeliveryMail.classify(headers: ["from": "Seller <abc@marketplace.amazon.com>", "subject": #"Delivered: "Lamp""#], uid: 0) == nil,
       "…so it needs a package word like any other sender")
expect(DeliveryMail.knownShipper(from: "Cool Shop <mailer@shopify.com>") == nil
       && DeliveryMail.store(from: "Cool Shop <mailer@shopify.com>") == "shopify.com"
       && DeliveryMail.knownShipper(from: "Shop <no-reply@shop.app>") == "Shop", "shopify.com sends for every shop: not a known sender")
expect(DeliveryMail.store(from: "Amazon <x@evil.example.com>") == "example.com", "a display name never names the store")
let spoofProblem = DeliveryMail.classify(headers: ["subject": "Missed delivery: reschedule your package now",
                                                   "from": "UPS Support <help@ups-reschedule.top>"], uid: 1)
expect(spoofProblem?.kind == .problem && spoofProblem?.store == "ups-reschedule.top",
       "problem alerts follow the same rules: \(spoofProblem?.title ?? "-")")
expect(DeliveryMail.classify(headers: ["subject": "Delivery attempted for your parcel", "from": "x@spam.top"], uid: 1)?.store == "spam.top",
       "an unknown sender's problem shows its domain")

// Gmail's check of the sender (Authentication-Results, on the app-password route).
let gmailPass = "mx.google.com; dkim=pass header.i=@ups.com header.s=s1 header.b=abc; spf=pass (google.com: domain of x@ups.com designates 1.2.3.4 as permitted sender) smtp.mailfrom=x@ups.com; dmarc=pass (p=REJECT) header.from=ups.com"
expect(DeliveryMail.signedBySender(gmailPass, domain: "ups.com"), "signed by ups.com")
expect(DeliveryMail.signedBySender("mx.google.com; dkim=pass header.i=@email.ups.com", domain: "ups.com")
       && DeliveryMail.signedBySender("mx.google.com; dkim=pass header.d=ups.com", domain: "mcinfo.ups.com"),
       "a subdomain of the same domain counts")
for (results, why) in [("mx.google.com; dkim=fail header.i=@ups.com", "failed"),
                       ("mx.google.com; dkim=pass header.i=@attacker.top", "signed by someone else"),
                       ("mx.google.com; dkim=none; spf=pass smtp.mailfrom=ups.com", "not signed"),
                       ("evil.example; dkim=pass header.i=@ups.com", "not Gmail's verdict"),
                       ("mx.google.com; spf=pass (google.com: \"; dkim=pass header.i=@ups.com\") smtp.mailfrom=x@evil.top", "text in a comment"),
                       ("mx.google.com; spf=pass smtp.mailfrom=\"a;dkim=pass header.i=@ups.com\"@evil.top", "text in quotes"),
                       ("mx.google.com; spf=pass (\") dkim=pass header.i=@ups.com (\") smtp.mailfrom=x@evil.top", "a quote in a comment")] {
    expect(!DeliveryMail.signedBySender(results, domain: "ups.com"), "not signed by ups.com: \(why)")
}
/// Headers as the IMAP route passes them: Gmail had the chance to check, and (if given) its verdict.
func checkedByGmail(_ subject: String, from: String, verdict: String?) -> Delivery? {
    var headers = ["subject": subject, "from": from, ":gmail-checked": "1"]
    if let verdict { headers[":gmail-verdict"] = verdict }
    return DeliveryMail.classify(headers: headers, uid: 1)
}
let forged = checkedByGmail("UPS Update: Package Delivered", from: "UPS <mcinfo@ups.com>",
                            verdict: "mx.google.com; dkim=pass header.i=@evil.top; spf=fail")
expect(forged?.store == "Unverified sender", "a forged UPS email never shows as UPS or ups.com: \(forged?.store ?? "-")")
expect(checkedByGmail("UPS Update: Delivery Attempted", from: "UPS <mcinfo@ups.com>",
                      verdict: "mx.google.com; dkim=fail header.i=@ups.com") == nil,
       "…and an unverified 'delivery problem' from a carrier's domain (the usual phishing) isn't shown")
expect(checkedByGmail(#"Delivered: "Lamp""#, from: "Target <orders@target.com>",
                      verdict: "mx.google.com; dkim=fail header.i=@target.com") == nil,
       "…and without a package word, it isn't announced at all")
expect(checkedByGmail("UPS Update: Package Delivered", from: "UPS <mcinfo@ups.com>", verdict: nil)?.store == "Unverified sender",
       "no verdict from Gmail on the IMAP route: not verified (never 'skip')")
var signedHeaders = ["subject": "UPS Update: Package Delivered", "from": "UPS <mcinfo@ups.com>", ":gmail-checked": "1",
                     ":gmail-verdict": gmailPass, ":gmail-id": "18c2f0a1b2c3d4e5"]
let signed = DeliveryMail.classify(headers: signedHeaders, uid: 1)
expect(signed?.store == "UPS" && signed?.gmailID == "18c2f0a1b2c3d4e5", "a signed one keeps its name, and Gmail's ID")
signedHeaders["authentication-results"] = gmailPass
signedHeaders[":gmail-verdict"] = nil
expect(DeliveryMail.classify(headers: signedHeaders, uid: 1)?.store == "Unverified sender",
       "only the verdict the IMAP reader picked counts, not any Authentication-Results")
// DMARC passing for the From domain counts too (senders whose DKIM is their mail provider's).
let ontrac = checkedByGmail("OnTrac: Delivered", from: "OnTrac <noreply@ontrac.com>",
                            verdict: "mx.google.com; spf=pass (google.com: domain of b@ontrac.com designates 1.2.3.4 as permitted sender) smtp.mailfrom=b@ontrac.com; dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=ontrac.com")
expect(ontrac?.kind == .delivered && ontrac?.store == "OnTrac", "aligned SPF and DMARC: verified: \(ontrac?.store ?? "-")")
let viaProvider = checkedByGmail("LaserShip: Delivered", from: "LaserShip <noreply@lasership.com>",
                                 verdict: "mx.google.com; dkim=pass header.i=@sendgrid.net; dmarc=pass (p=NONE) header.from=lasership.com")
expect(viaProvider?.store == "LaserShip", "DKIM by the mail provider, DMARC for the sender: verified")
expect(checkedByGmail("UPS Update: Package Delivered", from: "UPS <mcinfo@ups.com>",
                      verdict: "mx.google.com; dkim=pass header.i=@evil.top; dmarc=fail (p=REJECT) header.from=ups.com")?.store
       == "Unverified sender", "DMARC failing: not verified")
let gmailsFrom = checkedByGmail("Your package was delivered", from: "\"x\" <a@weird>",
                                verdict: "mx.google.com; dkim=pass header.i=@tinyshop.co; dmarc=pass header.from=tinyshop.co")
expect(gmailsFrom?.store == "tinyshop.co", "the domain Gmail read from the From header wins: \(gmailsFrom?.store ?? "-")")
for (results, why) in [("mx.google.com; spf=pass (google.com: domain of x@attacker.top designates 1.2.3.4 as permitted sender; dkim=pass header.i=@ups.com) smtp.mailfrom=x@attacker.top", "dkim=pass inside a comment"),
                       ("mx.google.com; spf=pass (x; dmarc=pass header.from=ups.com) smtp.mailfrom=x@attacker.top", "dmarc=pass inside a comment"),
                       ("mx.google.com; dkim=pass header.i=@x.attacker.top\\\"; dkim=pass header.i=@ups.com", "a backslash outside quotes"),
                       ("mx.google.com; dkim=pass header.d=ups.com.attacker.top", "a look-alike signer")] {
    expect(!DeliveryMail.signedBySender(results, domain: "ups.com"), "not verified: \(why)")
}
for (verdict, why) in [("mx.google.com; spf=pass (google.com: x; dkim=pass header.i=@ups.com ) smtp.mailfrom=x@attacker.top", "dkim=pass in a comment"),
                       ("mx.google.com; spf=pass (x; dmarc=pass header.from=ups.com ) smtp.mailfrom=x@attacker.top", "dmarc=pass in a comment"),
                       ("mx.google.com; dkim=fail header.i=@ups.com; dmarc=pass (p=NONE)", "DMARC passing, but for which domain?")] {
    expect(checkedByGmail("UPS Update: Package Delivered", from: "UPS <mcinfo@ups.com>", verdict: verdict)?.store == "Unverified sender",
           "not verified: \(why)")
}
expect(checkedByGmail("UPS Update: Package Delivered", from: "UPS <mcinfo@ups.com>",
                      verdict: "mx.google.com; dkim=pass header.i=@email.ups.com")?.store == "UPS"
       && checkedByGmail("UPS Update: Package Delivered", from: "UPS <mcinfo@email.ups.com>",
                         verdict: "mx.google.com; dkim=pass header.d=ups.com")?.store == "UPS",
       "signed by the same domain or a subdomain of it: verified")

// Item names
expect(DeliveryMail.item(in: #"Delivered: "" and 1 more item"#) == "2 items", "no name, one more: 2 items")
expect(DeliveryMail.item(in: #"Delivered: "Samsung 55" Class Crystal UHD TV" and 2 more items"#)
       == #"Samsung 55" Class Crystal UHD TV +2 more"#, "an inch mark doesn't end the name")
expect(DeliveryMail.item(in: "Delivered: “Samsung 65\" TV”") == "Samsung 65\" TV", "…in curly quotes either")
expect(DeliveryMail.item(in: #"Delivered: "Apple AirPods Pro (2nd..."#) == "Apple AirPods Pro (2nd...", "a name cut short")
expect(DeliveryMail.item(in: "Delivered: Your Walmart order") == nil, "'Your …' isn't an item")
let longMore = DeliveryMail.item(in: "Delivered: \"" + String(repeating: "x", count: 200) + "\" and 3 more items") ?? ""
expect(longMore.count == 80 && longMore.hasSuffix("… +3 more"), "a long name is cut, keeping '+3 more'")
expect(DeliveryMail.shorten("abc", to: 0) == "" && DeliveryMail.shorten("abc", to: -5) == ""
       && DeliveryMail.shorten("abc", to: 1) == "…" && DeliveryMail.shorten("abc", to: 3) == "abc", "shorten never crashes")
expect(DeliveryMail.tidy("👨‍👩‍👧 Your package was delivered") == "Your package was delivered", "a joined emoji leaves nothing behind")
expect(DeliveryMail.tidy("❤️ Thanks 👍🏽 for your order ✔️") == "Thanks for your order", "emoji with selectors and skin tones")
expect(DeliveryMail.tidy("Your \u{202E}redro\u{202C} was delivered") == "Your redro was delivered", "direction overrides are dropped")
expect(DeliveryMail.tidy("Fwd: FW: Your\u{00A0}package\twas delivered") == "Your package was delivered", "prefixes and odd spaces")
expect(HeaderText.parse(Array("Subject: Caf\u{E9} \u{FFFD} delivered\r\n".utf8))["subject"] == "Café \u{FFFD} delivered",
       "valid UTF-8 with a replacement character stays UTF-8")
expect(HeaderText.parse([UInt8]("Subject: Caf".utf8) + [0xE9] + [UInt8]("\r\nFrom: \u{E9}@x.com\r\n".utf8))["from"] == "é@x.com",
       "a Latin-1 line doesn't change how the next line is read")

// Notification text
let upsProblem = DeliveryMail.classify(headers: ["subject": "UPS Update: Delivery Attempted", "from": upsFrom], uid: 1)
expect(upsProblem?.title == "Delivery problem · UPS" && upsProblem?.body == "Delivery Attempted",
       "the store isn't repeated in the body: \(upsProblem?.body ?? "-")")
expect(DeliveryMail.bodyText("USPS® Delivery Attempt: Notice Left", store: "USPS") == "Delivery Attempt: Notice Left", "USPS®")
expect(DeliveryMail.bodyText("USPS® Item Delivered, In/At Mailbox 9400111899223344556677", store: "USPS")
       == "Item Delivered, In/At Mailbox …6677", "long tracking numbers are cut to their last 4")
expect(DeliveryMail.bodyText("FedEx Shipment 771234567890 Delivered", store: "FedEx") == "Shipment …7890 Delivered", "FedEx")
expect(DeliveryMail.bodyText("UPS", store: "UPS") == "UPS", "nothing left: the subject as it was")
expect(DeliveryMail.bodyText("Your order 1Z999AA10123456784 was delivered", store: "tinyshop.co")
       == "Your order …6784 was delivered", "UPS-style numbers too")

// Out for delivery, then delivered: the delivered one takes the out-for-delivery one's place.
let outFirst = DeliveryMail.classify(headers: ["subject": #"Out for delivery: "Anker 735 Charger""#, "from": amazonFrom,
                                               "message-id": "<a1@amazon.com>", "date": "Sat, 17 Oct 2026 08:00:00 +0000"], uid: 1)
let thenDelivered = DeliveryMail.classify(headers: ["subject": #"Delivered: "Anker 735 Charger""#,
                                                    "from": amazonFrom, "message-id": "<a2@amazon.com>",
                                                    "date": "Sat, 17 Oct 2026 13:00:00 +0000"], uid: 2)
expect(outFirst?.title == "Out for delivery · Amazon" && outFirst?.body == "Anker 735 Charger", "out for delivery text")
if let outFirst, let thenDelivered {
    let placed = DeliveryList.adding([thenDelivered], to: [outFirst], now: Date(timeIntervalSince1970: 1_792_250_000))
    expect(placed.count == 1 && placed.first?.notificationID == outFirst.notificationID
           && DeliveryList.replaced(by: thenDelivered, in: [outFirst])?.key == outFirst.key,
           "same package, same notification: \(placed.map(\.notificationID))")
    expect(DeliveryList.replaced(by: outFirst, in: [thenDelivered]) == nil, "never the other way round")
}
let uspsOut = DeliveryMail.classify(headers: ["subject": "USPS® Item Out for Delivery, 9400111899223344556677", "from": uspsFrom], uid: 1)
let uspsIn = DeliveryMail.classify(headers: ["subject": "USPS® Item Delivered, In/At Mailbox 9400111899223344556677",
                                             "from": uspsFrom], uid: 2)
expect(uspsOut?.package == "usps:9400111899223344556677" && uspsOut?.package == uspsIn?.package, "by tracking number")
expect(DeliveryMail.packageKey(subject: "Your order 112-1234567-1234567 was delivered", store: "Amazon") == nil
       && DeliveryMail.packageKey(subject: #"Delivered: "Lamp" (order 112-1234567-1234567)"#, store: "Amazon")
          == "amazon:112-1234567-1234567:lamp", "an order number only counts with the item: split shipments stay apart")
let upsA = DeliveryMail.classify(headers: ["subject": "UPS Update: Package Delivered", "from": upsFrom, "message-id": "<u1@ups.com>"], uid: 1)
expect(upsA?.package == nil && upsA?.notificationID == "delivery-<u1@ups.com>", "nothing to go on: one notification per email")
let otherPackage = DeliveryMail.classify(headers: ["subject": #"Delivered: "Lamp""#, "from": amazonFrom], uid: 3)
expect(otherPackage?.notificationID != thenDelivered?.notificationID, "another package, another notification")
// Repeat orders and split shipments stay apart.
func amazonEmail(_ subject: String, _ id: String, _ date: String) -> Delivery? {
    DeliveryMail.classify(headers: ["subject": subject, "from": amazonFrom, "message-id": "<\(id)@amazon.com>", "date": date], uid: 1)
}
let packNow = Date(timeIntervalSince1970: 1_792_250_000)                 // Sat 17 Oct 2026
if let firstOrder = amazonEmail(#"Delivered: "AA Batteries, 48 Count""#, "r1", "Tue, 13 Oct 2026 10:00:00 +0000"),
   let repeatOut = amazonEmail(#"Out for delivery: "AA Batteries, 48 Count""#, "r2", "Sat, 17 Oct 2026 08:00:00 +0000"),
   let repeatIn = amazonEmail(#"Delivered: "AA Batteries, 48 Count""#, "r3", "Sat, 17 Oct 2026 12:00:00 +0000"),
   let oldOut = amazonEmail(#"Out for delivery: "AA Batteries, 48 Count""#, "r0", "Tue, 13 Oct 2026 07:00:00 +0000") {
    var list = DeliveryList.adding([firstOrder], to: [], now: packNow)
    list = DeliveryList.adding([repeatOut], to: list, now: packNow)
    expect(list.map(\.key) == ["<r2@amazon.com>", "<r1@amazon.com>"] && repeatOut.notificationID != firstOrder.notificationID,
           "a repeat order's 'Out for delivery' never replaces the last order's 'Delivered'")
    list = DeliveryList.adding([repeatIn], to: list, now: packNow)
    expect(list.map(\.key) == ["<r3@amazon.com>", "<r1@amazon.com>"] && list.first?.notificationID == repeatOut.notificationID,
           "its own 'Delivered' replaces its 'Out for delivery': \(list.map(\.key))")
    expect(DeliveryList.replaced(by: repeatIn, in: [oldOut]) == nil, "an 'Out for delivery' from 4 days before is another parcel")
    let secondOut = amazonEmail(#"Out for delivery: "AA Batteries, 48 Count""#, "r4", "Sat, 17 Oct 2026 09:00:00 +0000")
    let secondIn = amazonEmail(#"Delivered: "AA Batteries, 48 Count""#, "r5", "Sat, 17 Oct 2026 13:00:00 +0000")
    expect(secondOut.map { DeliveryList.replaced(by: $0, in: [repeatOut]) } == .some(nil),
           "an 'Out for delivery' never replaces another one")
    expect(secondIn.map { DeliveryList.replaced(by: $0, in: [repeatIn]) } == .some(nil),
           "a 'Delivered' only ever replaces an 'Out for delivery', not another 'Delivered'")
}
let splitOut = amazonEmail("Your order 112-1234567-1234567 is out for delivery", "s1", "Sat, 17 Oct 2026 08:00:00 +0000")
let splitIn = amazonEmail("Your order 112-1234567-1234567 was delivered", "s2", "Sat, 17 Oct 2026 12:00:00 +0000")
if let splitOut, let splitIn {
    expect(DeliveryList.replaced(by: splitIn, in: [splitOut]) == nil && splitIn.notificationID != splitOut.notificationID,
           "a split shipment (same order, no item or tracking number) stays apart")
}
let partA = amazonEmail(#"Out for delivery: "Lamp" (order 112-1234567-1234567)"#, "p1", "Sat, 17 Oct 2026 08:00:00 +0000")
let partB = amazonEmail(#"Delivered: "Rug" (order 112-1234567-1234567)"#, "p2", "Sat, 17 Oct 2026 12:00:00 +0000")
expect(partA?.package != nil && partA?.package != partB?.package, "same order, different items: different parcels")
let cut1 = amazonEmail(#"Delivered: "Apple AirPods Pro (2nd..." and 1 more item"#, "c1", "Sat, 17 Oct 2026 12:00:00 +0000")
let cut2 = amazonEmail(#"Out for delivery: "Apple AirPods Pro (2nd...""#, "c2", "Sat, 17 Oct 2026 08:00:00 +0000")
expect(cut1?.package != cut2?.package, "a name cut short, with and without '+1 more': not the same parcel")
// A store's long order number isn't a tracking number, so two orders don't become one parcel.
func storeEmail(_ subject: String, _ from: String, _ id: String, _ date: String) -> Delivery? {
    DeliveryMail.classify(headers: ["subject": subject, "from": from, "message-id": "<\(id)@x>", "date": date], uid: 1)
}
let targetOut = storeEmail("Your Target order #102003456789012 is out for delivery", "Target <orders@oe1.target.com>", "t1",
                           "Sat, 17 Oct 2026 08:00:00 +0000")
let targetIn = storeEmail("Your Target order #102003456789099 has been delivered", "Target <orders@oe1.target.com>", "t2",
                          "Sat, 17 Oct 2026 12:00:00 +0000")
expect(targetOut?.package == nil && targetIn.flatMap { d in targetOut.map { DeliveryList.replaced(by: d, in: [$0]) } } == .some(nil),
       "a 15-digit order number isn't a tracking number: \(targetOut?.package ?? "-")")
let bestBuy = storeEmail("Your Best Buy order BBY01-806123456789 has been delivered", "Best Buy <BestBuyInfo@emailinfo.bestbuy.com>",
                         "b1", "Sat, 17 Oct 2026 12:00:00 +0000")
expect(bestBuy?.package == nil, "…nor a 12-digit one: \(bestBuy?.package ?? "-")")
let fedexOut = storeEmail("Your FedEx package 771234567890 is out for delivery", fedexFrom, "f1", "Sat, 17 Oct 2026 08:00:00 +0000")
let fedexIn = storeEmail("FedEx Shipment 771234567890 Delivered", fedexFrom, "f2", "Sat, 17 Oct 2026 12:00:00 +0000")
if let fedexOut, let fedexIn {
    expect(fedexOut.package == "fedex:771234567890" && DeliveryList.replaced(by: fedexIn, in: [fedexOut])?.key == fedexOut.key,
           "from FedEx itself, 12 digits are its tracking number")
}
// Two orders of the same thing out for delivery at once: the first "Delivered" can't tell which, so it replaces neither.
if let outA = amazonEmail(#"Out for delivery: "USB-C Cable""#, "o1", "Sat, 17 Oct 2026 07:00:00 +0000"),
   let outB = amazonEmail(#"Out for delivery: "USB-C Cable""#, "o2", "Sat, 17 Oct 2026 08:00:00 +0000"),
   let inA = amazonEmail(#"Delivered: "USB-C Cable""#, "o3", "Sat, 17 Oct 2026 11:00:00 +0000"),
   let early = amazonEmail(#"Delivered: "USB-C Cable""#, "o4", "Sat, 17 Oct 2026 06:00:00 +0000") {
    expect(DeliveryList.replaced(by: inA, in: [outA, outB]) == nil
           && DeliveryList.adding([inA], to: [outB, outA], now: packNow).count == 3,
           "a repeat order out at the same time: each keeps its own notification")
    expect(DeliveryList.replaced(by: early, in: [outA]) == nil, "a 'Delivered' sent before the 'Out for delivery' doesn't replace it")
}
let phone1 = DeliveryMail.classify(headers: ["subject": "Your Samsung order has been delivered — questions? Call 18005551234",
                                             "from": "Samsung <noreply@samsung.com>"], uid: 1)
expect(phone1?.package == nil && DeliveryMail.trackingNumbers(in: "Call 18005551234 or 8005551234").isEmpty,
       "phone numbers aren't tracking numbers")
expect(DeliveryMail.trackingNumbers(in: "1Z999AA10123456784 TBA123456789012 EA123456789US 771234567890 9400111899223344556677")
       == ["1Z999AA10123456784", "TBA123456789012", "EA123456789US", "9400111899223344556677"],
       "UPS, Amazon, USPS international and USPS formats, from anyone")
expect(DeliveryMail.trackingNumbers(in: "Shipment 771234567890 / 771234567890123", store: "FedEx") == ["771234567890", "771234567890123"]
       && DeliveryMail.trackingNumbers(in: "Order 102003456789012 / BBY01-806123456789", store: "Target").isEmpty
       && DeliveryMail.trackingNumbers(in: "Order 8187654321098765432", store: "AliExpress").isEmpty,
       "12- and 15-digit numbers only from FedEx: a store's order number isn't a tracking number")
expect(DeliveryMail.trackingNumbers(in: "Shipment 1234567890", store: "DHL") == ["1234567890"]
       && DeliveryMail.trackingNumbers(in: "Shipment 1234567890").isEmpty, "10 digits only from DHL")
expect(DeliveryMail.bodyText("Your order was delivered. Questions? Call 18005551234", store: "x.com")
       == "Your order was delivered. Questions? Call 18005551234", "a phone number in the text stays whole")

// The menu keeps a week of deliveries, and a package's newer email replaces its older one.
let listNow = Date(timeIntervalSince1970: 1_792_250_000)
func listed(_ name: String, daysAgo: Double, package: String? = nil, kind: Delivery.Kind = .delivered) -> Delivery {
    Delivery(kind: kind, store: "Amazon", item: name, subject: name, messageID: "<\(name)@x>",
             date: listNow.addingTimeInterval(-daysAgo * 86_400), uid: 0, package: package)
}
let weekList = DeliveryList.current([listed("new", daysAgo: 1), listed("old", daysAgo: 8),
                                     Delivery(kind: .delivered, store: "x", item: "undated", subject: "", messageID: nil,
                                              date: nil, uid: 0)], now: listNow)
expect(weekList.map(\.body) == ["new"], "only the last 7 days: \(weekList.map(\.body))")
let replaced = DeliveryList.adding([listed("Cable delivered", daysAgo: 0, package: "amazon:cable")],
                                   to: [listed("Cable out", daysAgo: 0.1, package: "amazon:cable", kind: .outForDelivery),
                                        listed("Lamp", daysAgo: 2)], now: listNow)
expect(replaced.map(\.body) == ["Cable delivered", "Lamp"], "delivered replaces out for delivery: \(replaced.map(\.body))")
expect(DeliveryList.adding((0..<12).map { listed("d\($0)", daysAgo: 0) }, to: [], now: listNow).count == 8, "at most 8")

// Opening the email itself (Gmail's ID), not a search for it.
let byID = Delivery(kind: .delivered, store: "UPS", item: nil, subject: "s", messageID: "<m@ups.com>", date: nil, uid: 0,
                    gmailID: "18c2f0a1b2c3d4e5")
expect(byID.gmailLink(account: "you@gmail.com")?.absoluteString == "https://mail.google.com/mail/?authuser=you@gmail.com#all/18c2f0a1b2c3d4e5",
       "Gmail's ID opens the email")
let oddID = Delivery(kind: .delivered, store: "UPS", item: nil, subject: "s", messageID: "<m@ups.com>", date: nil, uid: 0,
                     gmailID: "../x?y")
expect(oddID.gmailLink(account: "you@gmail.com")?.absoluteString.hasSuffix("#search/rfc822msgid%3Am@ups.com") == true,
       "an odd ID falls back to the Message-ID")

// Dates: two-digit years, zone names, no seconds, and quick on anything.
let dateBase = Date(timeIntervalSince1970: 1_792_245_731)            // Sat 17 Oct 2026 14:02:11 UTC
expect(DeliveryMail.parseDate("Sat, 17 Oct 26 14:02:11 +0000") == dateBase, "two-digit year")
expect(DeliveryMail.parseDate("Sat, 17 Oct 2026 10:02:11 EDT") == dateBase
       && DeliveryMail.parseDate("Sat, 17 Oct 2026 07:02:11 PDT") == dateBase, "zone names")
expect(DeliveryMail.parseDate("17 Oct 2026 14:02 GMT") == dateBase.addingTimeInterval(-11), "no seconds, no weekday")
expect(DeliveryMail.parseDate("Sat,17 oct 2026 14:02:11.250 +00:00") == dateBase, "odd spacing, fractions, +00:00")
expect(DeliveryMail.parseDate("Sat, 31 Feb 2026 14:02:11 +0000") == nil && DeliveryMail.parseDate("Sat, 17 Oct 2026 25:00 +0000") == nil
       && DeliveryMail.parseDate("Sat, 17 Oct 2026 14:02:11 -2500") == nil, "impossible dates")
expect(DeliveryMail.parseDate("日本 Sat, 17 Oct 2026 14:02:11 +0000") == dateBase, "only ASCII is read")
let slowDates = [String(repeating: "(", count: 65_536) + ")", String(repeating: "Sat, 17 ", count: 8_192),
                 "Sat, 17 Oct 2026 14:02:11 +0000 " + String(repeating: "(x) ", count: 16_000)]
let dateClock = Date()
for text in slowDates { _ = DeliveryMail.parseDate(text) }
expect(DeliveryMail.parseDate(slowDates[2]) == dateBase, "a date followed by 64 KB of comments")
expect(Date().timeIntervalSince(dateClock) < 0.5, "64 KB dates are quick: \(Date().timeIntervalSince(dateClock)) s")
let titleClock = Date()
_ = ScriptCheck.pageTitle("<title>" + String(repeating: "<title", count: 10_500))
_ = ScriptCheck.pageTitle(String(repeating: "<title>x", count: 8_000))
expect(Date().timeIntervalSince(titleClock) < 0.5, "62 KB page titles are quick: \(Date().timeIntervalSince(titleClock)) s")
let subjectClock = Date()
_ = DeliveryMail.classify(headers: ["subject": String(repeating: "Your package was delivered \"x' ", count: 2_000),
                                    "from": String(repeating: "a", count: 60_000) + "@ups.com"], uid: 1)
expect(Date().timeIntervalSince(subjectClock) < 1, "a huge subject and sender are quick: \(Date().timeIntervalSince(subjectClock)) s")

// Split encoded words: a character split across two words is joined first.
expect(HeaderText.decode("=?UTF-8?B?8J+T?= =?UTF-8?B?piBZb3VyIHBhY2thZ2Ugd2FzIGRlbGl2ZXJlZA==?=") == "📦 Your package was delivered",
       "an emoji split across two B words")
expect(HeaderText.decode("=?UTF-8?Q?Delivered:_=22Caf=C3?=\r\n =?UTF-8?Q?=A9_mug=22?=") == "Delivered: \"Café mug\"",
       "é split across two Q words, folded")
expect(HeaderText.decode("=?ISO-8859-1?Q?Caf=E9?= =?UTF-8?B?IOKchQ==?=") == "Café ✅", "different charsets are decoded apart")
expect(HeaderText.decode("=?UTF-8?B?8J+T?= and =?UTF-8?B?pg==?=") == "=?UTF-8?B?8J+T?= and =?UTF-8?B?pg==?=",
       "words with text between aren't joined, and a broken one stays as it was")

// MARK: Delivery alerts: the Keychain tool, and settings kept somewhere new

// Stand-ins for macOS's `security` tool: small shell scripts in a temporary folder.
let keychainDir = FileManager.default.temporaryDirectory.appendingPathComponent("hammer-keychain-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: keychainDir, withIntermediateDirectories: true)
func standIn(_ name: String, _ body: String) -> KeychainTool {
    let path = keychainDir.appendingPathComponent(name).path
    _ = FileManager.default.createFile(atPath: path, contents: Data(("#!/bin/sh\necho \"$@\" >> '\(keychainDir.path)/argv.log'\n" + body).utf8),
                                   attributes: [.posixPermissions: 0o755])
    return KeychainTool(path: path, timeout: 2)
}
let foundTool = standIn("found", "echo hunter2hunter2hunter\nexit 0\n")
expect(foundTool.find(service: "local.hammer.gmail", account: "you@gmail.com") == .found("hunter2hunter2hunter"), "found")
expect(standIn("missing", "exit 44\n").find(service: "s", account: "a") == .missing, "only 'not found' means missing")
if case .unavailable = standIn("locked", "exit 36\n").find(service: "s", account: "a") {
    expect(true, "any other failure (locked, denied) is passing, not missing")
} else { expect(false, "a locked Keychain was read as missing") }
let slowClock = Date()
if case .unavailable = standIn("slow", "sleep 30\n").find(service: "s", account: "a") {
    expect(Date().timeIntervalSince(slowClock) < 6, "a Keychain that doesn't answer gives up after its time limit")
} else { expect(false, "a hung Keychain wasn't stopped") }
if case .unavailable = KeychainTool(path: "/nonexistent/security").find(service: "s", account: "a") {
    expect(true, "no tool at all: passing")
} else { expect(false, "missing tool") }
let storeTool = standIn("store", """
    if [ "$1" = "-i" ]; then sed -n 's/.* -w \\([^ ]*\\)$/\\1/p' > '\(keychainDir.path)/kept'; exit 0; fi
    if [ "$1" = "find-generic-password" ]; then [ -s '\(keychainDir.path)/kept' ] || exit 44; cat '\(keychainDir.path)/kept'; exit 0; fi
    if [ "$1" = "delete-generic-password" ]; then [ -s '\(keychainDir.path)/kept' ] || exit 44; rm '\(keychainDir.path)/kept'; exit 0; fi
    exit 1

    """)
let secretURL = "https://script.google.com/macros/s/AKfycbSECRET123/exec"
expect(storeTool.save(service: "local.hammer.gmail", account: "script-url", label: "Hammer-Gmail-script-URL", secret: secretURL),
       "saved and read back")
expect(storeTool.find(service: "local.hammer.gmail", account: "script-url") == .found(secretURL), "the address is in the Keychain")
let argvLog = (try? String(contentsOfFile: keychainDir.appendingPathComponent("argv.log").path, encoding: .utf8)) ?? ""
expect(!argvLog.contains("AKfycbSECRET123") && !argvLog.contains("hunter2") && argvLog.contains("find-generic-password -s local.hammer.gmail"),
       "secrets never go on a command line")
for bad in ["has space", "quote\"d", "new\nline", "", "semi;colon"] {
    expect(!storeTool.save(service: "local.hammer.gmail", account: "a", label: "L", secret: bad), "not stored: \(bad.debugDescription)")
}
expect(storeTool.delete(service: "local.hammer.gmail", account: "script-url")
       && storeTool.find(service: "local.hammer.gmail", account: "script-url") == .missing
       && storeTool.delete(service: "local.hammer.gmail", account: "script-url"), "deleted; deleting again is fine")
expect(!standIn("locked2", "exit 36\n").delete(service: "s", account: "a"), "a failed delete says so")
// Saving the script's address and key together: if the key can't be saved, the address is put back.
let shelf = keychainDir.appendingPathComponent("shelf").path
try? FileManager.default.createDirectory(atPath: shelf, withIntermediateDirectories: true)
let shelfTool = standIn("shelf-tool", """
    account() { while [ $# -gt 0 ]; do [ "$1" = "-a" ] && { echo "$2"; return; }; shift; done; }
    if [ "$1" = "-i" ]; then
      line=$(cat); a=$(echo "$line" | sed -n 's/.* -a \\([^ ]*\\) .*/\\1/p'); v=$(echo "$line" | sed -n 's/.* -w \\([^ ]*\\)$/\\1/p')
      [ -e '\(shelf)/refuse-'"$a" ] && exit 0
      printf '%s' "$v" > '\(shelf)/'"$a"; touch '\(shelf)/written-'"$a"; exit 0
    fi
    a=$(account "$@")
    if [ "$1" = "find-generic-password" ]; then
      [ -e '\(shelf)/flaky-'"$a" ] && [ -e '\(shelf)/written-'"$a" ] && { rm '\(shelf)/flaky-'"$a" '\(shelf)/written-'"$a"; exit 36; }
      [ -e '\(shelf)/'"$a" ] || exit 44; cat '\(shelf)/'"$a"; exit 0
    fi
    if [ "$1" = "delete-generic-password" ]; then [ -e '\(shelf)/'"$a" ] || exit 44; rm '\(shelf)/'"$a"; exit 0; fi
    exit 1

    """)
let oldURL = "https://script.google.com/macros/s/AKfycbOLDONE/exec", newURL = "https://script.google.com/macros/s/AKfycbNEW/exec"
_ = shelfTool.save(service: "s", account: "script-url", label: "L", secret: oldURL)
_ = FileManager.default.createFile(atPath: shelf + "/refuse-script-key", contents: Data())
expect(!shelfTool.saveAll(service: "s", [("script-url", "L", newURL), ("script-key", "K", String(repeating: "a", count: 64))])
       && shelfTool.find(service: "s", account: "script-url") == .found(oldURL), "the key can't be saved: the old address is back")
_ = shelfTool.delete(service: "s", account: "script-url")
expect(!shelfTool.saveAll(service: "s", [("script-url", "L", newURL), ("script-key", "K", String(repeating: "a", count: 64))])
       && shelfTool.find(service: "s", account: "script-url") == .missing, "…or gone, if there wasn't one")
try? FileManager.default.removeItem(atPath: shelf + "/refuse-script-key")
expect(shelfTool.saveAll(service: "s", [("script-url", "L", newURL), ("script-key", "K", String(repeating: "a", count: 64))])
       && shelfTool.find(service: "s", account: "script-url") == .found(newURL)
       && shelfTool.find(service: "s", account: "script-key") == .found(String(repeating: "a", count: 64)), "both saved")
// The key's write lands but reading it back fails once: the key is put back too, not just the address.
try? FileManager.default.removeItem(atPath: shelf + "/written-script-key")
_ = FileManager.default.createFile(atPath: shelf + "/flaky-script-key", contents: Data())   // the next write's read-back fails
let olderKey = String(repeating: "a", count: 64), newerKey = String(repeating: "b", count: 64)
expect(!shelfTool.saveAll(service: "s", [("script-url", "L", oldURL), ("script-key", "K", newerKey)])
       && shelfTool.find(service: "s", account: "script-url") == .found(newURL)
       && shelfTool.find(service: "s", account: "script-key") == .found(olderKey),
       "a save that can't be confirmed is undone too: the address and key still go together")
try? FileManager.default.removeItem(at: keychainDir)

// The script's web address moves from Hammer's settings into the Keychain, once.
let oldAddress = "https://script.google.com/macros/s/AKfycbOLD/exec"
var copied: [URL] = []
var moved = DeliveryMigration.scriptAddress(keychain: .missing, setting: oldAddress) { copied.append($0); return true }
expect(moved.url?.absoluteString == oldAddress && moved.forgetSetting && copied.map(\.absoluteString) == [oldAddress],
       "copied into the Keychain, and the setting can go")
moved = DeliveryMigration.scriptAddress(keychain: .found(oldAddress), setting: nil) { copied.append($0); return true }
expect(moved.url?.absoluteString == oldAddress && !moved.forgetSetting && copied.count == 1, "already moved: nothing to do")
moved = DeliveryMigration.scriptAddress(keychain: .found(oldAddress), setting: oldAddress) { copied.append($0); return true }
expect(moved.forgetSetting && copied.count == 1, "moved before, but the setting is still there: it goes")
moved = DeliveryMigration.scriptAddress(keychain: .unavailable("locked"), setting: oldAddress) { copied.append($0); return true }
expect(moved.url?.absoluteString == oldAddress && !moved.forgetSetting && copied.count == 1,
       "Keychain locked: keep using the setting, move it later")
moved = DeliveryMigration.scriptAddress(keychain: .missing, setting: oldAddress) { _ in false }
expect(moved.url != nil && !moved.forgetSetting, "couldn't save: the setting stays")
moved = DeliveryMigration.scriptAddress(keychain: .missing, setting: "https://evil.example.com/macros/s/x/exec") { _ in true }
expect(moved.url == nil, "a setting that isn't a web app address isn't used")
expect(DeliveryMigration.scriptAddress(keychain: .missing, setting: nil) { _ in true }.url == nil, "nothing anywhere")

// MARK: IMAP: reading answers

/// Plays back a server's bytes in awkward pieces and records what was sent.
final class ScriptedTransport: IMAPTransport {
    var chunks: [[UInt8]]
    var sent: [String] = []
    var closed = false
    init(_ text: String, pieceSize: Int = 7) {
        let bytes = Array(text.utf8)
        chunks = stride(from: 0, to: bytes.count, by: pieceSize).map { Array(bytes[$0..<min($0 + pieceSize, bytes.count)]) }
    }
    func send(_ bytes: [UInt8]) throws { sent.append(String(decoding: bytes, as: UTF8.self)) }
    func receive() throws -> [UInt8] { chunks.isEmpty ? [] : chunks.removeFirst() }
    func close() { closed = true }
}

let headerBlock = "Subject: Delivered: \"Cable\"\r\nFrom: Amazon.com <a@amazon.com>\r\n\r\n"
let fetchAnswer = "* 1 FETCH (UID 41 BODY[HEADER.FIELDS (FROM SUBJECT)] {\(headerBlock.utf8.count)}\r\n\(headerBlock))\r\n"
let script = ScriptedTransport("* OK Gimap ready\r\nH001 OK logged in\r\n" + fetchAnswer + "H002 OK Success\r\n")
let connection = IMAPConnection(transport: script)
do {
    try connection.start()
    try connection.login(email: "you@gmail.com", password: "abcd\"efgh")
    expect(script.sent.first == "H001 LOGIN \"you@gmail.com\" \"abcd\\\"efgh\"\r\n", "login quotes and escapes")
    let reply = try connection.run("UID FETCH 41 (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])")
    expect(reply.status == "OK", "tagged OK")
    let fetched = IMAPReply.fetchedHeaders(reply.untagged)
    expect(fetched[41]?["subject"] == "Delivered: \"Cable\"", "literal read across pieces: \(fetched)")
} catch {
    expect(false, "scripted conversation failed: \(error)")
}

let refused = IMAPConnection(transport: ScriptedTransport("* OK hi\r\nH001 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n"))
do {
    try refused.start()
    try refused.login(email: "a", password: "b")
    expect(false, "a refused login throws")
} catch IMAPError.badLogin(let text) {
    expect(text.contains("AUTHENTICATIONFAILED"), "bad login reported with Gmail's reason")
} catch {
    expect(false, "wrong error for a refused login: \(error)")
}

let busy = IMAPConnection(transport: ScriptedTransport("* OK hi\r\nH001 NO [UNAVAILABLE] Temporary System Problem. Try again later (Failure)\r\n"))
do {
    try busy.start()
    try busy.login(email: "a", password: "b")
    expect(false, "a refused login throws")
} catch IMAPError.failed {
    expect(true, "a passing Gmail problem isn't treated as a wrong password")
} catch {
    expect(false, "wrong error for a temporary problem: \(error)")
}
expect(IMAPConnection.isRefusedLogin("[AUTHENTICATIONFAILED] Invalid credentials (Failure)"), "refused: wrong password")
expect(IMAPConnection.isRefusedLogin("[ALERT] Application-specific password required: https://…"), "refused: needs an app password")
expect(IMAPConnection.isRefusedLogin("[WEBALERT https://…] Web login required."), "refused: Google wants a browser sign-in")
expect(!IMAPConnection.isRefusedLogin("[UNAVAILABLE] Temporary System Problem"), "not refused: temporary")
expect(!IMAPConnection.isRefusedLogin("[ALERT] Too many simultaneous connections. (Failure)"), "not refused: too many connections")
expect(DeliveryCheck.explain(.badLogin("[WEBALERT x] Web login required")).contains("browser"), "browser sign-in message")

let hungUp = IMAPConnection(transport: ScriptedTransport("* OK hi\r\nH001 OK\r\n* 1 FETCH (UID 1 BODY[] {500}\r\nshort"))
do {
    try hungUp.start()
    _ = try hungUp.run("NOOP")
    _ = try hungUp.run("UID FETCH 1 BODY.PEEK[]")
    expect(false, "a connection that closes mid-answer throws")
} catch let error as IMAPError {
    expect(error == .offline, "hang-up mid-literal is 'offline'")
} catch {
    expect(false, "unexpected error \(error)")
}
let notIMAP = IMAPConnection(transport: ScriptedTransport("HTTP/1.1 400 Bad Request\r\n"))
expect((try? notIMAP.start()) == nil, "a server that isn't IMAP is rejected")
let huge = IMAPConnection(transport: ScriptedTransport("* OK hi\r\n* 1 FETCH (UID 1 BODY[] {99999999999}\r\n", pieceSize: 64))
do {
    try huge.start()
    _ = try huge.run("NOOP")
    expect(false, "an absurd literal size is refused")
} catch let error as IMAPError {
    expect(error != .offline, "refused before trying to read it")
} catch { expect(false, "\(error)") }

expect(IMAPConnection.literalSize(at: Array("* 1 FETCH (BODY[] {12}".utf8)) == 12, "literal size")
expect(IMAPConnection.literalSize(at: Array("x {12+}".utf8)) == 12, "non-synchronizing literal")
expect(IMAPConnection.literalSize(at: Array("subject {not}".utf8)) == nil, "not a literal")
expect(IMAPConnection.literalSize(at: Array("{}".utf8)) == nil, "empty braces")

let examine = Array("* FLAGS (\\Seen)\r\n* OK [UIDVALIDITY 7] UIDs valid.\r\n* 42 EXISTS\r\n* OK [UIDNEXT 1235] Predicted next UID.\r\n".utf8)
expect(IMAPReply.status(examine).map { [$0.uidNext, $0.uidValidity] } == [1235, 7], "UIDNEXT and UIDVALIDITY")
expect(IMAPReply.status(Array("* 42 EXISTS\r\n".utf8)) == nil, "missing numbers")
expect(IMAPReply.search(Array("* SEARCH 12 15 99\r\n".utf8)) == [12, 15, 99], "search hits")
expect(IMAPReply.search(Array("* SEARCH\r\n".utf8)) == [], "no hits")
expect(IMAPReply.search(Array("* OK nothing\r\n".utf8)) == nil, "no SEARCH line")
let afterBlock = "Subject: x\r\n\r\n"
let uidAfter = "* 3 FETCH (BODY[HEADER.FIELDS (SUBJECT)] {\(afterBlock.utf8.count)}\r\n\(afterBlock) UID 77)\r\n"
expect(IMAPReply.fetchedHeaders(Array(uidAfter.utf8))[77]?["subject"] == "x", "UID after the headers")

// Each FETCH response is read on its own, literals by their length.
func fetchedFrom(_ text: String) -> [Int: [String: String]] { IMAPReply.fetchedHeaders(Array(text.utf8)) }
let headersA = "Subject: Delivered: \"A\"\r\nFrom: a@amazon.com\r\n\r\n", headersB = "Subject: Delivered: \"B\"\r\n\r\n"
let fetchA = "* 2 FETCH (UID 51 BODY[HEADER.FIELDS (FROM SUBJECT)] {\(headersA.utf8.count)}\r\n\(headersA))\r\n"
let fetchB = "* 3 FETCH (X-GM-MSGID 1278455344230334865 UID 52 BODY[HEADER.FIELDS (FROM SUBJECT)] {\(headersB.utf8.count)}\r\n\(headersB))\r\n"
let interrupted = fetchedFrom(fetchA + "* 1 FETCH (UID 50 FLAGS (\\Seen))\r\n" + fetchB)
expect(interrupted[52]?["subject"] == "Delivered: \"B\"" && interrupted[50] == nil && interrupted.count == 2,
       "an unsolicited FETCH between two emails doesn't move headers: \(interrupted.keys.sorted())")
expect(interrupted[52]?[":gmail-id"] == "11bdfc5cae0c8191" && interrupted[51]?[":gmail-id"] == nil,
       "Gmail's ID, in hex as its links use it")
let smuggled = "Subject: x\r\n* 9 FETCH (UID 999 BODY[HEADER.FIELDS (SUBJECT)] {3}\r\nabc\r\n\r\n"
expect(fetchedFrom("* 2 FETCH (UID 51 BODY[HEADER.FIELDS (SUBJECT)] {\(smuggled.utf8.count)}\r\n\(smuggled))\r\n").keys.sorted() == [51],
       "a FETCH line inside an email's headers is just text")
expect(fetchedFrom("* 2 FETCH (UID 51 BODY[HEADER.FIELDS (SUBJECT)] \"\")\r\n" + fetchB).keys.sorted() == [52],
       "an empty body, then a normal one")
for size in ["-2", "9223372036854775807", "99999999999999999999", "9223372036854775806"] {
    let odd = "* 1 FETCH (UID 5 BODY[HEADER.FIELDS (SUBJECT)] {\(size)}\r\nSubject: x\r\n)\r\n" + fetchB
    expect(fetchedFrom(odd)[5] == nil, "a literal of {\(size)} doesn't crash and isn't read")
}
expect(fetchedFrom("* 1 FETCH (UID 5 BODY[HEADER.FIELDS (SUBJECT)] {40}\r\nSubject: cut short").isEmpty, "a cut-off literal")
// Only Gmail's own verdict counts: the first Authentication-Results, which Gmail puts on top.
func fetchedDelivery(_ lines: [String]) -> Delivery? {
    let block = lines.joined(separator: "\r\n") + "\r\n\r\n"
    let answer = "* 1 FETCH (UID 7 X-GM-MSGID 4660 BODY[HEADER.FIELDS (FROM SUBJECT AUTHENTICATION-RESULTS)] {\(block.utf8.count)}\r\n\(block))\r\n"
    return IMAPReply.fetchedHeaders(Array(answer.utf8))[7].flatMap { DeliveryMail.classify(headers: $0, uid: 7) }
}
let upsLines = ["From: UPS <mcinfo@ups.com>", "Subject: UPS Update: Package Delivered"]
expect(fetchedDelivery(["Authentication-Results: mx.google.com;", "\tdkim=pass header.i=@ups.com header.s=s1;", "\tspf=pass"] + upsLines)?.store
       == "UPS", "Gmail's verdict on top, folded: verified")
expect(fetchedDelivery(["Authentication-Results: mx.google.com; dkim=fail header.i=@ups.com"] + upsLines
                       + ["Authentication-Results: mx.google.com; dkim=pass header.i=@ups.com"])?.store == "Unverified sender",
       "the sender's own (passing) header further down never counts")
expect(fetchedDelivery(["Authentication-Results: mx.google.com; dkim=fail header.i=@attacker.top",
                        "Authentication-Results: mx.google.com; dkim=pass header.i=@ups.com"] + upsLines)?.store == "Unverified sender",
       "two before From: the first is Gmail's")
expect(fetchedDelivery(upsLines + ["Authentication-Results: mx.google.com; dkim=pass header.i=@ups.com"])?.store == "Unverified sender",
       "none from Gmail, the sender's own below From: not verified")
expect(fetchedDelivery(upsLines)?.store == "Unverified sender", "no verdict at all on the IMAP route: not verified")
expect(fetchedDelivery(["Authentication-Results: spoof.example; dkim=pass header.i=@ups.com",
                        "Authentication-Results: mx.google.com; dkim=pass header.i=@ups.com"] + upsLines)?.store == "Unverified sender",
       "the first isn't Gmail's: not verified (never the next one)")
expect(HeaderText.parse(Array("Subject: first\r\nSubject: second\r\n  continued\r\n".utf8))["subject"] == "first",
       "a repeated header: the first counts, and the second's folded lines aren't added")
// Headers are only ever read from the BODY[HEADER…] literal, never another one.
let helloBlock = "Subject: UPS Update: Hello\r\n\r\n"
let labelsFirst = "* 1 FETCH (UID 9 X-GM-LABELS ({6}\r\nInbox!) BODY[HEADER.FIELDS (SUBJECT)] {\(helloBlock.utf8.count)}\r\n\(helloBlock))\r\n"
expect(IMAPReply.fetchedHeaders(Array(labelsFirst.utf8))[9]?["subject"] == "UPS Update: Hello",
       "another literal before the headers isn't read as headers")
let labelsAfter = "* 1 FETCH (UID 9 BODY[HEADER.FIELDS (SUBJECT)] {\(helloBlock.utf8.count)}\r\n\(helloBlock) X-GM-LABELS ({6}\r\nInbox!))\r\n"
expect(IMAPReply.fetchedHeaders(Array(labelsAfter.utf8))[9]?["subject"] == "UPS Update: Hello",
       "…or after them")
expect(IMAPConnection.literalSize(at: Array("x {99999999999999999999}".utf8)) == Int.max, "a huge literal size is refused later")

// Login refusals: a wrong password stops checks; IMAP turned off isn't "temporary" forever.
func loginError(_ text: String) -> IMAPError? {
    let connection = IMAPConnection(transport: ScriptedTransport("* OK hi\r\nH001 NO \(text)\r\n"))
    do { try connection.start(); try connection.login(email: "you@gmail.com", password: "abcdefghijklmnop") }
    catch let error as IMAPError { return error } catch { return nil }
    return nil
}
let imapOff = loginError("[ALERT] Your account is not enabled for IMAP use. Please visit your Gmail settings page and enable your account for IMAP access. (Failure)")
expect(imapOff == .notAllowed("[ALERT] Your account is not enabled for IMAP use. Please visit your Gmail settings page and enable your account for IMAP access. (Failure)"),
       "IMAP turned off: a lasting refusal")
let imapOffFailure = imapOff.map(CheckFailure.init)
expect(imapOffFailure?.message == "IMAP is turned off for this account." && imapOffFailure?.needsSetup == true
       && imapOffFailure?.stopChecking == false && imapOffFailure?.hasFix == true, "says so, offers a fix, keeps checking")
let domainOff = loginError("[ALERT] IMAP access is disabled for your domain. Please contact your domain administrator. (Failure)").map(CheckFailure.init)
expect(domainOff?.advice == "Your Google Workspace administrator can turn it on.",
       "only an administrator can turn IMAP off (personal Gmail always has it since 2025)")
for failure in [imapOffFailure, domainOff, unknownRefusalFor("[ALERT] Account suspended (Failure)")].compactMap({ $0 }) {
    expect(!failure.setupMessage.lowercased().contains("script"), "the app-password window doesn't talk about the script: \(failure.setupMessage)")
}
func unknownRefusalFor(_ text: String) -> CheckFailure? { loginError(text).map(CheckFailure.init) }
let browser = loginError("[ALERT] Please log in via your web browser: https://support.google.com/mail/accounts/answer/78754 (Failure)")
expect(browser.map { if case .badLogin = $0 { return true }; return false } == true
       && browser.map(CheckFailure.init)?.message == "Google wants you to sign in to Gmail in your browser.",
       "'log in via your web browser' is lasting: sign in to Gmail in the browser")
for passing in ["[OVERQUOTA] Account exceeded command or bandwidth limits. (Failure)", "[SERVERBUG] Internal server error (Failure)"] {
    expect(loginError(passing) == .failed("Gmail is having trouble right now."), "passing: \(passing)")
}
let unknownRefusal = loginError("[ALERT] Account suspended (Failure)").map(CheckFailure.init)
expect(unknownRefusal?.message == "Gmail turned down the sign-in." && unknownRefusal?.advice.contains("“Account suspended”") == true,
       "anything else lasting: Gmail's own words: \(unknownRefusal?.advice ?? "-")")
expect(loginError("[UNAVAILABLE] Temporary System Problem. Try again later (Failure)") == .failed("Gmail is having trouble right now.")
       && loginError("[ALERT] Too many simultaneous connections. (Failure)") == .failed("Gmail is having trouble right now."),
       "passing problems")
expect(CheckFailure(.badLogin("[AUTHENTICATIONFAILED] Invalid credentials (Failure)")).stopChecking, "a wrong password stops checks")
// What setup says never promises a retry it won't make.
let setupFailures = [CheckFailure(.failed("Gmail is having trouble right now.")), .offline, CheckFailure(.badLogin("x")),
                     CheckFailure(.notAllowed("x"))] + ["", "<html>x</html>", #"{"ok":false,"error":"gmail"}"#].compactMap {
                        if case .failure(let f) = ScriptCheck.read(status: 200, body: Data($0.utf8)) { return f }; return nil }
                     + [429, 503].compactMap { if case .failure(let f) = ScriptCheck.read(status: $0, body: Data()) { return f }; return nil }
for failure in setupFailures {
    let text = failure.setupMessage.lowercased()
    expect(!text.contains("keep trying") && !text.contains("will try") && text.count > failure.message.count,
           "setup says what to do: \(failure.setupMessage)")
    expect(!failure.message.contains("\n") && failure.message.count <= 60, "one short menu line: \(failure.message)")
}
expect(CheckFailure.offline.setupMessage == "Can't reach Gmail right now. Check your internet connection, then try again.",
       "offline, during setup")

// MARK: Checking for deliveries

/// An in-memory inbox that answers the commands DeliveryCheck sends.
final class FakeInbox {
    var validity = 7
    var messages: [(uid: Int, headers: String)] = []
    var log: [String] = []
    var failOn: String?
    /// Like Gmail, puts its verdict on top: by default that the sender's domain signed it.
    func add(_ subject: String, from: String = "\"eBay\" <ebay@ebay.com>", date: String = "Sat, 17 Oct 2026 14:00:00 +0000",
             id: String? = nil, verdict: String? = "") {
        let uid = (messages.map(\.uid).max() ?? 100) + 1
        let checked = verdict.map { "Authentication-Results: " + ($0.isEmpty ? "mx.google.com; dkim=pass header.i=@\(DeliveryMail.domain(of: from))" : $0) + "\r\n" } ?? ""
        messages.append((uid, checked + "From: \(from)\r\nSubject: \(subject)\r\nDate: \(date)\r\nMessage-ID: <\(id ?? "m\(uid)")@x>\r\n\r\n"))
    }
    func answer(_ command: String) throws -> IMAPResponse {
        log.append(command)
        if let failOn, command.hasPrefix(failOn) { throw IMAPError.offline }
        let top = messages.map(\.uid).max() ?? 100
        if command == "EXAMINE INBOX" {
            return IMAPResponse(status: "OK", text: "[READ-ONLY]",
                                untagged: Array("* OK [UIDVALIDITY \(validity)] ok\r\n* OK [UIDNEXT \(top + 1)] ok\r\n".utf8))
        }
        if command.hasPrefix("UID SEARCH SINCE ") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "d-MMM-yyyy"
            let since = formatter.date(from: String(command.dropFirst(17))) ?? .distantFuture
            let hits = messages.filter { message in
                let date = HeaderText.parse(Array(message.headers.utf8))["date"].flatMap(DeliveryMail.parseDate)
                return (date ?? .distantPast) >= since
            }.map(\.uid)
            return IMAPResponse(status: "OK", text: "", untagged: Array("* SEARCH \(hits.map(String.init).joined(separator: " "))\r\n".utf8))
        }
        if command.hasPrefix("UID SEARCH UID ") {
            let from = Int(command.dropFirst(15).prefix { $0 != ":" }) ?? 0
            var hits = messages.filter { $0.uid >= from }.map(\.uid)
            if hits.isEmpty, let last = messages.last, from > last.uid { hits = [last.uid] }   // IMAP: n:* always includes the newest
            return IMAPResponse(status: "OK", text: "", untagged: Array("* SEARCH \(hits.map(String.init).joined(separator: " "))\r\n".utf8))
        }
        if command.hasPrefix("UID FETCH ") {
            let wanted = Set(command.dropFirst(10).prefix { $0 != " " }.split(separator: ",").compactMap { Int($0) })
            var out: [UInt8] = []
            for (index, message) in messages.enumerated() where wanted.contains(message.uid) {
                out += Array("* \(index + 1) FETCH (X-GM-MSGID \(9_000_000 + message.uid) UID \(message.uid) BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID AUTHENTICATION-RESULTS)] {\(message.headers.utf8.count)}\r\n".utf8)
                out += Array(message.headers.utf8) + Array(")\r\n".utf8)
            }
            return IMAPResponse(status: "OK", text: "", untagged: out)
        }
        return IMAPResponse(status: "BAD", text: "unknown", untagged: [])
    }
}

let now = Date(timeIntervalSince1970: 1_792_250_000)          // Sat 17 Oct 2026, ~15:13 UTC
let inbox = FakeInbox()
inbox.add("Your package was delivered")                         // already there when alerts are turned on
var deliveryState = DeliveryState()
do {
    var result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
    expect(result.deliveries.isEmpty && result.state.lastUID == 101 && result.state.uidValidity == 7,
           "first check only notes where the inbox is")
    deliveryState = result.state

    inbox.add("Your package was delivered: Apple iPhone 15 Pro Max")
    inbox.add("lunch?", from: "Friend <f@gmail.com>")
    inbox.add(#"Out for delivery: "Cable""#, from: "Amazon.com <a@amazon.com>")
    inbox.add(#"Delivered: "Cable""#, from: "Amazon.com <a@amazon.com>")
    inbox.add("Your package was delivered", date: "Mon, 12 Oct 2026 10:00:00 +0000")        // 5 days old
    inbox.log = []
    result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
    expect(result.deliveries.map(\.title) == ["Delivered · eBay", "Out for delivery · Amazon", "Delivered · Amazon"]
           && result.deliveries.map(\.body) == ["Apple iPhone 15 Pro Max", "Cable", "Cable"],
           "announces the new deliveries in order: \(result.deliveries.map(\.title))")
    expect(result.deliveries.first?.gmailID == String(9_000_102, radix: 16), "with Gmail's ID for each")
    expect(result.state.lastUID == 106, "moves past everything it looked at")
    expect(!inbox.log.contains { $0.hasPrefix("SELECT") } && !inbox.log.contains { $0.contains("BODY[") },
           "never opens the inbox for writing or reads in a way that marks mail read: \(inbox.log)")
    expect(inbox.log.contains { $0.contains("BODY.PEEK[HEADER.FIELDS") }, "reads headers with PEEK")
    deliveryState = result.state

    inbox.log = []
    result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
    expect(result.deliveries.isEmpty && inbox.log == ["EXAMINE INBOX"], "nothing new: one quick look, no search")

    inbox.add("Your package was delivered: Apple iPhone 15 Pro Max", id: "m102")             // same email again (moved back)
    result = try DeliveryCheck.run(state: result.state, now: now, command: inbox.answer)
    expect(result.deliveries.isEmpty, "the same email isn't announced twice")
    deliveryState = result.state

    inbox.add("lunch?", from: "Friend <f@gmail.com>")
    inbox.log = []
    result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
    let newest = inbox.messages.map(\.uid).max() ?? 0
    expect(result.deliveries.isEmpty && inbox.log.filter { $0.hasPrefix("UID FETCH") }
               == ["UID FETCH \(newest) (X-GM-MSGID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID AUTHENTICATION-RESULTS)])"],
           "only the one new email is read, nothing older: \(inbox.log)")
    deliveryState = result.state

    inbox.add("Delivered: \"Lamp\"", from: "Target <orders@target.com>")
    inbox.failOn = "UID FETCH"
    do {
        _ = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
        expect(false, "a failed fetch throws")
    } catch {
        inbox.failOn = nil
        result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
        expect(result.deliveries.map(\.body) == ["Lamp"], "after a failed check, the next one still finds it")
        deliveryState = result.state
    }

    inbox.validity = 8
    inbox.add("Delivered: \"Rug\"")
    result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
    expect(result.deliveries.isEmpty && result.state.uidValidity == 8, "Gmail renumbering starts over quietly")
} catch {
    expect(false, "delivery checks threw: \(error)")
}

// Setting up again after it stopped working looks back to the last good check (at most 3 days).
let missedInbox = FakeInbox()
missedInbox.add("Your package was delivered: Old lamp", date: "Mon, 12 Oct 2026 10:00:00 +0000")    // before the last good check
missedInbox.add(#"Delivered: "Clock""#, from: amazonFrom, date: "Sat, 17 Oct 2026 02:00:00 +0000", id: "clock")  // before it: seen then
missedInbox.add(#"Delivered: "Rug""#, from: amazonFrom, date: "Sat, 17 Oct 2026 09:00:00 +0000", id: "rug")
missedInbox.add(#"Delivered: "Mug""#, from: amazonFrom, date: "Sat, 17 Oct 2026 11:00:00 +0000", id: "mug")
missedInbox.add("lunch?", from: "f@gmail.com", date: "Sat, 17 Oct 2026 12:00:00 +0000")
let lastGood = Date(timeIntervalSince1970: 1_792_224_000)                               // Sat 17 Oct 2026 08:00 UTC
do {
    let fresh = try DeliveryCheck.run(state: DeliveryState(), now: now, command: missedInbox.answer)
    expect(fresh.deliveries.isEmpty, "a first setup still announces nothing old")
    missedInbox.log = []
    let again = try DeliveryCheck.run(state: DeliveryState(announced: ["<mug@x>"]), now: now, lookBack: lastGood,
                                      command: missedInbox.answer)
    expect(again.deliveries.map(\.body) == ["Rug"], "set up again: what arrived meanwhile, minus what was shown: \(again.deliveries.map(\.body))")
    expect(missedInbox.log.contains("UID SEARCH SINCE 16-Oct-2026") && again.state.lastUID == 105 && again.state.uidValidity == 7,
           "searched from the day before, and carries on from the newest: \(missedInbox.log)")
    let weekAgo = try DeliveryCheck.run(state: DeliveryState(), now: now, lookBack: now.addingTimeInterval(-9 * 86_400),
                                        command: missedInbox.answer)
    expect(weekAgo.deliveries.map(\.body) == ["Clock", "Rug", "Mug"], "never more than 3 days back")
} catch {
    expect(false, "look-back failed: \(error)")
}

// Scale: a big inbox with hundreds of new matching emails.
let bigInbox = FakeInbox()
for i in 0..<5_000 { bigInbox.messages.append((101 + i, "From: x@y.com\r\nSubject: newsletter \(i)\r\n\r\n")) }
var bigState = (try? DeliveryCheck.run(state: DeliveryState(), now: now, command: bigInbox.answer).state) ?? DeliveryState()
for i in 0..<400 { bigInbox.add("Delivered: \"Thing \(i)\"", from: "Amazon.com <a@amazon.com>") }
let started = Date()
if let result = try? DeliveryCheck.run(state: bigState, now: now, command: bigInbox.answer) {
    expect(result.deliveries.count == 400, "400 deliveries found in a 5,400-email inbox")
    expect(result.state.announced.count == 200, "only the last 200 are remembered")
    bigState = result.state
} else {
    expect(false, "big inbox check failed")
}
expect(Date().timeIntervalSince(started) < 5, "and quickly: \(Date().timeIntervalSince(started)) s")
expect(bigInbox.log.filter { $0.hasPrefix("UID FETCH") }.count >= 4, "headers fetched in batches")

// After a long time offline: only the newest 500 are looked at, but all are passed.
let backlog = FakeInbox()
backlog.add("old")
var backlogState = (try? DeliveryCheck.run(state: DeliveryState(), now: now, command: backlog.answer).state) ?? DeliveryState()
backlog.add(#"Delivered: "Early""#)
for i in 0..<700 { backlog.add("newsletter \(i)", from: "x@y.com") }
backlog.add(#"Delivered: "Late""#)
if let result = try? DeliveryCheck.run(state: backlogState, now: now, command: backlog.answer) {
    expect(result.deliveries.map(\.body) == ["Late"], "only the newest 500 checked: \(result.deliveries.map(\.body))")
    expect(result.state.lastUID == backlog.messages.map(\.uid).max(), "and none of the rest are looked at again")
    backlogState = result.state
} else {
    expect(false, "backlog check failed")
}

// MARK: The Google script route

let scriptKey = DeliveryScript.newKey()
expect(DeliveryScript.isKey(scriptKey) && DeliveryScript.newKey() != scriptKey, "random 64-character keys")
expect(!DeliveryScript.isKey("") && !DeliveryScript.isKey(String(repeating: "g", count: 64))
       && !DeliveryScript.isKey(String(repeating: "A", count: 64)), "not keys")
let scriptText = DeliveryScript.source(key: scriptKey)
expect(scriptText.contains("const HAMMER_KEY = '\(scriptKey)';") && !scriptText.contains(DeliveryScript.keyPlaceholder),
       "the script carries the key")
expect(scriptText.hasPrefix("/**") && scriptText.contains("function doGet(e)"), "and starts cleanly (no stray indentation)")

let deployed = "https://script.google.com/macros/s/AKfycbx1234567890abcdef/exec"
expect(DeliveryScript.webAppURL(deployed)?.absoluteString == deployed, "a web app URL")
expect(DeliveryScript.webAppURL("  \(deployed)\n")?.absoluteString == deployed, "pasted with spaces")
for bad in ["", "script.google.com/macros/s/x/exec", "http://script.google.com/macros/s/x/exec",
            "https://script.google.com/macros/s/x/dev", "https://evil.example.com/macros/s/x/exec",
            "https://script.google.com.evil.com/macros/s/x/exec", "https://script.google.com/home/projects/x/edit",
            "https://script.google.com/macros/s/x/exec?key=abc"] {
    expect(DeliveryScript.webAppURL(bad) == nil, "not a web app URL: \(bad)")
}
let asked = DeliveryScript.requestURL(base: URL(string: deployed)!, key: scriptKey)?.absoluteString
expect(asked == deployed + "?key=\(scriptKey)&v=2", "asks with the key: \(asked ?? "-")")
let askedSince = DeliveryScript.requestURL(base: URL(string: deployed)!, key: scriptKey,
                                           after: Date(timeIntervalSince1970: 1_792_250_000))?.absoluteString
expect(askedSince == deployed + "?key=\(scriptKey)&v=2&after=1792250000", "and when it last asked")
let workspace = "https://script.google.com/a/macros/example.com/s/AKfycbx123/exec"
expect(DeliveryScript.webAppURL(workspace)?.absoluteString == workspace, "a Google Workspace web app URL")

func reply(_ json: String, status: Int = 200) -> Result<ScriptCheck.Reply, CheckFailure> {
    ScriptCheck.read(status: status, body: Data(json.utf8))
}
let good = #"{"ok":true,"version":1,"account":"you@gmail.com","emails":[{"id":"m1","messageID":"<m1@mail>","from":"\"eBay\" <ebay@ebay.com>","subject":"Your package was delivered: Apple iPhone 15 Pro Max","date":"2026-10-17T15:00:00.000Z"}]}"#
if case .success(let r) = reply(good) {
    expect(r.account == "you@gmail.com" && r.emails?.count == 1 && r.emails?.first?.id == "m1", "reads the script's answer")
} else { expect(false, "good answer rejected") }
func failure(_ result: Result<ScriptCheck.Reply, CheckFailure>) -> CheckFailure? {
    if case .failure(let f) = result { return f }
    return nil
}
expect(failure(reply(#"{"ok":false,"error":"key"}"#))?.needsSetup == true, "wrong key: set up again")
let noPermission = failure(reply(#"{"ok":false,"error":"permission","message":"no permission"}"#))
expect(noPermission?.needsSetup == true && noPermission?.advice.contains("Select all") == true,
       "Gmail access not granted: says how to grant it")
let gmailBusy = failure(reply(#"{"ok":false,"error":"gmail","message":"Service invoked too many times"}"#))
expect(gmailBusy?.needsSetup == false && gmailBusy?.hasFix == false && gmailBusy?.message == "The script couldn't read Gmail just now.",
       "Gmail error: retried")
let signIn = failure(reply("<html><head><title>Sign in - Google Accounts</title></head><body>…</body></html>"))
expect(signIn?.needsSetup == true && signIn?.message == "The script isn't open to Anyone." && signIn?.advice.contains("pencil") == true,
       "sign-in page: access must be Anyone")
let redirected = failure(ScriptCheck.read(status: 200, body: Data("<html>…</html>".utf8),
                                          finalURL: URL(string: "https://accounts.google.com/v3/signin/identifier?x=1")))
expect(redirected?.message.contains("Anyone") == true, "sent to Google's sign-in: access must be Anyone")
let otherPage = failure(reply("<html><head><title>Error &amp; stuff</title></head><body><a href='https://accounts.google.com/'>Sign in</a></body></html>"))
expect(otherPage?.advice.contains("“Error & stuff”") == true && otherPage?.needsSetup == false,
       "any other Google page: says what it was, keeps trying: \(otherPage?.advice ?? "-")")
let missing = failure(reply("<html><title>Page Not Found</title>Sorry, unable to open the file at this time.</html>"))
expect(missing?.needsSetup == true && missing?.message.contains("can't find") == true, "no script at that address")
expect(ScriptCheck.pageTitle("<TITLE>\n  Sign in\n</TITLE>") == "Sign in" && ScriptCheck.pageTitle("no title") == nil
       && ScriptCheck.pageTitle("<title></title>") == nil, "page titles")
expect(failure(reply("<html>Script function not found: doGet</html>"))?.message.contains("saved") == true, "not saved")
expect(failure(reply("<html>Authorization is required to perform that action.</html>"))?.advice.contains("Run") == true,
       "needs permission again")
expect(failure(reply("Not Found", status: 404))?.needsSetup == true, "wrong address")
expect(failure(reply("<html>Error</html>", status: 503))?.needsSetup == false, "Google busy: retried")
expect(failure(reply("garbage"))?.needsSetup == false, "nonsense: retried")
expect(failure(reply(""))?.needsSetup == false, "empty: retried")

func email(_ id: String, _ subject: String, from: String = "\"eBay\" <ebay@ebay.com>", hoursAgo: Double = 1,
           messageID: String? = nil) -> ScriptCheck.Email {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return ScriptCheck.Email(id: id, messageID: messageID ?? "<\(id)@mail>", from: from, subject: subject,
                             date: formatter.string(from: now.addingTimeInterval(-hoursAgo * 3600)))
}
var scriptState = ScriptState()
expect(scriptState.searchFrom == nil, "first check: no 'after'")
var processed = ScriptCheck.process([email("old1", "Your package was delivered")], state: scriptState, now: now,
                                    askedAt: now)
expect(processed.state.askedAt == now && processed.state.searchFrom == now.addingTimeInterval(-15 * 60),
       "remembers when it asked, and looks back 15 minutes before that next time")
expect(processed.deliveries.isEmpty && processed.state.started && processed.state.seen == ["old1"],
       "first answer: notes what's there, announces nothing")
scriptState = processed.state
let batch = [
    email("old1", "Your package was delivered"),
    email("n2", #"Delivered: "Cable""#, from: "Amazon.com <a@amazon.com>", hoursAgo: 0.5, messageID: ""),
    email("n1", "Your package was delivered: Apple iPhone 15 Pro Max", hoursAgo: 2),
    email("n3", #"Out for delivery: "Lamp""#, from: "Target <t@target.com>"),
    email("n4", "Your package was delivered", hoursAgo: 24 * 5),
]
processed = ScriptCheck.process(batch, state: scriptState, now: now)
expect(processed.deliveries.map(\.body) == ["Apple iPhone 15 Pro Max", "Lamp", "Cable"]
       && processed.deliveries.map(\.kind) == [.delivered, .outForDelivery, .delivered],
       "new deliveries only, oldest first: \(processed.deliveries.map(\.body))")
expect(processed.deliveries.map(\.store) == ["eBay", "Target", "Amazon"] && processed.deliveries[2].messageID == nil
       && processed.deliveries[2].gmailID == "n2", "store, and Gmail's ID when there's no Message-ID")
expect(processed.state.seen == ["old1", "n2", "n1", "n3", "n4"], "everything looked at is remembered")
expect(processed.deliveries[2].gmailLink(account: "you@gmail.com")?.absoluteString
       == "https://mail.google.com/mail/?authuser=you@gmail.com#all/n2", "link by Gmail's ID")
expect(processed.deliveries[0].gmailLink(account: "you@gmail.com")?.absoluteString
       == "https://mail.google.com/mail/?authuser=you@gmail.com#all/n1", "Gmail's ID first, even with a Message-ID")
let alreadyShown = ScriptCheck.process([email("s1", "Your package was delivered", messageID: "<seen@mail>"),
                                        email("s2", #"Delivered: "Rug""#, from: amazonFrom, messageID: "<new@mail>"),
                                        email("s3", #"Delivered: "Rug""#, from: amazonFrom, messageID: "<new@mail>")],
                                       state: ScriptState(started: true), now: now, shown: ["<seen@mail>"])
expect(alreadyShown.deliveries.map(\.gmailID) == ["s2"], "one already shown (or twice in one answer) isn't announced again")
let undated = ScriptCheck.process([ScriptCheck.Email(id: "u1", messageID: nil, from: "eBay <e@ebay.com>",
                                                     subject: "Your package was delivered", date: "garbage")],
                                  state: ScriptState(started: true), now: now)
expect(undated.deliveries.first?.date == now, "no date: when Hammer saw it, so it drops off the menu in time")
scriptState = processed.state
processed = ScriptCheck.process(batch, state: scriptState, now: now)
expect(processed.deliveries.isEmpty, "nothing announced twice")
processed = ScriptCheck.process([ScriptCheck.Email(id: "", messageID: nil, from: nil, subject: "Delivered: x", date: nil)],
                                state: scriptState, now: now)
expect(processed.deliveries.isEmpty, "an email without an ID is ignored")
var bigScript = ScriptState(started: true, seen: [])
for chunk in 0..<6 {
    bigScript = ScriptCheck.process((0..<100).map { email("x\(chunk)-\($0)", "newsletter") }, state: bigScript, now: now).state
}
expect(bigScript.seen.count == 500 && bigScript.seen.last == "x5-99", "only the last 500 IDs are kept")

let noLink = Delivery(kind: .delivered, store: "Hammer", item: "test", subject: "", messageID: nil, date: nil, uid: 0)
expect(noLink.gmailLink(account: "you@gmail.com") == nil, "the test notification has no email to open")
let noAccount = Delivery(kind: .delivered, store: "eBay", item: nil, subject: "s", messageID: "<a@b>", date: nil, uid: 0)
expect(noAccount.gmailLink(account: "")?.absoluteString == "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Aa@b",
       "no account known: the first Gmail account")
expect(CheckFailure(.badLogin("[AUTHENTICATIONFAILED] x")).needsSetup && CheckFailure(.offline).offline
       && !CheckFailure(.failed("x")).needsSetup, "app-password errors map across")

// Saved deliveries from before this change still load.
let savedBefore = #"[{"kind":"delivered","store":"eBay","item":"x","subject":"s","messageID":"<a@b>","uid":3}]"#
expect((try? JSONDecoder().decode([Delivery].self, from: Data(savedBefore.utf8)))?.first?.gmailID == nil,
       "older saved deliveries still load")

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
