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
            var members = ports.compactMap { port in
                services[port.connection].map {
                    MonitorSet.Member(port: port, link: DDCLink(bus: AVServiceBus($0), ways: port.ways))
                }
            }
            // Only with an external monitor around: otherwise it can be the built-in screen's.
            if hasExternal, let service = defaultService {
                let port = MonitorPort.macDefault
                members.append(MonitorSet.Member(port: port, link: DDCLink(bus: AVServiceBus(service), ways: port.ways)))
            }
            return MonitorSet(members)
        }

        /// An external connection was found, or macOS shows an external screen.
        var hasExternal: Bool { !services.isEmpty || screens.contains { !$0.builtIn } }
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
                         defaultBus: scan.hasExternal ? scan.defaultService.map { AVServiceBus($0) } : nil)
    }
}
