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
    /// /live/…, /v/…, on www., m. or music., youtube-nocookie.com/embed/…, with or
    /// without https://, and the start time if it has one (t=90, t=1m30s, start=90).
    /// Links as they come in messages work too: <https://…>, or with a "." or ")" after
    /// them. nil if it isn't one.
    static func video(in text: String) -> (id: String, start: Int?)? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("<") && raw.hasSuffix(">") { raw = String(raw.dropFirst().dropLast()) }
        if raw.hasPrefix("(") { raw.removeFirst() }
        while raw.hasSuffix(".") || raw.hasSuffix(")") { raw.removeLast() }
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
        } else if host == "youtube-nocookie.com" || host == "www.youtube-nocookie.com" {
            if path.count >= 2, path[0] == "embed" { id = path[1] }
        }
        guard let found = id, isVideoID(found) else { return nil }
        return (found, start)
    }

    /// YouTube video IDs are 11 characters: letters, digits, - and _.
    static func isVideoID(_ text: String) -> Bool {
        text.count == 11 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// A start time later than this (24 hours) isn't a real one.
    static let latestStart = 24 * 3600

    /// "90", "90s", "1m30s", "1h2m3s" → seconds: each of h, m and s at most once, in that
    /// order, up to 24 hours. Anything else ("1h1h1h", absurd numbers) gives nil, never a crash.
    static func parseTime(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 24 else { return nil }
        if text.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard text.count <= 7, let seconds = Int(text), seconds <= latestStart else { return nil }
            return seconds
        }
        var total = 0, number = ""
        var units = "hms"[...]                               // the units still allowed, in order
        for character in text.lowercased() {
            if character.isASCII && character.isNumber {
                number.append(character)
                continue
            }
            guard number.count <= 7, let value = Int(number),         // up to 9,999,999
                  let at = units.firstIndex(of: character) else { return nil }
            units = units[units.index(after: at)...]
            total += value * (character == "h" ? 3600 : character == "m" ? 60 : 1)
            number = ""
        }
        guard number.isEmpty, total <= latestStart else { return nil }
        return total
    }

    /// The page in your browser: a video on YouTube's full site at the moment you're at
    /// (www.youtube.com/watch?v=…&t=…s), another YouTube page on the full site, and any
    /// other web page as it is. nil for anything that isn't a web page.
    static func browserURL(for page: URL, at seconds: Double?) -> URL? {
        if let video = video(in: page.absoluteString) {
            let now = seconds.flatMap { $0.isFinite && $0 >= 1 && $0 <= Double(latestStart) ? Int($0) : nil }
            return EdgeYouTube.watchURL(id: video.id, start: seconds == nil ? video.start : now)
        }
        guard let scheme = page.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var parts = URLComponents(url: page, resolvingAgainstBaseURL: false), let host = parts.host?.lowercased() else {
            return nil
        }
        if host == "m.youtube.com" || host == "youtube.com" {
            parts.scheme = "https"
            parts.host = "www.youtube.com"
        }
        return parts.url
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
        // Google's sign-in in other countries (accounts.google.de, .co.uk, .com.au …): only Google's own domains.
        let prefix = "accounts.google."
        return host.hasPrefix(prefix) && googleCountries.contains(String(host.dropFirst(prefix.count)))
    }

    /// The country domains Google signs in on: google.de, google.co.uk, google.com.au …
    /// (Google's list of its domains). Only these, so a look-alike can't stay in the player.
    static let googleCountries: Set<String> = {
        let bare = "ad ae al am as at az ba be bf bg bi bj bs bt by ca cat cd cf cg ch ci cl cm cn cv cz de dj dk dm dz ee es "
            + "fi fm fr ga ge gg gl gm gp gr gy hn hr ht hu ie im iq is it je jo kg ki kz la li lk lt lu lv md me mg mk ml mn "
            + "ms mu mv mw ne nl no nr nu pl pn ps pt ro rs ru rw sc se sh si sk sm sn so sr st td tg tk tl tm tn to tt vg vu ws"
        let co = "ao bw ck cr id il in jp ke kr ls ma mz nz th tz ug uk uz ve vi za zm zw"
        let com = "af ag ai ar au bd bh bn bo br bz co cu cy do ec eg et fj gh gi gt hk jm kh kw lb ly mm mt mx my na ng ni "
            + "np om pa pe pg ph pk pr py qa sa sb sg sl sv tj tr tw ua uy vc vn"
        let words = { (text: String) in text.split(separator: " ").map(String.init) }
        return Set(words(bare) + words(co).map { "co." + $0 } + words(com).map { "com." + $0 })
    }()
}

// MARK: - The shortcut's key

/// ⌘Y and ⌃⌥Y go on whichever key types "y" on your keyboard layout, not on the key
/// where Y is on an American keyboard (on a German one that key types Z, so ⌘Y would
/// take Undo; on Dvorak it types F, so ⌘Y would take Find).
enum ShortcutKey {
    static let americanY: UInt16 = 0x10                      // kVK_ANSI_Y

    /// The first key (0 to 127) that types exactly `letter`, given what each key types on
    /// the layout (`typed`, nil if it can't tell). nil if none does (a Cyrillic layout, say).
    static func code(typing letter: String, _ typed: (UInt16) -> String?) -> UInt16? {
        (0..<128).map(UInt16.init).first { typed($0) == letter }
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
        [whole(frame.minX), whole(mainScreenHeight - frame.maxY), whole(frame.maxX), whole(mainScreenHeight - frame.minY)]
    }

    /// No screen is ten million points across: a position or size from Edge beyond this is nonsense.
    static let farthest: Double = 10_000_000

    /// A point as a whole number, never a crash (nonsense becomes 0, or the farthest there is).
    private static func whole(_ value: CGFloat) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(max(Double(value), -farthest), farthest).rounded())
    }

    /// The window's size from its bounds, or nil if they don't make sense. Worked out in
    /// Double, so huge numbers can't overflow.
    static func size(ofBounds bounds: [Int]) -> CGSize? {
        guard bounds.count == 4, bounds.allSatisfy({ abs(Double($0)) <= farthest }) else { return nil }
        let width = Double(bounds[2]) - Double(bounds[0]), height = Double(bounds[3]) - Double(bounds[1])
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Where to show it: the top-right corner of the screen (the one with the
    /// pointer), at the size you left it (or the default), fitted to the screen.
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

    /// Where YouTube may send a new window before Hammer looks (its cookie
    /// question, in some countries): still Hammer's window.
    static let detours = ["https://consent.youtube.com/"]

    /// Hammer's window on any YouTube page (you may have gone to another video since).
    static let anyPage = [home.absoluteString] + detours

    /// The windows that could be Hammer's: ordinary (not InPrivate) Edge windows
    /// with one tab whose address starts with one of `prefixes` and, with `at`, whose
    /// bounds are exactly those. The script does the checking; only the windows'
    /// numbers come back to Hammer, as "3,7,".
    static func findScript(prefixes: [String], at place: [Int]? = nil) -> String {
        let address = prefixes.isEmpty ? "false"
            : prefixes.map { "(u starts with \(quoted($0)))" }.joined(separator: " or ")
        let there = place.flatMap { $0.count == 4 ? " and ((bounds of w) is {\($0.map(String.init).joined(separator: ", "))})" : nil }
            ?? ""
        return """
        \(tellEdge)
            set found to ""
            repeat with w in windows
                try
                    if (mode of w is "normal") and ((count of tabs of w) is 1) then
                        set u to URL of active tab of w
                        if (\(address))\(there) then set found to found & ((id of w) as text) & ","
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

    /// A position on screen: a whole number within ten million points, else nil (never a crash).
    private static func coordinate(_ text: Substring) -> Int? {
        guard let value = number(text), abs(value) <= farthest else { return nil }
        return Int(exactly: value.rounded())
    }

    static func parseState(_ output: String, id: Int) -> StateAnswer {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let first = lines.first else { return .unreadable }
        if first.trimmingCharacters(in: .whitespaces) == "missing" { return .missing }
        let head = first.split(separator: ",", omittingEmptySubsequences: false)
        guard head.count == 5, let minimized = flag(head[0]) else { return .unreadable }
        let bounds = head[1...].compactMap(coordinate)
        guard bounds.count == 4 else { return .unreadable }
        let windows = lines.dropFirst().compactMap { line -> Order? in
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 3, let wid = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let min = flag(parts[1]), let index = number(parts[2]) else { return nil }
            return Order(id: wid, minimized: min, index: index)
        }
        return .found(State(id: id, minimized: minimized, bounds: bounds, windows: windows))
    }

    /// Edge has other windows showing besides Hammer's (so after tucking it away
    /// you're still in Edge, on purpose).
    static func othersShown(_ state: State) -> Bool {
        state.windows.contains { $0.id != state.id && !$0.minimized }
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
    /// The visible frame of the screen to show it on (the one with the pointer), and the main screen's height.
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
        case opened, shown
        case hidden(othersShown: Bool)           // whether Edge still shows other windows
        case notInstalled
        case notAllowed(openedAnyway: Bool)      // you said no in Privacy & Security → Automation
        case failed(String)                      // plain words, for you
    }

    let driver: EdgeDriver
    /// Looking for a window Hammer just opened stops after this long.
    var findFor: TimeInterval = 25
    /// The time now (the tests set their own).
    var clock: () -> Date = Date.init
    /// A window Hammer opened but hasn't found is looked for this long afterwards, no longer.
    static let launchedFor: TimeInterval = 600
    private let windowKey = "edgeYouTubeWindow"   // "<Edge's run>|<window ID>"
    private let sizeKey = "edgeYouTubeSize"       // the size you last left it at: "width,height"
    /// A window Hammer opened but hasn't found yet: "<Edge's run, or nothing if Edge wasn't
    /// running yet>|<when, in seconds since 1970>|<the window IDs that were there already, or ?
    /// if Hammer couldn't look>|<the start of the address it opened>".
    private let launchedKey = "edgeYouTubeLaunched"
    /// Where Hammer's window last was, "left,top,right,bottom": Edge puts it back there when it restarts.
    private let placeKey = "edgeYouTubePlace"

    init(driver: EdgeDriver) { self.driver = driver }

    /// Hammer's window in this run of Edge, if it opened one.
    func savedWindow(for edge: String) -> Int? {
        guard let saved = driver.remembered(windowKey) else { return nil }
        let parts = saved.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == edge, let id = Int(parts[1]) else { return nil }
        return id
    }

    /// A window Hammer opened in the last ten minutes, in this run of Edge (or just before
    /// Edge started), that it hasn't found yet: the windows that were already there then
    /// (nil if Hammer couldn't look), and the start of the address it opened.
    func launchedUnfound(in edge: String) -> (besides: Set<Int>?, prefix: String)? {
        guard let saved = driver.remembered(launchedKey) else { return nil }
        let parts = saved.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let when = Double(parts[1]), !parts[3].isEmpty else { return nil }
        let age = clock().timeIntervalSince1970 - when
        guard age >= -60, age < Self.launchedFor else { return nil }
        if !parts[0].isEmpty && String(parts[0]) != edge { return nil }
        return (parts[2] == "?" ? nil : EdgeYouTube.parseIDs(String(parts[2])), String(parts[3]))
    }

    /// `besides`: the windows already there that look like it; nil when Hammer couldn't look.
    private func markLaunched(_ url: URL, in edge: String?, besides: Set<Int>?) {
        let when = Int(clock().timeIntervalSince1970)
        let there = besides.map { $0.sorted().map(String.init).joined(separator: ",") } ?? "?"
        driver.remember("\(edge ?? "")|\(when)|\(there)|" + EdgeYouTube.matchPrefix(url), launchedKey)
    }

    /// From now on this is Hammer's window.
    private func keep(_ id: Int, in edge: String) {
        driver.remember("\(edge)|\(id)", windowKey)
        driver.remember(nil, launchedKey)
    }

    private var rememberedSize: [Int]? {
        guard let parts = driver.remembered(sizeKey)?.split(separator: ",").compactMap({ Int($0) }),
              parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return [0, 0, parts[0], parts[1]]
    }

    /// Where Hammer's window last was (Edge puts it back there when it restarts).
    var rememberedPlace: [Int]? {
        guard let parts = driver.remembered(placeKey)?.split(separator: ",", omittingEmptySubsequences: false),
              parts.count == 4 else { return nil }
        let bounds = parts.compactMap { Int($0) }
        return bounds.count == 4 && EdgeYouTube.size(ofBounds: bounds) != nil ? bounds : nil
    }

    private func rememberPlace(_ bounds: [Int]) {
        guard EdgeYouTube.size(ofBounds: bounds) != nil else { return }
        driver.remember(bounds.map(String.init).joined(separator: ","), placeKey)
    }

    /// Where the window is now: its size for next time, and its place.
    private func remember(_ bounds: [Int]) {
        guard let size = EdgeYouTube.size(ofBounds: bounds) else { return }
        driver.remember("\(Int(size.width)),\(Int(size.height))", sizeKey)
        rememberPlace(bounds)
    }

    private func corner(_ current: [Int]?) -> [Int] {
        let screen = driver.screen()
        return EdgeYouTube.showBounds(current: current ?? rememberedSize, visible: screen.visible, mainScreenHeight: screen.mainHeight)
    }

    /// The shortcut: open, show or hide. `play`: a video to play (the window always shows then).
    func toggle(play url: URL? = nil) async -> Outcome {
        guard driver.installed else { return .notInstalled }
        let target = url ?? EdgeYouTube.home
        guard var edge = driver.running() else {
            return await open(target, play: url != nil)            // starting Edge this way opens just this window
        }
        let inFront = driver.edgeInFront()                         // before anything changes it
        var permission = await driver.permission(ask: true)
        var waits = 0
        while permission == .notRunning && waits < 10 {
            // macOS says Edge isn't there while it's starting or quitting: wait until it's one or the other.
            waits += 1
            await driver.pause(0.3)
            guard let now = driver.running() else { break }
            edge = now
            permission = await driver.permission(ask: true)
        }
        switch permission {
        case .allowed: break
        case .notRunning:
            guard driver.running() == nil else { return .failed(EdgeYouTube.plainError(nil)) }
            return await open(target, play: url != nil)            // Edge quit: start it again with the window
        case .denied, .notAsked: return await openUnsteered(url, in: edge)
        }
        var found = savedWindow(for: edge)
        var neverPlaced = false
        if found == nil {
            switch await findOwn(in: edge) {
            case .window(let id, let placed): found = id; neverPlaced = !placed
            case .nothing: break
            case .stop(let outcome): return outcome
            }
        }
        guard let id = found else { return await open(target, play: url != nil) }

        var answer = EdgeYouTube.StateAnswer.unreadable
        for attempt in 1...2 {
            switch await driver.run(EdgeYouTube.stateScript(id: id)) {
            case .ok(let text): answer = EdgeYouTube.parseState(text, id: id)
            case .failed(let number, _):
                if number == EdgeYouTube.notAllowed { return .notAllowed(openedAnyway: false) }
                if number == -600 { return await open(target, play: url != nil) }      // Edge quit meanwhile
                guard number == -1728 || number == -1719 else { return .failed(EdgeYouTube.plainError(number)) }
                // The window went while Edge was answering: make sure before opening another.
                answer = .missing
                if attempt == 1 { continue }
            }
            break
        }
        // Edge's own size for a window Hammer never placed isn't yours: that one gets the size you chose.
        if case .found(let state) = answer, !neverPlaced { remember(state.bounds) }
        var action = EdgeYouTube.decide(answer, edgeIsFrontApp: inFront)
        // A video to play, or a window Hammer has never put in the corner: always shown.
        if (url != nil || neverPlaced) && action == .hide { action = .show }
        switch action {
        case .open:
            return await open(target, play: url != nil)
        case .hide:
            var others = false
            if case .found(let state) = answer { others = EdgeYouTube.othersShown(state) }
            return outcome(await driver.run(EdgeYouTube.hideScript(id: id)), success: .hidden(othersShown: others))
        case .show:
            var current: [Int]?
            if case .found(let state) = answer, !neverPlaced { current = state.bounds }
            let place = corner(current)
            let shown = await driver.run(EdgeYouTube.showScript(id: id, bounds: place))
            if case .failed = shown { return outcome(shown, success: .shown) }
            rememberPlace(place)
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

    /// Hammer may not steer Edge: a video you asked for still plays (Edge puts the window
    /// where it likes). Once you allow Hammer, the next press finds that window rather
    /// than opening another. Hammer couldn't look at Edge's windows first, so it won't guess
    /// between several that look like it.
    private func openUnsteered(_ url: URL?, in edge: String?) async -> Outcome {
        guard let url else { return .notAllowed(openedAnyway: false) }
        let opened = await driver.launch(EdgeYouTube.launchArguments(url))
        if opened { markLaunched(url, in: edge, besides: nil) }
        return .notAllowed(openedAnyway: opened)
    }

    private enum Found { case window(Int, placed: Bool), nothing, stop(Outcome) }

    /// No window of Hammer's in this run of Edge yet: is one there anyway? The one Hammer
    /// opened in the last ten minutes but couldn't find (Edge was slow, or you hadn't allowed
    /// Hammer yet): on the address it opened, not there before, the first to come (later
    /// ones are yours). Or the one Edge brought back when it restarted: exactly where
    /// Hammer's last was. The scripts do the matching; only window numbers come back.
    private func findOwn(in edge: String) async -> Found {
        var searches: [(script: String, besides: Set<Int>?, placed: Bool)] = []
        if let launched = launchedUnfound(in: edge) {
            searches.append((EdgeYouTube.findScript(prefixes: [launched.prefix] + EdgeYouTube.detours), launched.besides, false))
        }
        if let place = rememberedPlace {
            searches.append((EdgeYouTube.findScript(prefixes: EdgeYouTube.anyPage, at: place), [], true))
        }
        for search in searches {
            switch await driver.run(search.script) {
            case .ok(let text):
                if !search.placed { driver.remember(nil, launchedKey) }     // looked for once
                let candidates = EdgeYouTube.parseIDs(text).subtracting(search.besides ?? [])
                // Hammer couldn't look before it opened its window: of several, any could be yours.
                if search.besides == nil && candidates.count > 1 { continue }
                guard let id = search.placed ? candidates.max() : candidates.min() else { continue }
                keep(id, in: edge)
                return .window(id, placed: search.placed)
            case .failed(let number, _):
                if number == EdgeYouTube.notAllowed { return .stop(.notAllowed(openedAnyway: false)) }
                if number == -600 { return .nothing }                       // Edge quit meanwhile: opening starts it again
                return .stop(.failed(EdgeYouTube.plainError(number)))
            }
        }
        return .nothing
    }

    private enum Snapshot { case taken(edge: String, ids: Set<Int>), edgeGone, stop(Outcome) }

    /// Edge is up (or on its way up or down): the windows already there that look like the
    /// new one, so none of them is ever taken for it. If Edge can't say, Hammer doesn't guess.
    private func snapshot(_ find: String, url: URL, play: Bool) async -> Snapshot {
        for attempt in 1...10 {
            guard let edge = driver.running() else { return .edgeGone }
            switch await driver.permission(ask: true) {
            case .denied, .notAsked:
                return .stop(await openUnsteered(play ? url : nil, in: edge))
            case .allowed:
                switch await driver.run(find) {
                case .ok(let text): return .taken(edge: edge, ids: EdgeYouTube.parseIDs(text))
                case .failed(let number, _):
                    if number == EdgeYouTube.notAllowed { return .stop(.notAllowed(openedAnyway: false)) }
                    if number != -600 { return .stop(.failed(EdgeYouTube.plainError(number))) }
                }
            case .notRunning:
                break
            }
            if attempt < 10 { await driver.pause(0.3) }    // starting or quitting: wait until it's one or the other
        }
        return .stop(.failed(EdgeYouTube.plainError(nil)))
    }

    /// Opens a new app window, finds it among Edge's windows, remembers it and puts it in the corner.
    private func open(_ url: URL, play: Bool) async -> Outcome {
        // Known by the address Hammer opened. When Edge starts with this window it
        // doesn't bring back your other windows, and when it's running, windows that
        // were already there don't count; of several new ones, the newest wins (it's
        // looked for right after it was opened).
        let find = EdgeYouTube.findScript(prefixes: [EdgeYouTube.matchPrefix(url)] + EdgeYouTube.detours)
        var before = Set<Int>()
        var run: String?                                 // the run of Edge those windows are from
        var asked = false
        if driver.running() != nil {
            switch await snapshot(find, url: url, play: play) {
            case .taken(let edge, let ids): before = ids; run = edge; asked = true
            case .edgeGone: break
            case .stop(let outcome): return outcome
            }
        }
        guard await driver.launch(EdgeYouTube.launchArguments(url)) else {
            return .failed("Microsoft Edge didn't open. If it's showing a question, answer it and try again.")
        }
        // Until it's found, the next press looks for this one rather than opening another.
        // (Edge not running yet: Hammer can't know which windows a later Edge brings back.)
        markLaunched(url, in: run, besides: run == nil ? nil : before)
        let deadline = clock().addingTimeInterval(findFor)
        var tries = 0
        while tries < 60 && clock() < deadline {        // about 15 seconds, more if Edge is slow
            tries += 1
            await driver.pause(0.3)
            guard let edge = driver.running() else { continue }
            if edge != run {
                // Edge has just started (or started again): its windows are all new, and IDs start over.
                before = []
                run = edge
                markLaunched(url, in: edge, besides: [])
            }
            if !asked {
                // Now macOS can ask whether Hammer may steer it.
                switch await driver.permission(ask: true) {
                case .notRunning: continue
                case .denied, .notAsked: return .notAllowed(openedAnyway: true)
                case .allowed: asked = true
                }
            }
            guard case .ok(let text) = await driver.run(find),
                  let id = EdgeYouTube.newWindow(after: EdgeYouTube.parseIDs(text), before: before) else { continue }
            keep(id, in: edge)
            let place = corner(nil)
            _ = await driver.run(EdgeYouTube.showScript(id: id, bounds: place))
            rememberPlace(place)
            await driver.bringForward()
            return .opened
        }
        return .failed("Microsoft Edge is taking a while to open YouTube. Once its window is there, try again: "
                       + "Hammer will put it in the corner.")
    }
}
