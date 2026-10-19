// EdgeMac.swift — YouTube in your own Microsoft Edge: the Mac side of
// EdgeController (Player.swift). It starts Edge with a YouTube app window, runs
// Hammer's AppleScripts through osascript (never on the main thread, always with
// a time limit), and asks macOS once whether Hammer may steer Edge.
//
// Hammer never reads Edge's cookies, passwords or history. Its scripts send back
// only window numbers, positions and whether they're minimized: never addresses.

import AppKit
import CoreServices

/// The real Edge, for EdgeController.
final class MacEdgeDriver: EdgeDriver, @unchecked Sendable {
    /// Taken on the main thread just before each press is handled.
    private var screenNow: (visible: CGRect, mainHeight: CGFloat) = (CGRect(x: 0, y: 0, width: 1440, height: 875), 900)
    private var frontNow = false

    @MainActor func prepare(screen: NSScreen?) {
        let main = NSScreen.screens.first                   // the one with the menu bar: AppleScript measures from it
        let visible = (screen ?? NSScreen.main ?? main)?.visibleFrame ?? screenNow.visible
        screenNow = (visible, main?.frame.height ?? screenNow.mainHeight)
        frontNow = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == EdgeYouTube.bundleID
    }

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: EdgeYouTube.bundleID) }
    var installed: Bool { Self.appURL != nil }

    /// Edge's main process: the first one started (a second one can live for a moment
    /// while it hands Edge a new window).
    static func edgeApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: EdgeYouTube.bundleID)
            .filter { !$0.isTerminated }
            .min { ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture) }
    }

    func running() -> String? {
        guard let edge = Self.edgeApp() else { return nil }
        return "\(edge.processIdentifier):\(Int(edge.launchDate?.timeIntervalSince1970 ?? 0))"
    }

    func edgeInFront() -> Bool { frontNow }

    func permission(ask: Bool) async -> EdgePermission {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {    // waits while macOS's question is up
                continuation.resume(returning: Self.permissionNow(ask: ask))
            }
        }
    }

    /// Whether Hammer may send Edge Apple events. With `ask`, macOS shows its
    /// "Hammer wants access to control Microsoft Edge" question the first time.
    static func permissionNow(ask: Bool) -> EdgePermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: EdgeYouTube.bundleID)
        // A real event ("get"), not a wildcard: with a wildcard macOS may not ask.
        let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, AEEventClass(kAECoreSuite),
                                                           AEEventID(kAEGetData), ask)
        switch Int(status) {
        case Int(noErr): return .allowed
        case Int(errAEEventWouldRequireUserConsent): return .notAsked
        case Int(procNotFound): return .notRunning
        default: return .denied                               // errAEEventNotPermitted, or anything odd
        }
    }

    func run(_ script: String) async -> EdgeScriptResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.osascript(script))
            }
        }
    }

    /// Runs a script with /usr/bin/osascript (given on its input, not its command
    /// line). If Edge doesn't answer in time, it's stopped.
    static func osascript(_ source: String, timeout: TimeInterval = 10) -> EdgeScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            return .failed(number: nil, message: "Couldn't run osascript: \(error.localizedDescription)")
        }
        let timedOut = Flag()
        let timer = DispatchWorkItem {
            if process.isRunning { timedOut.set(); process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let errorText = PipeReader(errors)
        try? input.fileHandleForWriting.write(contentsOf: Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        let err = String(decoding: errorText.wait(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut.isSet {
            NSLog("Hammer: Microsoft Edge didn't answer a script within %.0f s", timeout)
            return .failed(number: nil, message: "Microsoft Edge didn't answer")
        }
        guard process.terminationStatus == 0 else {
            NSLog("Hammer: Edge script failed: %@", err)               // the details, for Console; you see plain words
            return .failed(number: EdgeYouTube.errorNumber(err), message: err.isEmpty ? "osascript failed" : err)
        }
        return .ok(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func launch(_ arguments: [String]) async -> Bool {
        guard let url = Self.appURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        // If Edge is running, this starts a second copy for a moment, which hands the
        // window to the running Edge and quits (the way `open -n` does).
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        // If macOS holds Edge back (a question on screen), don't wait forever.
        return await withCheckedContinuation { continuation in
            let once = Once()
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { NSLog("Hammer: couldn't open Microsoft Edge: %@", error.localizedDescription) }
                once.run { continuation.resume(returning: error == nil) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                once.run { continuation.resume(returning: Self.edgeApp() != nil) }
            }
        }
    }

    /// Brings Edge to the front: if macOS lets Hammer hand over the focus, only
    /// Edge's front window (the YouTube one) comes forward. Otherwise Edge's own
    /// activate does it, which may bring Edge's other windows along.
    func bringForward() async {
        guard let edge = Self.edgeApp() else { return }
        await Self.handFocus(to: edge)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let front = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        if front != EdgeYouTube.bundleID {
            _ = await run(EdgeYouTube.activateScript())
        }
    }

    /// Makes `app` the active app. Since macOS 14 an app may only pass the focus on
    /// while it has it, so Hammer takes it first (you just pressed its shortcut).
    static func handFocus(to app: NSRunningApplication) async {
        if #available(macOS 14, *) {
            await MainActor.run { NSApp.activate() }
            for _ in 0..<10 {                                // up to a quarter of a second
                if await MainActor.run(body: { NSApp.isActive }) { break }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            _ = await MainActor.run { app.activate(from: .current, options: []) }
        } else {
            _ = await MainActor.run { app.activate(options: []) }
        }
    }

    func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func screen() -> (visible: CGRect, mainHeight: CGFloat) { screenNow }
    func remembered(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }
    func remember(_ value: String?, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}

/// Reads a pipe to the end on another thread, so a chatty process can't get stuck.
private final class PipeReader: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)
    init(_ pipe: Pipe) {
        DispatchQueue.global().async {
            self.data = pipe.fileHandleForReading.readDataToEndOfFile()
            self.done.signal()
        }
    }
    func wait() -> Data { done.wait(); return data }
}

/// Runs its block the first time only (whichever of two callbacks comes first).
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ block: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { block() }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// The shortcut and the menu use this when YouTube opens in Edge.
@MainActor
final class EdgePlayer {
    static var isInstalled: Bool { MacEdgeDriver.appURL != nil }

    private let driver = MacEdgeDriver()
    private lazy var controller = EdgeController(driver: driver)
    private let screen: () -> NSScreen?
    private let useHammerPlayer: () -> Void
    private var busySince: Date?
    private var toldAboutPermission = false
    private var cameFrom: NSRunningApplication?     // the app you were in before YouTube came forward

    /// `screen`: the menu bar icon's screen. `useHammerPlayer`: switch to Hammer's own player.
    init(screen: @escaping () -> NSScreen?, useHammerPlayer: @escaping () -> Void) {
        self.screen = screen
        self.useHammerPlayer = useHammerPlayer
    }

    /// Opens, shows or tucks away YouTube's Edge window; with `url`, plays it there.
    func toggle(play url: URL? = nil) {
        // One press at a time: the first may wait on macOS's question, and every step has
        // its own time limit. Only if something got stuck anyway is it forgotten (ten minutes).
        if let since = busySince, Date().timeIntervalSince(since) < 600 { return }
        busySince = Date()
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != EdgeYouTube.bundleID,
           front != NSRunningApplication.current {
            cameFrom = front
        }
        driver.prepare(screen: screen())
        let controller = self.controller
        Task { @MainActor in
            let outcome = await controller.toggle(play: url)
            self.busySince = nil
            self.handle(outcome)
        }
    }

    private func handle(_ outcome: EdgeController.Outcome) {
        switch outcome {
        case .opened, .shown:
            break
        case .hidden:
            // Typing goes back to where you were, not to an Edge window you can't see.
            if let app = cameFrom, !app.isTerminated,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == EdgeYouTube.bundleID {
                Task { await MacEdgeDriver.handFocus(to: app) }
            }
        case .notInstalled:
            useHammerPlayer()
        case .notAllowed(let openedAnyway):
            if openedAnyway && toldAboutPermission { return }  // don't nag every time; you know how to fix it
            toldAboutPermission = true
            let alert = NSAlert()
            alert.messageText = "Let Hammer steer Microsoft Edge"
            alert.informativeText = "To keep YouTube's Edge window in the corner and tuck it away with the shortcut, "
                + "Hammer needs your OK: System Settings → Privacy & Security → Automation → Hammer → turn on Microsoft Edge."
                + (openedAnyway ? "\n\nYouTube opened in Edge anyway." : "")
                + "\n\nHammer only finds that window and opens, moves and minimizes it. It never reads your tabs, cookies, passwords or history."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Use Hammer's Player")
            alert.addButton(withTitle: "Not Now")
            switch show(alert) {
            case .alertFirstButtonReturn:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            case .alertSecondButtonReturn:
                useHammerPlayer()
            default:
                break
            }
        case .failed(let message):
            let alert = NSAlert()
            alert.messageText = "Couldn't open YouTube in Edge"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Use Hammer's Player")
            if show(alert) == .alertSecondButtonReturn { useHammerPlayer() }
        }
    }

    private func show(_ alert: NSAlert) -> NSApplication.ModalResponse {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        return alert.runModal()
    }
}

// MARK: - Self-test (`Hammer edge-check`, run by the macOS build check)

/// What can be checked without your OK to steer Edge (a build server can't give
/// it): Edge is found, every script Hammer sends compiles against Edge's own
/// dictionary, and a YouTube app window opens. Exits 0 if all went well.
@MainActor
enum EdgeCheck {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in exit(await steps() ? 0 : 1) }
        app.run()
        exit(1)
    }

    private static func note(_ text: String) { print(text); fflush(stdout) }

    private static func steps() async -> Bool {
        note("Microsoft Edge check")
        guard let url = MacEdgeDriver.appURL else {
            note("SKIPPED: Microsoft Edge isn't installed here.")
            return true
        }
        note("  ok   Edge found: \(url.path)")
        var good = true

        // Compiling loads Edge's dictionary from its app; nothing is sent to Edge.
        let link = EdgeYouTube.watchURL(id: "jNQXAC9IVRw", start: 5)
        let scripts = [("find", EdgeYouTube.findScript(prefix: EdgeYouTube.matchPrefix(EdgeYouTube.home))),
                       ("state", EdgeYouTube.stateScript(id: 1)),
                       ("show", EdgeYouTube.showScript(id: 1, bounds: [3080, 25, 3840, 485])),
                       ("hide", EdgeYouTube.hideScript(id: 1)), ("play", EdgeYouTube.goScript(id: 1, url: link)),
                       ("activate", EdgeYouTube.activateScript())]
        for (name, source) in scripts {
            var error: NSDictionary?
            let compiled = NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false
            note((compiled ? "  ok   " : "  FAIL ") + "the \(name) script compiles against Edge's dictionary"
                 + (compiled ? "" : ": \(error?[NSAppleScript.errorMessage] ?? "?")"))
            if !compiled { good = false }
        }

        let before = Set(edgeWindows().map(\.number))
        note("  permission to steer Edge without asking: \(MacEdgeDriver.permissionNow(ask: false)) (a build server has none)")
        let driver = MacEdgeDriver()
        // As Hammer does it, plus what a build server needs (a test keychain, no first-run screens).
        let launched = await driver.launch(EdgeYouTube.launchArguments(EdgeYouTube.home)
                                           + ["--use-mock-keychain", "--no-first-run", "--no-default-browser-check"])
        var found: (number: Int, bounds: CGRect)?
        if launched {
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let window = edgeWindows().first(where: { !before.contains($0.number) && $0.bounds.width > 200 }) {
                    found = window
                    break
                }
            }
        }
        if found == nil && macOSIsAsking() {
            // A copy of Edge nobody has opened yet: macOS asks "Are you sure you want to open it?"
            // first, and only a person can answer. (On your Mac, you did the first time you used Edge.)
            note("  SKIPPED opening the window: macOS is asking whether to open Edge for the first time.")
            note(good ? "All Edge checks that can run here passed." : "Some Edge checks failed.")
            return good
        }
        note((launched ? "  ok   " : "  FAIL ") + "Edge started with a YouTube app window")
        note((found != nil ? "  ok   " : "  FAIL ") + "its window is on screen" + (found.map { ": \($0.bounds)" } ?? ""))
        if !launched || found == nil { good = false }
        note("  running as \(driver.running() ?? "nothing")")
        note(good ? "All Edge checks passed." : "Some Edge checks failed.")
        return good
    }

    /// macOS's "downloaded from the Internet" question is on screen (its window belongs to CoreServicesUIAgent).
    private static func macOSIsAsking() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "CoreServicesUIAgent" }
    }

    /// Edge's ordinary windows on screen (needs no permission: no names, just where they are).
    private static func edgeWindows() -> [(number: Int, bounds: CGRect)] {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: EdgeYouTube.bundleID).map(\.processIdentifier))
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return (number, rect)
        }
    }
}
