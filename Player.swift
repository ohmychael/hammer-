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
