// Deliveries.swift — delivery alerts from your Gmail. Foundation only, so it can be
// tested anywhere (Tests/main.swift, Tests/Deliveries/run.sh); Hammer.swift adds
// the menu, the Keychain and the notifications.
//
// Every few minutes Hammer looks at new inbox mail in Gmail (over IMAP, with your
// app password). It opens the inbox read-only and reads just the From/Subject/Date/
// Message-ID headers of new emails, so nothing is marked as read, and decides which
// are real delivery notices: "Delivered: …" from Amazon, eBay's
// "Your package was delivered", UPS/USPS/FedEx updates and the like. Mail that was
// already there when you turned this on is never announced.

import Foundation

// MARK: - What a delivery email says

struct Delivery: Codable, Equatable {
    enum Kind: String, Codable { case delivered, problem }
    let kind: Kind
    let store: String          // "eBay", "Amazon", "UPS"…
    let item: String?          // what was delivered, when the subject says
    let subject: String
    let messageID: String?     // for opening the email in Gmail
    let date: Date?
    let uid: Int
    var gmailID: String? = nil // Gmail's own ID for the email (from the Google script)

    /// Identifies this delivery in the menu.
    var key: String { messageID ?? gmailID ?? "uid:\(uid)" }
    var title: String { kind == .delivered ? "Delivered · \(store)" : "Delivery problem · \(store)" }
    var body: String { item ?? DeliveryMail.tidy(subject) }

    /// Opens this email in Gmail in the browser (in the right account), or nil if
    /// there's no email to open (e.g. the test notification).
    func gmailLink(account email: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@")
        func encoded(_ text: String) -> String? { text.addingPercentEncoding(withAllowedCharacters: allowed) }
        let messageID = (self.messageID ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        let target: String
        if !messageID.isEmpty, let query = encoded("rfc822msgid:" + messageID) {
            target = "search/" + query
        } else if let gmailID, !gmailID.isEmpty, let id = encoded(gmailID) {
            target = "all/" + id
        } else if !subject.isEmpty, let query = encoded("subject:(\(subject))") {
            target = "search/" + query
        } else {
            return nil
        }
        guard !email.isEmpty, let user = encoded(email) else {
            return URL(string: "https://mail.google.com/mail/u/0/#" + target)
        }
        return URL(string: "https://mail.google.com/mail/?authuser=\(user)#" + target)
    }
}

enum DeliveryMail {
    /// Reads one email's headers and says whether it's a delivery notice.
    static func classify(headers: [String: String], uid: Int) -> Delivery? {
        let subject = headers["subject"] ?? ""
        let from = headers["from"] ?? ""
        guard !isBounce(from: from), let kind = kind(ofSubject: subject) else { return nil }
        return Delivery(kind: kind, store: store(from: from), item: kind == .delivered ? item(in: subject) : nil,
                        subject: subject, messageID: headers["message-id"],
                        date: headers["date"].flatMap(parseDate), uid: uid)
    }

    /// "Delivered", "problem" (a failed or attempted delivery), or nil for anything
    /// else: shipping updates, "out for delivery", ads, replies.
    static func kind(ofSubject raw: String) -> Delivery.Kind? {
        let s = " " + normalized(raw) + " "
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("re:") || trimmed.hasPrefix("re :") { return nil }      // a conversation, not a notice
        let aboutAPackage = ["package", "parcel", "shipment", "order"].contains { s.contains($0) }

        // Failed or attempted deliveries. Some phrases only ever mean a package; the rest
        // also turn up in bounced email ("Undeliverable: …"), so they need a package word.
        let alwaysProblem = ["delivery attempt", "attempted delivery", "delivery was attempted",
                             "delivery exception", "missed delivery"]
        let problemWithPackage = ["not delivered", "not been delivered", "couldn't be delivered",
                                  "could not be delivered", "wasn't delivered", "unable to deliver", "undeliverable",
                                  "delivery failed", "failed delivery", "returned to sender", "return to sender",
                                  "being returned"]
        if alwaysProblem.contains(where: { s.contains($0) })
            || (aboutAPackage && problemWithPackage.contains(where: { s.contains($0) })) {
            return .problem
        }

        // Plainly past tense: delivered, whatever else the subject says.
        let delivered = ["was delivered", "were delivered", "has been delivered", "have been delivered",
                         "got delivered", "item delivered", "items delivered", "package delivered",
                         "parcel delivered", "order delivered", "shipment delivered", "was dropped off",
                         "been dropped off"]
        if delivered.contains(where: { s.contains($0) }) && !s.contains("will have been") { return .delivered }
        // "Your order has arrived", "Your package from Target has arrived", but not "Fall has arrived".
        let arrived = #"\b(package|parcel|order|shipment|items?|delivery|purchase)s?\b[^.!?:]{0,40}\b(has|have) arrived"#
        if s.range(of: arrived, options: .regularExpression) != nil { return .delivered }

        let notYet = ["will be delivered", "to be delivered", "out for delivery", "expected", "estimated",
                      "scheduled", "arriving", "on its way", "on the way", "get it delivered",
                      "get them delivered", "have it delivered", "free delivery", "% off"]
        if notYet.contains(where: { s.contains($0) }) { return nil }

        // "Delivered: …" (Amazon) and "FedEx Shipment 7712… Delivered".
        if trimmed.range(of: #"^delivered\s*[:\-–—|]"#, options: .regularExpression) != nil { return .delivered }
        let words = trimmed.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
        if words.last == "delivered" && aboutAPackage { return .delivered }
        return nil
    }

    /// Bounced email ("Undeliverable", "Mail delivery failed") comes from the mail system, not a store.
    static func isBounce(from raw: String) -> Bool {
        let from = HeaderText.decode(raw).lowercased()
        return ["mailer-daemon", "postmaster", "mail delivery", "microsoftexchange"].contains { from.contains($0) }
    }

    /// What was delivered, if the subject names it.
    /// 'Delivered: "Anker 735 Charger…" and 1 more item' → 'Anker 735 Charger… +1 more'
    /// 'Your package was delivered: Apple iPhone 15 Pro Max' → 'Apple iPhone 15 Pro Max'
    static func item(in raw: String) -> String? {
        let subject = tidy(raw)
        if let open = subject.firstIndex(where: { $0 == "\"" || $0 == "“" }),
           let close = subject[subject.index(after: open)...].firstIndex(where: { $0 == "\"" || $0 == "”" }) {
            var name = String(subject[subject.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            let after = subject[subject.index(after: close)...].lowercased()
            if let more = after.range(of: #"and (\d+) more"#, options: .regularExpression) {
                let count = after[more].filter(\.isNumber)
                name += " +\(count) more"
            }
            return name.isEmpty ? nil : shorten(name)
        }
        guard let colon = subject.firstIndex(of: ":") else { return nil }
        let before = subject[..<colon].lowercased()
        guard before.contains("deliver") || before.contains("arrived") else { return nil }
        let name = subject[subject.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.lowercased() != "your package", !name.lowercased().hasPrefix("your order")
        else { return nil }
        return shorten(name)
    }

    /// The store or carrier, from the sender.
    static func store(from raw: String) -> String {
        let from = HeaderText.decode(raw)
        let address: String
        if let lt = from.lastIndex(of: "<"), let gt = from.lastIndex(of: ">"), lt < gt {
            address = String(from[from.index(after: lt)..<gt])
        } else {
            address = from.trimmingCharacters(in: .whitespaces)
        }
        let domain = address.split(separator: "@").last.map { $0.lowercased() } ?? ""
        // A brand counts when it's a whole part of the domain: "email.ups.com" is UPS, "groups.com" isn't.
        let labels = domain.split(separator: ".").dropLast().map(String.init)
        let known: [String: String] = [
            "amazon": "Amazon", "ebay": "eBay", "ups": "UPS", "usps": "USPS", "fedex": "FedEx", "dhl": "DHL",
            "ontrac": "OnTrac", "lasership": "LaserShip", "walmart": "Walmart", "target": "Target",
            "bestbuy": "Best Buy", "apple": "Apple", "etsy": "Etsy", "shopify": "Shop", "costco": "Costco",
            "homedepot": "Home Depot", "lowes": "Lowe's", "wayfair": "Wayfair", "chewy": "Chewy", "temu": "Temu",
            "shein": "SHEIN", "aliexpress": "AliExpress", "backmarket": "Back Market", "nike": "Nike",
        ]
        if domain == "shop.app" || domain.hasSuffix(".shop.app") { return "Shop" }
        if let brand = labels.reversed().first(where: { known[$0] != nil }), let name = known[brand] {
            return name
        }
        // Otherwise the sender's name, or failing that the domain.
        if let lt = from.lastIndex(of: "<") {
            let name = from[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return shorten(name, to: 30) }
        }
        // "orders@weirdshop.co.uk" → "Weirdshop": skip "co", "mail" and the like.
        let generic: Set<String> = ["co", "com", "org", "net", "gov", "ac", "edu", "mail", "email", "e", "em",
                                    "info", "news", "orders", "order", "shop", "store", "notifications", "mg", "m"]
        if let name = labels.last(where: { !generic.contains($0) && !$0.isEmpty }) { return name.capitalized }
        return "Package"
    }

    /// Subject without emoji, mail prefixes and extra spaces, for showing.
    static func tidy(_ raw: String) -> String {
        var text = HeaderText.decode(raw)
        text = String(text.unicodeScalars.filter { !($0.properties.isEmojiPresentation || $0.value == 0xFE0F) }
            .map(Character.init))
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:|•")))
        if text.lowercased().hasPrefix("fwd:") { text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        if text.lowercased().hasPrefix("fw:") { text = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
        return text
    }

    static func shorten(_ text: String, to limit: Int = 80) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func normalized(_ raw: String) -> String {
        tidy(raw).lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func parseDate(_ raw: String) -> Date? {
        let text = raw.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

// MARK: - Setup checks

enum DeliverySetup {
    /// A plain address like you@gmail.com (no spaces, quotes or other surprises).
    static func isPlainEmail(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }

    /// Google shows app passwords as four groups of four letters ("abcd efgh ijkl mnop").
    /// Returns the 16 letters without spaces, or nil if it isn't one (e.g. a regular password).
    static func cleanPassword(_ text: String) -> String? {
        let letters = text.filter { !$0.isWhitespace }
        guard letters.count == 16, letters.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return letters
    }
}

// MARK: - Email headers

enum HeaderText {
    /// Splits raw header lines into lowercase name → value, joining folded lines.
    static func parse(_ data: [UInt8]) -> [String: String] {
        let text = String(decoding: data, as: UTF8.self).contains("\u{FFFD}")
            ? String(data.map { Character(Unicode.Scalar($0)) })      // not UTF-8: read as Latin-1
            : String(decoding: data, as: UTF8.self)
        var result: [String: String] = [:]
        var name: String?
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", let current = name {
                result[current, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard !key.isEmpty else { continue }
                name = key
                if result[key] == nil {
                    result[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            } else {
                name = nil
            }
        }
        return result
    }

    /// Decodes "=?UTF-8?B?…?=" / "=?utf-8?Q?…?=" words (RFC 2047), the way mail
    /// programs show subjects with emoji or accents.
    static func decode(_ raw: String) -> String {
        let pattern = #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return raw }
        var out = ""
        var cursor = 0
        for (index, match) in matches.enumerated() {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Spaces between two encoded words are dropped; other text is kept.
            if !(index > 0 && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { out += gap }
            let charset = ns.substring(with: match.range(at: 1)).lowercased()
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let text = ns.substring(with: match.range(at: 3))
            var bytes: [UInt8]?
            if mode == "B" {
                var padded = text
                while padded.count % 4 != 0 { padded += "=" }
                bytes = Data(base64Encoded: padded).map { [UInt8]($0) }
            } else {
                bytes = quotedPrintable(text)
            }
            if let bytes, let decoded = string(from: bytes, charset: charset) {
                out += decoded
            } else {
                out += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func quotedPrintable(_ text: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var chars = Array(text.utf8)[...]
        while let c = chars.popFirst() {
            if c == UInt8(ascii: "_") {
                bytes.append(0x20)
            } else if c == UInt8(ascii: "="), chars.count >= 2,
                      let value = UInt8(String(decoding: chars.prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(value)
                chars = chars.dropFirst(2)
            } else {
                bytes.append(c)
            }
        }
        return bytes
    }

    private static func string(from bytes: [UInt8], charset: String) -> String? {
        let charset = charset.split(separator: "*").first.map(String.init) ?? charset   // RFC 2231 language tag
        switch charset {
        case "utf-8", "utf8": return String(bytes: bytes, encoding: .utf8)
        case "us-ascii", "ascii": return String(bytes: bytes, encoding: .ascii) ?? String(bytes: bytes, encoding: .utf8)
        case "iso-8859-1", "latin1", "iso-8859-15": return String(bytes: bytes, encoding: .isoLatin1)
        case "windows-1252", "cp1252": return String(bytes: bytes, encoding: .windowsCP1252)
        default: return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
        }
    }
}

// MARK: - Talking to Gmail (IMAP)

enum IMAPError: Error, Equatable {
    case badLogin(String)  // Gmail refused the email or app password; the text says why
    case offline           // couldn't reach Gmail (no internet, asleep, timed out)
    case failed(String)    // anything else; the text is for the menu
}

/// Moves bytes to and from the mail server. In the app it's a TLS connection to
/// imap.gmail.com (Hammer.swift); in tests it's a plain socket to a fake server.
protocol IMAPTransport: AnyObject {
    func send(_ bytes: [UInt8]) throws
    /// Whatever the server sent next; empty when the connection has closed.
    /// Throws IMAPError.offline if nothing arrives in time.
    func receive() throws -> [UInt8]
    func close()
}

struct IMAPResponse {
    let status: String         // OK, NO or BAD
    let text: String           // the rest of the final line, e.g. "[AUTHENTICATIONFAILED] Invalid credentials"
    let untagged: [UInt8]      // everything the server sent before it, literals included
}

/// One IMAP conversation: tagged commands, answers read up to their tagged line,
/// with {n} literals read by length (that's how email headers come back).
final class IMAPConnection {
    private let transport: IMAPTransport
    private var buffer: [UInt8] = []
    private var position = 0                 // how much of `buffer` has been read
    private var counter = 0
    /// Answers bigger than this are cut off (a safety limit; headers are tiny).
    static let maxResponse = 4 << 20

    init(transport: IMAPTransport) { self.transport = transport }

    /// Reads the server's greeting ("* OK …").
    func start() throws {
        let line = try readLine()
        let text = String(decoding: line, as: UTF8.self)
        guard text.hasPrefix("* OK") || text.hasPrefix("* PREAUTH") else {
            throw IMAPError.failed("Gmail didn't answer as expected.")
        }
    }

    func login(email: String, password: String) throws {
        let reply = try run("LOGIN \(IMAPConnection.quoted(email)) \(IMAPConnection.quoted(password))")
        guard reply.status == "OK" else {
            if IMAPConnection.isRefusedLogin(reply.text) { throw IMAPError.badLogin(reply.text) }
            // e.g. "[UNAVAILABLE] Temporary System Problem", "Too many simultaneous connections"
            throw IMAPError.failed("Gmail is having trouble right now. Hammer will keep trying.")
        }
    }

    /// Sends one command and returns its answer.
    func run(_ command: String) throws -> IMAPResponse {
        counter += 1
        let tag = String(format: "H%03d", counter)
        try transport.send(Array("\(tag) \(command)\r\n".utf8))
        var untagged: [UInt8] = []
        let tagPrefix = Array("\(tag) ".utf8)
        while true {
            var line = try readLine()
            if line.starts(with: tagPrefix) {
                let rest = String(decoding: line.dropFirst(tagPrefix.count), as: UTF8.self)
                let status = rest.split(separator: " ", maxSplits: 1).first.map { $0.uppercased() } ?? ""
                let text = rest.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                return IMAPResponse(status: status, text: text, untagged: untagged)
            }
            // A line ending in {n} is followed by n bytes of data, then the rest of the line.
            while let size = IMAPConnection.literalSize(at: line) {
                untagged += line + [13, 10]
                untagged += try readBytes(size)
                line = try readLine()
            }
            untagged += line + [13, 10]
            if untagged.count > IMAPConnection.maxResponse { throw IMAPError.failed("Gmail's answer was too large.") }
        }
    }

    func logout() {
        _ = try? run("LOGOUT")
        transport.close()
    }

    // MARK: Reading

    private func fill() throws {
        if position > 65_536 {                                     // drop what's been read
            buffer.removeSubrange(..<position)
            position = 0
        }
        let more = try transport.receive()
        guard !more.isEmpty else { throw IMAPError.offline }       // the server hung up
        buffer += more
    }

    /// One line, without its CRLF.
    private func readLine() throws -> [UInt8] {
        var searchFrom = position
        while true {
            if let lf = buffer[searchFrom...].firstIndex(of: 10) {
                var line = Array(buffer[position..<lf])
                position = lf + 1
                if line.last == 13 { line.removeLast() }
                return line
            }
            if buffer.count - position > IMAPConnection.maxResponse {
                throw IMAPError.failed("Gmail's answer was too large.")
            }
            let unread = buffer.count - position
            try fill()
            searchFrom = position + unread          // only look through the new bytes
        }
    }

    private func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= IMAPConnection.maxResponse else {
            throw IMAPError.failed("Gmail's answer was too large.")
        }
        while buffer.count - position < count { try fill() }
        let bytes = Array(buffer[position..<(position + count)])
        position += count
        return bytes
    }

    /// Gmail turned the password down (as opposed to a passing problem on Gmail's side).
    static func isRefusedLogin(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("authenticationfailed") || t.contains("invalid credentials")
            || t.contains("application-specific password") || t.contains("webalert")
    }

    /// "… {123}" → 123 (also "{123+}").
    static func literalSize(at line: [UInt8]) -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = line[(open + 1)..<(line.count - 1)]
        if digits.last == UInt8(ascii: "+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    /// An IMAP quoted string: "…" with \ and " escaped.
    static func quoted(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        return "\"" + clean.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Reading the parts of IMAP's answers Hammer needs.
enum IMAPReply {
    /// From EXAMINE: "* OK [UIDVALIDITY 7] …" and "* OK [UIDNEXT 1235] …" (or a STATUS line) → (1235, 7)
    static func status(_ output: [UInt8]) -> (uidNext: Int, uidValidity: Int)? {
        let text = String(decoding: output, as: UTF8.self)
        guard let next = number(after: "UIDNEXT", in: text), let validity = number(after: "UIDVALIDITY", in: text)
        else { return nil }
        return (next, validity)
    }

    /// "* SEARCH 12 15" → [12, 15]
    static func search(_ output: [UInt8]) -> [Int]? {
        let text = String(decoding: output, as: UTF8.self)
        var found: [Int]?
        for line in text.split(whereSeparator: { $0.isNewline }) where line.uppercased().hasPrefix("* SEARCH") {
            found = (found ?? []) + line.dropFirst(8).split(separator: " ").compactMap { Int($0) }
        }
        return found
    }

    /// "* 3 FETCH (UID 12 BODY[HEADER.FIELDS (…)] {n}\r\n<n bytes>)" → [12: headers]
    static func fetchedHeaders(_ output: [UInt8]) -> [Int: [String: String]] {
        var result: [Int: [String: String]] = [:]
        var index = 0
        let bytes = output
        func find(_ needle: String, from start: Int) -> Int? {
            let target = Array(needle.utf8)
            guard !target.isEmpty, bytes.count >= target.count else { return nil }
            var i = start
            while i <= bytes.count - target.count {
                if bytes[i] == target[0] && bytes[i..<i + target.count].elementsEqual(target) { return i }
                i += 1
            }
            return nil
        }
        while let fetch = find(" FETCH (", from: index) {
            // The UID and the literal's size are on the same line, before "{n}\r\n".
            guard let open = find("{", from: fetch), let close = find("}", from: open),
                  let size = Int(String(decoding: bytes[(open + 1)..<close], as: UTF8.self)) else { break }
            let line = String(decoding: bytes[fetch..<open], as: UTF8.self)
            var start = close + 1
            if start < bytes.count, bytes[start] == 13 { start += 1 }
            if start < bytes.count, bytes[start] == 10 { start += 1 }
            let end = min(start + size, bytes.count)
            // The UID usually comes before the headers, but may come after them.
            let lineEnd = find("\n", from: end) ?? bytes.count
            let tail = String(decoding: bytes[end..<lineEnd], as: UTF8.self)
            if let uid = number(after: "UID", in: line) ?? number(after: "UID", in: tail) {
                result[uid] = HeaderText.parse(Array(bytes[start..<end]))
            }
            index = end
        }
        return result
    }

    private static func number(after key: String, in text: String) -> Int? {
        guard let range = text.range(of: #"\b"# + key + #"\s+(\d+)"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return Int(text[range].split(whereSeparator: { $0 == " " || $0 == "\t" }).last ?? "")
    }
}

// MARK: - Checking for new deliveries

/// What Hammer remembers between checks.
struct DeliveryState: Codable, Equatable {
    var uidValidity: Int?
    var lastUID: Int?                    // everything up to here has been looked at
    var announced: [String] = []         // Message-IDs already shown (the last 200)
}

enum DeliveryCheck {
    /// At most this many new emails are looked at in one check: after a long time
    /// offline, older ones would be too old to announce anyway.
    static let maxPerCheck = 500
    /// Headers are fetched this many emails at a time.
    static let batch = 100
    /// Deliveries older than this aren't announced (e.g. an old email moved back to the inbox).
    static let tooOld: TimeInterval = 3 * 24 * 3600

    /// One check over an open, logged-in connection: returns the new deliveries and the
    /// updated state. The inbox is opened read-only (EXAMINE) and only headers are read
    /// (BODY.PEEK), so nothing is marked as read. The first check after setup only notes
    /// where the inbox is, so old mail is never announced. The state only moves forward
    /// when the whole check succeeds.
    static func run(state: DeliveryState, now: Date = Date(),
                    command: (String) throws -> IMAPResponse) throws -> (deliveries: [Delivery], state: DeliveryState) {
        var next = state
        let inbox = try command("EXAMINE INBOX")
        guard inbox.status == "OK", let status = IMAPReply.status(inbox.untagged) else {
            throw IMAPError.failed("Couldn't open your inbox (\(inbox.text)).")
        }
        let newest = status.uidNext - 1

        guard let last = state.lastUID, state.uidValidity == status.uidValidity else {
            next.uidValidity = status.uidValidity          // first check, or Gmail renumbered: start from here
            next.lastUID = newest
            return ([], next)
        }
        guard newest > last else { return ([], next) }

        // Every new email, not a Gmail search: search results can lag behind new mail,
        // and the decision is made here anyway, from the subject and sender.
        let search = try command("UID SEARCH UID \(last + 1):*")
        guard search.status == "OK", let uids = IMAPReply.search(search.untagged) else {
            throw IMAPError.failed("Couldn't list new mail (\(search.text)).")
        }
        let new = uids.filter { $0 > last }.sorted()
        let found = Array(new.suffix(maxPerCheck))

        var deliveries: [Delivery] = []
        if !found.isEmpty {
            var headers: [Int: [String: String]] = [:]
            for start in stride(from: 0, to: found.count, by: batch) {
                let list = found[start..<min(start + batch, found.count)].map(String.init).joined(separator: ",")
                let fetch = try command("UID FETCH \(list) (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])")
                guard fetch.status == "OK" else { throw IMAPError.failed("Couldn't read new mail (\(fetch.text)).") }
                headers.merge(IMAPReply.fetchedHeaders(fetch.untagged)) { _, newer in newer }
            }
            for uid in found {
                guard let fields = headers[uid], let delivery = DeliveryMail.classify(headers: fields, uid: uid)
                else { continue }
                if let date = delivery.date, now.timeIntervalSince(date) > tooOld { continue }
                let key = delivery.messageID ?? "uid:\(status.uidValidity):\(uid)"
                if next.announced.contains(key) { continue }
                next.announced.append(key)
                deliveries.append(delivery)
            }
            next.announced = Array(next.announced.suffix(200))
        }
        next.lastUID = max(newest, new.max() ?? newest)
        return (deliveries, next)
    }

    /// Connects, logs in, checks and logs out.
    static func run(state: DeliveryState, email: String, password: String, now: Date = Date(),
                    transport: () throws -> IMAPTransport) -> Result<(deliveries: [Delivery], state: DeliveryState), IMAPError> {
        do {
            let connection = IMAPConnection(transport: try transport())
            defer { connection.logout() }
            try connection.start()
            try connection.login(email: email, password: password)
            return .success(try run(state: state, now: now, command: connection.run))
        } catch let error as IMAPError {
            return .failure(error)
        } catch {
            return .failure(.offline)
        }
    }

    /// What to show in the menu when a check fails.
    static func explain(_ error: IMAPError) -> String {
        switch error {
        case .badLogin(let text):
            if text.localizedCaseInsensitiveContains("application-specific") {
                return "Gmail needs an app password, not your regular one."
            }
            if text.localizedCaseInsensitiveContains("webalert") {
                return "Google blocked the sign-in as unusual. Open Gmail in your browser once, then set up Gmail again."
            }
            return "Gmail didn't accept the app password."
        case .offline: return "Can't reach Gmail right now. Hammer will keep trying."
        case .failed(let text): return text
        }
    }
}

// MARK: - The Google script route (no app password)
//
// Instead of logging in to Gmail, Hammer can ask a small Google Apps Script that
// runs in your own Google account. You paste the script (below) into
// script.google.com and deploy it as a web app; Hammer then asks its web address
// every few minutes, with a random key only the two of them know. The script
// answers with the sender, subject, date and ID of recent emails whose subject
// mentions a delivery, and Hammer decides which are deliveries (DeliveryMail).

enum DeliveryScript {
    static let keyPlaceholder = "__HAMMER_KEY__"

    /// A new random key for the script and Hammer to share (64 hex characters).
    static func newKey() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func isKey(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// The script to paste into Google, with this key in it.
    static func source(key: String) -> String {
        template.replacingOccurrences(of: keyPlaceholder, with: key)
    }

    /// The web app address Google shows after deploying, e.g.
    /// https://script.google.com/macros/s/AKfy…/exec. Nil if it isn't one.
    static func webAppURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: trimmed), parts.scheme == "https",
              parts.host == "script.google.com", parts.path.hasPrefix("/macros/"), parts.path.hasSuffix("/exec"),
              parts.query == nil || parts.query == "" else { return nil }
        return URL(string: "https://script.google.com" + parts.path)
    }

    /// The address Hammer asks: the web app, with the key.
    static func requestURL(base: URL, key: String) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "v", value: "1")]
        return parts.url
    }

    static let template = #"""
    /**
     * Hammer delivery alerts. This runs in your own Google account.
     *
     * Every few minutes Hammer (the Mac app) asks this script for recent emails whose
     * subject mentions a delivery. The script answers with just the sender, subject,
     * date and ID of those from the last 2 days. It doesn't change, send or delete
     * anything, and it only answers requests that carry Hammer's key.
     */
    const HAMMER_KEY = '__HAMMER_KEY__';
    const SEARCH = 'in:inbox newer_than:2d subject:(delivered OR delivery OR deliver OR arrived OR ' +
        'undeliverable OR "dropped off" OR "return to sender" OR "returned to sender")';
    const MAX_THREADS = 20;

    function doGet(e) {
      const key = e && e.parameter ? e.parameter.key : '';
      if (key !== HAMMER_KEY) return answer({ ok: false, error: 'key' });
      try {
        return answer({
          ok: true,
          version: 1,
          account: Session.getEffectiveUser().getEmail(),
          emails: recentDeliveryEmails()
        });
      } catch (error) {
        return answer({ ok: false, error: 'gmail', message: String(error) });
      }
    }

    function recentDeliveryEmails() {
      const since = Date.now() - 2 * 24 * 60 * 60 * 1000;
      const emails = [];
      GmailApp.search(SEARCH, 0, MAX_THREADS).forEach(function (thread) {
        thread.getMessages().forEach(function (message) {
          const date = message.getDate();
          if (date.getTime() < since || message.isInTrash()) return;
          emails.push({
            id: message.getId(),
            messageID: message.getHeader('Message-ID') || '',
            from: message.getFrom(),
            subject: message.getSubject(),
            date: date.toISOString()
          });
        });
      });
      return emails;
    }

    function answer(value) {
      return ContentService.createTextOutput(JSON.stringify(value))
          .setMimeType(ContentService.MimeType.JSON);
    }

    /** Run this from the editor to see what Hammer would get. */
    function test() {
      Logger.log(JSON.stringify(recentDeliveryEmails(), null, 2));
    }
    """#
}

/// Why a check didn't work, for the menu. `needsSetup` shows "Set Up Gmail Again…".
struct CheckFailure: Error, Equatable {
    let message: String
    var needsSetup = false
    var offline = false

    static let offline = CheckFailure(message: "Can't reach Google right now. Hammer will keep trying.", offline: true)

    init(message: String, needsSetup: Bool = false, offline: Bool = false) {
        self.message = message
        self.needsSetup = needsSetup
        self.offline = offline
    }

    /// From the app-password (IMAP) route.
    init(_ error: IMAPError) {
        switch error {
        case .badLogin: self.init(message: DeliveryCheck.explain(error), needsSetup: true)
        case .offline: self = .offline
        case .failed: self.init(message: DeliveryCheck.explain(error))
        }
    }
}

/// What Hammer remembers between script checks.
struct ScriptState: Codable, Equatable {
    var started = false           // the first answer only notes what's already there
    var seen: [String] = []       // Gmail IDs already looked at (the last 500)
}

enum ScriptCheck {
    struct Reply: Decodable {
        let ok: Bool
        let error: String?
        let message: String?
        let account: String?
        let emails: [Email]?
    }

    struct Email: Decodable, Equatable {
        let id: String
        let messageID: String?
        let from: String?
        let subject: String?
        let date: String?
    }

    /// Reads the script's answer, or makes sense of the page Google sends instead.
    static func read(status: Int, body: Data) -> Result<Reply, CheckFailure> {
        if status == 404 {
            return .failure(CheckFailure(message: "Hammer can't find the script at that address. "
                + "Check the web app URL (it ends in /exec).", needsSetup: true))
        }
        if status == 429 || status >= 500 {
            return .failure(CheckFailure(message: "Google is busy right now. Hammer will keep trying."))
        }
        if let reply = try? JSONDecoder().decode(Reply.self, from: body) {
            if reply.ok { return .success(reply) }
            if reply.error == "key" {
                return .failure(CheckFailure(message: "The script's key doesn't match Hammer's. Set up Gmail again "
                    + "and paste the new script over the old one.", needsSetup: true))
            }
            return .failure(CheckFailure(message: "The script couldn't read Gmail just now. Hammer will keep trying."))
        }
        let page = String(decoding: body.prefix(200_000), as: UTF8.self).lowercased()
        if page.contains("script function not found") {
            return .failure(CheckFailure(message: "The script wasn't saved before it was deployed. Set up Gmail again.",
                                         needsSetup: true))
        }
        if page.contains("authorization is required") || page.contains("authorisation is required") {
            return .failure(CheckFailure(message: "The script needs your permission again: open it at "
                + "script.google.com and click Run.", needsSetup: true))
        }
        if status == 401 || status == 403 || page.contains("accounts.google.com") || page.contains("sign in") {
            return .failure(CheckFailure(message: "Google asked for a sign-in instead of running the script. In the "
                + "script, open Deploy → Manage deployments and set Who has access to Anyone.", needsSetup: true))
        }
        return .failure(CheckFailure(message: "The script sent an answer Hammer didn't understand. Hammer will keep trying."))
    }

    /// New deliveries in the script's answer, oldest first, and what to remember.
    static func process(_ emails: [Email], state: ScriptState, now: Date = Date())
    -> (deliveries: [Delivery], state: ScriptState) {
        var next = state
        var known = Set(state.seen)
        var deliveries: [Delivery] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        for email in emails where !email.id.isEmpty && !known.contains(email.id) {
            known.insert(email.id)
            next.seen.append(email.id)
            guard state.started else { continue }
            let messageID = (email.messageID ?? "").isEmpty ? nil : email.messageID
            var headers = ["from": email.from ?? "", "subject": email.subject ?? ""]
            if let messageID { headers["message-id"] = messageID }
            guard let found = DeliveryMail.classify(headers: headers, uid: 0) else { continue }
            let date = email.date.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            if let date, now.timeIntervalSince(date) > DeliveryCheck.tooOld { continue }
            deliveries.append(Delivery(kind: found.kind, store: found.store, item: found.item, subject: found.subject,
                                       messageID: messageID, date: date, uid: 0, gmailID: email.id))
        }
        next.started = true
        next.seen = Array(next.seen.suffix(500))
        deliveries.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        return (deliveries, next)
    }
}
