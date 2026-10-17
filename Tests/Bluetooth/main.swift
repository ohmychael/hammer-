// Bluetooth scenarios for Hammer's GoveeBluetooth class, run against the mock
// CoreBluetooth next to this file, which behaves like a Govee H6006-style bulb and
// a phone that can grab it. Each scenario runs as its own process; run.sh builds
// and runs them all. A scenario exits 1 if any of its checks fails.
import Foundation
import CoreBluetooth

let scenario = CommandLine.arguments.dropFirst().first ?? "phone"
UserDefaults.standard.removeObject(forKey: "bluetoothBulbs")
var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("  \(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}
func run(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

// MARK: The bulb

final class Bulb {
    let peripheral: CBPeripheral
    var phoneHasIt = false          // the phone holds the link: our connect stays pending
    var connectFails = false        // connect attempts fail 50 ms later
    var dropAfter: Double? = nil    // the link drops this long after connecting
    var discoveryErrors = 0         // this many service discoveries fail with an error
    var discoveryHangs = false      // service discovery never answers
    var hasService = true
    var hasControl = true
    var echoesOnControl = false     // repeats every write back on the control channel
    var power = true
    var brightness = 100
    var pending = false
    var connects = 0
    let rx = CBCharacteristic(_sim: CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d2b10"), properties: [.read, .notify])
    let control = CBCharacteristic(_sim: GoveeBluetooth.controlUUID, properties: [.read, .write, .writeWithoutResponse, .notify])
    init(name: String?) { peripheral = CBPeripheral(_sim: UUID(), name: name) }
    var id: UUID { peripheral.identifier }
}
var bulbs: [UUID: Bulb] = [:]
func addBulb(name: String? = "ihoment_H6006_0FC3") -> Bulb {
    let bulb = Bulb(name: name)
    bulbs[bulb.id] = bulb
    simKnown[bulb.id] = bulb.peripheral
    return bulb
}

let gb = GoveeBluetooth()
var heldSet: Set<UUID> = []
var rebuilds = 0
gb.onChange = {                                   // what AppDelegate does on every change
    Task { @MainActor in
        rebuilds += 1
        _ = gb.lights
        gb.hold(heldSet)
    }
}

func finishConnect(_ bulb: Bulb) {
    let p = bulb.peripheral
    bulb.pending = false
    if bulb.connectFails {
        p._state = .disconnected
        gb.centralManager(simCentral!, didFailToConnect: p, error: NSError(domain: "CBErrorDomain", code: 14))
        return
    }
    p._state = .connected
    bulb.connects += 1
    let session = bulb.connects
    gb.centralManager(simCentral!, didConnect: p)
    if let after = bulb.dropAfter {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            guard p._state == .connected, bulb.connects == session else { return }
            p._state = .disconnected
            gb.centralManager(simCentral!, didDisconnectPeripheral: p, error: NSError(domain: "CBErrorDomain", code: 7))
        }
    }
}
simOnConnect = { p in
    guard let bulb = bulbs[p.identifier] else { return }
    if bulb.phoneHasIt { bulb.pending = true; return }
    DispatchQueue.main.asyncAfter(deadline: .now() + (bulb.connectFails ? 0.05 : 0.1)) {
        guard p._state == .connecting else { return }      // cancelled meanwhile
        finishConnect(bulb)
    }
}
simOnCancel = { p in
    bulbs[p.identifier]?.pending = false
    DispatchQueue.main.async { gb.centralManager(simCentral!, didDisconnectPeripheral: p, error: nil) }
}
simOnDiscoverServices = { p in
    guard let bulb = bulbs[p.identifier], !bulb.discoveryHangs else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        guard p._state == .connected else { return }
        if bulb.discoveryErrors > 0 {
            bulb.discoveryErrors -= 1
            p._services = nil
            gb.peripheral(p, didDiscoverServices: NSError(domain: "CBATTErrorDomain", code: 14))
            return
        }
        p._services = bulb.hasService ? [CBService(_sim: GoveeBluetooth.serviceUUID)] : []
        gb.peripheral(p, didDiscoverServices: nil)
    }
}
simOnDiscoverCharacteristics = { p, service in
    guard let bulb = bulbs[p.identifier] else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        guard p._state == .connected else { return }
        service._characteristics = bulb.hasControl ? [bulb.rx, bulb.control] : [bulb.rx]
        gb.peripheral(p, didDiscoverCharacteristicsFor: service, error: nil)
    }
}
simOnWrite = { p, data, type in
    guard let bulb = bulbs[p.identifier], p._state == .connected else { return }
    let bytes = [UInt8](data)
    if bytes.count >= 3, bytes[0] == 0x33, bytes[1] == 0x01 { bulb.power = bytes[2] != 0 }
    if bytes.count >= 3, bytes[0] == 0x33, bytes[1] == 0x04 { bulb.brightness = Int(bytes[2]) }
    if type == .withResponse {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { gb.peripheral(p, didWriteValueFor: bulb.control, error: nil) }
    }
    if bulb.echoesOnControl {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            bulb.control._value = data
            gb.peripheral(p, didUpdateValueFor: bulb.control, error: nil)
        }
    }
    if bytes.count >= 2, bytes[0] == 0xAA, bytes[1] == 0x01, p._notifying.contains(bulb.rx.uuid.uuidString) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard p._state == .connected else { return }
            bulb.rx._value = Data(GoveePacket.make([0xAA, 0x01, bulb.power ? 1 : 0]))
            gb.peripheral(p, didUpdateValueFor: bulb.rx, error: nil)
        }
    }
}

/// The phone takes the bulb: our link drops and the bulb stops answering us.
func phoneTakes(_ bulb: Bulb) {
    bulb.phoneHasIt = true
    if bulb.peripheral._state == .connected {
        bulb.peripheral._state = .disconnected
        gb.centralManager(simCentral!, didDisconnectPeripheral: bulb.peripheral, error: NSError(domain: "CBErrorDomain", code: 7))
    }
}
/// The phone lets go (app closed): a pending connect completes.
func phoneLetsGo(_ bulb: Bulb) {
    bulb.phoneHasIt = false
    if bulb.pending, bulb.peripheral._state == .connecting {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { finishConnect(bulb) }
    }
}
func powerOn() {
    simCentral!._state = .poweredOn
    gb.centralManagerDidUpdateState(simCentral!)
}
func startHammer(holding held: [Bulb]) {
    heldSet = Set(held.map { $0.id })
    gb.start()
    gb.hold(heldSet)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { powerOn() }
}
func writes(to bulb: Bulb, since: Date = .distantPast) -> [String] {
    simWrites.filter { $0.id == bulb.id && $0.at >= since }.map { w -> String in
        let b = [UInt8](w.data)
        switch (b[0], b[1]) {
        case (0x33, 0x01): return b[2] == 1 ? "on" : "off"
        case (0x33, 0x04): return "brightness \(b[2])"
        case (0x33, 0x05): return "color"
        case (0xAA, 0x01): return "status"
        default: return "other"
        }
    }
}
func commands(to bulb: Bulb, since: Date = .distantPast) -> [String] {
    writes(to: bulb, since: since).filter { $0 != "status" }
}
func connectCalls(_ bulb: Bulb) -> Int { simConnectCalls[bulb.id] ?? 0 }

// MARK: Scenarios

print("[\(scenario)]")
switch scenario {

case "phone":   // the reported bug: use the Govee phone app, then Hammer
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(3)
    check(gb.isConnected(bulb.id), "connected at start")
    check(gb.isOn(bulb.id) == true, "knows the bulb is on (from its own reply)")
    phoneTakes(bulb)
    run(1)
    check(!gb.isConnected(bulb.id) && gb.isOn(bulb.id) == nil, "phone took it: not connected, no stale checkmark")
    let tap = Date()
    gb.send([0x33, 0x01, 0x00], to: bulb.id)                    // Turn Off in Hammer while the phone has it
    run(8)
    check(gb.cantReach(bulb.id), "menu says can't reach while the phone has it")
    check(commands(to: bulb, since: tap).isEmpty, "nothing sent while unreachable")
    phoneLetsGo(bulb)                                           // force-quit the Govee app, 9 s after the tap
    run(2)
    check(gb.isConnected(bulb.id), "reconnects by itself once the phone lets go")
    check(commands(to: bulb, since: tap) == ["off"], "the Turn Off tapped 9 s ago is delivered: \(commands(to: bulb, since: tap))")
    check(bulb.power == false && gb.isOn(bulb.id) == false, "bulb is off and the menu knows")
    check(!gb.cantReach(bulb.id), "no longer 'can't reach'")
    run(20)
    check(gb.isConnected(bulb.id), "still holding the link 20 s later")
    check(connectCalls(bulb) <= 3, "few connection attempts in total: \(connectCalls(bulb))")
    check(rebuilds < 30, "menu rebuilt a sane number of times: \(rebuilds)")

case "phone-long":   // the phone holds it longer than 15 s: old taps are dropped, new ones work
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(2)
    phoneTakes(bulb)
    run(0.5)
    let tap = Date()
    gb.send([0x33, 0x01, 0x00], to: bulb.id)
    run(20)
    check(gb.cantReach(bulb.id), "can't reach")
    check(connectCalls(bulb) <= 4, "waits on one pending attempt, no hammering: \(connectCalls(bulb))")
    phoneLetsGo(bulb)
    run(2)
    check(gb.isConnected(bulb.id), "reconnects")
    check(commands(to: bulb, since: tap).isEmpty, "a 20 s old tap is not replayed")
    check(bulb.power == true, "bulb unchanged")
    let tap2 = Date()
    gb.send([0x33, 0x04, 40], to: bulb.id)
    run(0.5)
    check(commands(to: bulb, since: tap2) == ["brightness 40"], "a new tap goes straight through")

case "restart-busy":   // Hammer restarts (e.g. an update) while the phone has the bulb
    let bulb = addBulb()
    UserDefaults.standard.set([bulb.id.uuidString: "H6006|H6006 bulb 0FC3"], forKey: "bluetoothBulbs")
    bulb.phoneHasIt = true                                      // not advertising, not connectable
    startHammer(holding: [bulb])
    run(1)
    check(gb.lights.map { $0.name } == ["H6006 bulb 0FC3"], "listed under its saved name before it's seen")
    check(simRetrieveCalls >= 1 && connectCalls(bulb) == 1, "asked macOS for it by ID and is waiting to connect")
    run(7)
    check(gb.cantReach(bulb.id), "can't reach after 6 s")
    phoneLetsGo(bulb)
    run(1)
    check(gb.isConnected(bulb.id), "connects when free")

case "first-run":   // first run after this update: no saved name, macOS has no cached name, phone has it
    let bulb = addBulb(name: nil)
    bulb.phoneHasIt = true
    startHammer(holding: [bulb])
    run(1)
    check(gb.lights.count == 1, "your bulb is listed anyway")
    check(gb.lights.first?.name.hasPrefix("Bluetooth bulb ") == true, "with a placeholder name: \(gb.lights.first?.name ?? "-")")
    bulb.peripheral._name = "ihoment_H6006_0FC3"                // macOS learns the name on connecting
    phoneLetsGo(bulb)
    run(1)
    check(gb.isConnected(bulb.id), "connects")
    check(gb.lights.first?.name == "H6006 bulb 0FC3" && gb.lights.first?.sku == "H6006", "real name and model once known")
    let saved = UserDefaults.standard.dictionary(forKey: "bluetoothBulbs") as? [String: String]
    check(saved?[bulb.id.uuidString] == "H6006|H6006 bulb 0FC3", "and remembered for next time")

case "storm":   // every connection attempt fails at once (scenario A)
    let bulb = addBulb()
    bulb.connectFails = true
    startHammer(holding: [bulb])
    run(60)
    check(connectCalls(bulb) <= 8, "at most 8 attempts in a minute: \(connectCalls(bulb))")
    check(rebuilds <= 30, "menu rebuilds stay low: \(rebuilds)")
    check(gb.cantReach(bulb.id), "menu says can't reach")
    bulb.connectFails = false
    let tap = Date()
    gb.send([0x33, 0x01, 0x01], to: bulb.id)                     // a tap tries again within 2 s
    run(3)
    check(gb.isConnected(bulb.id) && commands(to: bulb, since: tap) == ["on"], "a tap brings it back quickly")

case "short-links":   // the link keeps dropping 1 s after connecting
    let bulb = addBulb()
    bulb.dropAfter = 1
    startHammer(holding: [bulb])
    run(60)
    check(bulb.connects <= 8, "reconnects back off: \(bulb.connects) links in a minute")

case "discovery-once":   // one failed service discovery (C2)
    let bulb = addBulb()
    bulb.discoveryErrors = 1
    startHammer(holding: [bulb])
    run(3)
    check(gb.isConnected(bulb.id), "recovers on the same link")
    check(!gb.isIncompatible(bulb.id), "not marked incompatible")
    check(connectCalls(bulb) == 1, "without reconnecting: \(connectCalls(bulb))")

case "discovery-always":   // discovery fails every time (C)
    let bulb = addBulb()
    bulb.discoveryErrors = 1_000
    startHammer(holding: [bulb])
    run(60)
    check(!gb.isIncompatible(bulb.id), "errors aren't taken as 'incompatible'")
    check(connectCalls(bulb) <= 6, "links retried slowly: \(connectCalls(bulb))")
    check(bulb.peripheral._discoverServicesCalls <= 3 * connectCalls(bulb), "at most 3 discoveries per link")
    bulb.discoveryErrors = 0
    run(70)
    check(gb.isConnected(bulb.id), "works once the bulb behaves")

case "discovery-hangs":   // the bulb connects but never answers discovery
    let bulb = addBulb()
    bulb.discoveryHangs = true
    startHammer(holding: [bulb])
    run(12)
    check(bulb.peripheral._state == .disconnected || bulb.connects >= 2, "gives up on the stuck link after 10 s")
    run(48)
    check(connectCalls(bulb) <= 5, "and retries slowly: \(connectCalls(bulb))")

case "incompatible":   // connects, but no Govee control channel (e.g. new firmware)
    let bulb = addBulb()
    bulb.hasControl = false
    startHammer(holding: [bulb])
    run(2)
    check(gb.isIncompatible(bulb.id), "marked incompatible")
    check(bulb.peripheral._state == .disconnected, "and let go, so the phone can use it")
    run(60)
    check(connectCalls(bulb) == 1, "not retried for 5 minutes: \(connectCalls(bulb))")
    check(gb.isIncompatible(bulb.id), "still says why")
    gb.send([0x33, 0x01, 0x01], to: bulb.id)
    run(3)
    check(connectCalls(bulb) == 2 && gb.isIncompatible(bulb.id), "a tap re-checks it once")

case "no-service":   // connects, and the Govee service is missing entirely
    let bulb = addBulb()
    bulb.hasService = false
    startHammer(holding: [bulb])
    run(30)
    check(gb.isIncompatible(bulb.id) && connectCalls(bulb) == 1 && bulb.peripheral._state == .disconnected,
          "incompatible, let go, not retried")

case "busy-link":   // macOS keeps saying "not ready to write" and never says it's ready
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(2)
    bulb.peripheral._canSend = false
    let tap = Date()
    gb.send([0x33, 0x01, 0x00], to: bulb.id)
    run(3)
    check(commands(to: bulb, since: tap) == ["off"], "the tap still goes out within a few seconds: \(commands(to: bulb, since: tap))")
    bulb.peripheral._canSend = true
    let tap2 = Date()
    gb.send([0x33, 0x01, 0x01], to: bulb.id)
    run(0.3)
    check(commands(to: bulb, since: tap2) == ["on"], "and immediately once it's ready")

case "slider":   // dragging the brightness slider: 40 changes in 2 s
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(2)
    let start = Date()
    for step in 1...40 {
        bulb.peripheral._canSend = step % 3 != 0               // the link is busy now and then
        gb.send([0x33, 0x04, UInt8(step * 2)], to: bulb.id)
        run(0.05)
    }
    bulb.peripheral._canSend = true
    run(1.5)
    let sent = commands(to: bulb, since: start)
    check(sent.last == "brightness 80" && bulb.brightness == 80, "ends on the final value")
    check(sent.count <= 40, "never more writes than changes: \(sent.count)")

case "reset":   // Bluetooth resets (e.g. waking from sleep)
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(2)
    let retrievesBefore = simRetrieveCalls
    simCentral!._state = .resetting
    bulb.peripheral._state = .disconnected
    gb.centralManagerDidUpdateState(simCentral!)
    check(gb.isOn(bulb.id) == nil && !gb.isConnected(bulb.id), "forgets the link and its on/off")
    gb.send([0x33, 0x01, 0x00], to: bulb.id)                     // a tap while it's resetting is ignored safely
    run(0.5)
    powerOn()
    run(2)
    check(simRetrieveCalls > retrievesBefore, "asks macOS for the bulb again")
    check(gb.isConnected(bulb.id), "reconnected after the reset")

case "bluetooth-off":   // Bluetooth turned off, then on
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(2)
    simCentral!._state = .poweredOff
    bulb.peripheral._state = .disconnected
    gb.centralManagerDidUpdateState(simCentral!)
    gb.send([0x33, 0x01, 0x00], to: bulb.id)
    run(15)
    check(!gb.cantReach(bulb.id), "doesn't claim 'can't reach' while Bluetooth is off (the menu says turn it on)")
    powerOn()
    run(2)
    check(gb.isConnected(bulb.id), "reconnects when Bluetooth is back")
    check(commands(to: bulb).isEmpty, "a tap made while Bluetooth was off isn't replayed")

case "remove":   // you remove a bulb from My Lights while Hammer is retrying it
    let bulb = addBulb()
    bulb.connectFails = true
    startHammer(holding: [bulb])
    run(4)                                                       // a retry is now pending
    heldSet = []
    gb.hold([])
    bulb.connectFails = false
    run(60)
    check(bulb.peripheral._state == .disconnected, "not connected to a bulb that isn't yours")
    check(bulb.connects == 0, "never grabbed it after removal")

case "remove-connected":   // removing a connected bulb lets go of it
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(2)
    heldSet = []
    gb.hold([])
    run(12)
    check(bulb.peripheral._state == .disconnected, "released within ~10 s")
    run(30)
    check(connectCalls(bulb) == 1, "and left alone: \(connectCalls(bulb))")

case "neighbor":   // a neighbor's bulb is nearby and advertising
    let mine = addBulb()
    let theirs = addBulb(name: "ihoment_H6006_ABCD")
    startHammer(holding: [mine])
    run(1)
    gb.centralManager(simCentral!, didDiscover: theirs.peripheral,
                      advertisementData: [CBAdvertisementDataLocalNameKey: "ihoment_H6006_ABCD"], rssi: -80)
    run(30)
    check(connectCalls(theirs) == 0, "never connects to it on its own")
    check(gb.lights.count == 2, "but lists it (for Other Lights)")

case "blink":   // Blink to Identify on a neighbor's bulb, then let go
    let theirs = addBulb(name: "ihoment_H6006_ABCD")
    startHammer(holding: [])
    run(1)
    for on: UInt8 in [1, 0, 1, 0, 1] {
        gb.send([0x33, 0x01, on], to: theirs.id)
        run(0.7)
    }
    check(commands(to: theirs) == ["on", "off", "on", "off", "on"], "all blinks delivered: \(commands(to: theirs))")
    run(12)
    check(theirs.peripheral._state == .disconnected, "let go 10 s later")
    run(30)
    check(connectCalls(theirs) == 1, "and not reconnected: \(connectCalls(theirs))")

case "echo":   // the bulb echoes writes on its control channel
    let bulb = addBulb()
    bulb.echoesOnControl = true
    startHammer(holding: [bulb])
    run(5)
    check(gb.isOn(bulb.id) == true, "an echoed 'are you on?' isn't read as 'off'")
    check(!bulb.peripheral._notifying.contains(GoveeBluetooth.controlUUID.uuidString), "doesn't subscribe to the control channel")

case "steady":   // a healthy link for 30 s
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(30)
    let status = writes(to: bulb).filter { $0 == "status" }.count
    check(status >= 12 && status <= 18, "asks 'are you on?' about every 2 s: \(status) in 30 s")
    check(rebuilds <= 8, "menu not rebuilt by the keep-alive: \(rebuilds)")
    check(connectCalls(bulb) == 1, "one connection")

case "two-bulbs":   // both of your bulbs, one held by the phone
    let a = addBulb(), b = addBulb(name: "ihoment_H6006_1A2B")
    b.phoneHasIt = true
    startHammer(holding: [a, b])
    run(8)
    check(gb.isConnected(a.id) && gb.cantReach(b.id), "one connected, the other can't be reached")
    let tap = Date()
    gb.send([0x33, 0x01, 0x00], to: a.id)
    gb.send([0x33, 0x01, 0x00], to: b.id)
    run(0.5)
    check(commands(to: a, since: tap) == ["off"], "the free bulb isn't held up by the busy one")
    phoneLetsGo(b)
    run(1)
    check(commands(to: b, since: tap) == ["off"], "the busy one catches up when free")

default:
    print("unknown scenario"); exit(2)
}
check(simMisuse.isEmpty, "no CoreBluetooth misuse: \(simMisuse.prefix(3))")
print(failures == 0 ? "  passed" : "  \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
