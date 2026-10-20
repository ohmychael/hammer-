// MonitorMac.swift — the macOS side of Monitor.swift: finds the monitor in IOKit's
// registry and moves bytes to it. Modeled on m1ddc (sources/ioregistry.m) and
// BetterDisplay's AppleSiliconDDC. What it finds is turned into decisions by
// Monitor.swift, which is tested in Tests/main.swift.

import AppKit
import IOKit

// MARK: - Private IOKit calls
//
// macOS has no public API for talking to a display over I²C on Apple Silicon.
// These functions live inside IOKit but aren't in any header, so we declare
// them ourselves. MonitorControl, m1ddc and BetterDisplay all use them.

typealias IOAVService = CFTypeRef

/// macOS's default display connection: what plain `m1ddc set …` talks to.
@_silgen_name("IOAVServiceCreate")
func IOAVServiceCreate(_ allocator: CFAllocator?) -> Unmanaged<IOAVService>?

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> Unmanaged<IOAVService>?

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: IOAVService, _ chipAddress: UInt32, _ offset: UInt32,
                        _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: IOAVService, _ chipAddress: UInt32, _ dataAddress: UInt32,
                         _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

/// One display connection's I²C, for DDCLink.
final class AVServiceBus: DDCBus {
    let service: IOAVService
    init(_ service: IOAVService) { self.service = service }

    func write(chip: UInt32, offset: UInt32, _ bytes: [UInt8]) -> Int32 {
        var buffer = bytes
        return IOAVServiceWriteI2C(service, chip, offset, &buffer, UInt32(buffer.count))
    }

    func read(chip: UInt32, offset: UInt32, count: Int) -> (status: Int32, bytes: [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = IOAVServiceReadI2C(service, chip, offset, &buffer, UInt32(count))
        return (status, buffer)
    }

    func copyEDID() -> [UInt8]? {
        guard let copy = Self.copyEDIDFunction else { return nil }
        var data: UnsafeRawPointer?
        let status = copy(Unmanaged.passUnretained(service).toOpaque(), &data)
        guard let data else { return nil }
        let edid = Unmanaged<CFData>.fromOpaque(data).takeRetainedValue() as Data   // ours to release either way
        return status == 0 ? [UInt8](edid) : nil
    }

    /// IOAVServiceCopyEDID(service, &data): private like the rest, looked up at run
    /// time so a macOS without it still builds and runs Hammer.
    private typealias CopyEDID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UnsafeRawPointer?>) -> Int32
    private static let copyEDIDFunction: CopyEDID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceCopyEDID") else { return nil }
        return unsafeBitCast(symbol, to: CopyEDID.self)
    }()
}

// MARK: - Finding the monitor

enum MacMonitors {
    struct Scan {
        var entries: [RegistryEntry] = []
        var services: [UInt64: IOAVService] = [:]   // by connection, external ones only
        var defaultService: IOAVService?               // macOS's default, tried last
        var screens: [MonitorScreen] = []

        var monitors: MonitorSet {
            let ports = MonitorDiscovery.ports(in: entries, screens: screens)
            var members = ports.compactMap { found -> MonitorSet.Member? in
                guard let service = services[found.connection] else { return nil }
                let bus = AVServiceBus(service)
                var port = found
                port.monitorInput = bus.copyEDID().flatMap(EDID.input)
                return MonitorSet.Member(port: port, link: DDCLink(bus: bus, ways: port.ways))
            }
            // Only with a monitor around: otherwise it can be the built-in screen's.
            if let service = defaultService,
               MonitorDiscovery.useDefault(ports: members.map { $0.port }, screens: screens) {
                let port = MonitorPort.macDefault
                members.append(MonitorSet.Member(port: port, link: DDCLink(bus: AVServiceBus(service), ways: port.ways)))
            }
            return MonitorSet(members)
        }
    }

    /// Reads the registry and the screen list. Call on the main thread (it asks NSScreen).
    static func scan() -> Scan {
        var scan = Scan()
        scan.screens = screens()
        scan.defaultService = IOAVServiceCreate(kCFAllocatorDefault)?.takeRetainedValue()

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, "IOService", IOOptionBits(kIORegistryIterateRecursively),
                                            &iterator) == KERN_SUCCESS else { return scan }
        defer { IOObjectRelease(iterator) }

        let name = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { name.deallocate() }
        let path = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
        defer { path.deallocate() }

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, name) == KERN_SUCCESS else { continue }
            let entryName = String(cString: name)
            let isConnection = entryName == "DCPAVServiceProxy"
            let isFramebuffer = !isConnection
                && (IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0                 // m1ddc
                    || entryName == "AppleCLCD2" || entryName == "IOMobileFramebufferShim")   // AppleSiliconDDC
            guard isConnection || isFramebuffer else { continue }

            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(entry, &id)
            var item = RegistryEntry(id: id, name: entryName, isFramebuffer: isFramebuffer)
            if IORegistryEntryGetPath(entry, "IOService", path) == KERN_SUCCESS {
                item.path = String(cString: path)
            }

            if isConnection {
                item.location = property(entry, "Location") as? String
                item.provider = parentProperty(entry, "EPICProviderClass") as? String
                if item.location == "External",
                   let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                    scan.services[id] = service
                }
            } else {
                let attributes = property(entry, "DisplayAttributes") as? NSDictionary
                let product = attributes?["ProductAttributes"] as? NSDictionary
                if let productName = product?["ProductName"] as? String, !productName.isEmpty {
                    item.productName = productName
                }
                item.hasDisplay = attributes != nil || property(entry, "EDID UUID") != nil
                if let transport = property(entry, "Transport") as? NSDictionary {
                    let parts = [transport["Upstream"], transport["Downstream"]].compactMap { $0 as? String }
                    if !parts.isEmpty { item.transport = parts.joined(separator: " → ") }
                }
            }
            scan.entries.append(item)
        }
        return scan
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> AnyObject? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func parentProperty(_ entry: io_registry_entry_t, _ key: String) -> AnyObject? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, "IOService", &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        return property(parent, key)
    }

    /// The screens macOS shows, and which framebuffer each is on. A screen with
    /// no framebuffer is a virtual one: DisplayLink, AirPlay or Sidecar.
    static func screens() -> [MonitorScreen] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }

        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }

        return ids.prefix(Int(count)).map { id in
            var screen = MonitorScreen(id: id, name: names[id] ?? "Display \(id)",
                                       builtIn: CGDisplayIsBuiltin(id) != 0)
            guard let createInfo = coreDisplayInfo else { return screen }    // can't tell; leave unknown
            guard let pointer = createInfo(id) else {
                screen.direct = false
                return screen
            }
            let info = Unmanaged<CFDictionary>.fromOpaque(pointer).takeRetainedValue() as NSDictionary
            if names[id] == nil, let productNames = info["DisplayProductName"] as? [String: String],
               let productName = productNames["en_US"] ?? productNames.values.first {
                screen.name = productName
            }
            guard let location = info["IODisplayLocation"] as? String else {
                screen.direct = false
                return screen
            }
            screen.direct = true
            let framebuffer = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
            if framebuffer != 0 {
                var framebufferID: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(framebuffer, &framebufferID) == KERN_SUCCESS {
                    screen.framebuffer = framebufferID
                }
                IOObjectRelease(framebuffer)
            }
            return screen
        }
    }

    /// CoreDisplay_DisplayCreateInfoDictionary: private, used by m1ddc and
    /// MonitorControl to find each screen's framebuffer. Looked up at run time so a
    /// macOS without it still builds and runs (the check then can't spot DisplayLink).
    private typealias CreateInfo = @convention(c) (CGDirectDisplayID) -> UnsafeMutableRawPointer?
    private static let coreDisplayInfo: CreateInfo? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(symbol, to: CreateInfo.self)
    }()

    // MARK: About this Mac, for the check

    static func mac() -> MonitorCheck.Mac {
        MonitorCheck.Mac(model: sysctl("hw.model") ?? "", chip: sysctl("machdep.cpu.brand_string") ?? "",
                         system: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The full check. Call `scan()` on the main thread first; this part talks to
    /// the monitor and takes a few seconds, so run it on the monitor queue.
    static func check(_ scan: Scan) -> MonitorCheck {
        MonitorCheck.run(mac: mac(), screens: scan.screens, entries: scan.entries,
                         bus: { id in scan.services[id].map { AVServiceBus($0) } },
                         defaultBus: scan.defaultService.map { AVServiceBus($0) })    // run() decides whether to use it
    }
}

// MARK: - Dimming the picture in software (SoftwareDim in Monitor.swift)

/// Scales a screen's color curves to dim its picture. Before each change it looks
/// at the curves as they are (SoftwareDim.base), so a new color profile or macOS
/// resetting them is picked up, and its own dimming is never taken as the original.
/// At 100% it writes nothing (and puts back the original if it had dimmed).
@MainActor
final class SoftwareDimmer {
    static let shared = SoftwareDimmer()
    private var original: [CGDirectDisplayID: GammaCurves] = [:]
    private var written: [CGDirectDisplayID: GammaCurves] = [:]   // what Hammer last put on each screen
    private var resets: [CGDirectDisplayID: Int] = [:]            // times in a row something else changed them
    /// Another app keeps changing a screen's curves (f.lux, another dimmer): Hammer stopped fighting it.
    private(set) var contested = false

    /// The level saved for this screen's monitor (100: not dimmed).
    func savedLevel(_ display: CGDirectDisplayID) -> Int {
        UserDefaults.standard.object(forKey: Self.key(display)) as? Int ?? 100
    }

    private static func key(_ display: CGDirectDisplayID) -> String {
        SoftwareDim.key(vendor: CGDisplayVendorNumber(display), model: CGDisplayModelNumber(display),
                        serial: CGDisplaySerialNumber(display))
    }

    /// Whether this monitor was being dimmed in software (kept across restarts,
    /// cleared once it answers Hammer again).
    func wasActive(_ display: CGDirectDisplayID) -> Bool {
        UserDefaults.standard.bool(forKey: Self.key(display) + ".active")
    }

    func setActive(_ on: Bool, for display: CGDirectDisplayID) {
        UserDefaults.standard.set(on, forKey: Self.key(display) + ".active")
    }

    /// Whether this screen's picture can be dimmed (its curves can be read, and look like its own).
    func canDim(_ display: CGDirectDisplayID) -> Bool { currentOriginal(display) != nil }

    /// Dims `display` to `level` (0–100), saving it. false if this screen can't be dimmed this way.
    @discardableResult
    func set(_ level: Int, on display: CGDirectDisplayID, save: Bool = true) -> Bool {
        let level = min(100, max(0, level))
        if save {
            UserDefaults.standard.set(level, forKey: Self.key(display))
            resets[display] = 0                          // you chose it: try again even if something fought it
            contested = false
        }
        guard level < 100 else {
            undo(display)
            return true
        }
        guard let base = currentOriginal(display) else { return false }
        let dimmed = base.scaled(by: SoftwareDim.factor(level: level))
        guard write(dimmed, to: display) else { return false }
        written[display] = dimmed
        return true
    }

    /// Puts the saved level on each of these screens (after a wake, a display change, or launch).
    func reapply(on displays: [CGDirectDisplayID]) {
        for display in displays { set(savedLevel(display), on: display, save: false) }
    }

    /// While dimming: if something reset a screen's curves (display sleep, a new color
    /// profile), dim it again. If something keeps changing them (another app that
    /// adjusts colors), stop after three times in a row rather than fight it.
    func keepApplied(on displays: [CGDirectDisplayID]) {
        for display in displays where savedLevel(display) < 100 {
            if let mine = written[display], let now = read(display), now.matches(mine) {
                resets[display] = 0
                continue
            }
            let count = (resets[display] ?? 0) + 1
            resets[display] = count
            if count > 3 {
                contested = true
                continue
            }
            set(savedLevel(display), on: display, save: false)
        }
    }

    /// Puts back a screen's original curves, if Hammer dimmed it and they're still
    /// Hammer's (if macOS or another app has changed them since, they're left alone).
    func undo(_ display: CGDirectDisplayID) {
        if let mine = written[display], let base = original[display], let now = read(display), now.matches(mine) {
            _ = write(base, to: display)
        }
        written[display] = nil
        original[display] = nil                          // read afresh next time
    }

    /// Undoes the dimming on every screen Hammer dimmed (the monitor answers again).
    func undoAll() {
        for display in Array(written.keys) { undo(display) }
    }

    private func currentOriginal(_ display: CGDirectDisplayID) -> GammaCurves? {
        let base = SoftwareDim.base(live: read(display), written: written[display], previous: original[display])
        original[display] = base
        return base
    }

    private func read(_ display: CGDirectDisplayID) -> GammaCurves? {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 1 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &count) == .success, count > 1 else { return nil }
        let n = Int(count)
        return GammaCurves(r: Array(r.prefix(n)), g: Array(g.prefix(n)), b: Array(b.prefix(n)))
    }

    /// Writes curves as they are (the self-test uses it to stand in for macOS or another app).
    func write(_ curves: GammaCurves, to display: CGDirectDisplayID) -> Bool {
        guard curves.r.count > 1, curves.g.count == curves.r.count, curves.b.count == curves.r.count else { return false }
        return CGSetDisplayTransferByTable(display, UInt32(curves.r.count), curves.r, curves.g, curves.b) == .success
    }

    /// For the self-test: the screen's curves now.
    func curvesNow(_ display: CGDirectDisplayID) -> GammaCurves? { read(display) }
}

/// `Hammer dim-check`: dims the main screen to half, then stands in for the things
/// that change a screen's curves (macOS resetting them, another app dimming them)
/// and checks Hammer dims from the right curves each time, never stacking; then
/// puts everything back exactly. Run by the macOS build check. macOS can report
/// curves it didn't actually show, so the screen itself still needs a look on a real Mac.
@MainActor
func runDimCheck() -> Int32 {
    let display = CGMainDisplayID()
    print("Software dimming check (display \(display))")
    let dimmer = SoftwareDimmer.shared
    guard let before = dimmer.curvesNow(display) else {
        print("SKIPPED: this screen has no color curves Hammer can change.")
        return 0
    }
    guard before.isScreensOwn, dimmer.set(50, on: display, save: false) else {
        print("SKIPPED: macOS didn't take a new color curve for this screen.")
        return 0
    }
    var good = true
    func check(_ ok: Bool, _ what: String) { print((ok ? "  ok   " : "  FAIL ") + what); if !ok { good = false } }
    let expected = before.scaled(by: SoftwareDim.factor(level: 50))
    check(dimmer.curvesNow(display).map { $0.matches(expected) } == true,
          "dimmed to half: top of the curve \(before.r.last ?? 0) → \(dimmer.curvesNow(display)?.r.last ?? -1)")
    dimmer.set(50, on: display, save: false)
    check(dimmer.curvesNow(display).map { $0.matches(expected) } == true, "dimmed again: doesn't stack")
    _ = dimmer.write(before, to: display)                          // as macOS does after a wake
    dimmer.set(50, on: display, save: false)
    check(dimmer.curvesNow(display).map { $0.matches(expected) } == true, "after macOS resets the curves: half again")
    _ = dimmer.write(before.scaled(by: 0.5), to: display)          // as another dimming app would
    dimmer.set(50, on: display, save: false)
    check(dimmer.curvesNow(display).map { $0.matches(expected) } == true,
          "after another app dims them: half of the original, not of the other app's")
    dimmer.set(100, on: display, save: false)
    check(dimmer.curvesNow(display) == before, "100%: put back exactly")
    if dimmer.curvesNow(display) != before { _ = dimmer.write(before, to: display) }
    return good ? 0 : 1
}
