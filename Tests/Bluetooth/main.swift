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
    var silent = false              // takes commands but never answers
    var deadLink = false            // macOS still says connected, but writes go nowhere
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
var results: [(id: UUID, ok: Bool)] = []          // what onCommandResult reported
gb.onCommandResult = { id, ok in results.append((id, ok)) }
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
    guard let bulb = bulbs[p.identifier], p._state == .connected, !bulb.deadLink else { return }
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
    if !bulb.silent, bytes.count >= 2, bytes[0] == 0xAA, bytes[1] == 0x01, p._notifying.contains(bulb.rx.uuid.uuidString) {
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
    gb.send([0x33, 0x01, 0x00], to: bulb.id)                     // a tap while it's resetting waits for it
    run(0.5)
    powerOn()
    run(2)
    check(simRetrieveCalls > retrievesBefore, "asks macOS for the bulb again")
    check(gb.isConnected(bulb.id), "reconnected after the reset")
    check(bulb.power == false, "and the tap made during the reset is delivered")

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
    check(commands(to: bulb).isEmpty, "a tap made 15 s before Bluetooth came back isn't replayed")
    check(results.contains { $0.id == bulb.id && !$0.ok }, "and Hammer says it didn't go out")

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

case "silent":   // takes commands but never answers (replies are optional)
    let bulb = addBulb()
    bulb.silent = true
    startHammer(holding: [bulb])
    run(40)
    check(gb.isConnected(bulb.id) && !gb.isAnswering(bulb.id), "keeps the link; menu just doesn't say 'responding'")
    let tap = Date()
    gb.send([0x33, 0x01, 0x00], to: bulb.id)
    run(0.5)
    check(commands(to: bulb, since: tap) == ["off"] && bulb.power == false, "commands still work")
    check(connectCalls(bulb) == 1, "never dropped for being quiet: \(connectCalls(bulb)) connects")

case "first-drop":   // setup stalls once, then works: the first failure is retried at once
    let bulb = addBulb()
    bulb.discoveryHangs = true
    startHammer(holding: [bulb])
    run(9.8)
    bulb.discoveryHangs = false                                  // behaves from the next link on
    check(connectCalls(bulb) == 1, "still waiting on the first link")
    run(1.0)                                                     // the 10 s setup limit passes
    check(connectCalls(bulb) == 2 && gb.isConnected(bulb.id), "dropped the stuck link and retried at once: \(connectCalls(bulb)) connects")

case "dying-link":   // a tap lands on a link that has died but macOS hasn't noticed yet
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(3)
    bulb.deadLink = true
    gb.send([0x33, 0x01, 0x00], to: bulb.id)
    run(1)
    bulb.peripheral._state = .disconnected
    gb.centralManager(simCentral!, didDisconnectPeripheral: bulb.peripheral, error: NSError(domain: "CBErrorDomain", code: 6))
    bulb.deadLink = false
    run(3)
    check(gb.isConnected(bulb.id), "reconnected")
    check(bulb.power == false, "the Turn Off is sent again after reconnecting")

case "delivered-then-drop":   // a tap that did arrive isn't repeated when the phone takes the bulb later
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(3)
    gb.send([0x33, 0x01, 0x00], to: bulb.id)                     // arrives; the bulb answers "off"
    run(1)
    phoneTakes(bulb)
    bulb.power = true                                            // you turn it back on with the phone
    run(1)
    phoneLetsGo(bulb)
    run(2)
    check(gb.isConnected(bulb.id), "reconnected")
    check(bulb.power == true, "Hammer doesn't undo what you did on the phone")

case "blink-thrice":   // Blink to Identify the same neighbor's bulb three times
    let bulb = addBulb()
    startHammer(holding: [])
    run(0.5)
    for round in 1...3 {
        let tap = Date()
        gb.send([0x33, 0x01, 0x01], to: bulb.id)
        run(0.6)
        check(commands(to: bulb, since: tap) == ["on"], "round \(round) goes out at once")
        run(11)                                                  // released after 10 s each time
    }

// From the lights review: commands that used to be lost, and the menu's hints.

case "launch-send":   // Hammer just started: the sleep timer or Turn On At sends before Bluetooth is on
    let bulb = addBulb()
    UserDefaults.standard.set([bulb.id.uuidString: "H6006|H6006 bulb 0FC3"], forKey: "bluetoothBulbs")
    heldSet = [bulb.id]
    gb.start()
    gb.hold(heldSet)
    gb.send([0x33, 0x01, 0x01], to: bulb.id, keepFor: 300)       // Bluetooth's state is still unknown
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { powerOn() }
    run(4)
    check(gb.isConnected(bulb.id), "connected once Bluetooth is on")
    check(commands(to: bulb) == ["on"], "the command sent before that is delivered: \(commands(to: bulb))")
    check(results.contains { $0.id == bulb.id && $0.ok }, "and reported as sent")

case "reset-keeps":   // Bluetooth resets (common on wake) while a command waits for the phone to let go
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(2)
    phoneTakes(bulb)
    run(0.3)
    gb.send([0x33, 0x01, 0x01], to: bulb.id, keepFor: 300)
    run(0.5)
    simCentral!._state = .resetting
    bulb.peripheral._state = .disconnected
    gb.centralManagerDidUpdateState(simCentral!)
    bulb.phoneHasIt = false
    run(0.5)
    powerOn()
    run(3)
    check(gb.isConnected(bulb.id), "reconnected")
    check(commands(to: bulb).contains("on"), "the waiting command survives the reset: \(commands(to: bulb))")

case "alarm-phone":   // Turn On At fires while the phone has the bulb; the phone lets go 20 s later
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(2)
    phoneTakes(bulb)
    run(0.5)
    let tap = Date()
    gb.send([0x33, 0x01, 0x01], to: bulb.id, keepFor: 300)       // scheduled: waits up to 5 minutes
    gb.send([0x33, 0x04, 50], to: bulb.id)                       // a tap: 15 s
    run(20)
    check(results.filter { !$0.ok }.count == 1, "only the tap is given up; the scheduled command still waits")
    phoneLetsGo(bulb)
    run(2)
    check(commands(to: bulb, since: tap) == ["on"], "the scheduled on still lands after 20 s, the old tap doesn't: \(commands(to: bulb, since: tap))")

case "gave-up":   // a command that never goes out is reported, so the menu can say so
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(2)
    gb.send([0x33, 0x01, 0x00], to: bulb.id)
    run(0.5)
    check(results.last.map { $0.id == bulb.id && $0.ok } == true, "a delivered command is reported as sent")
    phoneTakes(bulb)
    run(0.5)
    results.removeAll()
    gb.send([0x33, 0x01, 0x01], to: bulb.id, keepFor: 3)
    run(2)
    check(results.isEmpty, "nothing reported while it's still waiting")
    run(3)
    check(results.count == 1 && results[0].id == bulb.id && !results[0].ok, "given up after its time, once: \(results.map { $0.ok })")
    let neighbor = addBulb(name: "ihoment_H6006_ABCD")
    neighbor.connectFails = true
    results.removeAll()
    gb.send([0x33, 0x01, 0x01], to: neighbor.id)
    run(1)
    check(results.contains { $0.id == neighbor.id && !$0.ok }, "a neighbor's bulb that won't connect is reported at once")

case "limit":   // macOS refuses another link (too many devices); the bulb is otherwise free
    var list: [Bulb] = []
    for i in 0..<5 { list.append(addBulb(name: "ihoment_H6006_00\(i)\(i)")) }
    list[4].connectFails = true
    let busy = addBulb(name: "ihoment_H6006_BEEF")
    busy.phoneHasIt = true
    startHammer(holding: list + [busy])
    run(10)
    check(gb.cantReach(list[4].id) && gb.connectError(list[4].id) != nil, "can't reach, and the menu knows the connection failed")
    check(gb.cantReach(busy.id) && gb.connectError(busy.id) == nil, "a bulb the phone holds just never answers (the phone hint)")

case "blink-restores":   // Blink to Identify a neighbor's bulb that was off: it ends off
    let theirs = addBulb(name: "ihoment_H6006_ABCD")
    theirs.power = false
    startHammer(holding: [])
    run(1)
    gb.send([0xAA, 0x01], to: theirs.id)                         // what Govee.readPower does first
    var waited = 0.0
    while gb.isOn(theirs.id) == nil && waited < 4 { run(0.1); waited += 0.1 }
    check(gb.isOn(theirs.id) == false, "learns it's off before blinking")
    for on in Blink.steps(wasOn: gb.isOn(theirs.id), mine: false) {
        gb.send([0x33, 0x01, on ? 1 : 0], to: theirs.id)
        run(0.7)
    }
    check(commands(to: theirs) == ["on", "off", "on", "off"], "two flashes: \(commands(to: theirs))")
    run(12)
    check(theirs.power == false && theirs.peripheral._state == .disconnected, "left off, and let go")

case "rescan-twice":   // opening the menu again 10 s into a scan runs a full 15 s from then
    let bulb = addBulb()
    startHammer(holding: [bulb])
    run(10)                                                      // Bluetooth came on at 0.1 s: scanning
    gb.rescan()                                                  // the menu opens again
    run(6)                                                       // 16 s: the first scan's stop is due
    check(simScanning, "still scanning 6 s after the second open")
    run(10)
    check(!simScanning, "stops 15 s after it")

case "forget":   // neighbors' bulbs not seen for 30 days are forgotten; yours never
    let mine = addBulb(), theirs = addBulb(name: "ihoment_H6006_ABCD")
    let old = Date().addingTimeInterval(-40 * 86_400)
    UserDefaults.standard.set([mine.id.uuidString: "H6006|H6006 bulb 0FC3", theirs.id.uuidString: "H6006|H6006 bulb ABCD",
                               "11111111-2222-3333-4444-555555555555": "H6006|H6006 bulb 1111"], forKey: "bluetoothBulbs")
    UserDefaults.standard.set([mine.id.uuidString: old, theirs.id.uuidString: old], forKey: "bluetoothBulbsSeen")
    mine.phoneHasIt = true
    startHammer(holding: [mine])
    run(1)
    let saved = UserDefaults.standard.dictionary(forKey: "bluetoothBulbs") as? [String: String] ?? [:]
    let seen = UserDefaults.standard.dictionary(forKey: "bluetoothBulbsSeen") as? [String: Date] ?? [:]
    check(saved[theirs.id.uuidString] == nil, "the neighbor's bulb is forgotten")
    check(saved[mine.id.uuidString] != nil && gb.lights.first?.name == "H6006 bulb 0FC3", "yours keeps its name")
    check(saved["11111111-2222-3333-4444-555555555555"] != nil && seen["11111111-2222-3333-4444-555555555555"] != nil,
          "one with no date yet starts counting")

default:
    print("unknown scenario"); exit(2)
}
check(simMisuse.isEmpty, "no CoreBluetooth misuse: \(simMisuse.prefix(3))")
print(failures == 0 ? "  passed" : "  \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
