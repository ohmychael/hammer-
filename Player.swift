// Player.swift — the YouTube mini player's logic: recognizing YouTube links,
// which pages stay inside the player, and where the dropdown and the floating
// mini player go on screen. Foundation only, so it's tested on any machine
// (Tests/main.swift). The windows are in PlayerMac.swift; the bit that runs
// inside the YouTube page is PlayerScript.js.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics          // on a Mac, CGRect's helpers (width, maxX…) live here, not in Foundation
#endif

// MARK: - YouTube links

enum YouTubeLink {
    /// The mobile site: it fits a narrow window and plays inline.
    static let home = URL(string: "https://m.youtube.com/")!

    static func watchURL(id: String, start: Int? = nil) -> URL {
        var parts = URLComponents(string: "https://m.youtube.com/watch")!
        parts.queryItems = [URLQueryItem(name: "v", value: id)]
            + (start.map { [URLQueryItem(name: "t", value: "\($0)s")] } ?? [])
        return parts.url!
    }

    static func searchURL(_ query: String) -> URL {
        var parts = URLComponents(string: "https://m.youtube.com/results")!
        parts.queryItems = [URLQueryItem(name: "search_query", value: query)]
        return parts.url!
    }

    /// The video in a link: youtube.com/watch?v=…, youtu.be/…, /shorts/…, /embed/…,
    /// /live/…, /v/…, on www., m. or music., with or without https://, and the
    /// start time if it has one (t=90, t=1m30s, start=90). nil if it isn't one.
    static func video(in text: String) -> (id: String, start: Int?)? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.count < 2048, !raw.contains(" "), !raw.contains("\n") else { return nil }
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") { raw = "https://" + raw }
        guard let parts = URLComponents(string: raw), let host = parts.host?.lowercased() else { return nil }
        let query = parts.queryItems ?? []
        func item(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let start = (item("t") ?? item("start")).flatMap(parseTime)
        let path = parts.path.split(separator: "/").map(String.init)

        var id: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            id = path.first
        } else if isYouTubeHost(host) {
            if path.first == "watch" {
                id = item("v")
            } else if path.count >= 2, ["shorts", "embed", "live", "v", "e"].contains(path[0]) {
                id = path[1]
            }
        }
        guard let found = id, isVideoID(found) else { return nil }
        return (found, start)
    }

    /// YouTube video IDs are 11 characters: letters, digits, - and _.
    static func isVideoID(_ text: String) -> Bool {
        text.count == 11 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// "90", "90s", "1m30s", "1h2m3s" → seconds. Absurd numbers give nil, never a crash.
    static func parseTime(_ text: String) -> Int? {
        guard text.count <= 24 else { return nil }
        if text.allSatisfy(\.isNumber) { return text.count <= 7 ? Int(text) : nil }
        var total = 0, number = "", sawUnit = false
        for character in text.lowercased() {
            if character.isASCII && character.isNumber {
                number.append(character)
            } else {
                guard number.count <= 7, let value = Int(number) else { return nil }     // up to 9,999,999
                switch character {
                case "h": total += value * 3600
                case "m": total += value * 60
                case "s": total += value
                default: return nil
                }
                number = ""
                sawUnit = true
            }
        }
        guard sawUnit, number.isEmpty else { return nil }
        return total
    }

    static func isYouTubeHost(_ host: String) -> Bool {
        host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
}

// MARK: - Which pages stay in the player

enum PlayerNavigation: Equatable {
    case stay            // YouTube, and Google's sign-in and consent pages
    case openInBrowser   // a web link you clicked (in a video description, an ad)
    case block           // anything else: links to other apps, files, pages nobody clicked

    /// `clicked`: you clicked a link (or a button that opens a window), rather
    /// than the page going there by itself.
    static func decide(_ url: URL, clicked: Bool) -> PlayerNavigation {
        guard let scheme = url.scheme?.lowercased() else { return .block }
        if scheme == "about" || scheme == "blob" || scheme == "data" { return .stay }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return .block }
        if staysInside(host) { return .stay }
        return clicked ? .openInBrowser : .block
    }

    static func staysInside(_ host: String) -> Bool {
        if YouTubeLink.isYouTubeHost(host) || host == "youtu.be" { return true }
        // Signing in to YouTube goes through these.
        let google = ["accounts.google.com", "consent.google.com", "myaccount.google.com", "gds.google.com", "www.google.com"]
        if google.contains(host) { return true }
        // Google's sign-in in other countries: accounts.google.de, .co.uk, .com.au …
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 3, parts[0] == "accounts", parts[1] == "google" else { return false }
        let country = Array(parts.dropFirst(2))
        let isCountry = { (code: String) in code.count == 2 && code.allSatisfy { $0.isASCII && $0.isLetter } }
        if country.count == 1 { return isCountry(country[0]) }
        if country.count == 2 { return ["co", "com"].contains(country[0]) && isCountry(country[1]) }
        return false
    }
}

// MARK: - Where the windows go

/// Screen coordinates as macOS uses them: origin at the bottom left, and the
/// visible frame is the screen minus the menu bar and the Dock.
enum PlayerGeometry {
    static let dropdownSize = CGSize(width: 760, height: 460)       // wide and short; you can resize it
    static let minDropdownSize = CGSize(width: 480, height: 300)
    static let miniWidth: CGFloat = 400
    static let minMiniWidth: CGFloat = 240

    /// Flush in the screen's top-right corner, right under the menu bar (the
    /// visible frame's top-right corner), shrunk to fit a small screen.
    static func dropdown(size: CGSize = dropdownSize, visible: CGRect) -> CGRect {
        let width = min(max(size.width, minDropdownSize.width), visible.width)
        let height = min(max(size.height, minDropdownSize.height), visible.height)
        return CGRect(x: visible.maxX - width, y: visible.maxY - height, width: width, height: height)
    }

    /// The mini player's first place: the bottom-right corner, 16:9.
    static func miniDefault(visible: CGRect, width: CGFloat = miniWidth, margin: CGFloat = 16) -> CGRect {
        let w = max(minMiniWidth, min(width, visible.width / 2))
        let h = (w * 9 / 16).rounded()
        return CGRect(x: visible.maxX - margin - w, y: visible.minY + margin, width: w, height: h)
    }

    /// Moves a window to the screen corner nearest its middle.
    static func snap(_ frame: CGRect, in visible: CGRect, margin: CGFloat = 16) -> CGRect {
        let fitted = clamp(frame, in: visible.insetBy(dx: margin, dy: margin))
        let left = fitted.midX < visible.midX
        let bottom = fitted.midY < visible.midY
        return CGRect(x: left ? visible.minX + margin : visible.maxX - margin - fitted.width,
                      y: bottom ? visible.minY + margin : visible.maxY - margin - fitted.height,
                      width: fitted.width, height: fitted.height)
    }

    /// Keeps a window fully on screen (after a screen is unplugged, say), no bigger than the screen.
    static func clamp(_ frame: CGRect, in visible: CGRect) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return frame }
        var width = min(frame.width, visible.width)
        var height = min(frame.height, visible.height)
        if frame.width > 0, frame.height > 0, width / height != frame.width / frame.height {
            let scale = min(width / frame.width, height / frame.height)       // keep the shape
            width = (frame.width * scale).rounded(.down)
            height = (frame.height * scale).rounded(.down)
        }
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - YouTube in your own Microsoft Edge

/// YouTube in Microsoft Edge itself: your profile, so you're signed in and your
/// extensions run. Hammer opens it as an Edge app window (no tabs, no address
/// bar) and keeps it in the screen's top-right corner. Hammer steers that window
/// with AppleScript, which macOS asks you to allow once ("Hammer wants to control
/// Microsoft Edge"). Hammer never reads Edge's cookies, passwords or history.
///
/// These build the scripts and read their answers; EdgeMac.swift runs them.
enum EdgeYouTube {
    static let bundleID = "com.microsoft.edgemac"
    /// The full (desktop) site: it's Edge, so it's what your extensions expect.
    static let home = URL(string: "https://www.youtube.com/")!

    static func watchURL(id: String, start: Int? = nil) -> URL {
        var parts = URLComponents(string: "https://www.youtube.com/watch")!
        parts.queryItems = [URLQueryItem(name: "v", value: id)]
            + (start.map { [URLQueryItem(name: "t", value: "\($0)s")] } ?? [])
        return parts.url!
    }

    /// Edge's command line for a YouTube app window.
    static func launchArguments(_ url: URL) -> [String] { ["--app=\(url.absoluteString)"] }

    // MARK: Where the window goes

    /// AppleScript's window bounds {left, top, right, bottom}: measured from the
    /// top-left corner of the main screen (the one with the menu bar), y going
    /// down. `frame` is in macOS's own coordinates (from the bottom left, y going up).
    static func bounds(_ frame: CGRect, mainScreenHeight: CGFloat) -> [Int] {
        [Int(frame.minX.rounded()), Int((mainScreenHeight - frame.maxY).rounded()),
         Int(frame.maxX.rounded()), Int((mainScreenHeight - frame.minY).rounded())]
    }

    /// The window's size from its bounds, or nil if they don't make sense.
    static func size(ofBounds bounds: [Int]) -> CGSize? {
        guard bounds.count == 4, bounds[2] > bounds[0], bounds[3] > bounds[1] else { return nil }
        return CGSize(width: bounds[2] - bounds[0], height: bounds[3] - bounds[1])
    }

    /// Where to show it: the top-right corner of the screen with the menu bar
    /// icon, at the size you left it (or the default), fitted to the screen.
    static func showBounds(current: [Int]?, visible: CGRect, mainScreenHeight: CGFloat) -> [Int] {
        let size = current.flatMap(size(ofBounds:)) ?? PlayerGeometry.dropdownSize
        return bounds(PlayerGeometry.dropdown(size: size, visible: visible), mainScreenHeight: mainScreenHeight)
    }

    // MARK: The scripts

    /// AppleScript text in quotes. Quotes and backslashes are escaped; anything
    /// that can't go in a one-line script (returns, tabs, control characters) is dropped.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || scalar == "\u{2028}" || scalar == "\u{2029}" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static let tellEdge = "tell application id \(quoted(bundleID))"
    // "tab" means Edge's tabs inside a tell block, so separators are made outside it.
    private static let separators = "set sep to character id 9\nset nl to character id 10\n"

    /// Every Edge window: "id<TAB>tabs<TAB>URL of the tab showing" per line.
    static func listScript() -> String {
        separators + """
        \(tellEdge)
            set out to ""
            repeat with w in windows
                try
                    set u to (URL of active tab of w) as text
                on error
                    set u to ""
                end try
                set out to out & ((id of w) as text) & sep & ((count of tabs of w) as text) & sep & u & nl
            end repeat
            return out
        end tell
        """
    }

    struct Window: Equatable {
        let id: Int
        let tabs: Int
        let url: String
    }

    static func parseList(_ output: String) -> [Window] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let id = Int(parts[0]), let tabs = Int(parts[1]) else { return nil }
            return Window(id: id, tabs: tabs, url: parts[2])
        }
    }

    /// The app window Hammer just opened: a window that wasn't there before, with
    /// one tab, on YouTube. If several (Edge was starting and brought back your
    /// last windows too), the newest.
    static func newWindow(in windows: [Window], before: Set<Int>) -> Int? {
        windows.filter { window in
            guard !before.contains(window.id), window.tabs == 1,
                  let host = URL(string: window.url)?.host?.lowercased() else { return false }
            return YouTubeLink.isYouTubeHost(host) || host == "youtu.be"
        }.map(\.id).max()
    }

    /// The window's state: "missing", or "minimized,index,left,top,right,bottom".
    static func stateScript(id: Int) -> String {
        """
        \(tellEdge)
            if not (exists window id \(id)) then return "missing"
            set w to window id \(id)
            set b to bounds of w
            return ((minimized of w) as text) & "," & ((index of w) as text) & "," & (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text)
        end tell
        """
    }

    struct State: Equatable {
        let minimized: Bool
        let index: Int          // 1: in front of Edge's other windows
        let bounds: [Int]
    }

    enum StateAnswer: Equatable {
        case missing
        case found(State)
        case unreadable
    }

    static func parseState(_ output: String) -> StateAnswer {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "missing" { return .missing }
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 6, parts[0] == "true" || parts[0] == "false", let index = Int(parts[1]) else { return .unreadable }
        let bounds = parts[2...].compactMap { Int($0) ?? Double($0).flatMap { $0.isFinite ? Int($0.rounded()) : nil } }
        guard bounds.count == 4 else { return .unreadable }
        return .found(State(minimized: parts[0] == "true", index: index, bounds: bounds))
    }

    enum Action: Equatable {
        case open       // no window yet (or you closed it): open one
        case show       // bring it to the corner, in front
        case hide       // it's in front: tuck it away (minimize; a playing video keeps playing)
    }

    /// The shortcut toggles: in front → away; anywhere else → in front, in the corner.
    static func decide(_ answer: StateAnswer, edgeIsFrontApp: Bool) -> Action {
        switch answer {
        case .missing, .unreadable: return .open
        case .found(let state):
            return !state.minimized && state.index == 1 && edgeIsFrontApp ? .hide : .show
        }
    }

    /// In the corner and in front of Edge's other windows (Hammer then brings Edge forward).
    static func showScript(id: Int, bounds: [Int]) -> String {
        let b = bounds.count == 4 ? bounds : [0, 0, 760, 460]
        return """
        \(tellEdge)
            set w to window id \(id)
            if minimized of w then set minimized of w to false
            set bounds of w to {\(b[0]), \(b[1]), \(b[2]), \(b[3])}
            set index of w to 1
        end tell
        """
    }

    static func hideScript(id: Int) -> String {
        """
        \(tellEdge)
            set minimized of window id \(id) to true
        end tell
        """
    }

    /// Plays a video in the window that's already open.
    static func goScript(id: Int, url: URL) -> String {
        """
        \(tellEdge)
            set URL of active tab of window id \(id) to \(quoted(url.absoluteString))
        end tell
        """
    }

    /// Edge's own "activate", for when macOS won't let Hammer bring it forward directly.
    static func activateScript() -> String { "\(tellEdge) to activate" }

    /// osascript's error number in its message: "… (-1743)".
    static func errorNumber(_ message: String) -> Int? {
        guard let open = message.lastIndex(of: "("), let close = message.lastIndex(of: ")"), open < close else { return nil }
        return Int(message[message.index(after: open)..<close])
    }

    /// -1743: you said no (or haven't been asked yet) in Privacy & Security → Automation.
    static let notAllowed = -1743
}

// MARK: Steering Edge

/// What the Edge player needs from the Mac. EdgeMac.swift has the real one; the
/// tests use a stand-in Edge.
protocol EdgeDriver: AnyObject {
    var installed: Bool { get }
    /// Edge's process while it runs: changes when Edge restarts (window IDs start over then).
    func running() -> String?
    /// Edge is the app in front.
    func edgeInFront() -> Bool
    /// May Hammer steer Edge? `ask`: show macOS's question if you haven't answered it yet.
    func permission(ask: Bool) async -> EdgePermission
    func run(_ script: String) async -> EdgeScriptResult
    /// Starts Edge (or hands it these arguments if it's running). false: it couldn't.
    func launch(_ arguments: [String]) async -> Bool
    func bringForward() async
    func pause(_ seconds: Double) async
    /// The visible frame of the screen with the menu bar icon, and the main screen's height.
    func screen() -> (visible: CGRect, mainHeight: CGFloat)
    func remembered(_ key: String) -> String?
    func remember(_ value: String?, _ key: String)
}

enum EdgePermission: Equatable { case allowed, denied, notAsked, notRunning }

enum EdgeScriptResult: Equatable {
    case ok(String)
    case failed(number: Int?, message: String)
}

/// The shortcut and the menu, with Edge: opens YouTube in an Edge app window in
/// the corner, brings it back there, or tucks it away.
final class EdgeController {
    enum Outcome: Equatable {
        case opened, shown, hidden
        case notInstalled
        case notAllowed(openedAnyway: Bool)      // you said no in Privacy & Security → Automation
        case failed(String)
    }

    let driver: EdgeDriver
    private let windowKey = "edgeYouTubeWindow"   // "<Edge's run>|<window ID>"
    private let sizeKey = "edgeYouTubeSize"       // the size you last left it at: "width,height"

    init(driver: EdgeDriver) { self.driver = driver }

    /// Hammer's window in this run of Edge, if it opened one.
    func savedWindow(for edge: String) -> Int? {
        guard let saved = driver.remembered(windowKey) else { return nil }
        let parts = saved.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == edge, let id = Int(parts[1]) else { return nil }
        return id
    }

    private var rememberedSize: [Int]? {
        guard let parts = driver.remembered(sizeKey)?.split(separator: ",").compactMap({ Int($0) }),
              parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return [0, 0, parts[0], parts[1]]
    }

    private func rememberSize(_ bounds: [Int]) {
        guard let size = EdgeYouTube.size(ofBounds: bounds) else { return }
        driver.remember("\(Int(size.width)),\(Int(size.height))", sizeKey)
    }

    private func corner(_ current: [Int]?) -> [Int] {
        let screen = driver.screen()
        return EdgeYouTube.showBounds(current: current ?? rememberedSize, visible: screen.visible, mainScreenHeight: screen.mainHeight)
    }

    /// The shortcut: open, show or hide. `play`: a video to play (the window always shows then).
    func toggle(play url: URL? = nil) async -> Outcome {
        guard driver.installed else { return .notInstalled }
        let target = url ?? EdgeYouTube.home
        guard let edge = driver.running() else {
            return await open(target, edgeWasRunning: false)        // starting Edge this way opens just this window
        }
        let inFront = driver.edgeInFront()                         // before anything changes it
        switch await driver.permission(ask: true) {
        case .allowed: break
        case .notRunning: return await open(target, edgeWasRunning: false)   // Edge just quit
        case .denied, .notAsked: return .notAllowed(openedAnyway: false)
        }
        guard let id = savedWindow(for: edge) else { return await open(target, edgeWasRunning: true) }

        let answer: EdgeYouTube.StateAnswer
        switch await driver.run(EdgeYouTube.stateScript(id: id)) {
        case .ok(let text): answer = EdgeYouTube.parseState(text)
        case .failed(let number, let message):
            if number == EdgeYouTube.notAllowed { return .notAllowed(openedAnyway: false) }
            if number == -600 { return await open(target, edgeWasRunning: false) }      // Edge quit meanwhile
            if number == -1728 || number == -1719 { answer = .missing } else { return .failed(message) }
        }
        var action = EdgeYouTube.decide(answer, edgeIsFrontApp: inFront)
        if url != nil && action == .hide { action = .show }        // a video to play: always show it
        switch action {
        case .open:
            return await open(target, edgeWasRunning: true)
        case .hide:
            if case .found(let state) = answer { rememberSize(state.bounds) }
            return outcome(await driver.run(EdgeYouTube.hideScript(id: id)), success: .hidden)
        case .show:
            var current: [Int]?
            if case .found(let state) = answer { current = state.bounds; rememberSize(state.bounds) }
            let shown = await driver.run(EdgeYouTube.showScript(id: id, bounds: corner(current)))
            if case .failed = shown { return outcome(shown, success: .shown) }
            if let url { _ = await driver.run(EdgeYouTube.goScript(id: id, url: url)) }
            await driver.bringForward()
            return .shown
        }
    }

    private func outcome(_ result: EdgeScriptResult, success: Outcome) -> Outcome {
        switch result {
        case .ok: return success
        case .failed(let number, let message):
            return number == EdgeYouTube.notAllowed ? .notAllowed(openedAnyway: false) : .failed(message)
        }
    }

    /// Opens a new app window, finds it among Edge's windows, remembers it and puts it in the corner.
    private func open(_ url: URL, edgeWasRunning: Bool) async -> Outcome {
        var before = Set<Int>()
        if edgeWasRunning, case .ok(let text) = await driver.run(EdgeYouTube.listScript()) {
            before = Set(EdgeYouTube.parseList(text).map(\.id))
        }
        guard await driver.launch(EdgeYouTube.launchArguments(url)) else { return .failed("Microsoft Edge didn't open") }
        var asked = edgeWasRunning
        for _ in 0..<50 {                                          // up to about 15 seconds
            await driver.pause(0.3)
            guard let edge = driver.running() else { continue }
            if !asked {
                // Edge has just started: now macOS can ask whether Hammer may steer it.
                switch await driver.permission(ask: true) {
                case .notRunning: continue
                case .denied, .notAsked: return .notAllowed(openedAnyway: true)
                case .allowed: asked = true
                }
            }
            guard case .ok(let text) = await driver.run(EdgeYouTube.listScript()),
                  let id = EdgeYouTube.newWindow(in: EdgeYouTube.parseList(text), before: before) else { continue }
            driver.remember("\(edge)|\(id)", windowKey)
            _ = await driver.run(EdgeYouTube.showScript(id: id, bounds: corner(nil)))
            await driver.bringForward()
            return .opened
        }
        return .failed("Edge opened YouTube, but Hammer couldn't find its window to put it in the corner")
    }
}
