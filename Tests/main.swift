// Tests for HammerCore.swift. Run by build.sh before every install:
//   swiftc HammerCore.swift Tests/main.swift -o hammer-tests && ./hammer-tests
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
expect(DDCPacket.get(code: 0x10) == [0x82, 0x01, 0x10, 0xAC], "get brightness")

let goodReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
let parsed = DDCPacket.parseReply(goodReply, code: 0x10)
expect(parsed?.current == 50 && parsed?.max == 100, "reads current 50 of max 100")
var corrupt = goodReply
corrupt[9] = 0x33
expect(DDCPacket.parseReply(corrupt, code: 0x10) == nil, "a bad checksum is rejected")
expect(DDCPacket.parseReply(goodReply, code: 0x12) == nil, "an answer about another setting is rejected")
var unsupported = goodReply
unsupported[3] = 0x01
unsupported[10] ^= 0x01                                    // keep the checksum valid
expect(DDCPacket.parseReply(unsupported, code: 0x10) == nil, "\"unsupported\" result is rejected")
expect(DDCPacket.parseReply(Array(goodReply.prefix(10)), code: 0x10) == nil, "too short")
expect(DDCPacket.parseReply([], code: 0x10) == nil, "empty")

// MARK: Text

expect(TimerText.describe(minutes: 5) == "5 min", "5 min")
expect(TimerText.describe(minutes: 45) == "45 min", "45 min")
expect(TimerText.describe(minutes: 60) == "1 hr", "1 hr")
expect(TimerText.describe(minutes: 90) == "1 hr 30 min", "1 hr 30 min")
expect(TimerText.describe(minutes: 480) == "8 hr", "8 hr")

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
