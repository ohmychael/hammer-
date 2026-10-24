// Hammer — a tiny menu bar app for your desk:
//   • sets the external monitor's real brightness and contrast over DDC/CI
//     (the same way MonitorControl does), and
//   • turns Govee lights on and off, dims them and changes their color.
//
// Apple Silicon Macs only (Intel Macs use a different I²C API for the monitor).
//
// Install (builds it and keeps it updated from GitHub):
//   curl -fsSL https://raw.githubusercontent.com/ohmychael/hammer-/main/install-hammer.sh | bash
//
// Build by hand:  bash build.sh  (runs the tests, compiles for the macOS this Mac runs, with
//                 -swift-version 5 and -target, and installs ~/Applications/Hammer.app)
// Tests:          swiftc HammerCore.swift Monitor.swift Player.swift Deliveries.swift Tests/main.swift -o hammer-tests && ./hammer-tests
// Run:    ./Hammer                        menu bar app (hammer icon)
//         If the icon is hidden behind the notch, open Hammer from Apps or
//         Spotlight, or press Control-Option-H: the menu appears at the pointer.
//
// Monitor from Terminal:
//         ./Hammer get brightness         read a value from the monitor
//         ./Hammer set brightness 40      write a value
//         ./Hammer monitor check          if it doesn't work: tests each step and says why
//         Names: brightness, contrast, volume — or a hex VCP code like 10.
//         Stick to codes you know: some (e.g. 04) reset the monitor to factory settings.
//
// Govee from Terminal:
//         ./Hammer govee list             find your lights
//         ./Hammer govee on | off         all lights
//         ./Hammer govee brightness 40    all lights, 1–100
//         ./Hammer govee key <API key>    save a Govee cloud API key (optional)
//
// Govee lights are reached one of three ways:
//   • Bluetooth — for nearby bulbs without LAN Control (H6004/H6006/H6008/H6009
//     family). Found automatically by the menu bar app; not by Terminal commands.
//   • Local network — fast, no account. Turn on "LAN Control" for each light
//     in the Govee Home app (device page → settings). Not every model has it.
//   • Govee cloud — works for other Wi-Fi models, a little slower. Request a
//     free API key in the Govee Home app ("Apply for API Key" in settings),
//     then save it with `./Hammer govee key ...`.

import AppKit
import Carbon.HIToolbox     // global keyboard shortcut
import CoreBluetooth
import IOKit

// MARK: - Govee lights

struct GoveeLight {
    let id: String          // Govee device ID (looks like a MAC address)
    let sku: String         // model number, e.g. H6159
    var name: String
    var lanIP: String?      // set when the light answered on the local network
    var bluetoothID: UUID? = nil   // set when the light was found over Bluetooth

    /// Route order: local network, then Bluetooth, then the Govee cloud.
    var routeLabel: String { lanIP != nil ? "" : bluetoothID != nil ? "Bluetooth" : "cloud" }
}

/// A color for a light: a mix of its color LEDs, or white from its white LEDs.
enum LightLook {
    case color(Int, Int, Int)
    case white(Int)                 // color temperature in kelvin

    func apply(to light: GoveeLight) {
        switch self {
        case .color(let r, let g, let b): Govee.setColor(light, red: r, green: g, blue: b)
        case .white(let kelvin): Govee.setWhite(light, kelvin: kelvin)
        }
    }
}

/// Lets a network callback hand a result back to the code waiting for it.
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

enum Govee {
    // Local network ("LAN API"): small JSON messages over UDP.
    static let scanGroup = "239.255.255.250"   // discovery request goes to this multicast group…
    static let scanPort: UInt16 = 4001         // …on this port
    static let replyPort: UInt16 = 4002        // lights answer the scan on this port
    static let commandPort: UInt16 = 4003      // commands go to each light's IP on this port

    // Cloud API.
    static let cloudBase = "https://openapi.api.govee.com/router/api/v1/"

    // MARK: API key

    static var keyFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/hammer/govee-api-key")
    }

    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["GOVEE_API_KEY"], !env.isEmpty { return env }
        let saved = (try? String(contentsOf: keyFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return saved?.isEmpty == false ? saved : nil
    }

    static func saveAPIKey(_ key: String) throws {
        try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try key.write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }

    // MARK: Finding lights (blocks for a couple of seconds — call off the main thread)

    static func discover() -> [GoveeLight] {
        // Ask the cloud in the background while we scan the local network.
        let cloud = Box<[GoveeLight]>([])
        let cloudDone = DispatchSemaphore(value: 0)
        if let key = apiKey {
            fetchCloudLights(apiKey: key, into: cloud, done: cloudDone)
        } else {
            cloudDone.signal()
        }

        let local = scanLocalNetwork()
        _ = cloudDone.wait(timeout: .now() + 10)

        // Merge: prefer the fast local route, but keep the name from the Govee app.
        var byID: [String: GoveeLight] = [:]
        for light in local { byID[light.id.uppercased()] = light }
        for light in cloud.value {
            let id = light.id.uppercased()
            if var known = byID[id] {
                known.name = light.name
                byID[id] = known
            } else {
                byID[id] = light
            }
        }
        return byID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func scanLocalNetwork(seconds: TimeInterval = 2) -> [GoveeLight] {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return [] }
        defer { close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Listen on the reply port.
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = replyPort.bigEndian
        local.sin_addr.s_addr = 0                    // any interface
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return [] }          // port busy, e.g. another Govee tool is running

        // Also listen on the multicast group, in case replies are sent there.
        var group = ip_mreq()
        inet_pton(AF_INET, scanGroup, &group.imr_multiaddr)
        setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, &group, socklen_t(MemoryLayout<ip_mreq>.size))

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let scan = message("scan", ["account_topic": "reserve"])
        for _ in 0..<2 { sendPacket(scan, from: sock, to: scanGroup, port: scanPort) }   // UDP can drop packets

        var found: [String: GoveeLight] = [:]
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let count = recv(sock, &buffer, buffer.count, 0)
            guard count > 0,
                  let json = try? JSONSerialization.jsonObject(with: Data(buffer[0..<count])) as? [String: Any],
                  let msg = json["msg"] as? [String: Any], msg["cmd"] as? String == "scan",
                  let data = msg["data"] as? [String: Any],
                  let ip = data["ip"] as? String, let id = data["device"] as? String
            else { continue }                        // timeouts, our own echoed request, junk
            let sku = data["sku"] as? String ?? "Govee"
            found[id] = GoveeLight(id: id, sku: sku, name: "\(sku) (\(ip))", lanIP: ip)
        }
        return Array(found.values)
    }

    static func fetchCloudLights(apiKey: String, into result: Box<[GoveeLight]>, done: DispatchSemaphore) {
        var request = URLRequest(url: URL(string: cloudBase + "user/devices")!)
        request.setValue(apiKey, forHTTPHeaderField: "Govee-API-Key")
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devices = json["data"] as? [[String: Any]] else { return }
            result.value = devices.compactMap { (device) -> GoveeLight? in
                guard let id = device["device"] as? String, let sku = device["sku"] as? String,
                      let capabilities = device["capabilities"] as? [[String: Any]],
                      capabilities.contains(where: { $0["instance"] as? String == "brightness" })
                else { return nil }                  // skip plugs, heaters and other non-lights
                return GoveeLight(id: id, sku: sku, name: device["deviceName"] as? String ?? sku, lanIP: nil)
            }
        }.resume()
    }

    // MARK: Commands

    static func setPower(_ light: GoveeLight, on: Bool) {
        if light.lanIP != nil {
            sendLocal(light, "turn", ["value": on ? 1 : 0])
        } else if let ble = light.bluetoothID {
            sendBluetooth(ble, [0x33, 0x01, on ? 0x01 : 0x00])
        } else {
            sendCloud(light, type: "devices.capabilities.on_off", instance: "powerSwitch", value: on ? 1 : 0)
        }
    }

    static func setBrightness(_ light: GoveeLight, _ percent: Int) {
        let value = min(max(percent, 1), 100)
        if light.lanIP != nil {
            sendLocal(light, "brightness", ["value": value])
        } else if let ble = light.bluetoothID {
            sendBluetooth(ble, [0x33, 0x04, UInt8(value)])          // these bulbs take 1–100 directly
        } else {
            sendCloud(light, type: "devices.capabilities.range", instance: "brightness", value: value)
        }
    }

    static func setColor(_ light: GoveeLight, red: Int, green: Int, blue: Int) {
        if light.lanIP != nil {
            sendLocal(light, "colorwc", ["color": ["r": red, "g": green, "b": blue], "colorTemInKelvin": 0])
        } else if let ble = light.bluetoothID {
            sendBluetooth(ble, [0x33, 0x05, 0x0D, UInt8(red), UInt8(green), UInt8(blue)])
        } else {
            sendCloud(light, type: "devices.capabilities.color_setting", instance: "colorRgb",
                      value: red << 16 | green << 8 | blue)
        }
    }

    /// White light at a color temperature, 2000–9000 K.
    static func setWhite(_ light: GoveeLight, kelvin: Int) {
        if light.lanIP != nil {
            sendLocal(light, "colorwc", ["color": ["r": 0, "g": 0, "b": 0], "colorTemInKelvin": kelvin])
        } else if let ble = light.bluetoothID {
            // Bluetooth bulbs only accept exact table values; these two are the published ones.
            let warm: [UInt8] = [0x33, 0x05, 0x0D, 0xFF, 0xFF, 0xFF, 0x0A, 0x8C, 0xFF, 0xAE, 0x54]   // 2700 K
            let cool: [UInt8] = [0x33, 0x05, 0x0D, 0xFF, 0xFF, 0xFF, 0x19, 0x64, 0xFF, 0xF9, 0xFB]   // 6500 K
            sendBluetooth(ble, kelvin < 4600 ? warm : cool)
        } else {
            sendCloud(light, type: "devices.capabilities.color_setting", instance: "colorTemperatureK", value: kelvin)
        }
    }

    /// Bluetooth runs on the main thread, so hop there.
    static func sendBluetooth(_ id: UUID, _ payload: [UInt8]) {
        DispatchQueue.main.async { GoveeBluetooth.shared.send(payload, to: id) }
    }

    // MARK: Transport

    static func message(_ cmd: String, _ data: [String: Any]) -> Data {
        let inner: [String: Any] = ["cmd": cmd, "data": data]
        let body: [String: Any] = ["msg": inner]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func sendPacket(_ payload: Data, from sock: Int32, to ip: String, port: UInt16) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &address.sin_addr)
        payload.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddress in
                    _ = sendto(sock, bytes.baseAddress, bytes.count, 0, sockAddress,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    static func sendLocal(_ light: GoveeLight, _ cmd: String, _ data: [String: Any]) {
        guard let ip = light.lanIP else { return }
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        defer { close(sock) }
        sendPacket(message(cmd, data), from: sock, to: ip, port: commandPort)
    }

    /// Waits for Govee's reply, so commands go out one at a time and stay
    /// under the cloud's limit of about 2 commands a second per light.
    static func sendCloud(_ light: GoveeLight, type: String, instance: String, value: Int) {
        guard let key = apiKey else { return }
        var request = URLRequest(url: URL(string: cloudBase + "device/control")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Govee-API-Key")
        let capability: [String: Any] = ["type": type, "instance": instance, "value": value]
        let payload: [String: Any] = ["sku": light.sku, "device": light.id, "capability": capability]
        let body: [String: Any] = ["requestId": UUID().uuidString, "payload": payload]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }
}

// MARK: - Govee over Bluetooth
//
// For bulbs without LAN Control, e.g. older H6006s. Uses the command set the
// Goveon project traced for Govee's "type-64" bulbs (H6004/H6006/H6008/H6009…):
// 20-byte packets starting 0x33 (0xAA for status reads), a command byte, the
// payload, zero padding, and an XOR checksum in the last byte.
//
// A bulb talks to one device at a time over Bluetooth. The Govee app on a phone
// keeps trying to reconnect in the background, so if Hammer ever lets go of
// your bulbs the phone takes them and Hammer is locked out. So for your lights
// Hammer keeps a standing connection, reconnects by itself whenever it drops,
// and finds them again after a restart even while they're busy. (Your phone's
// Govee app still works, over Wi-Fi.) Bulbs that aren't yours are only ever
// connected briefly, e.g. for Blink to Identify.
//
// Everything here runs on the main thread (CoreBluetooth calls back on .main).

final class GoveeBluetooth: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = GoveeBluetooth()

    static let serviceUUID = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d1910")
    static let controlUUID = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d2b11")
    static let supportedModels: Set<String> = ["H6004", "H6006", "H6008", "H6009", "H600A", "H600D", "H6010"]

    /// Commands still waiting this long for a connection are dropped, so a tap from
    /// minutes ago doesn't suddenly happen when the bulb frees up.
    private static let freshFor: TimeInterval = 15
    /// How long a connection attempt runs before the menu says the bulb can't be reached.
    private static let patience: TimeInterval = 6
    /// How often your connected bulbs are asked "are you on?". Govee's own app does
    /// this every 2 seconds; it keeps the link alive and the checkmarks current.
    private static let keepAliveEvery: TimeInterval = 2
    /// A link that drops sooner than this after becoming ready counts as a failure.
    private static let shortLink: TimeInterval = 10
    /// Connected but still not ready for commands after this long: start over.
    private static let setupTimeout: TimeInterval = 10
    /// A bulb that connects without Govee's control channel is checked again this often.
    private static let incompatiblePause: TimeInterval = 300
    /// macOS can take a few seconds to notice a link has died. Commands written that
    /// recently, with no answer from the bulb since, are sent again after reconnecting.
    private static let lostWindow: TimeInterval = 6

    /// Called on the main thread whenever the bulbs, their connections or their state change.
    var onChange: (() -> Void)?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var found: [UUID: (model: String, name: String)] = [:]
    private var placeholders: Set<UUID> = []                 // listed, but its real name isn't known yet
    private var signalStrength: [UUID: Int] = [:]            // latest signal strength, in dBm
    private var controls: [UUID: CBCharacteristic] = [:]
    private var outbox: [UUID: CommandQueue] = [:]           // see CommandQueue in HammerCore.swift
    private var writeInFlight: [UUID: Date] = [:]
    private var waitingToWrite: [UUID: Date] = [:]           // since when the link has said "not yet"
    private var pumpScheduled: Set<UUID> = []
    private var connectingSince: [UUID: Date] = [:]
    private var connectedAt: [UUID: Date] = [:]
    private var readyAt: [UUID: Date] = [:]                  // when the link could take commands
    private var recentlyWritten: [UUID: [(item: CommandQueue.Item, at: Date)]] = [:]
    private var backoff = ConnectBackoff()                  // see HammerCore.swift
    private var retryAt: [UUID: Date] = [:]
    private var patienceCheck: Set<UUID> = []
    private var setupRetries: [UUID: Int] = [:]
    private var releaseTimers: [UUID: DispatchWorkItem] = [:]
    private var held: Set<UUID> = []                         // your bulbs: always kept connected
    private var incompatible: Set<UUID> = []                 // connected, but no Govee control channel
    private var powerState: [UUID: Bool] = [:]               // from the bulb's own replies
    private var lastHeard: [UUID: Date] = [:]
    private var seenThisRun: Set<UUID> = []                  // advertised since Hammer started
    private var keepAlive: Timer?
    private var ticks = 0

    /// macOS requires a Bluetooth usage message in the app's Info.plist, which the
    /// installer adds. Without it (e.g. the bare Terminal binary) Bluetooth stays off.
    var isAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    var lights: [GoveeLight] {
        found.map { id, info in
            GoveeLight(id: id.uuidString, sku: info.model, name: info.name, lanIP: nil, bluetoothID: id)
        }.sorted { $0.name < $1.name }
    }

    /// A short note for the menu when Bluetooth can't be used, or nil when it's fine.
    var problem: String? {
        guard let central else { return nil }
        switch central.state {
        case .poweredOff: return "Turn on Bluetooth to reach Bluetooth bulbs."
        case .unauthorized: return "Allow Hammer in Settings → Privacy & Security → Bluetooth."
        case .unsupported: return "This Mac's Bluetooth isn't available."
        default: return nil
        }
    }

    // MARK: Status for the menu

    /// Roughly how far away a bulb is, from its signal strength.
    func distance(of id: UUID) -> String? {
        signalStrength[id].map { GoveeName.distance(dBm: $0) }
    }

    func isConnected(_ id: UUID) -> Bool {
        peripherals[id]?.state == .connected && controls[id] != nil
    }

    /// True when Hammer has been trying to reach one of your bulbs for a while without success.
    func cantReach(_ id: UUID) -> Bool {
        guard central?.state == .poweredOn else { return false }
        guard let peripheral = peripherals[id] else { return held.contains(id) }
        if peripheral.state == .connected { return false }
        guard let since = connectingSince[id] else { return held.contains(id) }
        return Date().timeIntervalSince(since) > Self.patience
    }

    /// The bulb connected but doesn't offer the control channel Hammer uses.
    func isIncompatible(_ id: UUID) -> Bool { incompatible.contains(id) }

    /// On or off, as the bulb itself reported over the current link; nil if it hasn't said.
    func isOn(_ id: UUID) -> Bool? { powerState[id] }

    /// Whether the bulb has answered Hammer recently. Answers only feed the menu
    /// (checkmarks, "responding"): a quiet bulb still takes commands, so Hammer
    /// never drops a link for being quiet.
    func isAnswering(_ id: UUID) -> Bool {
        guard let heard = lastHeard[id] else { return false }
        return Date().timeIntervalSince(heard) < 60
    }

    // MARK: Starting up

    func start() {
        guard isAvailable, central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)   // asks for Bluetooth permission

        // Every 2 seconds: "are you on?" to each connected bulb of yours.
        // Every 10 seconds: reconnect anything of yours that dropped.
        let timer = Timer(timeInterval: Self.keepAliveEvery, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        keepAlive = timer
    }

    /// Looks for nearby bulbs for 15 seconds. Duplicates are allowed so a bulb whose
    /// name arrives in a later advertisement still gets picked up.
    func rescan() {
        guard let central, central.state == .poweredOn else { return }
        central.stopScan()
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let central = self?.central, central.state == .poweredOn else { return }
            central.stopScan()
        }
    }

    /// Your bulbs. Hammer keeps these connected; any others it lets go of.
    func hold(_ ids: Set<UUID>) {
        guard ids != held else { return }
        let letGo = held.subtracting(ids)
        held = ids
        for id in letGo { if let peripheral = peripherals[id] { releaseSoon(peripheral) } }
        connectHeld()
    }

    /// Connects to every one of your bulbs that isn't connected, including ones
    /// from earlier runs that haven't been seen yet (a busy bulb doesn't broadcast,
    /// but macOS can still hand it over by its ID).
    func connectHeld() {
        for id in held where found[id] == nil {
            if let saved = knownBulbs[id.uuidString] {
                found[id] = saved
            } else {
                // Yours, but Hammer hasn't heard its name yet: list it anyway so it can
                // be used and shows its status. The real name replaces this once known.
                found[id] = ("", "Bluetooth bulb \(id.uuidString.prefix(4))")
                placeholders.insert(id)
            }
        }
        guard let central, central.state == .poweredOn else { return }
        let unseen = held.filter { peripherals[$0] == nil }
        if !unseen.isEmpty {
            for peripheral in central.retrievePeripherals(withIdentifiers: Array(unseen)) { adopt(peripheral) }
        }
        for id in held { if let peripheral = peripherals[id] { connect(peripheral) } }
    }

    private func tick() {
        ticks += 1
        for id in held where isConnected(id) {
            send([0xAA, 0x01], to: id)            // "are you on?" (replaces any unsent one)
        }
        if ticks % 5 == 0 { connectHeld() }
    }

    // MARK: Remembering bulbs between runs

    private var knownBulbs: [String: (model: String, name: String)] {
        let saved = UserDefaults.standard.dictionary(forKey: "bluetoothBulbs") as? [String: String] ?? [:]
        var result: [String: (model: String, name: String)] = [:]
        for (id, value) in saved {
            let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[id] = (parts[0], parts[1]) }
        }
        return result
    }

    private func remember(_ id: UUID, model: String, name: String) {
        var saved = UserDefaults.standard.dictionary(forKey: "bluetoothBulbs") as? [String: String] ?? [:]
        saved[id.uuidString] = "\(model)|\(name)"
        UserDefaults.standard.set(saved, forKey: "bluetoothBulbs")
    }

    /// Takes a bulb's model and name from what it calls itself, if Hammer didn't know
    /// them yet. Returns true if anything changed.
    @discardableResult
    private func learnName(_ id: UUID, from advertised: String?) -> Bool {
        guard found[id] == nil || placeholders.contains(id), let advertised,
              let model = GoveeName.model(in: advertised), Self.supportedModels.contains(model) else { return false }
        let name = GoveeName.displayName(model: model, advertised: advertised)
        found[id] = (model, name)
        placeholders.remove(id)
        remember(id, model: model, name: name)
        return true
    }

    private func adopt(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard peripherals[id] == nil else { return }
        peripherals[id] = peripheral
        if found[id] == nil, let saved = knownBulbs[id.uuidString] { found[id] = saved }
        learnName(id, from: peripheral.name)
        onChange?()
    }

    // MARK: Sending

    func send(_ payload: [UInt8], to id: UUID) {
        if peripherals[id] == nil, let central, central.state == .poweredOn {
            for peripheral in central.retrievePeripherals(withIdentifiers: [id]) { adopt(peripheral) }
        }
        guard let peripheral = peripherals[id] else { return }

        let packet = GoveePacket.make(payload)
        enqueue(packet, for: id)
        if GoveePacket.isCommand(packet) { enqueue(GoveePacket.statusRead, for: id) }   // then ask, so the menu learns on/off

        if !held.contains(id) { releaseSoon(peripheral) }            // someone else's bulb: brief visit only
        if isConnected(id) {
            pump(peripheral)
        } else {
            backoff.hurry(id, within: 2)                             // you asked for it: don't wait out a long backoff
            connect(peripheral)
        }
    }

    /// Queues a packet, replacing any older one of the same kind: if you change the
    /// brightness five times while the bulb is busy, only the last one matters.
    private func enqueue(_ packet: [UInt8], for id: UUID) {
        var queue = outbox[id] ?? CommandQueue(freshFor: Self.freshFor)
        queue.add(packet)
        outbox[id] = queue
    }

    private func hasWork(_ id: UUID) -> Bool {
        guard var queue = outbox[id] else { return false }
        queue.dropStale()
        outbox[id] = queue
        return !queue.isEmpty
    }

    /// Hammer always wants a link to your bulbs, and to anyone else's only while it
    /// has something to send (Blink to Identify).
    private func wantsLink(_ id: UUID) -> Bool { held.contains(id) || hasWork(id) }

    /// Writes queued packets one at a time, as fast as the bulb can take them.
    /// (Writing faster than the link allows makes macOS silently drop packets.)
    private func pump(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard peripheral.state == .connected, let control = controls[id] else { return }
        if let started = writeInFlight[id] {
            let left = 2 - Date().timeIntervalSince(started)
            if left > 0 { schedulePump(id, after: left + 0.05); return }   // the answer never came: carry on after 2 s
            writeInFlight[id] = nil
        }

        var queue = outbox[id] ?? CommandQueue(freshFor: Self.freshFor)
        queue.dropStale()
        while let item = queue.items.first {
            let next = item.packet
            if control.properties.contains(.writeWithoutResponse) {
                if !peripheral.canSendWriteWithoutResponse {
                    // macOS usually says when the link is ready again, but not always:
                    // look again shortly, and after a second of "not yet" send anyway.
                    let since = waitingToWrite[id] ?? Date()
                    waitingToWrite[id] = since
                    if Date().timeIntervalSince(since) < 1 {
                        schedulePump(id, after: 0.25)
                        break
                    }
                }
                waitingToWrite[id] = nil
                peripheral.writeValue(Data(next), for: control, type: .withoutResponse)
                noteWritten(item, to: id)
                queue.removeFirst()
            } else {
                peripheral.writeValue(Data(next), for: control, type: .withResponse)
                noteWritten(item, to: id)
                queue.removeFirst()
                writeInFlight[id] = Date()                                     // resumes in didWriteValueFor
                schedulePump(id, after: 2.05)
                break
            }
        }
        outbox[id] = queue
    }

    private func noteWritten(_ item: CommandQueue.Item, to id: UUID) {
        guard GoveePacket.isCommand(item.packet) else { return }
        let now = Date()
        var recent = (recentlyWritten[id] ?? []).filter { now.timeIntervalSince($0.at) < Self.lostWindow }
        recent.append((item: item, at: now))
        recentlyWritten[id] = recent
    }

    /// One pending re-check per bulb.
    private func schedulePump(_ id: UUID, after delay: TimeInterval) {
        guard !pumpScheduled.contains(id) else { return }
        pumpScheduled.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pumpScheduled.remove(id)
            if let peripheral = self.peripherals[id] { self.pump(peripheral) }
        }
    }

    // MARK: Connecting

    private func connect(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard let central, central.state == .poweredOn, peripheral.state == .disconnected else { return }
        guard backoff.canTry(id) else { scheduleRetry(id); return }
        incompatible.remove(id)                    // checked again once connected
        connectingSince[id] = Date()
        central.connect(peripheral)                // waits as long as it takes; no timeout
        // Let the menu say "can't reach" if this is taking a while.
        if !patienceCheck.contains(id) {
            patienceCheck.insert(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.patience + 0.5) { [weak self] in
                self?.patienceCheck.remove(id)
                self?.onChange?()
            }
        }
    }

    /// Tries again once the backoff is over. One pending try per bulb; a sooner one replaces it.
    private func scheduleRetry(_ id: UUID) {
        let when = Date().addingTimeInterval(backoff.wait(id) + 0.05)
        if let pending = retryAt[id], pending <= when { return }
        retryAt[id] = when
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, when.timeIntervalSinceNow)) { [weak self] in
            guard let self, self.retryAt[id] == when else { return }
            self.retryAt[id] = nil
            if self.wantsLink(id), let peripheral = self.peripherals[id] { self.connect(peripheral) }
        }
    }

    /// Ends a link that isn't working and waits before trying again, so a bulb that
    /// keeps failing isn't flooded with retries (and isn't kept from your phone).
    private func dropLink(_ peripheral: CBPeripheral, pause: TimeInterval? = nil) {
        let id = peripheral.identifier
        if let pause { backoff.pause(id, for: pause) } else { backoff.failed(id) }
        connectedAt[id] = nil                                 // counted here, so didDisconnect doesn't count it again
        readyAt[id] = nil
        guard let central, central.state == .poweredOn else { return }
        central.cancelPeripheralConnection(peripheral)        // didDisconnect follows, and waits out the backoff
    }

    /// Lets go of a bulb that isn't yours 10 seconds after Hammer last used it.
    private func releaseSoon(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        releaseTimers[id]?.cancel()
        let release = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.releaseTimers[id] = nil
            guard !self.held.contains(id) else { return }
            self.outbox[id] = nil
            self.recentlyWritten[id] = nil
            self.connectingSince[id] = nil
            self.connectedAt[id] = nil                        // letting go on purpose isn't a failure
            self.readyAt[id] = nil
            if let central = self.central, central.state == .poweredOn, let current = self.peripherals[id],
               current.state != .disconnected {
                central.cancelPeripheralConnection(current)
            }
        }
        releaseTimers[id] = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: release)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            rescan()
            connectHeld()
        } else {
            // Bluetooth went off, is resetting, or isn't allowed: every link is gone,
            // and after a reset macOS's bulb objects are no good either, so they're
            // fetched again when it's back.
            peripherals.removeAll()
            controls.removeAll()
            writeInFlight.removeAll()
            waitingToWrite.removeAll()
            connectingSince.removeAll()
            connectedAt.removeAll()
            readyAt.removeAll()
            outbox.removeAll()
            powerState.removeAll()
            lastHeard.removeAll()
            recentlyWritten.removeAll()
            retryAt.removeAll()
            setupRetries.removeAll()
            releaseTimers.values.forEach { $0.cancel() }
            releaseTimers.removeAll()
            backoff = ConnectBackoff()
        }
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Govee bulbs advertise names like "ihoment_H6006_1A2B".
        let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard let model = GoveeName.model(in: advertised), Self.supportedModels.contains(model) else { return }
        let id = peripheral.identifier
        if RSSI.intValue < 0 { signalStrength[id] = RSSI.intValue }   // 127 means "unknown"
        if peripherals[id] == nil { peripherals[id] = peripheral }

        if !seenThisRun.contains(id) || placeholders.contains(id) {
            seenThisRun.insert(id)
            let name = GoveeName.displayName(model: model, advertised: advertised)
            found[id] = (model, name)
            placeholders.remove(id)
            remember(id, model: model, name: name)
            onChange?()
        }
        if held.contains(id) { connect(peripheral) }      // one of yours just became free
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        connectingSince[id] = nil
        let session = Date()
        connectedAt[id] = session
        setupRetries[id] = 0
        learnName(id, from: peripheral.name)
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        // If getting the link ready stalls, start over (after a pause) rather than sit on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.setupTimeout) { [weak self] in
            guard let self, self.connectedAt[id] == session, self.controls[id] == nil,
                  let current = self.peripherals[id], current.state == .connected else { return }
            self.dropLink(current)
        }
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        connectingSince[id] = nil
        backoff.failed(id)
        if held.contains(id) {
            scheduleRetry(id)                             // keep trying, a little slower each time
        } else {
            outbox[id] = nil
        }
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let id = peripheral.identifier
        controls[id] = nil
        writeInFlight[id] = nil
        waitingToWrite[id] = nil
        connectingSince[id] = nil
        // Commands written since the bulb last answered may have gone nowhere: send them again.
        let heard = lastHeard[id] ?? .distantPast
        let lost = (recentlyWritten.removeValue(forKey: id) ?? [])
            .filter { $0.at > heard && Date().timeIntervalSince($0.at) < Self.lostWindow }
            .map { $0.item }
        if !lost.isEmpty {
            var queue = outbox[id] ?? CommandQueue(freshFor: Self.freshFor)
            queue.restore(lost)
            outbox[id] = queue
        }
        powerState[id] = nil                              // it may change while someone else has it
        lastHeard[id] = nil
        // Hammer's own disconnects (dropLink, releaseSoon) were already accounted for.
        let ready = readyAt.removeValue(forKey: id)
        if connectedAt.removeValue(forKey: id) != nil {
            if let ready, Date().timeIntervalSince(ready) >= Self.shortLink {
                backoff.succeeded(id)                     // it was a good link: reconnect right away
            } else {
                backoff.failed(id)                        // never got going, or dropped soon after: back off if it repeats
            }
        }
        if wantsLink(id) { connect(peripheral) }          // yours: reconnects the moment it's free again
        onChange?()
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if peripheral.services?.contains(where: { $0.uuid == Self.serviceUUID }) == true {
            continueSetup(peripheral)
        } else if error != nil {
            retrySetup(peripheral)                        // a hiccup, not an answer
        } else {
            markIncompatible(peripheral)                  // the bulb really has no Govee service
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        let characteristics = service.characteristics ?? []
        guard let control = characteristics.first(where: { $0.uuid == Self.controlUUID }) else {
            if error != nil { retrySetup(peripheral) } else { markIncompatible(peripheral) }
            return
        }
        controls[id] = control
        readyAt[id] = Date()
        setupRetries[id] = 0
        // Listen for the bulb's replies (on/off state, and proof it's answering). Not on
        // the control channel itself: an echo of "are you on?" would read as "off".
        for characteristic in characteristics
        where characteristic.uuid != Self.controlUUID
            && (characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate)) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        enqueue(GoveePacket.statusRead, for: id)
        pump(peripheral)
        onChange?()
    }

    /// The next step of getting a fresh link ready: find the service, then its channels.
    private func continueSetup(_ peripheral: CBPeripheral) {
        if let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) {
            peripheral.discoverCharacteristics(nil, for: service)
        } else {
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    /// A setup step failed on a working link (it happens now and then): try it again
    /// twice, then start the link over after a pause.
    private func retrySetup(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        let tries = (setupRetries[id] ?? 0) + 1
        setupRetries[id] = tries
        guard tries <= 2 else { dropLink(peripheral); return }
        let session = connectedAt[id]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, session != nil, self.connectedAt[id] == session,
                  let current = self.peripherals[id], current.state == .connected else { return }
            self.continueSetup(current)
        }
    }

    /// The bulb connected but doesn't offer Govee's control channel (e.g. after a
    /// firmware update). Keeping the link would only block your phone, so let go
    /// and check again in 5 minutes, or sooner if you use the light.
    private func markIncompatible(_ peripheral: CBPeripheral) {
        incompatible.insert(peripheral.identifier)
        dropLink(peripheral, pause: Self.incompatiblePause)
        onChange?()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeInFlight[peripheral.identifier] = nil
        pump(peripheral)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pump(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid != Self.controlUUID, let value = characteristic.value else { return }
        let id = peripheral.identifier
        var changed = !isAnswering(id)
        lastHeard[id] = Date()
        if let on = GoveePacket.powerState(in: [UInt8](value)), powerState[id] != on {
            powerState[id] = on
            changed = true
        }
        if changed { onChange?() }
    }
}

// MARK: - Menu bar app

/// Called by macOS when ⌃⌥H (id 1), ⌃⌥Y (id 2) or ⌘Y (id 3) is pressed.
func hotKeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return noErr }
    var hotKey = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
    let which = status == noErr ? hotKey.id : 1
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in delegate.handleHotKey(which) }
    return noErr
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    // Monitor (Monitor.swift, MonitorMac.swift). The MonitorSet object talks to the
    // monitor and keeps what it learns, so it's only ever used on ddcQueue.
    private var monitors = MonitorSet([])
    private var monitorCount = 0                     // connections found, for the menu
    private var monitorAttached = 0                  // ...with a monitor plugged in
    private var monitorHasDefault = false            // macOS's default connection is tried too
    private var monitorViaHDMIAdapter = false        // on HDMI through a USB-C adapter (blocks control)
    private lazy var macModel = MacMonitors.mac().model   // e.g. "MacBookPro18,1"
    private var monitorMisses = 0                    // reads in a row with no answer
    private var monitorScreens: [MonitorScreen] = []
    private var monitorAnswers: Bool?                // nil until asked
    private var monitorValues: [UInt8: (current: UInt16, max: UInt16)] = [:]
    private var monitorSliders: [UInt8: NSSlider] = [:]
    private var monitorMoved: [UInt8: Date] = [:]    // when you last moved each slider
    private let sliderMoves = SliderMoves()          // the same, for reads in the background
    private var monitorReadAt: Date?
    private var monitorGeneration = 0                // bumps when the monitor list is rebuilt
    private var checkingMonitor = false
    private var networkLights: [GoveeLight] = []     // found over Wi-Fi or the Govee cloud
    private var bluetoothLights: [GoveeLight] = []   // found nearby over Bluetooth
    private var searchingForLights = false

    /// Every light, each listed once. The same bulb can be found both in the Govee
    /// cloud and over Bluetooth, and the two don't share an ID, so match by model:
    /// - one of a model each way: same bulb — keep its app name, use Bluetooth.
    /// - several of a model, same count each way: same bulbs, but we can't tell
    ///   which is which, so list the Bluetooth ones (always the right bulb).
    private var foundLights: [GoveeLight] {
        var result = networkLights
        for (sku, nearby) in Dictionary(grouping: bluetoothLights, by: { $0.sku }) {
            let cloudOnly = result.indices.filter {
                result[$0].sku == sku && result[$0].lanIP == nil && result[$0].bluetoothID == nil
            }
            if cloudOnly.count == 1 && nearby.count == 1 {
                result[cloudOnly[0]].bluetoothID = nearby[0].bluetoothID
                continue
            }
            if cloudOnly.count == nearby.count {
                result = result.enumerated().filter { !cloudOnly.contains($0.offset) }.map { $0.element }
            }
            result.append(contentsOf: nearby)
        }
        return result
    }

    /// Your lights: the only ones Hammer controls, including All Lights.
    private var lights: [GoveeLight] { named(foundLights.filter { isMine($0) }) }

    /// Everything else in range: listed under Other Lights, never controlled.
    private var otherLights: [GoveeLight] { named(foundLights.filter { !isMine($0) }) }

    /// A light found only over Bluetooth could be anyone's (Bluetooth reaches
    /// through walls), so it's yours only once you add it. Lights on your Wi-Fi
    /// or in your Govee account are yours unless you remove them.
    private func isMine(_ light: GoveeLight) -> Bool {
        isBluetoothOnly(light) ? myBluetoothIDs.contains(light.id) : !hiddenIDs.contains(light.id)
    }

    private func isBluetoothOnly(_ light: GoveeLight) -> Bool {
        light.lanIP == nil && light.bluetoothID?.uuidString == light.id
    }

    private func named(_ list: [GoveeLight]) -> [GoveeLight] {
        let names = customNames
        return list
            .map { light -> GoveeLight in
                var named = light
                if let name = names[light.id] { named.name = name }
                return named
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Bluetooth bulbs you've added. Until the first add, any bulb you'd
    /// already renamed counts as yours.
    private var myBluetoothIDs: Set<String> {
        get {
            if let saved = UserDefaults.standard.stringArray(forKey: "myBluetoothLights") { return Set(saved) }
            return Set(customNames.keys)
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: "myBluetoothLights") }
    }

    /// Names you've given lights, and Wi-Fi/cloud lights you've removed, kept between launches.
    private var customNames: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "lightNames") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "lightNames") }
    }

    private var hiddenIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hiddenLights") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "hiddenLights") }
    }

    /// The installed version (a commit from the GitHub repo), written in by build.sh.
    static let version: String = {
        guard let url = Bundle.main.url(forResource: "VERSION", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "dev" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    /// "abc1234 · Oct 22": the version and the day it was made (VERSION-DATE, from build.sh).
    static let versionText: String = {
        guard let url = Bundle.main.url(forResource: "VERSION-DATE", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return version }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let day = parser.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return version }
        let formatter = DateFormatter()
        let thisYear = Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year)
        formatter.setLocalizedDateFormatFromTemplate(thisYear ? "MMMd" : "yMMMd")
        return version + " · " + formatter.string(from: day)
    }()
    private var colorTargetID: String?
    private var hotKeyRef: EventHotKeyRef?
    private var playerHotKeyRef: EventHotKeyRef?
    private var playerHotKeyWorks = true                 // false if another app has Control-Option-Y
    private var commandYRef: EventHotKeyRef?
    private var commandYWorks = true                     // false if another app took Command-Y everywhere
    /// Command-Y opens YouTube too (on unless you turn it off). While it's on, other
    /// apps don't get Command-Y (Finder's Quick Look, History in browsers).
    private var commandYOn: Bool {
        get { UserDefaults.standard.object(forKey: "playerCommandY") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "playerCommandY") }
    }
    // YouTube mini player (Player.swift, PlayerMac.swift), made the first time it's used.
    private var youTube: YouTubePlayer?
    // YouTube in your own Microsoft Edge (EdgeMac.swift), likewise.
    private var edgeYouTube: EdgePlayer?

    private let ddcQueue = DispatchQueue(label: "Hammer.ddc")       // I²C is slow; keep it off the main thread
    private let goveeQueue = DispatchQueue(label: "Hammer.govee")   // one light command at a time
    private var pending: [String: DispatchWorkItem] = [:]            // latest value per slider

    /// `Hammer tour <folder> [--demo]`: screenshots of every menu and window (TourMac below).
    static var tour: (folder: URL, demo: Bool)?
    private var tourDemo: Bool { Self.tour?.demo == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hammer", accessibilityDescription: "Hammer")
        statusItem.autosaveName = "Hammer"   // remembers where you Cmd-drag the icon
        installEditMenu()
        registerHotKey()
        findMonitors()

        GoveeBluetooth.shared.onChange = { [weak self] in
            guard let delegate = self else { return }
            Task { @MainActor in delegate.bluetoothChanged() }
        }
        GoveeBluetooth.shared.start()        // first time: macOS asks to allow Bluetooth
        GoveeBluetooth.shared.hold(heldBluetoothIDs)
        DeliveryWatcher.shared.onChange = { [weak self] in
            guard let delegate = self else { return }
            Task { @MainActor in delegate.rebuildMenuSoon() }
        }
        if !tourDemo { DeliveryWatcher.shared.start() }   // checks Gmail for deliveries, if set up
        scheduleUpdateChecks()
        rescanLights()                       // also builds the menu

        // Pick up a sleep timer set before Hammer restarted (e.g. for an update),
        // unless it ran out more than an hour ago.
        if let end = timerEnd, Date().timeIntervalSince(end) > 3600 { timerEnd = nil }
        armTimer()
        startClock()

        // Pick up the monitor automatically when it's plugged in or unplugged.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        if Self.tour != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.startTour() }
        }
    }

    /// Opening Hammer again (from Apps, Spotlight or Finder) shows its menu
    /// right where the pointer is, so it works even when the menu bar icon
    /// is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenuAtMouse()
        return false
    }

    /// Hammer was opened by you (Finder, Spotlight, `open`), not at login, by an update
    /// (both pass --login) or for a tour: then its menu pops up at the pointer, so you
    /// see it even when the menu bar icon is hidden.
    static var openedByYou = false

    private var iconHidden = false                   // the menu bar icon isn't showing
    private var iconHiddenChecks = 0
    private var iconTimer: Timer?

    /// Every 10 seconds: is the menu bar icon actually on screen? macOS hides it when
    /// the menu bar is too full (behind the camera notch) and, from macOS 26, when it's
    /// turned off in Menu Bar settings. Not while the menu bar itself can be hidden
    /// (full screen, or set to hide automatically) or the screen is off or locked.
    private func watchIcon() {
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIcon() }
        }
        RunLoop.main.add(timer, forMode: .common)
        iconTimer = timer
    }

    private func checkIcon() {
        guard NSMenu.menuBarVisible(), !UserDefaults.standard.bool(forKey: "_HIHideMenuBar"),
              CGDisplayIsAsleep(CGMainDisplayID()) == 0,
              (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool != true,
              let window = statusItem.button?.window else { return }
        iconHiddenChecks = window.occlusionState.contains(.visible) ? 0 : iconHiddenChecks + 1
        let hidden = iconHiddenChecks >= 2
        if hidden != iconHidden {
            iconHidden = hidden
            rebuildMenuSoon()
        }
    }

    /// Opened by clicking the icon: then it plainly isn't hidden.
    private func menuOpening(_ menu: NSMenu) {
        guard let window = statusItem.button?.window, NSApp.currentEvent?.window === window else { return }
        iconHiddenChecks = 0
        iconHidden = false
        menu.items.first { $0.action == #selector(explainHiddenIcon) }?.isHidden = true
    }

    @objc private func explainHiddenIcon() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert()
        alert.messageText = "Hammer's menu bar icon is hidden"
        let meanwhile = "\n\nUntil then, press Control-Option-H, or open Hammer from Spotlight."
        if #available(macOS 26, *) {
            alert.informativeText = "In System Settings → Menu Bar, turn on Hammer under Allow in the Menu Bar. "
                + "If it's on already, the menu bar is too full: quit an app with a menu bar icon to make room."
                + meanwhile
            alert.addButton(withTitle: "Open Menu Bar Settings")
            alert.addButton(withTitle: "Cancel")
        } else {
            alert.informativeText = "The menu bar is too full, so macOS hides some icons (behind the camera, "
                + "on a MacBook). Quit an app with a menu bar icon to make room." + meanwhile
        }
        guard alert.runModal() == .alertFirstButtonReturn, #available(macOS 26, *),
              let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") else { return }
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    func showMenuAtMouse() {
        guard let menu = statusItem.menu else { return }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)   // let the app launcher close first
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    /// Control-Option-H opens the menu from anywhere; Control-Option-Y the YouTube player.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x484D_4D52), id: 1)    // "HMMR"
        RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        registerYouTubeKeys()
        // ⌃⌥Y and ⌘Y are on the key that types "y", which moves when you switch keyboard layouts.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(keyboardLayoutChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    /// Control-Option-Y, and Command-Y while it's on: on whichever key types "y" on your
    /// keyboard layout (on a German keyboard the American Y key types Z, so ⌘Y there
    /// would take Undo everywhere).
    private func registerYouTubeKeys() {
        if let ref = playerHotKeyRef { UnregisterEventHotKey(ref) }
        playerHotKeyRef = nil
        youTubeKeys = YouTubeKeys(plain: YKey.code(withCommand: false), command: YKey.code(withCommand: true))
        let playerID = EventHotKeyID(signature: OSType(0x484D_4D52), id: 2)
        playerHotKeyWorks = RegisterEventHotKey(youTubeKeys.plain, UInt32(controlKey | optionKey), playerID,
                                                GetApplicationEventTarget(), 0, &playerHotKeyRef) == noErr
        registerCommandY()
    }

    /// The keys ⌃⌥Y and ⌘Y are on now.
    private struct YouTubeKeys: Equatable {
        var plain = UInt32(ShortcutKey.americanY)
        var command = UInt32(ShortcutKey.americanY)
    }
    private var youTubeKeys = YouTubeKeys()

    /// Command-Y, while it's on.
    private func registerCommandY() {
        if let ref = commandYRef { UnregisterEventHotKey(ref) }
        commandYRef = nil
        commandYWorks = true
        guard commandYOn else { return }
        let id = EventHotKeyID(signature: OSType(0x484D_4D52), id: 3)
        commandYWorks = RegisterEventHotKey(youTubeKeys.command, UInt32(cmdKey), id,
                                            GetApplicationEventTarget(), 0, &commandYRef) == noErr
    }

    /// Another keyboard layout (or input method): only if "y" moved are the shortcuts moved.
    @objc private func keyboardLayoutChanged() {
        guard YouTubeKeys(plain: YKey.code(withCommand: false), command: YKey.code(withCommand: true)) != youTubeKeys else { return }
        registerYouTubeKeys()
        rebuildMenuSoon()
    }

    /// The key that types "y" on the keyboard layout in use (Carbon's UCKeyTranslate).
    /// `withCommand`: as typed with ⌘ held, for layouts that switch then ("Dvorak – QWERTY ⌘").
    /// A layout with no "y" (Russian, say) uses its Latin layout, as macOS does for ⌘
    /// shortcuts; failing that, the American Y key.
    private enum YKey {
        static func code(withCommand: Bool) -> UInt32 {
            let sources = [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()]
                .compactMap { $0?.takeRetainedValue() }
            for source in sources {
                guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
                let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
                guard let bytes = CFDataGetBytePtr(data) else { continue }
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                let modifiers = withCommand ? UInt32((cmdKey >> 8) & 0xFF) : 0
                let found = ShortcutKey.code(typing: "y") { key in
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDisplay), modifiers, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeys,
                                                characters.count, &length, &characters)
                    return status == noErr ? String(utf16CodeUnits: characters, count: length) : nil
                }
                if let found { return UInt32(found) }
            }
            return UInt32(ShortcutKey.americanY)
        }
    }

    @objc private func toggleCommandY() {
        commandYOn.toggle()
        registerCommandY()
        rebuildMenuSoon()
    }

    func handleHotKey(_ id: UInt32) {
        if id == 2 || id == 3 { toggleYouTube() } else { showMenuAtMouse() }
    }

    // MARK: YouTube

    private var player: YouTubePlayer {
        if let youTube { return youTube }
        let made = YouTubePlayer(anchor: { [weak self] in
            guard let window = self?.statusItem.button?.window else { return (NSScreen.main, nil) }
            return (window.screen, window.frame)
        })
        made.onChange = { [weak self] in self?.rebuildMenuSoon() }
        youTube = made
        return made
    }

    private var edge: EdgePlayer {
        if let edgeYouTube { return edgeYouTube }
        let made = EdgePlayer(screen: { [weak self] in self?.statusItem.button?.window?.screen },
                              useHammerPlayer: { [weak self] in
                                  self?.setYouTubeInEdge(false)
                                  self?.player.showDropdown()
                              })
        made.onChange = { [weak self] in self?.rebuildMenuSoon() }
        edgeYouTube = made
        return made
    }

    @objc private func allowEdgeControl() { EdgePlayer.openAutomationSettings() }

    /// YouTube opens in Microsoft Edge (signed in, your extensions) if it's installed,
    /// unless you chose Hammer's own player in Open In.
    private var youTubeInEdge: Bool {
        (UserDefaults.standard.object(forKey: "youTubeInEdge") as? Bool ?? true) && EdgePlayer.isInstalled
    }

    private func setYouTubeInEdge(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "youTubeInEdge")
        if on { youTube?.putAway() }
        rebuildMenuSoon()
    }

    @objc private func useEdgeForYouTube() { if EdgePlayer.isInstalled { setYouTubeInEdge(true) } }
    @objc private func useHammerPlayerForYouTube() { setYouTubeInEdge(false) }

    @objc private func toggleYouTube() {
        if youTubeInEdge { edge.toggle() } else { player.toggle() }
    }

    /// Plays the YouTube link you copied. Reading the clipboard only when you
    /// choose this keeps macOS from asking about it every time the menu opens.
    @objc private func playCopiedLink() {
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        guard let link = YouTubeLink.video(in: copied) else {
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            let alert = NSAlert()
            alert.messageText = "No YouTube link copied"
            alert.informativeText = "Copy a video's link (in YouTube: Share → Copy link), then choose Play Copied Link."
            alert.runModal()
            return
        }
        if youTubeInEdge { edge.toggle(play: EdgeYouTube.watchURL(id: link.id, start: link.start)) } else { player.play(link) }
    }

    private func addYouTube(to menu: NSMenu) {
        menu.addItem(label("YouTube"))
        let inEdge = youTubeInEdge
        // In Hammer's player with a video playing in the dropdown, this pops it back out.
        let backToMini = !inEdge && youTube?.place == .dropdown && youTube?.playing == true
        let open = action(backToMini ? "Back to the Mini Player" : "Open YouTube", #selector(toggleYouTube))
        // The shortcut shown is one that's really registered.
        if commandYOn && commandYWorks {
            open.keyEquivalent = "y"
            open.keyEquivalentModifierMask = [.command]
        } else if playerHotKeyWorks {
            open.keyEquivalent = "y"
            open.keyEquivalentModifierMask = [.control, .option]
        }
        menu.addItem(open)
        let commandYTaken = commandYOn && !commandYWorks
        if !playerHotKeyWorks && commandYTaken {
            menu.addItem(hint("Other apps have ⌘Y and ⌃⌥Y; use the menu."))
        } else if !playerHotKeyWorks && !commandYOn {
            menu.addItem(hint("Another app has ⌃⌥Y; use the menu."))
        }
        menu.addItem(action("Play Copied Link", #selector(playCopiedLink)))
        if !inEdge, let youTube, youTube.place != .hidden, !youTube.title.isEmpty {
            menu.addItem(hint((youTube.playing ? "Playing: " : "Paused: ") + truncated(youTube.title, 44)))
        }
        if inEdge, edgeYouTube?.needsPermission == true {
            menu.addItem(action("Allow Edge Control…", #selector(allowEdgeControl)))
        }
        menu.addItem(youTubeOpenIn(inEdge: inEdge))
        let commandY = action("⌘Y Shortcut", #selector(toggleCommandY))
        commandY.state = commandYOn ? .on : .off
        commandY.toolTip = "While it's on, other apps don't get ⌘Y (Quick Look in Finder, History in browsers, Redo in Office)."
        menu.addItem(commandY)
        if commandYTaken && playerHotKeyWorks {
            menu.addItem(hint("Another app has ⌘Y; use ⌃⌥Y."))
        }
    }

    /// Where YouTube opens.
    private func youTubeOpenIn(inEdge: Bool) -> NSMenuItem {
        let options = NSMenu()
        options.autoenablesItems = false                 // so the Edge choice really is off without Edge
        let edgeItem = action("Microsoft Edge", #selector(useEdgeForYouTube))
        edgeItem.state = inEdge ? .on : .off
        edgeItem.toolTip = "Your Edge account and extensions"
        let installed = EdgePlayer.isInstalled
        edgeItem.isEnabled = installed
        options.addItem(edgeItem)
        if !installed { options.addItem(hint("Microsoft Edge isn't installed.")) }
        let hammerItem = action("Hammer's Player", #selector(useHammerPlayerForYouTube))
        hammerItem.state = inEdge ? .off : .on
        hammerItem.toolTip = "Glass dropdown and a floating mini player"
        options.addItem(hammerItem)
        let item = NSMenuItem(title: "Open In", action: nil, keyEquivalent: "")
        item.submenu = options
        return item
    }

    private func truncated(_ text: String, _ length: Int) -> String {
        text.count <= length ? text : String(text.prefix(length - 1)) + "…"
    }

    /// Menu bar apps have no Edit menu, which stops Cmd-V from pasting into
    /// text boxes. This invisible one fixes that.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func bluetoothChanged() {
        guard !tourDemo else { return }                  // the tour's stand-in lights stay
        bluetoothLights = GoveeBluetooth.shared.lights
        GoveeBluetooth.shared.hold(heldBluetoothIDs)
        rebuildMenuSoon()
    }

    /// Your Bluetooth bulbs, which Hammer keeps connected. Taken from the saved
    /// list too, so they're held from the moment Hammer starts — before they're seen.
    private var heldBluetoothIDs: Set<UUID> {
        Set(myBluetoothIDs.compactMap { UUID(uuidString: $0) }).union(lights.compactMap { $0.bluetoothID })
    }

    private var screenChanges = 0                        // a burst of display changes gets one rescan

    @objc private func screensChanged() {
        // The screens now (quick), so a replugged monitor is dimmed again at once; the full rescan
        // of its connections waits for the burst of changes to end.
        monitorScreens = MacMonitors.screens()
        if !resumeSoftwareDimming() { reapplyIfDimming() }
        screenChanges += 1
        let change = screenChanges
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.screenChanges == change else { return }   // more changes came: rescan after the last
            self.findMonitors()
            self.reapplyIfDimming()
            self.rebuildMenuSoon()
        }
    }

    // MARK: Dimming the picture in software (when the monitor can't dim itself)

    private var softwareDimming = SoftwareDimming()      // when to dim, and what to do next (Monitor.swift)
    private var dimWatch: Timer?                         // while dimming: puts it back if something resets it
    private var softwareReadout: NSTextField?            // the software Brightness slider's "40%"
    private var shownDimState = SoftwareDimState.off     // what the menu shows

    private var dimmingInSoftware: Bool {                // as last applied
        get { softwareDimming.on }
        set { softwareDimming.on = newValue }
    }

    /// Dimming in software before (this run, or before a restart, until the monitor answers again).
    private var wasDimming: Bool {
        dimmingInSoftware || dimmableScreens.contains { SoftwareDimmer.shared.wasActive($0) }
    }

    /// The menu's Brightness slider is the software one (the same rule as the menu).
    private var softwareSliderShowing: Bool {
        SoftwareDim.showing(answers: monitorAnswers, misses: monitorMisses, hdmiAdapter: monitorViaHDMIAdapter,
                            noConnection: noMonitorConnection, wasDimming: wasDimming)
    }

    /// What dimming in software can do now, for the menu and the monitor check.
    private var softwareDimState: SoftwareDimState {
        guard softwareSliderShowing, !dimmableScreens.isEmpty else { return .off }
        let dimmer = SoftwareDimmer.shared
        if dimmableScreens.contains(where: { dimmer.canDim($0) }) { return dimmer.contested ? .paused : .on }
        guard dimmableScreens.contains(where: { dimmer.canRead($0) }) else { return .unsupported }
        // "Another app" only if one was seen changing the curves; otherwise they were already adjusted.
        return dimmableScreens.contains(where: { dimmer.sawOtherApp($0) }) ? .cantDim : .adjusted
    }

    private var softwareDimLevel: Int { dimmableScreens.first.map { SoftwareDimmer.shared.savedLevel($0) } ?? 100 }

    /// External screens with a real cable (not DisplayLink or AirPlay, which have no color curves
    /// to change), except Apple displays, whose brightness macOS sets itself.
    private var dimmableScreens: [CGDirectDisplayID] {
        monitorScreens.filter { !$0.builtIn && $0.direct != false && !$0.brightnessByMacOS }.map { CGDirectDisplayID($0.id) }
    }

    /// Dims (or undims) the picture to match what the monitor said, after each read.
    /// True: ask the monitor again in 10 seconds.
    @discardableResult
    private func updateSoftwareDimming() -> Bool {
        guard let answers = monitorAnswers else { return false }   // not asked yet: reapplyIfDimming covers that time
        let dimmer = SoftwareDimmer.shared
        let plan = softwareDimming.afterRead(answers: answers, misses: monitorMisses, hdmiAdapter: monitorViaHDMIAdapter,
                                             noConnection: noMonitorConnection,
                                             wasActive: dimmableScreens.contains { dimmer.wasActive($0) },
                                             screens: !dimmableScreens.isEmpty)
        if let remember = plan.remember {
            for display in dimmableScreens { dimmer.setActive(remember, for: display) }
        }
        switch plan.change {
        case .fadeIn: dimmer.fade(on: dimmableScreens, dimming: true)      // starting or stopping: a short fade
        case .fadeOut: dimmer.fade(on: dimmableScreens, dimming: false)
        case .reapply: dimmer.reapply(on: dimmableScreens)
        case .undo: dimmer.undoAll()
        }
        watchDimming()
        return plan.askAgain
    }

    /// At launch (also after an update) or when a monitor that was dimmed in software is
    /// plugged in again: dim it straight away, rather than at full brightness until it's asked.
    @discardableResult
    private func resumeSoftwareDimming() -> Bool {
        guard softwareDimming.resume(wasActive: dimmableScreens.contains { SoftwareDimmer.shared.wasActive($0) }) else { return false }
        reapplyIfDimming()
        watchDimming()
        return true
    }

    /// After a wake, display sleep or a display change macOS resets screens' curves:
    /// dim again straight away (and a moment later, as screens settle), without
    /// waiting to ask the monitor. Where Hammer gave way to another app, it tries again.
    private func reapplyIfDimming() {
        guard dimmingInSoftware else { return }
        if SoftwareDimmer.shared.forgetGiveUps() { rebuildMenuSoon() }   // drop "Paused"
        for delay in [0.0, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let delegate = self else { return }
                Task { @MainActor in
                    guard delegate.dimmingInSoftware else { return }
                    SoftwareDimmer.shared.reapply(on: delegate.dimmableScreens)
                }
            }
        }
    }

    /// While dimming, checks every 10 seconds that the curves are still Hammer's, and
    /// updates the menu if what dimming can do changed (e.g. another app let go).
    private func watchDimming() {
        if dimmingInSoftware {
            guard dimWatch == nil else { return }
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                guard let delegate = self else { return }
                Task { @MainActor in
                    guard delegate.softwareDimming.keepsApplied else { return }   // the monitor answered meanwhile
                    SoftwareDimmer.shared.keepApplied(on: delegate.dimmableScreens)
                    if delegate.softwareDimState != delegate.shownDimState { delegate.rebuildMenuSoon() }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            dimWatch = timer
        } else {
            dimWatch?.invalidate()
            dimWatch = nil
        }
    }

    @objc private func softwareDimMoved(_ slider: NSSlider) {
        guard softwareSliderShowing else { return }        // the monitor answers again: this slider is stale
        let wasContested = SoftwareDimmer.shared.contested
        dimmingInSoftware = true
        watchDimming()
        let level = Int(slider.doubleValue.rounded())
        softwareReadout?.stringValue = "\(level)%"
        for display in dimmableScreens { SoftwareDimmer.shared.set(level, on: display) }
        if wasContested { rebuildMenuSoon() }              // moving it tries again: drop the note
    }

    @objc private func screensWoke() { reapplyIfDimming() }

    // MARK: Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        menu.addItem(label("Monitor"))
        addMonitor(to: menu)

        menu.addItem(.separator())
        menu.addItem(label("Govee Lights"))
        if let problem = GoveeBluetooth.shared.problem {
            menu.addItem(hint(problem))
        }
        let others = otherLights
        if lights.isEmpty && others.isEmpty && searchingForLights {
            menu.addItem(hint("Searching…"))
        } else if lights.isEmpty && !others.isEmpty {
            menu.addItem(label("No lights added yet"))
            menu.addItem(hint("Bulbs found over Bluetooth could be anyone's, so"))
            menu.addItem(hint("Hammer won't touch them until you add yours from"))
            menu.addItem(hint("Other Lights below."))
        } else if lights.isEmpty {
            menu.addItem(label("No lights found"))
            menu.addItem(hint("Bluetooth bulbs (like the H6006) appear by themselves"))
            menu.addItem(hint("when nearby. Close the Govee app on your phone first,"))
            menu.addItem(hint("since a bulb talks to one device at a time."))
            menu.addItem(hint("Wi-Fi lights: turn on LAN Control in the Govee app,"))
            menu.addItem(hint("then choose Rescan Lights."))
        } else {
            if lights.count > 1 { menu.addItem(lightItem(nil)) }    // "All Lights"
            for light in lights { menu.addItem(lightItem(light)) }
        }
        if !others.isEmpty { menu.addItem(otherLightsItem(others)) }
        menu.addItem(action("Rescan Lights", #selector(rescanLights)))

        menu.addItem(.separator())
        addDeliveries(to: menu)

        menu.addItem(.separator())
        addYouTube(to: menu)

        menu.addItem(.separator())
        addUpdates(to: menu)
        menu.addItem(NSMenuItem(title: "Quit Hammer", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Look for Bluetooth bulbs again every time the menu opens, so a bulb that
    /// was busy with your phone shows up without a manual rescan.
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        menuOpening(menu)
        GoveeBluetooth.shared.rescan()
        // Catches changes made with the monitor's own buttons, and a monitor that
        // starts answering (e.g. DDC/CI switched on). Asking a silent one is slow,
        // so that's at most once a minute.
        readMonitor(ifOlderThan: monitorMisses >= 2 ? 60 : 5)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if menuNeedsRebuild {
            menuNeedsRebuild = false
            rebuildMenu()
        }
    }

    private var menuIsOpen = false
    private var menuNeedsRebuild = false
    private var updateTimer: Timer?

    /// Asks the background updater to look for a new version every 2 minutes (it's
    /// quiet unless it installs something), and shows what it last did (UpdatesMac.swift).
    /// Also, at launch: tells build.sh Hammer started, marks dialogs as busy, pops the
    /// menu up if you opened Hammer, and keeps an eye on the menu bar icon.
    private func scheduleUpdateChecks() {
        Updates.shared.onChange = { [weak self] in self?.rebuildMenuSoon() }
        Updates.shared.start()
        let timer = Timer(timeInterval: 120, repeats: true) { _ in
            MainActor.assumeIsolated { Updates.shared.kick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        Busy.watchDialogs()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Updates.markLaunched(version: Self.version) }
        if Self.openedByYou {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showMenuAtMouse() }
        }
        watchIcon()
    }

    /// Rebuilds now, or once the menu closes if it's open (so it doesn't change under the pointer).
    private func rebuildMenuSoon() {
        if menuIsOpen { menuNeedsRebuild = true } else { rebuildMenu() }
    }

    private func checked(_ item: NSMenuItem, _ isOn: Bool) -> NSMenuItem {
        item.state = isOn ? .on : .off
        return item
    }

    // MARK: Deliveries (see DeliveryAlerts.swift and Deliveries.swift)

    private func addDeliveries(to menu: NSMenu) {
        let watcher = DeliveryWatcher.shared
        menu.addItem(label("Deliveries"))
        if watcher.isSettingUp {
            menu.addItem(hint("Checking your Gmail setup…"))
            return
        }
        guard watcher.isOn else {
            menu.addItem(hint("Get a notification when a package is delivered."))
            menu.addItem(action("Set Up Delivery Alerts…", #selector(setUpDeliveries)))
            return
        }
        if let problem = watcher.problem {
            for line in Self.wrap(problem) { menu.addItem(hint(line)) }
        }
        if watcher.needsSetup {
            menu.addItem(action("Set Up Gmail Again…", #selector(setUpDeliveries)))
        }
        if watcher.notificationsOff {
            menu.addItem(hint("Notifications are off for Hammer, so alerts can't show."))
            menu.addItem(action("Turn On Notifications…", #selector(openNotificationSettings)))
        }
        let recent = watcher.recent.prefix(3)
        if recent.isEmpty {
            menu.addItem(hint("No deliveries yet. Hammer checks Gmail every 3 minutes."))
        }
        for delivery in recent {
            let item = NSMenuItem(title: deliveryTitle(delivery), action: #selector(openDelivery(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = delivery.key
            item.toolTip = delivery.subject.isEmpty ? nil : DeliveryMail.tidy(delivery.subject)
            menu.addItem(item)
        }

        let settings = NSMenu()
        let account = (watcher.email ?? "").isEmpty ? "Gmail" : watcher.email ?? "Gmail"
        settings.addItem(hint(watcher.source == .script ? "\(account), through your Google script" : account))
        if watcher.isChecking {
            settings.addItem(hint("Checking now…"))
        } else if let last = watcher.lastChecked {
            settings.addItem(hint("Last checked \(clockTime(last))"))
        }
        settings.addItem(action("Check Now", #selector(checkDeliveriesNow)))
        settings.addItem(action("Send Test Notification", #selector(sendTestDelivery)))
        settings.addItem(.separator())
        settings.addItem(action("Change Gmail Account…", #selector(setUpDeliveries)))
        settings.addItem(action("Turn Off Delivery Alerts", #selector(turnOffDeliveries)))
        let item = NSMenuItem(title: "Delivery Alerts", action: nil, keyEquivalent: "")
        item.submenu = settings
        menu.addItem(item)
    }

    /// "eBay · Apple iPhone 15 Pro Max · 2:14 PM" (or the date, if not today).
    private func deliveryTitle(_ delivery: Delivery) -> String {
        var title = DeliveryMail.shorten("\(delivery.kind == .problem ? "⚠︎ " : "")\(delivery.store) · \(delivery.body)", to: 48)
        if let date = delivery.date {
            if Calendar.current.isDateInToday(date) {
                title += " · " + clockTime(date)
            } else {
                let formatter = DateFormatter()
                formatter.setLocalizedDateFormatFromTemplate("MMMd")
                title += " · " + formatter.string(from: date)
            }
        }
        return title
    }

    /// Splits a long note into menu-width lines.
    private static func wrap(_ text: String, width: Int = 52) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty && line.count + word.count + 1 > width {
                lines.append(line)
                line = ""
            }
            line += line.isEmpty ? String(word) : " " + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    @objc private func setUpDeliveries() {
        guard !DeliveryWatcher.shared.isSettingUp else { return }      // the first check is still running
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert()
        alert.messageText = "Delivery alerts from Gmail"
        alert.informativeText = """
        Hammer can show a notification when a package is delivered, from the delivery \
        emails in your Gmail: eBay, Amazon, UPS, USPS, FedEx and most other stores.

        To read them, you add a small script to your own Google account. It takes \
        about 2 minutes and needs no app password. The script only tells Hammer the \
        sender and subject of recent delivery emails.
        """
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use an App Password Instead")
        switch alert.runModal() {
        case .alertFirstButtonReturn: setUpWithScript()
        case .alertThirdButtonReturn: setUpWithAppPassword()
        default: return
        }
    }

    /// Copies the script, opens a new Google Apps Script project, and walks through
    /// deploying it; then asks for the web app address.
    private func setUpWithScript() {
        let key = DeliveryScript.newKey()
        copyScript(key: key)
        if let url = URL(string: "https://script.new") { NSWorkspace.shared.open(url) }
        askForScriptAddress(key: key, address: "", note: nil)
    }

    private func copyScript(key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DeliveryScript.source(key: key), forType: .string)
    }

    /// The steps, and a box for the web app address. Shown again, with the problem,
    /// if the address doesn't work, keeping the same script and key.
    private func askForScriptAddress(key: String, address: String, note: String?) {
        var address = address
        var note = note
        while true {
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            let alert = NSAlert()
            alert.messageText = "Add the script to your Google account"
            alert.informativeText = (note.map { "⚠︎ " + $0 + "\n\n" } ?? "") + """
            The script is copied, and a new Google Apps Script project is open in your browser. \
            It has to be in the Google account your deliveries go to: if you use several, check \
            the picture at the top right of the editor. Drag this window aside as you go.

            1. Click in the code, press ⌘A then ⌘V to replace it, and press ⌘S to save.
            2. Click Deploy → New deployment. Click the gear ⚙ next to "Select type" and choose Web app.
            3. Set Execute as: Me, and Who has access: Anyone. Click Deploy.
            4. Click Authorize access and choose that account. Google says it hasn't verified \
            the app (it's your own script): click Advanced, then Go to … (unsafe). Tick Select all \
            (so it can read Gmail), then click Continue.
            5. Copy the Web app URL (it ends in /exec), paste it below, and click Turn On.

            Google's permission screen lists everything a Gmail script could do. This one only \
            reads the sender and subject of delivery emails; you can see that in the code.
            """
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = "https://script.google.com/macros/s/…/exec"
            field.stringValue = address
            alert.accessoryView = field
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Copy Script Again")
            alert.window.initialFirstResponder = field
            // Hammer has no Dock icon to click back to, so keep the steps above the browser,
            // off to the side of it.
            alert.window.level = .floating
            alert.layout()
            if let screen = NSScreen.main?.visibleFrame {
                let size = alert.window.frame.size
                alert.window.setFrameTopLeftPoint(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - 16))
            }
            let choice = alert.runModal()
            address = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if choice == .alertThirdButtonReturn {
                copyScript(key: key)
                note = "Copied again."
                continue
            }
            guard choice == .alertFirstButtonReturn else { return }
            guard let url = DeliveryScript.webAppURL(address) else {
                note = "That isn't the web app URL. It starts with https://script.google.com/macros/s/ and ends in /exec."
                continue
            }
            let tried = address
            DeliveryWatcher.shared.turnOn(scriptURL: url, key: key) { [weak self] error in
                guard let delegate = self else { return }
                Task { @MainActor in
                    if let error {
                        delegate.askForScriptAddress(key: key, address: tried, note: error)
                    } else {
                        delegate.deliverySetupFinished(error: nil) {}
                    }
                }
            }
            return
        }
    }

    private func setUpWithAppPassword() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        var email = DeliveryWatcher.shared.email ?? ""
        var note: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "Delivery alerts from Gmail"
            alert.informativeText = (note.map { "⚠︎ " + $0 + "\n\n" } ?? "") + """
            Hammer looks at your Gmail every 3 minutes for "delivered" emails from eBay, \
            Amazon, UPS, USPS, FedEx and other stores, and shows a notification. It reads \
            only the sender and subject, and never marks anything as read.

            It needs a Gmail app password, not your regular password:
            1. Click Get App Password (2-Step Verification has to be on).
            2. Type Hammer as the name and click Create.
            3. Copy the 16 letters and paste them below.
            """
            let emailField = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
            emailField.placeholderString = "you@gmail.com"
            emailField.stringValue = email
            let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            passwordField.placeholderString = "App password (16 letters)"
            let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))
            fields.addSubview(emailField)
            fields.addSubview(passwordField)
            alert.accessoryView = fields
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Get App Password")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = email.isEmpty ? emailField : passwordField
            alert.window.level = .floating                 // stays above the browser while you get the password
            let choice = alert.runModal()
            email = emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if choice == .alertSecondButtonReturn {
                if let url = URL(string: "https://myaccount.google.com/apppasswords") { NSWorkspace.shared.open(url) }
                note = nil
                continue
            }
            guard choice == .alertFirstButtonReturn else { return }
            guard DeliverySetup.isPlainEmail(email) else {
                note = "That email address doesn't look right."
                continue
            }
            guard let password = DeliverySetup.cleanPassword(passwordField.stringValue) else {
                note = "That isn't an app password. It's 16 letters, shown in four groups of four."
                continue
            }
            DeliveryWatcher.shared.turnOn(email: email, password: password) { [weak self] error in
                guard let delegate = self else { return }
                Task { @MainActor in delegate.deliverySetupFinished(error: error) { delegate.setUpWithAppPassword() } }
            }
            return
        }
    }

    private func deliverySetupFinished(error: String?, tryAgain: () -> Void) {
        rebuildMenuSoon()
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert()
        if let error {
            alert.messageText = "Couldn't turn on delivery alerts"
            alert.informativeText = error
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { tryAgain() }
        } else {
            alert.messageText = "Delivery alerts are on"
            let account = DeliveryWatcher.shared.email ?? ""
            alert.informativeText = (account.isEmpty ? "" : "Reading deliveries from \(account). ")
                + "Hammer will show a notification when a package is delivered. "
                + "If macOS asks, allow notifications from Hammer."
            alert.addButton(withTitle: "Done")
            alert.addButton(withTitle: "Send Test Notification")
            if alert.runModal() == .alertSecondButtonReturn { DeliveryWatcher.shared.sendTest() }
        }
    }

    @objc private func openDelivery(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        DeliveryWatcher.shared.open(key: key)
    }

    @objc private func checkDeliveriesNow() {
        DeliveryWatcher.shared.checkNow()
        rebuildMenuSoon()
    }

    @objc private func sendTestDelivery() {
        DeliveryWatcher.shared.sendTest()
    }

    @objc private func turnOffDeliveries() {
        DeliveryWatcher.shared.turnOff()
    }

    @objc private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Light modes (for the checkmarks)

    private enum LightMode: String { case warmWhite, daylight, nightLight, color }

    /// What each light is set to. Saved so restarts and updates keep the checkmarks.
    private var modes: [String: LightMode] {
        get {
            let saved = UserDefaults.standard.dictionary(forKey: "lightModes") as? [String: String] ?? [:]
            return saved.compactMapValues { LightMode(rawValue: $0) }
        }
        set { UserDefaults.standard.set(newValue.mapValues { $0.rawValue }, forKey: "lightModes") }
    }

    private func setMode(_ mode: LightMode, for targets: [GoveeLight]) {
        var all = modes
        var changed = false
        for light in targets where all[light.id] != mode {
            all[light.id] = mode
            changed = true
        }
        if changed {
            modes = all
            rebuildMenuSoon()
        }
    }

    /// The mode to check: a light's own, or for All Lights the one they all share.
    private func mode(forID id: String) -> LightMode? {
        let current = modes
        let shown = lightsMatching(id).map { current[$0.id] }
        guard let first = shown.first, let mode = first, shown.allSatisfy({ $0 == mode }) else { return nil }
        return mode
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Small gray instruction text.
    private func hint(_ text: String) -> NSMenuItem {
        let item = label(text)
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    @objc private func addCloudKey() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert()
        alert.messageText = "Govee cloud key"
        alert.informativeText = "Only needed for lights without LAN Control. Request an API key in the "
            + "Govee Home app's settings (Govee emails it to you), then paste it here."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Paste your API key"
        field.stringValue = Govee.apiKey ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try? Govee.saveAPIKey(key)
        rescanLights()
    }

    /// A clickable menu item. `lightID` nil means "all lights".
    private func action(_ title: String, _ selector: Selector, lightID: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        item.representedObject = lightID
        return item
    }

    private func sliderItem(_ title: String, range: ClosedRange<Double>, value: Double, action: Selector,
                            configure: (NSSlider) -> Void) -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 50))

        let text = NSTextField(labelWithString: title)
        text.frame = NSRect(x: 16, y: 28, width: 208, height: 16)

        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                              target: self, action: action)
        slider.frame = NSRect(x: 16, y: 6, width: 208, height: 20)
        slider.isContinuous = true
        configure(slider)

        view.addSubview(text)
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    /// Sliders fire dozens of events a second, so only send the latest value
    /// once the slider pauses briefly.
    private func schedule(_ key: String, on queue: DispatchQueue, after delay: Double,
                          _ work: @escaping () -> Void) {
        pending[key]?.cancel()
        let item = DispatchWorkItem(block: work)
        pending[key] = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: Monitor (the logic is in Monitor.swift, the macOS calls in MonitorMac.swift)

    private var monitorReadouts: [UInt8: NSTextField] = [:]   // each slider's "40%", by DDC code

    /// No DDC connection at all (not even macOS's default): the monitor can't be asked.
    private var noMonitorConnection: Bool { monitorCount == 0 && !monitorHasDefault }

    /// Finds the monitor's connection again (at launch and whenever screens
    /// change), then reads its brightness and contrast for the sliders.
    private func findMonitors() {
        let scan = MacMonitors.scan()
        monitors = scan.monitors
        monitorCount = monitors.members.filter { !$0.port.isDefault }.count
        monitorHasDefault = monitors.members.contains { $0.port.isDefault }
        monitorAttached = monitors.members.filter { $0.port.attached }.count
        let model = macModel
        monitorViaHDMIAdapter = monitors.members.contains { $0.port.attached && $0.port.throughHDMIAdapter(onMac: model) }
        monitorScreens = scan.screens
        monitorGeneration += 1
        monitorAnswers = nil
        monitorMisses = 0
        monitorReadAt = Date()               // not straight away: just after waking, monitors need a moment
        let generation = monitorGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard self.monitorGeneration == generation else { return }
            self.readMonitor(ifOlderThan: 0)
        }
        resumeSoftwareDimming()
    }

    /// Reads brightness and contrast in the background and moves the sliders to
    /// match, unless you've just moved one yourself.
    private func readMonitor(ifOlderThan seconds: TimeInterval) {
        if noMonitorConnection {
            // Nothing to ask: a direct external screen counts as not answering, and is dimmed in software.
            if monitorAnswers == nil && !dimmableScreens.isEmpty {
                monitorWasRead([:], answers: false, started: Date(), generation: monitorGeneration)
            }
            return
        }
        if let last = monitorReadAt, Date().timeIntervalSince(last) < seconds { return }
        let started = Date()
        monitorReadAt = started
        let set = monitors, generation = monitorGeneration, moves = sliderMoves
        ddcQueue.async {
            // Stops between tries if you move a slider, so your change goes out first.
            let stop = { moves.movedSince(started) }
            var values: [UInt8: (current: UInt16, max: UInt16)] = [:]
            if let brightness = set.read(code: DDCCode.brightness, stop: stop) {
                values[DDCCode.brightness] = brightness.reading
                if let contrast = brightness.member.link.read(code: DDCCode.contrast, stop: stop).reading {
                    values[DDCCode.contrast] = contrast
                }
            }
            let found = values
            let answers: Bool? = set.lastReadInterrupted ? nil : set.anyAnswers
            Task { @MainActor in
                self.monitorWasRead(found, answers: answers, started: started, generation: generation)
            }
        }
    }

    private func monitorWasRead(_ values: [UInt8: (current: UInt16, max: UInt16)], answers: Bool?,
                                started: Date, generation: Int) {
        guard generation == monitorGeneration else { return }      // the monitors changed meanwhile
        guard let answers else {                                    // interrupted: ask again next time
            monitorReadAt = nil
            return
        }
        let before = monitorAnswers
        monitorAnswers = answers
        monitorMisses = answers ? 0 : monitorMisses + 1
        for (code, value) in values {
            if let moved = monitorMoved[code], moved >= started { continue }   // you moved it since: yours wins
            monitorValues[code] = value
            if let slider = monitorSliders[code] { show(value, on: slider) }
        }
        let askAgain = updateSoftwareDimming()
        if before != answers || monitorMisses == 2 { rebuildMenuSoon() }   // "isn't answering", or dimming in software
        if askAgain { askMonitorAgain(generation: generation) }
    }

    /// After a first miss, asks again in 10 seconds: a monitor that still doesn't answer is
    /// then dimmed in software (and one that answers again, after a restart, is undimmed),
    /// rather than only once the menu is opened again.
    private func askMonitorAgain(generation: Int) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard self.monitorGeneration == generation, self.monitorMisses == 1 else { return }
            self.readMonitor(ifOlderThan: 5)
        }
    }

    private func addMonitor(to menu: NSMenu) {
        monitorSliders = [:]
        monitorReadouts = [:]
        softwareReadout = nil
        let software = softwareDimState
        shownDimState = software
        let state = MonitorMenu.make(connections: monitorCount, hasDefault: monitorHasDefault,
                                     attached: monitorAttached, screens: monitorScreens, answers: monitorAnswers,
                                     hdmiAdapter: monitorViaHDMIAdapter, software: software)
        if let title = state.title { menu.addItem(label(title)) }
        if state.sliders && software != .off {
            let level = softwareDimLevel
            let item = sliderItem("Brightness", range: 0...100, value: Double(level),
                                  action: #selector(softwareDimMoved(_:))) { _ in }
            softwareReadout = addReadout(to: item)
            softwareReadout?.stringValue = "\(level)%"
            menu.addItem(item)
        } else if state.sliders {
            menu.addItem(monitorSlider("Brightness", code: DDCCode.brightness))
            if state.contrast { menu.addItem(monitorSlider("Contrast", code: DDCCode.contrast)) }
        }
        for line in state.hints { menu.addItem(hint(line)) }
        if state.offerCheck { menu.addItem(checkMonitorItem()) }
    }

    private func monitorSlider(_ title: String, code: UInt8) -> NSMenuItem {
        let item = sliderItem(title, range: 0...100, value: 50, action: #selector(monitorSliderMoved(_:))) { slider in
            slider.tag = Int(code)
            monitorSliders[code] = slider
        }
        monitorReadouts[code] = addReadout(to: item)
        if let value = monitorValues[code], let slider = monitorSliders[code] { show(value, on: slider) }
        return item
    }

    /// The value on the right of a monitor slider's name ("Brightness   40%"), so you can
    /// see where it is, and that it moves.
    private func addReadout(to item: NSMenuItem) -> NSTextField? {
        guard let view = item.view else { return nil }
        let readout = NSTextField(labelWithString: "")
        readout.frame = NSRect(x: 16, y: 28, width: 208, height: 16)
        readout.alignment = .right
        readout.textColor = .secondaryLabelColor
        readout.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.addSubview(readout)
        return readout
    }

    private func show(_ value: (current: UInt16, max: UInt16), on slider: NSSlider) {
        slider.maxValue = Double(Swift.max(1, value.max))
        slider.doubleValue = Double(value.current)
        monitorReadouts[UInt8(slider.tag)]?.stringValue = MonitorMenu.readout(current: value.current, max: value.max)
    }

    @objc private func monitorSliderMoved(_ slider: NSSlider) {
        let code = UInt8(slider.tag)
        let value = UInt16(slider.doubleValue.rounded())
        monitorMoved[code] = Date()
        sliderMoves.moved()
        monitorValues[code] = (current: value, max: UInt16(slider.maxValue.rounded()))
        monitorReadouts[code]?.stringValue = MonitorMenu.readout(current: value, max: UInt16(slider.maxValue.rounded()))
        let set = monitors
        schedule("ddc-\(code)", on: ddcQueue, after: 0.05) {
            set.write(code: code, value: value)
        }
    }

    private func checkMonitorItem() -> NSMenuItem {
        checkingMonitor ? hint("Checking the monitor…") : action("Check Monitor Connection…", #selector(checkMonitor))
    }

    /// Tests each step to the monitor and says what's wrong, if anything.
    @objc private func checkMonitor() {
        guard !checkingMonitor else { return }
        checkingMonitor = true
        rebuildMenuSoon()
        let scan = MacMonitors.scan()
        ddcQueue.async {
            let found = MacMonitors.check(scan)
            Task { @MainActor in
                var check = found
                check.softwareDim = self.softwareDimState      // what dimming in software was doing meanwhile
                check.softwareDimLevel = self.softwareDimLevel
                self.checkingMonitor = false
                self.findMonitors()            // start fresh, in case something changed (e.g. DDC/CI turned on)
                self.rebuildMenuSoon()
                self.showMonitorCheck(check)
            }
        }
    }

    private func showMonitorCheck(_ check: MonitorCheck) {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert()
        alert.messageText = check.title
        alert.informativeText = check.advice.joined(separator: "\n")
            + (check.testNote.map { "\n\n" + $0 } ?? "")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let size = scroll.contentSize
        let text = NSTextView(frame: NSRect(origin: .zero, size: size))
        text.minSize = NSSize(width: 0, height: size.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.isEditable = false
        text.isSelectable = true
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = check.details                     // the result and advice are above it
        scroll.documentView = text
        alert.accessoryView = scroll

        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy Report")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(check.text, forType: .string)
        }
    }

    // MARK: Govee

    @objc private func rescanLights() {
        searchingForLights = true
        GoveeBluetooth.shared.rescan()
        GoveeBluetooth.shared.connectHeld()
        rebuildMenu()
        goveeQueue.async {
            let found = Govee.discover()
            Task { @MainActor in
                if !self.tourDemo { self.networkLights = found }
                self.searchingForLights = false
                self.rebuildMenu()
            }
        }
    }

    /// Stands in for "every light" wherever a light ID is expected.
    private let allLightsID = "all-lights"

    /// On or off as the bulbs themselves last reported, if they all agree.
    private func powerState(forID id: String) -> Bool? {
        let states = lightsMatching(id).map { light in light.bluetoothID.flatMap { GoveeBluetooth.shared.isOn($0) } }
        guard let first = states.first, let state = first, states.allSatisfy({ $0 == state }) else { return nil }
        return state
    }

    /// A line or two at the top of a light's menu when its Bluetooth link isn't right.
    private func addConnectionStatus(for light: GoveeLight?, to submenu: NSMenu) {
        let bluetooth = GoveeBluetooth.shared
        guard let light else {
            // All Lights: point at any bulb that's stuck.
            let stuck = lights.filter { light in
                light.bluetoothID.map { bluetooth.cantReach($0) || bluetooth.isIncompatible($0) } ?? false
            }
            guard !stuck.isEmpty else { return }
            submenu.addItem(hint(stuck.count == 1 ? "1 bulb can't be reached right now;"
                                                  : "\(stuck.count) bulbs can't be reached right now;"))
            submenu.addItem(hint("open it in the list for what to do."))
            submenu.addItem(.separator())
            return
        }
        guard let ble = light.bluetoothID else { return }
        if bluetooth.isIncompatible(ble) {
            submenu.addItem(hint("This bulb answered but doesn't accept Hammer's"))
            submenu.addItem(hint("commands, so Hammer let it go. Was its firmware just"))
            submenu.addItem(hint("updated in the Govee app? Tell Claude the new version."))
        } else if bluetooth.cantReach(ble) {
            submenu.addItem(hint("Can't reach this bulb right now. If the Govee app on"))
            submenu.addItem(hint("your phone has it, force-quit the app; Hammer connects"))
            submenu.addItem(hint("by itself the moment it's free. Also check the switch."))
        } else if bluetooth.isConnected(ble) {
            submenu.addItem(hint(bluetooth.isAnswering(ble) ? "Connected and responding" : "Connected"))
        } else {
            submenu.addItem(hint("Connecting…"))
        }
        submenu.addItem(.separator())
    }

    /// One light's submenu, or the "All Lights" submenu when `light` is nil.
    /// Both have the same controls.
    private func lightItem(_ light: GoveeLight?) -> NSMenuItem {
        let id = light?.id ?? allLightsID
        let submenu = NSMenu()
        addConnectionStatus(for: light, to: submenu)
        let power = powerState(forID: id)              // ✓ from what the bulb itself reports
        submenu.addItem(checked(action("Turn On", #selector(turnOn(_:)), lightID: id), power == true))
        submenu.addItem(checked(action("Turn Off", #selector(turnOff(_:)), lightID: id), power == false))
        submenu.addItem(sliderItem("Brightness", range: 0...100, value: levels[id] ?? 100,
                                   action: #selector(lightSliderMoved(_:))) { slider in
            slider.identifier = NSUserInterfaceItemIdentifier(id)
        })
        submenu.addItem(.separator())
        let current = mode(forID: id)                  // ✓ next to what the light is set to
        submenu.addItem(checked(action("Choose Color…", #selector(chooseColor(_:)), lightID: id), current == .color))
        submenu.addItem(checked(action("Warm White", #selector(warmWhite(_:)), lightID: id), current == .warmWhite))
        submenu.addItem(checked(action("Daylight", #selector(daylight(_:)), lightID: id), current == .daylight))
        submenu.addItem(checked(action("Night Light", #selector(nightLight(_:)), lightID: id), current == .nightLight))
        if light != nil {
            submenu.addItem(.separator())
            submenu.addItem(action("Blink to Identify", #selector(blink(_:)), lightID: id))
            submenu.addItem(action("Rename…", #selector(renameLight(_:)), lightID: id))
            submenu.addItem(action("Remove from My Lights", #selector(removeFromMyLights(_:)), lightID: id))
        }

        // The sleep timer turns off all your lights, so it lives in All Lights —
        // or in the one light's menu when there's only one (and no All Lights).
        let hasTimer = light == nil || lights.count == 1
        if hasTimer {
            addSleepTimer(to: submenu)
            addTurnOnTime(to: submenu)
        }

        var title: String
        if let light {
            var route = light.routeLabel
            if let ble = light.bluetoothID,
               GoveeBluetooth.shared.cantReach(ble) || GoveeBluetooth.shared.isIncompatible(ble) {
                route = "can't reach"
            }
            title = route.isEmpty ? light.name : "\(light.name) · \(route)"
        } else {
            title = "All Lights (\(lights.count))"
        }
        if hasTimer, let end = timerEnd { title += " · off at \(clockTime(end))" }
        if hasTimer, let next = turnOnNext { title += " · on at \(clockTime(next))" }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func lightsMatching(_ id: String?) -> [GoveeLight] {
        guard let id, id != allLightsID else { return lights }
        return lights.filter { $0.id == id }
    }

    private func targetLights(_ sender: NSMenuItem) -> [GoveeLight] {
        lightsMatching(sender.representedObject as? String)
    }

    /// Cloud lights accept about 2 commands a second, so wait longer before sending to them.
    private func delay(for light: GoveeLight) -> Double { light.routeLabel == "cloud" ? 0.5 : 0.08 }

    @objc private func turnOn(_ sender: NSMenuItem) {
        let targets = targetLights(sender)
        goveeQueue.async { targets.forEach { Govee.setPower($0, on: true) } }
    }

    @objc private func turnOff(_ sender: NSMenuItem) {
        let targets = targetLights(sender)
        goveeQueue.async { targets.forEach { Govee.setPower($0, on: false) } }
    }

    // MARK: Brightness and color
    //
    // The Brightness slider is the bulb's own brightness, 1–100%, and nothing
    // else: it never sends a color. (Faking "dimmer than 1%" by darkening the
    // color shifts it toward red, because the green and blue LEDs cut out first.)

    private var levels: [String: Double] = [:]      // slider position per light (and for All Lights)

    @objc private func lightSliderMoved(_ slider: NSSlider) {
        guard let id = slider.identifier?.rawValue else { return }
        let level = slider.doubleValue
        levels[id] = level
        for light in lightsMatching(id) { applyLevel(level, to: light) }
        // Brightening a Night Light makes it plain Warm White.
        if level >= 2 {
            let current = modes
            let raised = lightsMatching(id).filter { current[$0.id] == .nightLight }
            if !raised.isEmpty { setMode(.warmWhite, for: raised) }
        }
    }

    private func applyLevel(_ level: Double, to light: GoveeLight) {
        levels[light.id] = level
        let percent = max(1, Int(level.rounded()))
        schedule("level-\(light.id)", on: goveeQueue, after: delay(for: light)) {
            Govee.setPower(light, on: true)        // adjusting a light that's off turns it on
            Govee.setBrightness(light, percent)
        }
    }

    /// Changes the lights' color; brightness stays where it is.
    private func setLook(_ look: LightLook, for targets: [GoveeLight]) {
        for light in targets {
            schedule("look-\(light.id)", on: goveeQueue, after: delay(for: light)) {
                Govee.setPower(light, on: true)
                look.apply(to: light)
            }
        }
    }

    @objc private func warmWhite(_ sender: NSMenuItem) {
        setLook(.white(2700), for: targetLights(sender))
        setMode(.warmWhite, for: targetLights(sender))
    }

    @objc private func daylight(_ sender: NSMenuItem) {
        setLook(.white(6500), for: targetLights(sender))
        setMode(.daylight, for: targetLights(sender))
    }

    /// The dimmest the bulb goes without changing color: warm white at 1%.
    @objc private func nightLight(_ sender: NSMenuItem) {
        let targets = targetLights(sender)
        if let id = sender.representedObject as? String { levels[id] = 0 }
        setLook(.white(2700), for: targets)
        for light in targets { applyLevel(0, to: light) }
        setMode(.nightLight, for: targets)
        rebuildMenu()                                  // move the sliders to the far left
    }

    @objc private func chooseColor(_ sender: NSMenuItem) {
        colorTargetID = sender.representedObject as? String
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.isContinuous = true
        panel.showsAlpha = false            // opacity means nothing for a bulb
        // A menu bar app has to bring itself forward before the panel will show.
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        panel.makeKeyAndOrderFront(nil)
    }

    /// The picker chooses the color only (hue and saturation, at full strength);
    /// brightness stays on the Brightness slider, so the two never fight.
    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let id = colorTargetID, let color = panel.color.usingColorSpace(.sRGB) else { return }
        var hue: CGFloat = 0, saturation: CGFloat = 0, value: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha)
        let vivid = NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: 1, alpha: 1)

        func byte(_ component: CGFloat) -> Int { min(max(Int((component * 255).rounded()), 0), 255) }
        setLook(.color(byte(vivid.redComponent), byte(vivid.greenComponent), byte(vivid.blueComponent)),
                for: lightsMatching(id))
        setMode(.color, for: lightsMatching(id))
    }

    // MARK: Sleep timer

    /// Times on the timer slider, in minutes.
    private static let timerSteps = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360, 480]
    private var timerChoice = 30                      // what the slider is set to
    private var timerChoiceLabel: NSTextField?
    private var timerCheck: Timer?
    private var stayAwake: NSObjectProtocol?

    /// When your lights go off. Saved so a restart (like an update) keeps it.
    private var timerEnd: Date? {
        get { UserDefaults.standard.object(forKey: "lightsOffAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lightsOffAt") }
    }


    private func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The sleep timer section at the bottom of All Lights.
    private func addSleepTimer(to submenu: NSMenu) {
        submenu.addItem(.separator())
        submenu.addItem(label("Sleep Timer"))
        if let end = timerEnd {
            submenu.addItem(hint("Your lights go off at \(clockTime(end))."))
            submenu.addItem(action("Cancel Timer", #selector(cancelTimer)))
        }
        submenu.addItem(timerPicker())
        submenu.addItem(action(timerEnd == nil ? "Start Timer" : "Restart Timer", #selector(startTimer)))
        submenu.addItem(hint("The Mac stays awake until then, but"))
        submenu.addItem(hint("closing the lid still puts it to sleep."))
    }

    /// A slider that snaps to the times in `timerSteps`, with the choice shown above it.
    private func timerPicker() -> NSMenuItem {
        let steps = Self.timerSteps
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))

        let text = NSTextField(labelWithString: "Turn off in \(TimerText.describe(minutes: timerChoice))")
        text.frame = NSRect(x: 16, y: 32, width: 228, height: 16)
        timerChoiceLabel = text

        let slider = NSSlider(value: Double(steps.firstIndex(of: timerChoice) ?? 4),
                              minValue: 0, maxValue: Double(steps.count - 1),
                              target: self, action: #selector(timerSliderMoved(_:)))
        slider.numberOfTickMarks = steps.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.frame = NSRect(x: 16, y: 4, width: 228, height: 26)

        view.addSubview(text)
        view.addSubview(slider)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @objc private func timerSliderMoved(_ slider: NSSlider) {
        let index = min(max(Int(slider.doubleValue.rounded()), 0), Self.timerSteps.count - 1)
        timerChoice = Self.timerSteps[index]
        timerChoiceLabel?.stringValue = "Turn off in \(TimerText.describe(minutes: timerChoice))"
    }

    @objc private func startTimer() {
        timerEnd = Date().addingTimeInterval(TimeInterval(timerChoice * 60))
        armTimer()
        rebuildMenu()
    }

    @objc private func cancelTimer() {
        timerEnd = nil
        armTimer()
        rebuildMenu()
    }

    /// Checks the clock every 20 seconds rather than setting one long timer,
    /// because a long timer can fire late if the Mac sleeps. While a timer is
    /// set, idle sleep is held off so the Mac is awake to send the command.
    private func armTimer() {
        timerCheck?.invalidate()
        timerCheck = nil
        if let activity = stayAwake {
            ProcessInfo.processInfo.endActivity(activity)
            stayAwake = nil
        }
        guard timerEnd != nil else { return }

        stayAwake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                           reason: "Hammer sleep timer")
        let check = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            guard let delegate = self else { return }
            Task { @MainActor in delegate.checkTimer() }
        }
        RunLoop.main.add(check, forMode: .common)     // keeps ticking while the menu is open
        timerCheck = check
        checkTimer()
    }

    func checkTimer() {
        guard let end = timerEnd, Date() >= end else { return }
        let targets = lights
        goveeQueue.async { targets.forEach { Govee.setPower($0, on: false) } }
        timerEnd = nil
        armTimer()
        rebuildMenu()
    }

    // MARK: Turn on at a set time

    private let defaults = UserDefaults.standard
    private var clock: Timer?

    /// The next time your lights turn on, and the time of day it repeats at.
    /// Saved so restarts and updates keep the schedule.
    private var turnOnNext: Date? {
        get { defaults.object(forKey: "turnOnNext") as? Date }
        set { defaults.set(newValue, forKey: "turnOnNext") }
    }
    private var turnOnHour: Int { defaults.integer(forKey: "turnOnHour") }
    private var turnOnMinute: Int { defaults.integer(forKey: "turnOnMinute") }
    private var turnOnRepeats: Bool { defaults.bool(forKey: "turnOnRepeats") }
    private var turnOnWakesMac: Bool { defaults.bool(forKey: "turnOnWakesMac") }

    private func addTurnOnTime(to submenu: NSMenu) {
        submenu.addItem(.separator())
        submenu.addItem(label("Turn On At"))
        if let next = turnOnNext {
            let when = turnOnRepeats ? "every day at \(clockTime(next))" : "at \(clockTime(next))"
            submenu.addItem(hint("Your lights turn on \(when)."))
            if turnOnWakesMac { submenu.addItem(hint("Your Mac wakes a minute before.")) }
            submenu.addItem(action("Change Time…", #selector(setTurnOnTime)))
            submenu.addItem(action("Remove", #selector(removeTurnOnTime)))
        } else {
            submenu.addItem(action("Set a Time…", #selector(setTurnOnTime)))
        }
    }

    /// Checks the schedule every 30 seconds and right after the Mac wakes.
    private func startClock() {
        let tick = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let delegate = self else { return }
            Task { @MainActor in delegate.checkTurnOn() }
        }
        RunLoop.main.add(tick, forMode: .common)
        clock = tick
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(macWoke),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensWoke),
                                                          name: NSWorkspace.screensDidWakeNotification, object: nil)
        checkTurnOn()
    }

    @objc private func macWoke() {
        // Give Bluetooth a few seconds to come back before sending anything.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let delegate = self else { return }
            Task { @MainActor in
                delegate.checkTurnOn()
                delegate.checkTimer()
                delegate.reapplyIfDimming()                 // macOS resets screens' color curves on wake
            }
        }
    }

    func checkTurnOn() {
        guard let next = turnOnNext, Date() >= next else { return }
        // Skip it if the Mac was asleep and it's now more than 30 minutes late.
        if Date().timeIntervalSince(next) < 30 * 60 {
            let targets = lights
            goveeQueue.async { targets.forEach { Govee.setPower($0, on: true) } }
        }
        turnOnNext = turnOnRepeats ? nextOccurrence(hour: turnOnHour, minute: turnOnMinute) : nil
        rebuildMenuSoon()
    }

    private func nextOccurrence(hour: Int, minute: Int) -> Date? {
        Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: hour, minute: minute, second: 0),
                                  matchingPolicy: .nextTime)
    }

    @objc private func setTurnOnTime() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }

        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .hourMinute
        picker.dateValue = turnOnNext ?? nextOccurrence(hour: 7, minute: 0) ?? Date()
        picker.frame = NSRect(x: 0, y: 54, width: 110, height: 24)

        let everyDay = NSButton(checkboxWithTitle: "Every day", target: nil, action: nil)
        everyDay.state = (turnOnNext == nil || turnOnRepeats) ? .on : .off
        everyDay.frame = NSRect(x: 0, y: 28, width: 320, height: 20)

        let wake = NSButton(checkboxWithTitle: "Wake my Mac for this (asks for your password)",
                            target: nil, action: nil)
        wake.state = (turnOnNext == nil || turnOnWakesMac) ? .on : .off
        wake.frame = NSRect(x: 0, y: 2, width: 340, height: 20)

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 80))
        box.addSubview(picker)
        box.addSubview(everyDay)
        box.addSubview(wake)

        let alert = NSAlert()
        alert.messageText = "Turn your lights on at"
        alert.informativeText = "They come back with the color and brightness they last had. "
            + "Your Mac needs to be awake then, and it can't wake with the lid closed on battery."
        alert.accessoryView = box
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let parts = Calendar.current.dateComponents([.hour, .minute], from: picker.dateValue)
        let hour = parts.hour ?? 7, minute = parts.minute ?? 0
        let repeats = everyDay.state == .on
        defaults.set(hour, forKey: "turnOnHour")
        defaults.set(minute, forKey: "turnOnMinute")
        defaults.set(repeats, forKey: "turnOnRepeats")
        turnOnNext = nextOccurrence(hour: hour, minute: minute)

        if wake.state == .on, let next = turnOnNext {
            defaults.set(scheduleMacWake(before: next, everyDay: repeats), forKey: "turnOnWakesMac")
        } else {
            defaults.set(false, forKey: "turnOnWakesMac")
        }
        rebuildMenu()
    }

    @objc private func removeTurnOnTime() {
        if turnOnWakesMac && turnOnRepeats {
            runAsAdmin("/usr/bin/pmset repeat cancel")     // stop the daily wake too
        }
        turnOnNext = nil
        defaults.set(false, forKey: "turnOnWakesMac")
        rebuildMenu()
    }

    /// Asks macOS to wake the Mac a minute before `date` (needs your password once).
    /// A daily wake replaces any other repeating wake schedule on this Mac.
    private func scheduleMacWake(before date: Date, everyDay: Bool) -> Bool {
        let wakeAt = date.addingTimeInterval(-60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if everyDay {
            formatter.dateFormat = "HH:mm:ss"
            return runAsAdmin("/usr/bin/pmset repeat wake MTWRFSU \(formatter.string(from: wakeAt))")
        } else {
            formatter.dateFormat = "MM/dd/yy HH:mm:ss"
            return runAsAdmin("/usr/bin/pmset schedule wake '\(formatter.string(from: wakeAt))'")
        }
    }

    /// Runs a command with administrator rights, using macOS's standard password prompt.
    @discardableResult
    private func runAsAdmin(_ command: String) -> Bool {
        let source = "do shell script \"\(command)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    // MARK: Telling lights apart

    /// Lights that aren't yours yet, each with how far away it seems and a way to add it.
    private func otherLightsItem(_ others: [GoveeLight]) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.addItem(hint("Hammer never controls these, not even with"))
        submenu.addItem(hint("All Lights. Add the ones that are yours."))
        submenu.addItem(.separator())
        for light in others {
            let options = NSMenu()
            if let ble = light.bluetoothID, let distance = GoveeBluetooth.shared.distance(of: ble) {
                options.addItem(hint("Signal: \(distance)"))
            }
            options.addItem(action("Add to My Lights", #selector(addToMyLights(_:)), lightID: light.id))
            options.addItem(action("Blink to Identify", #selector(blink(_:)), lightID: light.id))
            options.addItem(hint("Blinking flashes this bulb wherever it is."))
            let item = NSMenuItem(title: light.name, action: nil, keyEquivalent: "")
            item.submenu = options
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Other Lights (\(others.count))", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Flashes the light off and on twice so you can see which one it is.
    @objc private func blink(_ sender: NSMenuItem) {
        // Works on your lights and on Other Lights (to check which bulb one is).
        guard let id = sender.representedObject as? String else { return }
        let targets = foundLights.filter { $0.id == id }
        goveeQueue.async {
            targets.forEach { Govee.setPower($0, on: true) }   // wakes a sleeping Bluetooth link first
            usleep(1_500_000)
            for on in [false, true, false, true] {
                targets.forEach { Govee.setPower($0, on: on) }
                usleep(700_000)
            }
        }
    }

    @objc private func renameLight(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let light = lights.first(where: { $0.id == id }) else { return }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert()
        alert.messageText = "Rename light"
        alert.informativeText = "Not sure which bulb this is? Use Blink to Identify first."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = light.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = customNames
        names[id] = name.isEmpty ? nil : name        // an empty name goes back to the original
        customNames = names
        rebuildMenu()
    }

    @objc private func addToMyLights(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let light = foundLights.first(where: { $0.id == id }) else { return }
        if isBluetoothOnly(light) {
            var mine = myBluetoothIDs
            mine.insert(id)
            myBluetoothIDs = mine
            GoveeBluetooth.shared.hold(heldBluetoothIDs)   // connect to it, or let it go
        } else {
            var hidden = hiddenIDs
            hidden.remove(id)
            hiddenIDs = hidden
        }
        rebuildMenu()
    }

    /// Moves a light to Other Lights, where Hammer won't control it.
    @objc private func removeFromMyLights(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let light = foundLights.first(where: { $0.id == id }) else { return }
        if isBluetoothOnly(light) {
            var mine = myBluetoothIDs
            mine.remove(id)
            myBluetoothIDs = mine
            GoveeBluetooth.shared.hold(heldBluetoothIDs)   // connect to it, or let it go
        } else {
            var hidden = hiddenIDs
            hidden.insert(id)
            hiddenIDs = hidden
        }
        rebuildMenu()
    }

    // MARK: Updates

    /// Asks the background updater to run now. If there's a new version, it
    /// rebuilds and restarts Hammer; otherwise a notification says it's up to date.
    /// The updater must run as its own job, not as part of Hammer, or it would be
    /// stopped along with the old Hammer halfway through the update.
    @objc private func checkForUpdates() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let script = home.appendingPathComponent("Hammer/repo/update.sh").path
        guard FileManager.default.fileExists(atPath: script) else {
            if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
            let alert = NSAlert()
            alert.messageText = "Automatic updates aren't set up yet"
            alert.informativeText = "Paste this into Terminal once to turn them on:\n\n"
                + "curl -fsSL https://raw.githubusercontent.com/ohmychael/hammer-/main/install-hammer.sh | bash"
            alert.runModal()
            return
        }
        if Updates.shared.off != nil {
            Updates.shared.turnOn { Updates.shared.checkNow() }
        } else {
            Updates.shared.checkNow()
        }
    }

    /// "Updates are off · Turn On…" (or opening at login): a login item was switched off.
    @objc private func turnOnLoginItems() { Updates.shared.turnOn() }

    /// The end of the menu: how to open it, updates, and the version.
    private func addUpdates(to menu: NSMenu) {
        if iconHidden { menu.addItem(action("Menu Bar Icon Is Hidden…", #selector(explainHiddenIcon))) }
        // No hot key reference means Control-Option-H didn't register (another app has it).
        menu.addItem(hint(hotKeyRef == nil ? "Another app has Control-Option-H, so open Hammer from Spotlight."
                                           : "Open this menu anywhere: Control-Option-H"))
        let updates = Updates.shared
        if let off = updates.off { menu.addItem(action(off + " · Turn On…", #selector(turnOnLoginItems))) }
        menu.addItem(action("Check for Updates", #selector(checkForUpdates)))
        if let line = updates.menuLine { menu.addItem(hint(line)) }
        menu.addItem(hint("Version " + Self.versionText))
    }
}

// MARK: - Entry point

@main
enum Hammer {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let command = args.first {
            switch command {
            case "get", "set": exit(runMonitorCommand(args))
            case "monitor": exit(runMonitorCheck(args))
            case "dim-check": exit(runDimCheck())
            case "player-check": PlayerCheck.run(args)
            case "edge-check": EdgeCheck.run()
            case "tour":
                guard args.count >= 2 else { print("usage: Hammer tour <folder> [--demo]"); exit(2) }
                let demo = args.contains("--demo")
                // The stand-in data goes into Hammer's settings, so only on a build server.
                if demo && ProcessInfo.processInfo.environment["CI"] != "true" {
                    print("--demo only runs on a build server (it would change your settings).")
                    exit(2)
                }
                AppDelegate.tour = (URL(fileURLWithPath: args[1]), demo)
                if demo { AppDelegate.writeTourDeliveries() }
            case "govee": exit(runGoveeCommand(Array(args.dropFirst())))
            case "make-icon":
                guard args.count >= 2 else { print("usage: Hammer make-icon <folder>"); exit(2) }
                exit(AppIcon.write(to: URL(fileURLWithPath: args[1])) ? 0 : 1)
            case "help", "--help", "-h":
                print(usage)
                exit(0)
            default:
                // Only the menu bar app itself starts from here (no arguments, or --login).
                guard Launch.startsMenuBarApp(args) else { print(usage); exit(2) }
            }
        }
        AppDelegate.openedByYou = AppDelegate.tour == nil && !Launch.atLogin(args)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)     // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }

    static let usage = """
        usage: Hammer                          the menu bar app
               Hammer get <brightness|contrast|volume|hex code>
               Hammer set <brightness|contrast|volume|hex code> <value>
               Hammer monitor check
               Hammer govee list | on | off | brightness <1-100> | key <API key>
        """

    static func runMonitorCommand(_ args: [String]) -> Int32 {
        guard args.count >= 2, let code = DDCCode.parse(args[1]) else {
            print("usage: Hammer get <brightness|contrast|volume|hex code>")
            print("       Hammer set <brightness|contrast|volume|hex code> <value>")
            print("       Hammer monitor check")
            return 2
        }
        let monitors = MacMonitors.scan().monitors
        guard !monitors.members.isEmpty else {
            print("No monitor connection found. Run: ~/Hammer/Hammer monitor check")
            return 1
        }

        if args[0] == "get" {
            guard let found = monitors.read(code: code) else {
                print(monitors.lastReadUnsupported
                      ? "The monitor says it has no such setting."
                      : "The monitor didn't answer. Run: ~/Hammer/Hammer monitor check")
                return 1
            }
            print("\(found.reading.current) (max \(found.reading.max))")
        } else {
            guard args.count >= 3, let value = UInt16(args[2]) else {
                print("Give a number to set, e.g. Hammer set brightness 40")
                return 2
            }
            _ = monitors.read(code: code)            // learns which connection answers, so it goes there
            guard monitors.write(code: code, value: value) else {
                print("macOS wouldn't send it. Run: ~/Hammer/Hammer monitor check")
                return 1
            }
            if monitors.anyAnswers {
                let names = Set(monitors.targets.map { $0.port.name ?? "the monitor" })
                print("Sent to \(names.sorted().joined(separator: ", ")).")
            } else {
                print("Sent, but the monitor isn't answering, so Hammer can't confirm it took it."
                      + " Run: ~/Hammer/Hammer monitor check")
            }
        }
        return 0
    }

    /// `Hammer monitor check`: tests each step to the monitor and says what's wrong.
    static func runMonitorCheck(_ args: [String]) -> Int32 {
        guard args.count >= 2, args[1] == "check" else {
            print("usage: Hammer monitor check")
            return 2
        }
        print("Checking the monitor (its brightness may change for a moment)…\n")
        let check = MacMonitors.check(MacMonitors.scan())
        print(check.text)
        return check.verdict == .working ? 0 : 1
    }

    static func runGoveeCommand(_ args: [String]) -> Int32 {
        let usage = "usage: Hammer govee list | on | off | brightness <1-100> | key <API key>"
        let command = args.first ?? ""

        if command == "key" {
            guard args.count >= 2 else { print(usage); return 2 }
            do {
                try Govee.saveAPIKey(args[1])
                print("Saved to \(Govee.keyFile.path)")
                return 0
            } catch {
                print("Couldn't save the key: \(error.localizedDescription)")
                return 1
            }
        }

        guard ["list", "on", "off", "brightness"].contains(command) else { print(usage); return 2 }
        var percent = 0
        if command == "brightness" {
            guard args.count >= 2, let value = Int(args[1]) else { print(usage); return 2 }
            percent = value
        }

        let lights = Govee.discover()
        if lights.isEmpty {
            print("No lights found. Turn on LAN Control for each light in the Govee Home app,")
            print("or save a cloud API key with: Hammer govee key <API key>")
            return 1
        }

        switch command {
        case "list":
            for light in lights {
                let route = light.lanIP.map { "local \($0)" } ?? "cloud"
                print("\(light.name)  [\(light.sku)]  \(route)")
            }
        case "on", "off":
            lights.forEach { Govee.setPower($0, on: command == "on") }
            print("Done.")
        default:
            lights.forEach { Govee.setBrightness($0, percent) }
            print("Done.")
        }
        return 0
    }
}

// MARK: - Tour (`Hammer tour <folder> [--demo]`, run by the macOS build check)

/// Opens the real menu, each submenu, the dialogs and the YouTube dropdown, and
/// takes a screenshot of each, so the build check shows what Hammer looks like.
/// `--demo` (build servers only) first fills in stand-in lights, a monitor that
/// can only be dimmed in software, and a few deliveries, like the real setup.
extension AppDelegate {
    private struct TourStep {
        let name: String
        let wait: Double                    // seconds before the picture
        let open: () -> Void
        let close: () -> Void
    }

    /// Stand-in deliveries, written before Hammer starts (build servers only).
    static func writeTourDeliveries() {
        let now = Date()
        let deliveries = [
            Delivery(kind: .delivered, store: "eBay", item: "Belkin USB-C to DisplayPort Adapter", subject: "",
                     messageID: "<tour1@example.com>", date: now.addingTimeInterval(-3600), uid: 1),
            Delivery(kind: .delivered, store: "Amazon", item: "Anker 735 Charger", subject: "",
                     messageID: "<tour2@example.com>", date: now.addingTimeInterval(-86_400 * 2), uid: 2),
            Delivery(kind: .problem, store: "UPS", item: "Delivery attempted", subject: "",
                     messageID: "<tour3@example.com>", date: now.addingTimeInterval(-86_400 * 3), uid: 3),
        ]
        UserDefaults.standard.set("appPassword", forKey: "deliverySource")
        UserDefaults.standard.set("you@gmail.com", forKey: "deliveryEmail")
        if let data = try? JSONEncoder().encode(deliveries) { UserDefaults.standard.set(data, forKey: "recentDeliveries") }
    }

    private func applyTourDemo() {
        networkLights = [
            GoveeLight(id: "D1:7A:A4:C1:38:42:11:90", sku: "H6159", name: "Desk Strip", lanIP: "192.168.1.40"),
            GoveeLight(id: "C3:12:A4:C1:38:9B:20:4E", sku: "H6006", name: "Bedroom Bulb", lanIP: nil),
            GoveeLight(id: "A8:55:A4:C1:38:61:7F:02", sku: "H6006", name: "Hallway Bulb", lanIP: nil),
        ]
        let nearby = UUID(uuidString: "6F1C2B9A-5D3E-4A7B-9C10-2E8F4D6A1B3C")!
        bluetoothLights = [GoveeLight(id: nearby.uuidString, sku: "H6006", name: "H6006", lanIP: nil, bluetoothID: nearby)]
        searchingForLights = false
        // The Dell on HDMI through a USB-C adapter: it doesn't answer, so the picture is dimmed.
        monitorCount = 1
        monitorAttached = 1
        monitorViaHDMIAdapter = true
        monitorAnswers = false
        monitorMisses = 1
        monitorScreens = [MonitorScreen(id: CGMainDisplayID(), name: "DELL U3818DW", builtIn: false,
                                        framebuffer: 300, direct: true)]
        dimmingInSoftware = true
        rebuildMenu()
    }

    func startTour() {
        guard let tour = Self.tour else { return }
        Self.tourLog("tour: starting (demo: \(tour.demo))")
        try? FileManager.default.createDirectory(at: tour.folder, withIntermediateDirectories: true)
        if tour.demo { applyTourDemo() }
        let prefix = tour.demo ? "demo" : "plain"
        var steps: [TourStep] = []

        // The menu, as you see it when you click the hammer: right under the icon.
        steps.append(TourStep(name: "\(prefix)-01-menu", wait: 1.5, open: { [weak self] in
            guard let self, let menu = self.statusItem.menu else { return }
            let icon = self.statusItem.button?.window?.frame ?? NSRect(x: 900, y: 740, width: 24, height: 24)
            menu.popUp(positioning: nil, at: NSPoint(x: icon.minX, y: icon.minY - 2), in: nil)
        }, close: { [weak self] in self?.statusItem.menu?.cancelTracking() }))
        // Each submenu, opened on its own near the menu bar.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 740)
        let spot = NSPoint(x: screen.maxX - 330, y: screen.maxY - 8)
        var number = 2
        for item in statusItem.menu?.items ?? [] {
            guard let submenu = item.submenu else { continue }
            let title = item.title.isEmpty ? "item" : item.title
            let safe = String(title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            steps.append(TourStep(name: String(format: "\(prefix)-%02d-sub-\(safe)", number), wait: 1.2,
                                  open: {
                                      item.submenu = nil            // a menu can only be in one place
                                      submenu.popUp(positioning: nil, at: spot, in: nil)
                                      item.submenu = submenu
                                  },
                                  close: { submenu.cancelTracking() }))
            number += 1
        }
        if tour.demo {
            // Dialogs.
            let modalClose = { if NSApp.modalWindow != nil { NSApp.abortModal() } }
            steps.append(TourStep(name: "demo-20-turn-on-at", wait: 2,
                                  open: { [weak self] in self?.setTurnOnTime() }, close: modalClose))
            steps.append(TourStep(name: "demo-21-rename", wait: 2, open: { [weak self] in
                let item = NSMenuItem()
                item.representedObject = self?.lights.first?.id
                self?.renameLight(item)
            }, close: modalClose))
            steps.append(TourStep(name: "demo-22-delivery-setup", wait: 2,
                                  open: { [weak self] in self?.setUpDeliveries() }, close: modalClose))
        } else {
            steps.append(TourStep(name: "plain-20-monitor-check", wait: 12,
                                  open: { [weak self] in self?.checkMonitor() },
                                  close: { if NSApp.modalWindow != nil { NSApp.abortModal() } }))
            steps.append(TourStep(name: "plain-21-youtube-dropdown", wait: 12,
                                  open: { [weak self] in self?.player.showDropdown() },
                                  close: { [weak self] in self?.player.putAway() }))
        }
        runTour(steps)
    }

    private func runTour(_ steps: [TourStep]) {
        guard let step = steps.first, let folder = Self.tour?.folder else {
            print("Tour finished.")
            exit(0)
        }
        let rest = Array(steps.dropFirst())
        // A timer in every run loop mode, so it fires while a menu or dialog is up. Main-run-loop
        // timers fire on the main thread, so it can act straight away (no hop that a menu might hold up).
        Self.tourLog("tour: \(step.name): opening")
        let timer = Timer(timeInterval: step.wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.screenshot(folder.appendingPathComponent(step.name + ".png"))
                Self.tourLog("tour: \(step.name): picture taken")
                step.close()
                let next = Timer(timeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated { self?.runTour(rest) }
                }
                RunLoop.main.add(next, forMode: .common)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        step.open()                                   // returns at once, or once the menu or dialog is closed
        Self.tourLog("tour: \(step.name): open returned")
    }

    nonisolated private static func tourLog(_ text: String) {
        print(text)
        fflush(stdout)
    }

    nonisolated private static func screenshot(_ url: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", url.path]
        try? task.run()
        task.waitUntilExit()
    }
}
