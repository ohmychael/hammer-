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
// Build by hand:  swiftc -parse-as-library -O Hammer.swift -o Hammer
// Run:    ./Hammer                        menu bar app (hammer icon)
//         If the icon is hidden behind the notch, open Hammer from Apps or
//         Spotlight, or press Control-Option-H: the menu appears at the pointer.
//
// Monitor from Terminal:
//         ./Hammer get brightness         read a value from the monitor
//         ./Hammer set brightness 40      write a value
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

// MARK: - Private IOKit calls (monitor)
//
// macOS has no public API for talking to a display over I²C on Apple Silicon.
// These three functions live inside IOKit but aren't in any header, so we
// declare them ourselves. MonitorControl, m1ddc and BetterDisplay all use them.

typealias IOAVService = CFTypeRef

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<IOAVService>?

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: IOAVService, _ chipAddress: UInt32, _ offset: UInt32,
                        _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: IOAVService, _ chipAddress: UInt32, _ dataAddress: UInt32,
                         _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

// MARK: - Finding the monitor

/// One handle per external display. A MacBook's built-in screen reports
/// Location = "Embedded" and is skipped.
func externalDisplays() -> [IOAVService] {
    var displays: [IOAVService] = []
    var iterator = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"),
                                       &iterator) == KERN_SUCCESS else { return displays }
    defer { IOObjectRelease(iterator) }

    var entry = IOIteratorNext(iterator)
    while entry != 0 {
        let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if location == "External",
           let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() {
            displays.append(service)
        }
        IOObjectRelease(entry)
        entry = IOIteratorNext(iterator)
    }
    return displays
}

// MARK: - DDC/CI protocol (VESA MCCS)
//
// The monitor listens on I²C address 0x37. Each message from the Mac is:
// a length byte (0x80 | n), an opcode, the payload, and an XOR checksum that
// also covers the bus addresses 0x6E (monitor) and 0x51 (Mac).

enum DDC {
    static let monitorAddress: UInt32 = 0x37
    static let hostAddress: UInt32 = 0x51

    /// Standard MCCS "VCP" feature codes.
    static let codes: [String: UInt8] = ["brightness": 0x10, "contrast": 0x12, "volume": 0x62]

    static func checksum(_ bytes: ArraySlice<UInt8>, seed: UInt8) -> UInt8 {
        bytes.reduce(seed) { $0 ^ $1 }
    }

    /// "Set VCP Feature": 0x84 = four bytes follow, 0x03 = set.
    static func write(_ display: IOAVService, code: UInt8, value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(packet[0..<5], seed: 0x6E ^ 0x51)

        var sent = false
        for _ in 0..<2 {                    // many monitors drop the odd write, so send it twice
            usleep(10_000)
            if IOAVServiceWriteI2C(display, monitorAddress, hostAddress,
                                   &packet, UInt32(packet.count)) == kIOReturnSuccess {
                sent = true
            }
        }
        return sent
    }

    /// "Get VCP Feature": 0x82 = two bytes follow, 0x01 = get.
    static func read(_ display: IOAVService, code: UInt8) -> (current: UInt16, max: UInt16)? {
        var request: [UInt8] = [0x82, 0x01, code, 0]
        request[3] = checksum(request[0..<3], seed: 0x6E ^ 0x51)
        var reply = [UInt8](repeating: 0, count: 11)

        for _ in 0..<4 {                    // the monitor doesn't always answer first time
            usleep(10_000)
            guard IOAVServiceWriteI2C(display, monitorAddress, hostAddress,
                                      &request, UInt32(request.count)) == kIOReturnSuccess else { continue }
            usleep(50_000)                  // DDC/CI gives the monitor 40 ms to prepare its answer
            guard IOAVServiceReadI2C(display, monitorAddress, hostAddress,
                                     &reply, UInt32(reply.count)) == kIOReturnSuccess else { continue }

            // Reply: 6E 88 02 result code type maxHi maxLo curHi curLo checksum
            guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == code,
                  checksum(reply[0..<10], seed: 0x50) == reply[10] else { continue }
            return (current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
                    max: UInt16(reply[6]) << 8 | UInt16(reply[7]))
        }
        return nil
    }
}

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

/// What color a light is showing, so Hammer can darken it and put it back.
enum LightLook {
    case color(Int, Int, Int)
    case white(Int)                 // color temperature in kelvin

    /// The same color at `strength` (0–1), never all the way to black. Only colors
    /// can be darkened like this: whites come from separate white LEDs that can't
    /// go below 1%, and faking them with the color LEDs would change the shade.
    func shaded(_ strength: Double) -> (Int, Int, Int)? {
        guard case .color(let red, let green, let blue) = self else { return nil }
        func scale(_ value: Int) -> Int { min(255, Int((Double(value) * strength).rounded())) }
        var result = (scale(red), scale(green), scale(blue))
        if max(result.0, result.1, result.2) < 2 { result.0 = max(result.0, 2) }   // stay above black
        return result
    }

    var isColor: Bool {
        if case .color = self { return true }
        return false
    }

    /// Sends the look at full strength.
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
// 20-byte packets starting 0x33, a command byte, the payload, zero padding,
// and an XOR checksum in the last byte, written to one characteristic.
//
// Everything here runs on the main thread (CoreBluetooth calls back on .main).

final class GoveeBluetooth: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = GoveeBluetooth()

    static let serviceUUID = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d1910")
    static let controlUUID = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d2b11")
    static let supportedModels: Set<String> = ["H6004", "H6006", "H6008", "H6009", "H600A", "H600D", "H6010"]

    /// Called on the main thread whenever the list of Bluetooth bulbs or the status changes.
    var onChange: (() -> Void)?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var found: [UUID: (model: String, name: String)] = [:]
    private var signalStrength: [UUID: Int] = [:]          // latest signal strength, in dBm

    /// Roughly how far away a bulb is, from its signal strength.
    func distance(of id: UUID) -> String? {
        guard let dBm = signalStrength[id] else { return nil }
        if dBm >= -60 { return "very close" }
        if dBm >= -75 { return "nearby" }
        return "far away"
    }
    private var controls: [UUID: CBCharacteristic] = [:]
    private var queued: [UUID: [Data]] = [:]
    private var idleTimers: [UUID: DispatchWorkItem] = [:]

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

    func start() {
        guard isAvailable, central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)   // asks for Bluetooth permission
    }

    /// Looks for nearby bulbs for 15 seconds. Duplicates are allowed so a bulb whose
    /// name arrives in a later advertisement still gets picked up.
    func rescan() {
        guard let central, central.state == .poweredOn else { return }
        central.stopScan()
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.central?.stopScan() }
    }

    func send(_ payload: [UInt8], to id: UUID) {
        guard let central, let peripheral = peripherals[id] else { return }
        var packet = [UInt8](repeating: 0, count: 20)
        for (index, byte) in payload.prefix(19).enumerated() { packet[index] = byte }
        packet[19] = packet[0..<19].reduce(0) { $0 ^ $1 }
        let data = Data(packet)

        if peripheral.state == .connected, let control = controls[id] {
            write(data, to: peripheral, control)
        } else {
            queued[id, default: []].append(data)    // sent as soon as we're connected
            if peripheral.state != .connecting { central.connect(peripheral) }
        }
    }

    private func write(_ data: Data, to peripheral: CBPeripheral, _ control: CBCharacteristic) {
        let type: CBCharacteristicWriteType =
            control.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: control, type: type)

        // Let go after a minute of quiet so the Govee app on your phone can still connect.
        idleTimers[peripheral.identifier]?.cancel()
        let release = DispatchWorkItem { [weak self] in self?.central?.cancelPeripheralConnection(peripheral) }
        idleTimers[peripheral.identifier] = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: release)
    }

    static func model(in name: String) -> String? {
        guard let range = name.range(of: "H[0-9A-F]{4}", options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return name[range].uppercased()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { rescan() }
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Govee bulbs advertise names like "ihoment_H6006_1A2B".
        let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard let model = Self.model(in: advertised), Self.supportedModels.contains(model) else { return }
        if RSSI.intValue < 0 { signalStrength[peripheral.identifier] = RSSI.intValue }   // 127 means "unknown"
        guard found[peripheral.identifier] == nil else { return }
        let suffix = advertised.split(separator: "_").count >= 3 ? " " + advertised.split(separator: "_").last! : ""
        peripherals[peripheral.identifier] = peripheral
        found[peripheral.identifier] = (model, "\(model) bulb\(suffix)")
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        queued[peripheral.identifier] = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        controls[peripheral.identifier] = nil
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.controlUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let control = service.characteristics?.first(where: { $0.uuid == Self.controlUUID }) else { return }
        controls[peripheral.identifier] = control
        for data in queued[peripheral.identifier] ?? [] { write(data, to: peripheral, control) }
        queued[peripheral.identifier] = nil
    }
}

// MARK: - Menu bar app

/// Called by macOS when Control-Option-H is pressed.
func hotKeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return noErr }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in delegate.showMenuAtMouse() }
    return noErr
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var displays: [IOAVService] = []
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
    private var colorTargetID: String?
    private var monitorStatus: NSMenuItem?      // shown if the monitor doesn't answer
    private var hotKeyRef: EventHotKeyRef?

    private let ddcQueue = DispatchQueue(label: "Hammer.ddc")       // I²C is slow; keep it off the main thread
    private let goveeQueue = DispatchQueue(label: "Hammer.govee")   // one light command at a time
    private var pending: [String: DispatchWorkItem] = [:]            // latest value per slider

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "hammer", accessibilityDescription: "Hammer")
        statusItem.autosaveName = "Hammer"   // remembers where you Cmd-drag the icon
        installEditMenu()
        registerHotKey()
        displays = externalDisplays()

        GoveeBluetooth.shared.onChange = { [weak self] in
            guard let delegate = self else { return }
            Task { @MainActor in delegate.bluetoothChanged() }
        }
        GoveeBluetooth.shared.start()        // first time: macOS asks to allow Bluetooth
        rescanLights()                       // also builds the menu

        // Pick up a sleep timer set before Hammer restarted (e.g. for an update),
        // unless it ran out more than an hour ago.
        if let end = timerEnd, Date().timeIntervalSince(end) > 3600 { timerEnd = nil }
        armTimer()

        // Pick up the monitor automatically when it's plugged in or unplugged.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    /// Opening Hammer again (from Apps, Spotlight or Finder) shows its menu
    /// right where the pointer is, so it works even when the menu bar icon
    /// is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMenuAtMouse()
        return false
    }

    func showMenuAtMouse() {
        guard let menu = statusItem.menu else { return }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)   // let the app launcher close first
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    /// Control-Option-H opens the menu from anywhere.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x484D_4D52), id: 1)    // "HMMR"
        RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
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
        bluetoothLights = GoveeBluetooth.shared.lights
        rebuildMenu()
    }

    @objc private func screensChanged() {
        displays = externalDisplays()
        rebuildMenu()
    }

    // MARK: Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        menu.addItem(label("Monitor"))
        monitorStatus = nil
        if displays.isEmpty {
            menu.addItem(label("Dell not connected"))
            menu.addItem(hint("Plug it in with USB-C or DisplayPort."))
            menu.addItem(hint("Hammer picks it up automatically."))
            menu.addItem(hint("Not a DisplayLink dock — those block control."))
        } else {
            menu.addItem(monitorSlider("Brightness", code: 0x10))
            menu.addItem(monitorSlider("Contrast", code: 0x12))
            let status = hint("Not responding? On the Dell: Menu → Others → DDC/CI → On")
            status.isHidden = true
            monitorStatus = status
            menu.addItem(status)
        }

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
        menu.addItem(hint("Open this menu anywhere: Control-Option-H"))
        menu.addItem(action("Check for Updates", #selector(checkForUpdates)))
        menu.addItem(hint("Version \(Self.version)"))
        menu.addItem(NSMenuItem(title: "Quit Hammer", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Look for Bluetooth bulbs again every time the menu opens, so a bulb that
    /// was busy with your phone shows up without a manual rescan.
    func menuWillOpen(_ menu: NSMenu) {
        GoveeBluetooth.shared.rescan()
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

    // MARK: Monitor

    private func monitorSlider(_ title: String, code: UInt8) -> NSMenuItem {
        sliderItem(title, range: 0...100, value: 50, action: #selector(monitorSliderMoved(_:))) { slider in
            slider.tag = Int(code)
            // Start the slider at the monitor's actual current value.
            guard let display = displays.first else { return }
            ddcQueue.async {
                guard let reading = DDC.read(display, code: code) else {
                    Task { @MainActor in self.monitorStatus?.isHidden = false }   // show the DDC/CI tip
                    return
                }
                Task { @MainActor in
                    slider.maxValue = Double(reading.max)
                    slider.doubleValue = Double(reading.current)
                }
            }
        }
    }

    @objc private func monitorSliderMoved(_ slider: NSSlider) {
        let code = UInt8(slider.tag)
        let value = UInt16(slider.doubleValue.rounded())
        let targets = displays
        schedule("ddc-\(code)", on: ddcQueue, after: 0.05) {
            for display in targets { _ = DDC.write(display, code: code, value: value) }
        }
    }

    // MARK: Govee

    @objc private func rescanLights() {
        searchingForLights = true
        GoveeBluetooth.shared.rescan()
        rebuildMenu()
        goveeQueue.async {
            let found = Govee.discover()
            Task { @MainActor in
                self.networkLights = found
                self.searchingForLights = false
                self.rebuildMenu()
            }
        }
    }

    /// Stands in for "every light" wherever a light ID is expected.
    private let allLightsID = "all-lights"

    /// One light's submenu, or the "All Lights" submenu when `light` is nil.
    /// Both have the same controls.
    private func lightItem(_ light: GoveeLight?) -> NSMenuItem {
        let id = light?.id ?? allLightsID
        let submenu = NSMenu()
        submenu.addItem(action("Turn On", #selector(turnOn(_:)), lightID: id))
        submenu.addItem(action("Turn Off", #selector(turnOff(_:)), lightID: id))
        submenu.addItem(sliderItem("Brightness", range: 0...100, value: levels[id] ?? 100,
                                   action: #selector(lightSliderMoved(_:))) { slider in
            slider.identifier = NSUserInterfaceItemIdentifier(id)
        })
        submenu.addItem(hint("Far left: extra dim for colors picked here."))
        submenu.addItem(hint("Whites stop at 1%. The color never changes."))
        submenu.addItem(.separator())
        submenu.addItem(action("Choose Color…", #selector(chooseColor(_:)), lightID: id))
        submenu.addItem(action("Warm White", #selector(warmWhite(_:)), lightID: id))
        submenu.addItem(action("Daylight", #selector(daylight(_:)), lightID: id))
        submenu.addItem(action("Night Light", #selector(nightLight(_:)), lightID: id))
        if light != nil {
            submenu.addItem(.separator())
            submenu.addItem(action("Blink to Identify", #selector(blink(_:)), lightID: id))
            submenu.addItem(action("Rename…", #selector(renameLight(_:)), lightID: id))
            submenu.addItem(action("Remove from My Lights", #selector(removeFromMyLights(_:)), lightID: id))
        }

        // The sleep timer turns off all your lights, so it lives in All Lights —
        // or in the one light's menu when there's only one (and no All Lights).
        let hasTimer = light == nil || lights.count == 1
        if hasTimer { addSleepTimer(to: submenu) }

        var title: String
        if let light {
            title = light.routeLabel.isEmpty ? light.name : "\(light.name) · \(light.routeLabel)"
        } else {
            title = "All Lights (\(lights.count))"
        }
        if hasTimer, let end = timerEnd { title += " · off at \(clockTime(end))" }
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
    // One brightness scale, 0–100, for the menu slider:
    //   20–100  the bulb's own brightness, 1–100%
    //    0–20   the bulb stays at 1% and its color is darkened instead, the only
    //           way to go dimmer. Never all the way to black: bulbs treat black
    //           as "dark" and then stop responding to colors.
    // Hammer remembers each light's color ("look") so it can darken it and
    // put it back.

    private static let dimZoneTop = 20.0
    private static let darkestShade = 0.04          // color strength at the far left

    private var levels: [String: Double] = [:]      // slider position per light (and for All Lights)
    private var looks: [String: LightLook] = [:]    // each light's current color
    private var darkened: Set<String> = []          // lights currently showing a darkened color

    @objc private func lightSliderMoved(_ slider: NSSlider) {
        guard let id = slider.identifier?.rawValue else { return }
        let level = slider.doubleValue
        levels[id] = level
        for light in lightsMatching(id) { applyLevel(level, to: light) }
    }

    /// Sends a light to a point on the 0–100 scale.
    private func applyLevel(_ level: Double, to light: GoveeLight) {
        levels[light.id] = level
        let look = looks[light.id]                         // nil: Hammer doesn't know the color
        let dimTop = Self.dimZoneTop, darkest = Self.darkestShade
        // Only a color picked in Hammer can go below 1%; anything else stops at 1%
        // and its color is never touched.
        let darken = level < dimTop && look?.isColor == true
        let restoreColor = darkened.contains(light.id) && !darken   // coming back up from darkened
        if darken { darkened.insert(light.id) } else { darkened.remove(light.id) }

        schedule("level-\(light.id)", on: goveeQueue, after: delay(for: light)) {
            Govee.setPower(light, on: true)        // adjusting a light that's off turns it on
            if darken, let look {
                // Squared so the dimmest end changes gently; eyes notice small changes most there.
                let t = level / dimTop
                if let shade = look.shaded(darkest + t * t * (1 - darkest)) {
                    Govee.setBrightness(light, 1)
                    Govee.setColor(light, red: shade.0, green: shade.1, blue: shade.2)
                }
            } else {
                if restoreColor, let look { look.apply(to: light) }
                let percent = level < dimTop ? 1 : Int((1 + (level - dimTop) / (100 - dimTop) * 99).rounded())
                Govee.setBrightness(light, percent)
            }
        }
    }

    /// Changes the lights' color and keeps each one's place on the brightness scale.
    private func setLook(_ look: LightLook, for targets: [GoveeLight]) {
        for light in targets {
            looks[light.id] = look
            let level = levels[light.id] ?? 100
            if level >= Self.dimZoneTop || !look.isColor {
                // Send the color as is; a color in the dim zone is sent darkened by the level step instead.
                schedule("look-\(light.id)", on: goveeQueue, after: delay(for: light)) {
                    Govee.setPower(light, on: true)
                    look.apply(to: light)
                }
            }
            applyLevel(level, to: light)
        }
    }

    @objc private func warmWhite(_ sender: NSMenuItem) { setLook(.white(2700), for: targetLights(sender)) }
    @objc private func daylight(_ sender: NSMenuItem) { setLook(.white(6500), for: targetLights(sender)) }

    /// The far left of the brightness scale, in warm amber.
    @objc private func nightLight(_ sender: NSMenuItem) {
        let targets = targetLights(sender)
        if let id = sender.representedObject as? String { levels[id] = 0 }
        for light in targets {
            looks[light.id] = .color(255, 100, 20)
            applyLevel(0, to: light)
        }
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

    static func describe(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
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

        let text = NSTextField(labelWithString: "Turn off in \(Self.describe(minutes: timerChoice))")
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
        timerChoiceLabel?.stringValue = "Turn off in \(Self.describe(minutes: timerChoice))"
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
        // Tell the updater this check was asked for, so it reports "up to date" too.
        FileManager.default.createFile(atPath: home.appendingPathComponent("Hammer/.manual-check").path,
                                       contents: nil)

        let job = "gui/\(getuid())/local.hammer.updater"
        let plist = home.appendingPathComponent("Library/LaunchAgents/local.hammer.updater.plist").path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Start the job; if it isn't loaded yet, load it first (loading also starts it).
        task.arguments = ["-c", "launchctl kickstart '\(job)' || launchctl bootstrap 'gui/\(getuid())' '\(plist)'"]
        try? task.run()
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
            case "govee": exit(runGoveeCommand(Array(args.dropFirst())))
            default: break
            }
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)     // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }

    static func runMonitorCommand(_ args: [String]) -> Int32 {
        guard args.count >= 2, let code = parseCode(args[1]) else {
            print("usage: Hammer get <brightness|contrast|volume|hex code>")
            print("       Hammer set <brightness|contrast|volume|hex code> <value>")
            return 2
        }
        guard let display = externalDisplays().first else {
            print("No external display found.")
            return 1
        }

        if args[0] == "get" {
            guard let value = DDC.read(display, code: code) else {
                print("The monitor didn't answer. Check that DDC/CI is on in its menu (Others).")
                return 1
            }
            print("\(value.current) (max \(value.max))")
        } else {
            guard args.count >= 3, let value = UInt16(args[2]) else {
                print("Give a number to set, e.g. Hammer set brightness 40")
                return 2
            }
            guard DDC.write(display, code: code, value: value) else {
                print("Write failed.")
                return 1
            }
            print("Done.")
        }
        return 0
    }

    static func parseCode(_ text: String) -> UInt8? {
        let lower = text.lowercased()
        if let named = DDC.codes[lower] { return named }
        let hex = lower.hasPrefix("0x") ? String(lower.dropFirst(2)) : lower
        return UInt8(hex, radix: 16)
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
