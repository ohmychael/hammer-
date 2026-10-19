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
/// Microsoft Edge"). The scripts only ever send Hammer window numbers, positions
/// and whether they're minimized: never your tabs' addresses, and Hammer never
/// reads Edge's cookies, passwords or history.
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

    /// How Hammer knows its new window: its address starts with this. A video's
    /// address without the start time (YouTube may drop it); otherwise the address itself.
    static func matchPrefix(_ url: URL) -> String {
        let text = url.absoluteString
        if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.path == "/watch",
           let id = parts.queryItems?.first(where: { $0.name == "v" })?.value, YouTubeLink.isVideoID(id) {
            return "https://www.youtube.com/watch?v=\(id)"
        }
        return text
    }

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

    /// The windows that could be Hammer's: ordinary (not InPrivate) Edge windows
    /// with one tab whose address starts with `prefix`. The check happens inside
    /// Edge's script; only their numbers come back, as "3,7,".
    static func findScript(prefix: String) -> String {
        """
        \(tellEdge)
            set found to ""
            repeat with w in windows
                try
                    if (mode of w is "normal") and ((count of tabs of w) is 1) and ((URL of active tab of w) starts with \(quoted(prefix))) then
                        set found to found & ((id of w) as text) & ","
                    end if
                end try
            end repeat
            return found
        end tell
        """
    }

    static func parseIDs(_ output: String) -> Set<Int> {
        Set(output.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Int($0) })
    }

    /// The window Hammer just opened: one that wasn't there before. If several
    /// (Edge was starting and brought back windows too), the newest.
    static func newWindow(after: Set<Int>, before: Set<Int>) -> Int? {
        after.subtracting(before).max()
    }

    /// Hammer's window: "missing", or a first line "minimized,left,top,right,bottom",
    /// then "id,minimized,index" for each Edge window (to tell which is in front).
    static func stateScript(id: Int) -> String {
        """
        set sep to ","
        set nl to character id 10
        \(tellEdge)
            if not (exists window id \(id)) then return "missing"
            set w to window id \(id)
            set b to bounds of w
            set out to ((minimized of w) as text) & sep & (item 1 of b as text) & sep & (item 2 of b as text) & sep & (item 3 of b as text) & sep & (item 4 of b as text) & nl
            repeat with v in windows
                try
                    set out to out & ((id of v) as text) & sep & ((minimized of v) as text) & sep & ((index of v) as text) & nl
                end try
            end repeat
            return out
        end tell
        """
    }

    /// Where an Edge window is in the front-to-back order.
    struct Order: Equatable {
        let id: Int
        let minimized: Bool
        let index: Double            // Edge may count from 0 or 1, and give minimized windows a huge number
    }

    struct State: Equatable {
        let id: Int
        let minimized: Bool
        let bounds: [Int]
        let windows: [Order]

        /// In front of Edge's other windows: not minimized, and first among those
        /// that aren't (whether Edge counts from 0 or 1, and with other windows
        /// such as picture in picture in between).
        var inFront: Bool {
            guard !minimized else { return false }
            let shown = windows.filter { !$0.minimized }
            guard let first = shown.min(by: { $0.index < $1.index }) else { return true }   // no order given
            return first.id == id
        }
    }

    enum StateAnswer: Equatable {
        case missing
        case found(State)
        case unreadable              // there, but the answer didn't make sense
    }

    private static func flag(_ text: Substring) -> Bool? {
        switch text.trimmingCharacters(in: .whitespaces) { case "true": return true; case "false": return false; default: return nil }
    }

    private static func number(_ text: Substring) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
    }

    static func parseState(_ output: String, id: Int) -> StateAnswer {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let first = lines.first else { return .unreadable }
        if first.trimmingCharacters(in: .whitespaces) == "missing" { return .missing }
        let head = first.split(separator: ",", omittingEmptySubsequences: false)
        guard head.count == 5, let minimized = flag(head[0]) else { return .unreadable }
        let bounds = head[1...].compactMap { number($0).map { Int($0.rounded()) } }
        guard bounds.count == 4 else { return .unreadable }
        let windows = lines.dropFirst().compactMap { line -> Order? in
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 3, let wid = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let min = flag(parts[1]), let index = number(parts[2]) else { return nil }
            return Order(id: wid, minimized: min, index: index)
        }
        return .found(State(id: id, minimized: minimized, bounds: bounds, windows: windows))
    }

    enum Action: Equatable {
        case open       // no window (you closed it): open one
        case show       // bring it to the corner, in front
        case hide       // it's in front: tuck it away (minimize; a playing video keeps playing)
    }

    /// The shortcut toggles: in front → away; anywhere else → in front, in the corner.
    /// A window that's there but answered oddly is shown, never opened again.
    static func decide(_ answer: StateAnswer, edgeIsFrontApp: Bool) -> Action {
        switch answer {
        case .missing: return .open
        case .unreadable: return .show
        case .found(let state): return state.inFront && edgeIsFrontApp ? .hide : .show
        }
    }

    /// In the corner and in front of Edge's other windows (Hammer then brings Edge
    /// forward). Moved before it's un-minimized, and again once it's back (it
    /// may still have been on its way back to its old place).
    static func showScript(id: Int, bounds: [Int]) -> String {
        let b = bounds.count == 4 ? bounds : [0, 0, 760, 460]
        let box = "{\(b[0]), \(b[1]), \(b[2]), \(b[3])}"
        return """
        \(tellEdge)
            set w to window id \(id)
            set wasMinimized to minimized of w
            set bounds of w to \(box)
            if wasMinimized then set minimized of w to false
            set index of w to 1
        end tell
        if wasMinimized then
            delay 0.4
            \(tellEdge) to set bounds of window id \(id) to \(box)
        end if
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

    /// What to tell you when a script fails: short and plain (the details go to Hammer's log).
    static func plainError(_ number: Int?) -> String {
        switch number {
        case nil: return "Microsoft Edge didn't answer. If it's busy or showing a question, deal with that and try again."
        case .some(-600): return "Microsoft Edge quit while Hammer was opening YouTube. Try again."
        case .some(-1728), .some(-1719): return "YouTube's Edge window closed while Hammer was moving it. Try again."
        case let code?: return "Microsoft Edge couldn't do that just now (error \(code)). Try again."
        }
    }
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
    /// Starts Edge (or hands it these arguments if it's running). false: it didn't.
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
        case failed(String)                      // plain words, for you
    }

    let driver: EdgeDriver
    /// Looking for a window Hammer just opened stops after this long.
    var findFor: TimeInterval = 25
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
        case .denied, .notAsked:
            // Can't steer it, but a video you asked for still plays (Edge puts the window where it likes).
            guard let url else { return .notAllowed(openedAnyway: false) }
            return .notAllowed(openedAnyway: await driver.launch(EdgeYouTube.launchArguments(url)))
        }
        guard let id = savedWindow(for: edge) else { return await open(target, edgeWasRunning: true) }

        let answer: EdgeYouTube.StateAnswer
        switch await driver.run(EdgeYouTube.stateScript(id: id)) {
        case .ok(let text): answer = EdgeYouTube.parseState(text, id: id)
        case .failed(let number, _):
            if number == EdgeYouTube.notAllowed { return .notAllowed(openedAnyway: false) }
            if number == -600 { return await open(target, edgeWasRunning: false) }      // Edge quit meanwhile
            if number == -1728 || number == -1719 { answer = .missing } else { return .failed(EdgeYouTube.plainError(number)) }
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
        case .failed(let number, _):
            return number == EdgeYouTube.notAllowed ? .notAllowed(openedAnyway: false) : .failed(EdgeYouTube.plainError(number))
        }
    }

    /// Opens a new app window, finds it among Edge's windows, remembers it and puts it in the corner.
    private func open(_ url: URL, edgeWasRunning: Bool) async -> Outcome {
        let find = EdgeYouTube.findScript(prefix: EdgeYouTube.matchPrefix(url))
        var before = Set<Int>()
        if edgeWasRunning {
            // Windows that already look like it aren't the new one. If Edge can't say, don't guess.
            switch await driver.run(find) {
            case .ok(let text): before = EdgeYouTube.parseIDs(text)
            case .failed(let number, _):
                if number == EdgeYouTube.notAllowed { return .notAllowed(openedAnyway: false) }
                if number != -600 { return .failed(EdgeYouTube.plainError(number)) }
            }
        }
        guard await driver.launch(EdgeYouTube.launchArguments(url)) else {
            return .failed("Microsoft Edge didn't open. If it's showing a question, answer it and try again.")
        }
        var asked = edgeWasRunning
        let deadline = Date().addingTimeInterval(findFor)
        for _ in 0..<60 where Date() < deadline {               // about 15 seconds, more if Edge is slow
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
            guard case .ok(let text) = await driver.run(find),
                  let id = EdgeYouTube.newWindow(after: EdgeYouTube.parseIDs(text), before: before) else { continue }
            driver.remember("\(edge)|\(id)", windowKey)
            _ = await driver.run(EdgeYouTube.showScript(id: id, bounds: corner(nil)))
            await driver.bringForward()
            return .opened
        }
        return .failed("YouTube opened in Edge, but Hammer couldn't find its window to put it in the corner.")
    }
}
