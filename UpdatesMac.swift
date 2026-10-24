// UpdatesMac.swift — Hammer's side of keeping itself up to date. update.sh and
// build.sh do the work (they run on their own, so they can restart Hammer). Here:
//   • the menu's update line, read from ~/Hammer/update-status, and notifications
//     for it (from Hammer, so macOS shows them as Hammer's);
//   • noticing that a login item was turned off, and turning it back on;
//   • telling build.sh that Hammer has started (~/Hammer/.launched), so a version
//     that crashes at launch is never kept, and when it's in use (~/Hammer/.busy),
//     so an update doesn't interrupt a dialog or a video;
//   • `Hammer make-icon <folder>`: the app icon, which build.sh turns into Hammer.icns.

import AppKit
import UserNotifications

private let hammerFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Hammer")

/// Tells build.sh not to restart Hammer for an update just now (it waits up to 30
/// minutes). Dialogs are covered by `watchDialogs()`; Hammer's own YouTube player sets
/// "YouTube" while it's open or playing; Turn On At's password prompt, Blink to Identify
/// and Check Monitor Connection use `begin`/`end`. Anything else that shouldn't be cut
/// off can do the same.
@MainActor
enum Busy {
    private static var reasons: Set<String> = []
    private static var dialogTimer: Timer?
    static let file = hammerFolder.appendingPathComponent(".busy")

    static func set(_ reason: String, _ on: Bool) {
        let before = reasons
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        guard reasons != before else { return }
        if reasons.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else {
            // Its PID first, so build.sh can tell a file left by a Hammer that has quit.
            let text = "\(getpid())\n\(reasons.sorted().joined(separator: ", "))\n"
            try? FileManager.default.createDirectory(at: hammerFolder, withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// For things that can overlap (two Blinks, two wake changes): busy until every
    /// `begin` has had its `end`.
    private static var counts: [String: Int] = [:]
    static func begin(_ reason: String) {
        counts[reason, default: 0] += 1
        set(reason, true)
    }
    static func end(_ reason: String) {
        let left = Swift.max(0, (counts[reason] ?? 0) - 1)
        counts[reason] = left == 0 ? nil : left
        set(reason, left > 0)
    }

    /// Any dialog open (an alert, or a window that runs modally) counts as busy.
    static func watchDialogs() {
        guard dialogTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { Busy.set("a dialog is open", NSApp.modalWindow != nil) }
        }
        RunLoop.main.add(timer, forMode: .common)       // fires while a dialog is up, too
        dialogTimer = timer
    }
}

@MainActor
final class Updates {
    static let shared = Updates()

    /// Called when anything the menu shows has changed.
    var onChange: (() -> Void)?

    private(set) var status: UpdateStatus?
    /// "Updates are off" or "Opening at login is off", when a login item has been turned off.
    private(set) var off: String?
    private var asked: Date?                // when you chose Check for Updates, until it answers
    private var statusModified: Date?
    private var watch: Timer?

    private static let statusFile = hammerFolder.appendingPathComponent("update-status")
    private static let repo = hammerFolder.appendingPathComponent("repo")
    private static let agents = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
    private static var domain: String { "gui/\(getuid())" }

    /// Installed with install-hammer.sh (not just built by hand).
    var isSetUp: Bool { FileManager.default.fileExists(atPath: Self.repo.appendingPathComponent("update.sh").path) }

    func start() {
        readStatus()
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { Updates.shared.readStatus() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
        checkLoginItems()
    }

    /// Tells build.sh this Hammer has started properly (it waits for this before it
    /// keeps an update, and otherwise puts the previous Hammer back).
    static func markLaunched(version: String) {
        try? FileManager.default.createDirectory(at: hammerFolder, withIntermediateDirectories: true)
        try? "\(version)\n\(getpid())\n".write(to: hammerFolder.appendingPathComponent(".launched"),
                                               atomically: true, encoding: .utf8)
    }

    /// Tells build.sh you quit this Hammer yourself (Quit Hammer, or logging out), so
    /// quitting a new version in its first seconds doesn't count as it crashing.
    /// (build.sh's own stop for an update is a plain kill, which doesn't come here.)
    static func markQuit(version: String) {
        try? "\(version)\n".write(to: hammerFolder.appendingPathComponent(".quit"), atomically: true, encoding: .utf8)
    }

    // MARK: The menu line

    /// The line under Check for Updates ("Up to date · checked 2:14 PM"), or nil.
    var menuLine: String? {
        // Until update.sh says something (it may be busy: then its own line shows).
        if let asked, (status?.time ?? .distantPast) < asked.addingTimeInterval(-2),
           Date().timeIntervalSince(asked) < 180 { return "Checking…" }
        guard let status, !status.isStale(now: Date()) else { return nil }
        return status.menuLine(when: Self.when(status.time))
    }

    /// "2:14 PM" today, otherwise "Oct 22".
    static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }

    private func readStatus() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: Self.statusFile.path))?[.modificationDate] as? Date
        guard modified != statusModified else { return }
        statusModified = modified
        guard let text = try? String(contentsOf: Self.statusFile, encoding: .utf8),
              let read = UpdateStatus.parse(text) else { return }
        let changed = read != status
        status = read
        let defaults = UserDefaults.standard
        if let notice = read.notice(asked: asked, lastNotice: defaults.string(forKey: "updateNotice"), now: Date()) {
            defaults.set(read.noticeKey, forKey: "updateNotice")
            notify(notice.title, notice.body)
        }
        if let asked, !read.inProgress, read.time >= asked.addingTimeInterval(-2) {
            self.asked = nil                 // answered
            onChange?()
        } else if changed {
            onChange?()
        }
    }

    // MARK: Checking

    /// Every 2 minutes: asks update.sh to look for a new version (it's quiet unless it
    /// installs one), and checks that the login items are still on.
    func kick() {
        guard isSetUp else { return }
        run("launchctl kickstart '\(Self.domain)/local.hammer.updater'") { _ in }
        checkLoginItems()
    }

    /// Check for Updates: asks update.sh to run now, and says so straight away. Its
    /// answer (even "up to date") comes as a notification. The updater must run as
    /// its own job, not as part of Hammer, or it would stop along with the old Hammer.
    func checkNow() {
        asked = Date()
        onChange?()
        // Tells update.sh this check was asked for, so it retries a version that failed.
        FileManager.default.createFile(atPath: hammerFolder.appendingPathComponent(".manual-check").path, contents: nil)
        notify("Checking for updates…", "")
        let plist = Self.agents.appendingPathComponent("local.hammer.updater.plist").path
        // Start the job; if it isn't loaded, load it (loading also starts it).
        run("launchctl kickstart '\(Self.domain)/local.hammer.updater' || launchctl bootstrap '\(Self.domain)' '\(plist)'") {
            [weak self] status in
            guard let self, status != 0 else { return }
            self.asked = nil
            self.checkLoginItems()
            self.notify("Couldn't check for updates", "Updates are off. Turn them on from Hammer's menu.")
        }
    }

    // MARK: Login items

    /// Are both login items on? You can turn them off in System Settings → General →
    /// Login Items, and then Hammer doesn't update or open at login. One that's written
    /// but not loaded yet isn't off: an install from before Hammer's login items were
    /// loaded straight away leaves it so until the next login (or restart).
    func checkLoginItems(done: ((Bool) -> Void)? = nil) {
        guard isSetUp else { off = nil; done?(false); return }
        let updater = Self.agents.appendingPathComponent("local.hammer.updater.plist").path
        let login = Self.agents.appendingPathComponent("local.hammer.plist").path
        let script = """
        disabled="$(launchctl print-disabled '\(Self.domain)' 2>/dev/null)"
        boot="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \\([0-9]*\\).*/\\1/p')"
        off() {   # off <label> <plist>
          printf '%s' "$disabled" | grep -Eq "\\"$1\\" => (disabled|true)" && return 0
          launchctl print "\(Self.domain)/$1" >/dev/null 2>&1 && return 1
          # Not loaded: off, unless it was written after this Mac started (it loads at the next login).
          [ -n "$boot" ] && [ "$(stat -f %m "$2" 2>/dev/null || echo 0)" -lt "$boot" ]
        }
        [ -f '\(updater)' ] || exit 3
        off local.hammer.updater '\(updater)' && exit 3
        [ -f '\(login)' ] && off local.hammer '\(login)' && exit 4
        exit 0
        """
        run(script) { [weak self] status in
            guard let self else { return }
            let now: String? = status == 3 ? "Updates are off" : status == 4 ? "Opening at login is off" : nil
            if now != self.off {
                self.off = now
                self.onChange?()
            }
            done?(now != nil)
        }
    }

    /// Turn On…: sets the login items up again and turns them on. If macOS keeps one
    /// off (it was switched off in Login Items), shows where to turn it back on.
    func turnOn(then next: (() -> Void)? = nil) {
        let script = Self.repo.appendingPathComponent("agents.sh").path
        run("/bin/bash '\(script)'") { [weak self] _ in
            self?.checkLoginItems { stillOff in
                if stillOff { fromRunLoop { self?.explainLoginItems() } } else { next?() }
            }
        }
    }

    private func explainLoginItems() {
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        let alert = NSAlert()
        alert.messageText = "Turn Hammer on in Login Items"
        alert.informativeText = "In System Settings → General → Login Items, under Allow in the Background, "
            + "turn on Hammer and Hammer Updates (until you next log in, they may be listed as "
            + "“open” and “bash”). Then Hammer opens when you log in and keeps itself up to date."
        alert.addButton(withTitle: "Open Login Items")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Notifications (from Hammer itself, so macOS shows them as Hammer's)

    /// Shows a notification, asking for permission first if Hammer never has.
    private func notify(_ title: String, _ body: String) {
        whenNotificationsAllowed { [weak self] in self?.post(title, body) }
    }

    private func post(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }      // only an app bundle can
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // One at a time: the answer replaces "Checking for updates…".
        let request = UNNotificationRequest(identifier: "hammer-update", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    /// Asks for permission if Hammer never has, then runs `then` if notifications are allowed.
    private func whenNotificationsAllowed(_ then: @escaping @MainActor () -> Void) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { Task { @MainActor in then() } }
                }
            case .denied: break
            default: Task { @MainActor in then() }
            }
        }
    }

    // MARK: Running commands

    /// Runs a shell command off the main thread; `done` gets its exit status.
    private func run(_ command: String, done: @escaping @MainActor (Int32) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in done(status) }
        }
        do { try task.run() } catch { done(-1) }
    }
}

// MARK: - The app icon

@MainActor
enum AppIcon {
    /// `Hammer make-icon <folder>`: the icon at every size macOS's iconutil wants
    /// (build.sh turns the folder into Hammer.icns). Returns false if it can't.
    static func write(to folder: URL) -> Bool {
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return false }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
                guard let png = draw(pixels: size * scale),
                      (try? png.write(to: folder.appendingPathComponent(name))) != nil else { return false }
            }
        }
        return true
    }

    /// The hammer symbol in white on a rounded square with an orange gradient, on
    /// macOS's icon grid (the square is 824 of 1024 points, with room for its shadow).
    static func draw(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep),
              let symbol = NSImage(systemSymbolName: "hammer", accessibilityDescription: nil) else { return nil }
        let size = CGFloat(pixels)
        let unit = size / 1024
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context

        let square = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let shape = NSBezierPath(roundedRect: square, xRadius: 185 * unit, yRadius: 185 * unit)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 20 * unit
        shadow.shadowOffset = NSSize(width: 0, height: -8 * unit)
        shadow.set()
        NSColor.black.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        let gradient = NSGradient(starting: NSColor(srgbRed: 1.00, green: 0.62, blue: 0.24, alpha: 1),
                                  ending: NSColor(srgbRed: 0.91, green: 0.30, blue: 0.12, alpha: 1))
        gradient?.draw(in: shape, angle: -90)                       // lighter at the top

        let configured = symbol.withSymbolConfiguration(.init(pointSize: 400 * unit, weight: .semibold)) ?? symbol
        let glyph = configured.size
        guard glyph.width > 0, glyph.height > 0 else { return nil }
        let white = NSImage(size: glyph, flipped: false) { rect in
            configured.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let scale = min(520 * unit / glyph.width, 520 * unit / glyph.height)
        let drawn = NSSize(width: glyph.width * scale, height: glyph.height * scale)
        white.draw(in: NSRect(x: square.midX - drawn.width / 2, y: square.midY - drawn.height / 2,
                              width: drawn.width, height: drawn.height))
        return rep.representation(using: .png, properties: [:])
    }
}
