// MonitorMac.swift — the macOS side of Monitor.swift: finds the monitor in IOKit's
// registry and moves bytes to it. Modeled on m1ddc (sources/ioregistry.m) and
// BetterDisplay's AppleSiliconDDC. What it finds is turned into decisions by
// Monitor.swift, which is tested in Tests/main.swift.

import AppKit
import IOKit

// MARK: - Private IOKit calls
//
// macOS has no public API for talking to a display over I²C on Apple Silicon.
// These functions live inside IOKit but aren't in any header. MonitorControl,
// m1ddc and BetterDisplay all use them. They're looked up when first used rather
// than linked, so a macOS without one of them still opens Hammer (the monitor
// then just doesn't answer, and Hammer dims the picture in software).

typealias IOAVService = CFTypeRef

enum AVServiceCalls {
    private typealias Create = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias CreateWithService = @convention(c) (UnsafeRawPointer?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias TransferI2C = @convention(c) (UnsafeRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    private static func lookUp<Function>(_ name: String, as type: Function.Type) -> Function? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: type)
    }
    private static let createFunction = lookUp("IOAVServiceCreate", as: Create.self)
    private static let createWithServiceFunction = lookUp("IOAVServiceCreateWithService", as: CreateWithService.self)
    private static let readFunction = lookUp("IOAVServiceReadI2C", as: TransferI2C.self)
    private static let writeFunction = lookUp("IOAVServiceWriteI2C", as: TransferI2C.self)
    private static let unsupported = Int32(bitPattern: 0xE00002C7)     // kIOReturnUnsupported

    /// The calls this macOS doesn't have, for the check's report.
    static var missing: [String] {
        [("IOAVServiceCreate", createFunction == nil), ("IOAVServiceCreateWithService", createWithServiceFunction == nil),
         ("IOAVServiceReadI2C", readFunction == nil), ("IOAVServiceWriteI2C", writeFunction == nil),
         ("IOAVServiceCopyEDID", !AVServiceBus.canCopyEDID)].filter { $0.1 }.map { $0.0 }
    }

    /// macOS's default display connection: what plain `m1ddc set …` talks to.
    static func createDefault() -> IOAVService? {
        guard let create = createFunction, let service = create(nil) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(service).takeRetainedValue()
    }

    /// The connection for one DCPAVServiceProxy in the registry.
    static func create(for entry: io_service_t) -> IOAVService? {
        guard let create = createWithServiceFunction, let service = create(nil, entry) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(service).takeRetainedValue()
    }

    static func read(_ service: IOAVService, chip: UInt32, offset: UInt32,
                     _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32 {
        guard let read = readFunction else { return unsupported }
        return withExtendedLifetime(service) { read(Unmanaged.passUnretained(service).toOpaque(), chip, offset, buffer, size) }
    }

    static func write(_ service: IOAVService, chip: UInt32, offset: UInt32,
                      _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32 {
        guard let write = writeFunction else { return unsupported }
        return withExtendedLifetime(service) { write(Unmanaged.passUnretained(service).toOpaque(), chip, offset, buffer, size) }
    }
}

/// One display connection's I²C, for DDCLink.
final class AVServiceBus: DDCBus {
    let service: IOAVService
    init(_ service: IOAVService) { self.service = service }

    func write(chip: UInt32, offset: UInt32, _ bytes: [UInt8]) -> Int32 {
        var buffer = bytes
        return AVServiceCalls.write(service, chip: chip, offset: offset, &buffer, UInt32(buffer.count))
    }

    func read(chip: UInt32, offset: UInt32, count: Int) -> (status: Int32, bytes: [UInt8]) {
        var buffer = [UInt8](repeating: 0, count: count)
        let status = AVServiceCalls.read(service, chip: chip, offset: offset, &buffer, UInt32(count))
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

    static var canCopyEDID: Bool { copyEDIDFunction != nil }

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
        scan.defaultService = AVServiceCalls.createDefault()

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
                if item.location == "External", let service = AVServiceCalls.create(for: entry) {
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
                                       builtIn: CGDisplayIsBuiltin(id) != 0, vendor: CGDisplayVendorNumber(id))
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
        var check = MonitorCheck.run(mac: mac(), screens: scan.screens, entries: scan.entries,
                                     bus: { id in scan.services[id].map { AVServiceBus($0) } },
                                     defaultBus: scan.defaultService.map { AVServiceBus($0) })    // run() decides whether to use it
        check.missingCalls = AVServiceCalls.missing
        return check
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
    private var writtenFactor: [CGDirectDisplayID: Double] = [:]  // ...and how much of the signal that kept
    private var watches: [CGDirectDisplayID: DimWatch] = [:]      // whether something else keeps changing them
    private var otherAppSeen: Set<CGDirectDisplayID> = []         // another app's curves were seen on these
    private var fades = DimFade()                                 // any other change interrupts a fade

    /// Another app keeps changing a screen's curves (f.lux, another dimmer), so
    /// Hammer has stopped putting its dimming back on that screen.
    var contested: Bool { watches.values.contains { $0.gaveUp } }
    private func gaveUp(_ display: CGDirectDisplayID) -> Bool { watches[display]?.gaveUp ?? false }

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
    /// Only looks: what Hammer dims from is taken when it actually dims.
    func canDim(_ display: CGDirectDisplayID) -> Bool {
        SoftwareDim.base(live: read(display), written: written[display], previous: original[display]) != nil
    }

    /// Whether this screen's curves can be read at all (if they can but it still can't be
    /// dimmed, they're already adjusted: another app, or a calibration).
    func canRead(_ display: CGDirectDisplayID) -> Bool { read(display) != nil }

    /// Whether another app's curves have been seen changing this screen's under Hammer.
    func sawOtherApp(_ display: CGDirectDisplayID) -> Bool { otherAppSeen.contains(display) }

    /// After a wake or a display change: try again where Hammer gave way to another app
    /// (if it's still at it, Hammer gives way again after three tries). True if there were any.
    @discardableResult
    func forgetGiveUps() -> Bool {
        let any = contested
        watches = watches.filter { !$0.value.gaveUp }
        return any
    }

    /// Dims `display` to `level` (0–100), saving it. false if this screen can't be dimmed this way.
    @discardableResult
    func set(_ level: Int, on display: CGDirectDisplayID, save: Bool = true) -> Bool {
        fades.interrupt()                                // this has the last word over a fade
        let level = min(100, max(0, level))
        if save {
            UserDefaults.standard.set(level, forKey: Self.key(display))
            watches[display] = nil                       // you chose it: try again even if something fought it
        }
        guard level < 100 else {
            undo(display)
            return true
        }
        return apply(SoftwareDim.factor(level: level), on: display)
    }

    /// Dims to `factor` of the signal, from the screen's own curves.
    private func apply(_ factor: Double, on display: CGDirectDisplayID) -> Bool {
        guard let base = currentOriginal(display) else { return false }
        let dimmed = base.scaled(by: factor)
        guard write(dimmed, to: display) else { return false }
        written[display] = dimmed
        writtenFactor[display] = factor
        return true
    }

    /// Puts the saved level on each of these screens (after a wake, a display change, or launch),
    /// except where Hammer gave up because another app keeps changing the curves.
    func reapply(on displays: [CGDirectDisplayID]) {
        for display in displays where !gaveUp(display) { set(savedLevel(display), on: display, save: false) }
    }

    /// While dimming: if something reset a screen's curves (display sleep, a new color
    /// profile), dim it again. If something keeps changing them (another app that adjusts
    /// colors), stop rather than fight it, until that app's curves are gone (DimWatch).
    func keepApplied(on displays: [CGDirectDisplayID]) {
        watches = watches.filter { displays.contains($0.key) }   // screens that are gone
        for display in displays where savedLevel(display) < 100 {
            var watch = watches[display] ?? DimWatch()
            let action = watch.check(now: read(display), written: written[display], original: original[display])
            watches[display] = watch
            if watch.sawOther { otherAppSeen.insert(display) }
            if action == .dim { set(savedLevel(display), on: display, save: false) }
        }
    }

    /// Starts (`dimming`) or stops dimming in a few steps over about a quarter of a second,
    /// rather than at once. It ends exactly as setting the level or undoAll would; anything else
    /// that sets a screen meanwhile (the slider, a wake, an undo) stops it and has the last word.
    /// `levels`: where to fade to (the saved levels if nil).
    func fade(on displays: [CGDirectDisplayID], dimming: Bool, levels: [CGDirectDisplayID: Int]? = nil) {
        let id = fades.start()
        let targets = levels ?? Dictionary(displays.map { ($0, savedLevel($0)) }, uniquingKeysWith: { first, _ in first })
        // Each screen's way, as how much of the signal is kept: from all of it to its level, or back.
        let paths: [FadePath] = dimming
            ? displays.filter { !gaveUp($0) && (targets[$0] ?? 100) < 100 }
                .map { FadePath(display: $0, from: 1, to: SoftwareDim.factor(level: targets[$0] ?? 100)) }
            : writtenFactor.filter { isHammers($0.key) }.map { FadePath(display: $0.key, from: $0.value, to: 1) }
        Task { @MainActor in
            for step in 1..<DimFade.steps {
                guard self.fades.goesOn(id) else { return }
                for path in paths where dimming || self.isHammers(path.display) {
                    _ = self.apply(DimFade.factor(step: step, from: path.from, to: path.to), on: path.display)
                }
                try? await Task.sleep(nanoseconds: DimFade.pause)
            }
            guard self.fades.goesOn(id) else { return }
            if dimming {
                for display in displays where !self.gaveUp(display) {
                    self.set(targets[display] ?? 100, on: display, save: false)
                }
            } else {
                self.undoAll()
            }
        }
    }

    private struct FadePath { let display: CGDirectDisplayID; let from: Double; let to: Double }

    /// The curves on the screen are still the ones Hammer put there.
    private func isHammers(_ display: CGDirectDisplayID) -> Bool {
        guard let mine = written[display], let now = read(display) else { return false }
        return now.matches(mine)
    }

    /// Puts back a screen's original curves, if Hammer dimmed it and they're still
    /// Hammer's (if macOS or another app has changed them since, they're left alone).
    func undo(_ display: CGDirectDisplayID) {
        fades.interrupt()
        if let base = original[display], isHammers(display) {
            _ = write(base, to: display)
        }
        written[display] = nil
        writtenFactor[display] = nil
        original[display] = nil                          // read afresh next time
    }

    /// Undoes the dimming on every screen Hammer dimmed (the monitor answers again).
    func undoAll() {
        fades.interrupt()
        for display in Array(written.keys) { undo(display) }
        watches = [:]
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
/// and checks Hammer dims from the right curves each time, never stacking; fades in
/// and out, and an undo during a fade; then puts everything back exactly. Run by the
/// macOS build check. macOS can report curves it didn't actually show, so the screen
/// itself still needs a look on a real Mac.
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
    // Starting and stopping fade in a few steps; anything set meanwhile has the last word.
    func wait(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: end) }
    }
    /// Lets a fade finish (up to 2 s on a busy machine): how long it took, or nil if it never got there.
    func settle(_ done: () -> Bool) -> String? {
        let start = Date()
        while Date().timeIntervalSince(start) < 2 {
            if done() { return String(format: "%.2f s", Date().timeIntervalSince(start)) }
            wait(0.02)
        }
        return nil
    }
    dimmer.set(50, on: display, save: false)
    dimmer.fade(on: [display], dimming: false)
    wait(0.1)
    check(dimmer.curvesNow(display).map { !$0.matches(expected) && !$0.matches(before) } == true,
          "fading out: partway after 0.1 s (top \(dimmer.curvesNow(display)?.r.last ?? -1))")
    var took = settle { dimmer.curvesNow(display) == before }
    let topNow = dimmer.curvesNow(display)?.r.last ?? -1
    check(took != nil, "fading out: then put back exactly (\(took ?? "not within 2 s; top \(topNow)"))")
    dimmer.set(50, on: display, save: false)
    dimmer.fade(on: [display], dimming: false)
    dimmer.set(50, on: display, save: false)
    wait(0.6)
    check(dimmer.curvesNow(display).map { $0.matches(expected) } == true, "set during a fade: that wins")
    dimmer.set(100, on: display, save: false)
    dimmer.fade(on: [display], dimming: true, levels: [display: 50])
    wait(0.1)
    check(dimmer.curvesNow(display).map { !$0.matches(expected) && !$0.matches(before) } == true,
          "fading in: partway after 0.1 s (top \(dimmer.curvesNow(display)?.r.last ?? -1))")
    took = settle { dimmer.curvesNow(display).map { $0.matches(expected) } == true }
    check(took != nil, "fading in: then exactly half (\(took ?? "not within 2 s"))")
    dimmer.set(100, on: display, save: false)
    dimmer.fade(on: [display], dimming: true, levels: [display: 50])
    wait(0.1)
    dimmer.undo(display)
    wait(0.6)
    check(dimmer.curvesNow(display) == before, "undone during a fade in: stays undone")
    dimmer.set(50, on: display, save: false)
    dimmer.fade(on: [display], dimming: false)
    wait(0.1)
    dimmer.undoAll()
    wait(0.6)
    check(dimmer.curvesNow(display) == before, "undone during a fade out: stays undone")
    dimmer.set(100, on: display, save: false)
    check(dimmer.curvesNow(display) == before, "100%: put back exactly")
    if dimmer.curvesNow(display) != before { _ = dimmer.write(before, to: display) }
    return good ? 0 : 1
}
