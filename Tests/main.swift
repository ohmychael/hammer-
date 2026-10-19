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
func runCheck(_ entries: [RegistryEntry], _ screens: [MonitorScreen], _ buses: [UInt64: FakeMonitor]) -> MonitorCheck {
    MonitorCheck.run(mac: mac, screens: screens, entries: entries, bus: { buses[$0] }, sleep: { _ in })
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
expect(check.verdict == .hdmiAdapter && check.ports[0].port.throughHDMIAdapter
       && check.text.contains("Its ID info (EDID), from macOS: DELL U3818DW, on its HDMI input")
       && check.advice.joined(separator: " ").contains("USB-C to USB-C cable from the Mac to the monitor's USB-C port")
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
expect(check.verdict == .noAnswer && !check.ports[0].port.throughHDMIAdapter, "the Mac's own HDMI port isn't \"an adapter\"")
state = MonitorMenu.make(connections: 1, attached: 1, screens: lidClosed, answers: false, hdmiAdapter: true)
expect(state.sliders && state.hints == ["The Dell is on one of its HDMI ports, which blocks",
                                        "control. Use its DisplayPort or USB-C port instead."], "menu: says to leave HDMI")
state = MonitorMenu.make(connections: 1, attached: 1, screens: lidClosed, answers: true, hdmiAdapter: true)
expect(state.hints.isEmpty, "menu: an adapter that works isn't mentioned")

// What the user had next: a USB-C to DisplayPort adapter, then HDMI into the Dell. macOS calls
// the link "DP → HDMI" (no M1 converter) and refuses to send (e0114000).
let belkinEntries = [framebuffer(300, "DELL U3818DW", display: true, transport: "DP → HDMI"),
                     proxy(301, path: "IOService:/x/dcpext0@1/y")]
dell = FakeMonitor(); dell.writeStatus = Int32(bitPattern: 0xE0114000); dell.edid = makeEDID("DELL U3818DW", hdmi: true)
check = runCheck(belkinEntries, lidClosed, [301: dell])
let belkinAdvice = check.advice.joined(separator: "\n")
expect(check.verdict == .hdmiAdapter && check.ports[0].port.throughHDMIAdapter
       && check.text.contains("DELL U3818DW (dcpext0, DP → HDMI)") && check.text.contains("Sent: no (error e0114000)"),
       "USB-C, then HDMI into the monitor, reported as DP → HDMI: the adapter case\n\(check.text)")
expect(belkinAdvice.contains("plugged into one of its HDMI ports") && belkinAdvice.contains("DisplayPort cable into the monitor's DP port")
       && belkinAdvice.contains("A DisplayPort to HDMI cable still lands on HDMI") && !belkinAdvice.contains("This Mac's HDMI port"),
       "says to use the monitor's DP or USB-C port, not that the Mac's own HDMI port is the problem:\n\(belkinAdvice)")
// The same, but the monitor's ID info doesn't say which input: no guessing about adapters.
dell = FakeMonitor(); dell.writeStatus = Int32(bitPattern: 0xE0114000); dell.edid = makeEDID("DELL U3818DW")
check = runCheck(belkinEntries, lidClosed, [301: dell])
expect(check.verdict == .cantSend && check.advice.joined().contains("Connect to the monitor's DisplayPort or USB-C port instead (not HDMI)")
       && !check.advice.joined().contains("This Mac's HDMI port"), "HDMI link, input unknown: still points at DP or USB-C\n\(check.text)")


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
var playerDrop = PlayerGeometry.dropdown(visible: playerWideScreen, anchorMaxX: 3700)
expect(playerDrop == CGRect(x: 2940, y: 1111, width: 760, height: 460), "dropdown under the icon, wide and short: \(playerDrop)")
playerDrop = PlayerGeometry.dropdown(visible: playerWideScreen, anchorMaxX: nil)
expect(playerDrop.maxX == 3832 && playerDrop.maxY == 1571, "no icon: the top-right corner")
playerDrop = PlayerGeometry.dropdown(visible: playerWideScreen, anchorMaxX: 200)
expect(playerDrop.minX == 8 && playerDrop.width == 760, "an icon near the left edge: kept on screen")
playerDrop = PlayerGeometry.dropdown(visible: CGRect(x: 0, y: 0, width: 300, height: 500), anchorMaxX: 290)
expect(playerDrop.width == 284 && playerDrop.height == 460 && playerDrop.minX == 8 && playerDrop.minY >= 0, "a small screen: shrunk to fit")
playerDrop = PlayerGeometry.dropdown(size: CGSize(width: 900, height: 380), visible: playerWideScreen, anchorMaxX: nil)
expect(playerDrop.size == CGSize(width: 900, height: 380), "your own size is kept")
playerDrop = PlayerGeometry.dropdown(size: CGSize(width: 100, height: 50), visible: playerWideScreen, anchorMaxX: nil)
expect(playerDrop.size == CGSize(width: 480, height: 300), "never smaller than 480 × 300")
let playerSecond = CGRect(x: -1920, y: 200, width: 1920, height: 1055)  // a screen to the left
playerDrop = PlayerGeometry.dropdown(visible: playerSecond, anchorMaxX: nil)
expect(playerSecond.contains(playerDrop), "another screen: inside it")

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
    "Fwd: Your package has been delivered",
    "Your Walmart order was delivered",
    "=?utf-8?Q?Your_package_was_delivered_=E2=9C=85?=",
    "Your package was delivered earlier than expected",
    "DELIVERED: \"Phone case\"",
    "Your package has been dropped off",
    "Your order from Target has arrived",
    "Your items have arrived",
]
for subject in deliveredSubjects {
    expect(DeliveryMail.kind(ofSubject: subject) == .delivered, "delivered: \(subject)")
}
let problemSubjects = [
    "Delivery attempted - we'll try again tomorrow",
    "UPS Update: Delivery Attempted",
    "Your package couldn't be delivered",
    "Action needed: delivery exception for your order",
    "Your parcel is being returned to sender",
    "We were unable to deliver your package",
]
for subject in problemSubjects {
    expect(DeliveryMail.kind(ofSubject: subject) == .problem, "problem: \(subject)")
}
let otherSubjects = [
    #"Out for delivery: "Anker 735 Charger""#,
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
expect(DeliveryMail.store(from: "Google Groups <noreply@groups.com>") == "Google Groups", "groups.com isn't UPS")
expect(DeliveryMail.store(from: "Shop <no-reply@shop.app>") == "Shop", "Shop app")
expect(DeliveryMail.store(from: "=?UTF-8?Q?Caf=C3=A9_Store?= <orders@cafe-store.com>") == "Café Store", "encoded name")
expect(DeliveryMail.store(from: "orders@weirdshop.co.uk") == "Weirdshop", "no name: from the domain")
expect(DeliveryMail.store(from: "") == "Package", "nothing to go on")

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
expect(classified("UPS Update: Delivery Attempted", from: "someone@example.com") == .problem,
       "delivery problems already need delivery wording")
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

// MARK: Checking for deliveries

/// An in-memory inbox that answers the commands DeliveryCheck sends.
final class FakeInbox {
    var validity = 7
    var messages: [(uid: Int, headers: String)] = []
    var log: [String] = []
    var failOn: String?
    func add(_ subject: String, from: String = "\"eBay\" <ebay@ebay.com>", date: String = "Sat, 17 Oct 2026 14:00:00 +0000",
             id: String? = nil) {
        let uid = (messages.map(\.uid).max() ?? 100) + 1
        messages.append((uid, "From: \(from)\r\nSubject: \(subject)\r\nDate: \(date)\r\nMessage-ID: <\(id ?? "m\(uid)")@x>\r\n\r\n"))
    }
    func answer(_ command: String) throws -> IMAPResponse {
        log.append(command)
        if let failOn, command.hasPrefix(failOn) { throw IMAPError.offline }
        let top = messages.map(\.uid).max() ?? 100
        if command == "EXAMINE INBOX" {
            return IMAPResponse(status: "OK", text: "[READ-ONLY]",
                                untagged: Array("* OK [UIDVALIDITY \(validity)] ok\r\n* OK [UIDNEXT \(top + 1)] ok\r\n".utf8))
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
                out += Array("* \(index + 1) FETCH (UID \(message.uid) BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)] {\(message.headers.utf8.count)}\r\n".utf8)
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
    expect(result.deliveries.map(\.body) == ["Apple iPhone 15 Pro Max", "Cable"],
           "announces the two new deliveries in order: \(result.deliveries.map(\.body))")
    expect(result.deliveries.map(\.store) == ["eBay", "Amazon"], "with their stores")
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
               == ["UID FETCH \(newest) (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])"],
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
expect(noPermission?.needsSetup == true && noPermission?.message.contains("Select all") == true,
       "Gmail access not granted: says how to grant it")
let gmailBusy = failure(reply(#"{"ok":false,"error":"gmail","message":"Service invoked too many times"}"#))
expect(gmailBusy?.needsSetup == false && gmailBusy?.message.contains("keep trying") == true, "Gmail error: retried")
let signIn = failure(reply("<html><head><title>Sign in - Google Accounts</title></head><body>…</body></html>"))
expect(signIn?.needsSetup == true && signIn?.message.contains("Anyone") == true, "sign-in page: access must be Anyone")
let redirected = failure(ScriptCheck.read(status: 200, body: Data("<html>…</html>".utf8),
                                          finalURL: URL(string: "https://accounts.google.com/v3/signin/identifier?x=1")))
expect(redirected?.message.contains("Anyone") == true, "sent to Google's sign-in: access must be Anyone")
let otherPage = failure(reply("<html><head><title>Error &amp; stuff</title></head><body><a href='https://accounts.google.com/'>Sign in</a></body></html>"))
expect(otherPage?.message.contains("“Error & stuff”") == true && otherPage?.needsSetup == false,
       "any other Google page: says what it was, keeps trying: \(otherPage?.message ?? "-")")
let missing = failure(reply("<html><title>Page Not Found</title>Sorry, unable to open the file at this time.</html>"))
expect(missing?.needsSetup == true && missing?.message.contains("can't find") == true, "no script at that address")
expect(ScriptCheck.pageTitle("<TITLE>\n  Sign in\n</TITLE>") == "Sign in" && ScriptCheck.pageTitle("no title") == nil
       && ScriptCheck.pageTitle("<title></title>") == nil, "page titles")
expect(failure(reply("<html>Script function not found: doGet</html>"))?.message.contains("saved") == true, "not saved")
expect(failure(reply("<html>Authorization is required to perform that action.</html>"))?.message.contains("Run") == true,
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
expect(processed.deliveries.map(\.body) == ["Apple iPhone 15 Pro Max", "Cable"],
       "new deliveries only, oldest first: \(processed.deliveries.map(\.body))")
expect(processed.deliveries.map(\.store) == ["eBay", "Amazon"] && processed.deliveries[1].messageID == nil
       && processed.deliveries[1].gmailID == "n2", "store, and Gmail's ID when there's no Message-ID")
expect(processed.state.seen == ["old1", "n2", "n1", "n3", "n4"], "everything looked at is remembered")
expect(processed.deliveries[1].gmailLink(account: "you@gmail.com")?.absoluteString
       == "https://mail.google.com/mail/?authuser=you@gmail.com#all/n2", "link by Gmail's ID")
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
