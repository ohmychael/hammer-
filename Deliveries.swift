// Deliveries.swift — delivery alerts from your Gmail. Foundation only, so it can be
// tested anywhere (Tests/main.swift, Tests/Deliveries/run.sh); DeliveryAlerts.swift
// adds the notifications and the checks every few minutes, Hammer.swift the menu.
//
// Every few minutes Hammer looks at new inbox mail in Gmail (over IMAP, with your
// app password, or through a small Google script). Over IMAP it opens the inbox
// read-only and reads just a few headers of new emails (From, Subject, Date,
// Message-ID and Gmail's sender check), so nothing is marked as read. It decides
// which are delivery notices: "Delivered: …" from Amazon, eBay's "Your package was
// delivered", UPS/USPS/FedEx updates and the like. Only English subjects are
// understood. Mail that was already there when you turned this on isn't announced.
//
// Email content is untrusted: subjects and senders are only ever shown as text and
// matched against fixed wording, never run or followed.

import Foundation

// MARK: - What a delivery email says

struct Delivery: Codable, Equatable {
    enum Kind: String, Codable { case delivered, problem, outForDelivery }
    let kind: Kind
    let store: String          // "eBay", "Amazon", "UPS"… or the sender's domain if Hammer doesn't know it
    let item: String?          // what was delivered, when the subject says
    let subject: String
    let messageID: String?     // for opening the email in Gmail
    var date: Date?
    let uid: Int
    var gmailID: String? = nil // Gmail's own ID for the email (X-GM-MSGID in hex, or from the Google script)
    var package: String? = nil // the same package across its emails: "Delivered" replaces "Out for delivery"

    /// Identifies this delivery in the menu.
    var key: String { messageID ?? gmailID ?? "uid:\(uid)" }
    var title: String {
        switch kind {
        case .delivered: return "Delivered · \(store)"
        case .problem: return "Delivery problem · \(store)"
        case .outForDelivery: return "Out for delivery · \(store)"
        }
    }
    var body: String { item ?? DeliveryMail.bodyText(subject, store: store) }
    /// One notification per package, so "Delivered" replaces that package's "Out for delivery".
    var notificationID: String { "delivery-" + (package ?? key) }

    /// Opens this email in Gmail in the browser (in the right account), or nil if
    /// there's no email to open (e.g. the test notification). Gmail's own ID opens the
    /// email itself; the Message-ID or subject only opens a search for it.
    func gmailLink(account email: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~@")
        func encoded(_ text: String) -> String? { text.addingPercentEncoding(withAllowedCharacters: allowed) }
        let messageID = (self.messageID ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        let target: String
        if let gmailID, !gmailID.isEmpty, gmailID.count <= 40,
           gmailID.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) {
            target = "all/" + gmailID
        } else if !messageID.isEmpty, let query = encoded("rfc822msgid:" + messageID) {
            target = "search/" + query
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
    /// Reads one email's headers and says whether it's a delivery notice. On the
    /// app-password route `headers` include Gmail's Authentication-Results and
    /// ":gmail-id" (see IMAPReply.fetchedHeaders).
    static func classify(headers: [String: String], uid: Int) -> Delivery? {
        let subject = headers["subject"] ?? ""
        let from = headers["from"] ?? ""
        guard !isBounce(from: from), let kind = kind(ofSubject: subject) else { return nil }
        // "Your message was delivered", "Your report has been delivered": the wording alone
        // isn't enough. It has to come from a known store or carrier, or be about a package.
        // The same goes for problems: a "missed delivery" from anyone else needs a package word.
        let known = knownShipper(from: from, authentication: headers["authentication-results"])
        if known == nil && !mentionsAPackage(subject) { return nil }
        let store = known ?? senderDomain(from)
        let gmailID = headers[":gmail-id"].flatMap { $0.isEmpty ? nil : $0 }
        return Delivery(kind: kind, store: store, item: kind == .problem ? nil : item(in: subject),
                        subject: subject, messageID: headers["message-id"],
                        date: headers["date"].flatMap(parseDate), uid: uid, gmailID: gmailID,
                        package: packageKey(subject: subject, store: store))
    }

    /// "Delivered", "problem" (a failed or attempted delivery), "out for delivery", or
    /// nil for anything else: shipping updates, questions, returns, ads, replies.
    static func kind(ofSubject raw: String) -> Delivery.Kind? {
        var full = normalized(raw)
        // "[EXT] Re: …": tags a mail system put in front
        while full.hasPrefix("["), let close = full.firstIndex(of: "]"), full.distance(from: full.startIndex, to: close) < 24 {
            full = String(full[full.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if full.hasPrefix("re:") || full.hasPrefix("re :") { return nil }        // a conversation, not a notice

        // Product names can't decide: 'Shipped: "Package Delivered Sign"' is a shipping
        // update, 'Delivered: "Expected Value"' a delivery.
        let text = withoutQuotes(full)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // How the subject starts decides: Amazon's "Shipped: …", "Arriving today: …".
        if matches(trimmed, #"^(shipped|ordered|shipping confirmation)\s*([:\-–—|]|$)"#)
            || matches(trimmed, #"^(now )?arriving\b"#)
            || matches(trimmed, #"^your (\S+ ){0,2}(order|package|item|shipment|parcel)s? (has|have) (been )?shipped\b"#) {
            return nil
        }
        if matches(trimmed, #"^out for delivery\b"#) { return .outForDelivery }
        if matches(trimmed, #"^delivered\s*[:\-–—|]"#) { return .delivered }

        // Questions ask rather than tell: "Was your order delivered on time?", "Item not delivered? Get help".
        let s = " " + withoutQuestions(text) + " "
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        // Returns you sent, parcels handed to the carrier, "New items have arrived": not yours arriving.
        let notYours = [#"\byour return\b"#, #"\breturn (package|parcel|shipment|item|order|label|request)s?\b"#,
                        #"\bdrop[- ]?off\b[^.]*\breturn"#,
                        #"\bdelivered to (the |a |an |our |your )?(carrier|courier|seller|merchant|retailer|shipper|warehouse|post office|postal service|airline|shipping (company|carrier|partner|provider)|logistics( partner| provider| company)?)\b"#,
                        #"\b(handed|given) (over )?to (the |a )?(carrier|courier)\b"#]
        if notYours.contains(where: { matches(s, $0) }) { return nil }
        let aboutAPackage = ["package", "parcel", "shipment", "order"].contains { s.contains($0) }

        // Failed or attempted deliveries. Some phrases only ever mean a package; the rest
        // also turn up in bounced email ("Undeliverable: …"), so they need a package word.
        // "Never have a missed delivery again" is an ad.
        if matches(s, #"\b(never|no more|avoid|prevent|without|don't|stop|end)\b[^.!?:]{0,30}\b(missed deliver|delivery attempt|attempted deliver|failed deliver)"#) {
            return nil
        }
        let alwaysProblem = ["delivery attempt", "attempted delivery", "delivery was attempted",
                             "delivery exception", "missed delivery"]
        let problemWithPackage = ["not delivered", "not been delivered", "couldn't be delivered",
                                  "could not be delivered", "wasn't delivered", "unable to deliver", "undeliverable",
                                  "delivery failed", "failed delivery", "returned to sender", "return to sender",
                                  "being returned"]
        // "was never delivered", "hasn't been delivered", "not yet delivered"
        let negated = #"(\bnot|\bnever|n't)\s+([a-z]+\s+){0,2}delivered\b"#
        if alwaysProblem.contains(where: { s.contains($0) })
            || (aboutAPackage && (problemWithPackage.contains(where: { s.contains($0) }) || matches(s, negated))) {
            return .problem
        }
        if matches(s, negated) { return nil }

        // Plainly past tense: delivered, whatever else the subject says.
        let delivered = ["was delivered", "were delivered", "has been delivered", "have been delivered",
                         "got delivered", "item delivered", "items delivered", "package delivered",
                         "parcel delivered", "order delivered", "shipment delivered", "was dropped off",
                         "been dropped off"]
        if delivered.contains(where: { s.contains($0) }) && !s.contains("will have been") { return .delivered }
        if hasArrived(s) { return .delivered }

        if s.contains("out for delivery")
            && !matches(s, #"\b(will|to) (be|go) out for delivery|\bscheduled\b|\bexpected\b"#) {
            return .outForDelivery
        }
        let notYet = ["will be delivered", "to be delivered", "out for delivery", "expected", "estimated",
                      "scheduled", "arriving", "on its way", "on the way", "get it delivered",
                      "get them delivered", "have it delivered", "free delivery", "% off"]
        if notYet.contains(where: { s.contains($0) }) { return nil }

        // "FedEx Shipment 7712… Delivered"
        let words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
        if words.last == "delivered" && aboutAPackage { return .delivered }
        return nil
    }

    /// "Your order has arrived", "Your package has arrived at a UPS Access Point", but not
    /// "Fall has arrived", "New items have arrived" or "…has arrived at the sorting center".
    private static func hasArrived(_ s: String) -> Bool {
        let pattern = #"\b(package|parcel|order|shipment|items?|delivery|purchase)s?\b[^.!?:]{0,40}\b(has|have) arrived\b"#
        guard let found = s.range(of: pattern, options: .regularExpression) else { return false }
        if matches(String(s[..<found.upperBound]), #"\b(new|fresh|latest|just)\s+([a-z]+\s+)?(items?|arrivals|products|styles)\b"#) {
            return false
        }
        // Still on its way: arrived at a sorting center, in the destination country, at customs…
        var rest = String(s[found.upperBound...])
        if let end = rest.firstIndex(where: { ".!?:;".contains($0) }) { rest = String(rest[..<end]) }
        let transit = #"\b(country|sorting|sort|center|centre|facility|hub|depot|warehouse|post office|customs|airport|terminal|origin|transit|distribution|processing|station|city|region|area|port)\b"#
        return !matches(rest, transit)
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
        if let quoted = quotedName(subject) {
            let name = quoted.name.trimmingCharacters(in: .whitespaces)
            var more: Int?
            let after = quoted.after.lowercased()
            if let found = after.range(of: #"and (\d+) more"#, options: .regularExpression) {
                more = Int(after[found].filter(\.isNumber))
            }
            if name.isEmpty { return more.map { "\($0 + 1) items" } }    // 'Delivered: "" and 1 more item'
            guard let more else { return shorten(name) }
            let suffix = " +\(more) more"
            return shorten(name, to: 80 - suffix.count) + suffix
        }
        guard let colon = subject.firstIndex(of: ":") else { return nil }
        let before = subject[..<colon].lowercased()
        guard before.contains("deliver") || before.contains("arrived") else { return nil }
        let name = subject[subject.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.lowercased().hasPrefix("your ") else { return nil }
        return shorten(name)
    }

    /// The name in quotes and the text after it. The closing quote is the last one, so
    /// an inch mark in 'Delivered: "Samsung 55" Class TV" and 1 more item' stays in the
    /// name. A name Amazon cut short, without its closing quote, runs to the end.
    static func quotedName(_ text: String) -> (name: String, after: String)? {
        guard let open = text.firstIndex(where: { $0 == "\"" || $0 == "“" || $0 == "«" }) else { return nil }
        let closers: Set<Character> = text[open] == "«" ? ["»"] : ["\"", "”"]
        let rest = text[text.index(after: open)...]
        guard let close = rest.lastIndex(where: { closers.contains($0) }) else { return (String(rest), "") }
        return (String(rest[..<close]), String(rest[rest.index(after: close)...]))
    }

    // MARK: Who sent it

    /// Stores and carriers whose "delivered" emails need no package word, by the
    /// domain they send from. A subdomain counts ("email.ups.com" is UPS); a domain
    /// that merely contains the name doesn't ("ups.attacker.top", "groups.com").
    static let knownShippers: [String: String] = {
        var names: [String: String] = [:]
        let list: [(String, [String])] = [
            ("Amazon", ["amazon.com", "amazon.co.uk", "amazon.ca", "amazon.com.au", "amazon.in", "amazon.ie",
                        "amazon.sg", "amazon.de", "amazon.fr", "amazon.es", "amazon.it", "amazon.nl", "amazon.co.jp",
                        "amazon.com.mx", "amazon.com.br", "amazon.se", "amazon.pl", "amazon.com.be", "amazon.ae"]),
            ("eBay", ["ebay.com", "ebay.co.uk", "ebay.ca", "ebay.com.au", "ebay.ie", "ebay.de", "ebay.fr", "ebay.it",
                      "ebay.es", "ebay.at", "ebay.ch", "ebay.nl", "ebay.be", "ebay.pl"]),
            ("UPS", ["ups.com"]), ("USPS", ["usps.com", "usps.gov"]), ("FedEx", ["fedex.com"]),
            ("DHL", ["dhl.com", "dhl.de", "dhl.co.uk"]), ("OnTrac", ["ontrac.com"]), ("LaserShip", ["lasership.com"]),
            ("Royal Mail", ["royalmail.com"]), ("Canada Post", ["canadapost.ca", "canadapost-postescanada.ca"]),
            ("Australia Post", ["auspost.com.au"]), ("Purolator", ["purolator.com"]), ("DPD", ["dpd.co.uk", "dpd.com"]),
            ("Evri", ["evri.com"]), ("Walmart", ["walmart.com", "walmart.ca"]), ("Target", ["target.com"]),
            ("Best Buy", ["bestbuy.com", "bestbuy.ca"]), ("Apple", ["apple.com"]), ("Etsy", ["etsy.com"]),
            ("Shop", ["shop.app", "shopify.com"]), ("Costco", ["costco.com", "costco.ca"]),
            ("Home Depot", ["homedepot.com"]), ("Lowe's", ["lowes.com"]), ("Wayfair", ["wayfair.com"]),
            ("Chewy", ["chewy.com"]), ("Temu", ["temu.com"]), ("SHEIN", ["shein.com"]),
            ("AliExpress", ["aliexpress.com"]), ("Back Market", ["backmarket.com"]), ("Nike", ["nike.com"]),
        ]
        for (name, domains) in list { for domain in domains { names[domain] = name } }
        return names
    }()

    /// The sender's email domain, lowercased: "Amazon.com <a@email.amazon.com>" → "email.amazon.com".
    static func domain(of raw: String) -> String {
        let from = HeaderText.decode(String(raw.prefix(2000)))
        let address: String
        if let lt = from.lastIndex(of: "<"), let gt = from.lastIndex(of: ">"), lt < gt {
            address = String(from[from.index(after: lt)..<gt])
        } else {
            address = from.trimmingCharacters(in: .whitespaces)
        }
        guard address.contains("@") else { return "" }
        let domain = (address.split(separator: "@").last.map { $0.lowercased() } ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard domain.contains("."), domain.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }
        return domain
    }

    /// The domain someone registered: "email.informeddelivery.usps.com" → "usps.com",
    /// "mail.shop.co.uk" → "shop.co.uk". (A close guess, without the full list of
    /// public suffixes.)
    static func registeredDomain(_ domain: String) -> String {
        let labels = domain.split(separator: ".")
        guard labels.count > 2 else { return domain }
        let secondLevel: Set<Substring> = ["co", "com", "org", "net", "gov", "ac", "edu", "ne", "or", "go", "gv"]
        let take = labels[labels.count - 1].count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// The store or carrier's name if the email comes from one Hammer knows, by its
    /// domain. Display names don't count: anyone can call themselves "Amazon". With
    /// Gmail's Authentication-Results (the app-password route), the email must also be
    /// signed (DKIM) by that domain, so a forged From address doesn't count either.
    static func knownShipper(from raw: String, authentication: String? = nil) -> String? {
        let domain = domain(of: raw)
        let labels = domain.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        var name: String?
        for start in 0..<(labels.count - 1) {
            if let found = knownShippers[labels[start...].joined(separator: ".")] { name = found; break }
        }
        guard let name else { return nil }
        if let authentication, !signedBySender(authentication, domain: domain) { return nil }
        return name
    }

    /// Whether Gmail's verdict (its own Authentication-Results header, "mx.google.com; …")
    /// says the email was signed by the sender's domain: "dkim=pass header.i=@ups.com".
    /// Comments and quoted text are left out first, since they can carry text the
    /// sender chose.
    static func signedBySender(_ results: String, domain: String) -> Bool {
        let sender = registeredDomain(domain)
        guard !sender.isEmpty else { return false }
        var plain = ""
        var depth = 0, quoted = false, escaped = false
        for c in results.prefix(4000) {
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if quoted { if c == "\"" { quoted = false }; continue }
            if c == "\"" && depth == 0 { quoted = true; continue }
            if c == "(" { depth += 1; continue }
            if c == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { plain.append(c) }
        }
        let parts = plain.lowercased().split(separator: ";")
        guard parts.first?.split(separator: " ").first == "mx.google.com" else { return false }   // only Gmail's own
        for part in parts.dropFirst() {
            let tokens = part.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.first == "dkim=pass" else { continue }
            for token in tokens.dropFirst() where token.hasPrefix("header.i=") || token.hasPrefix("header.d=") {
                let signer = String(token.dropFirst(9).split(separator: "@").last ?? "")
                if !signer.isEmpty && registeredDomain(signer) == sender { return true }
            }
        }
        return false
    }

    /// Whether the subject is about a package rather than, say, a message or report.
    static func mentionsAPackage(_ subject: String) -> Bool {
        let words = Set(tidy(subject).lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["package", "packages", "parcel", "parcels", "order", "orders", "shipment",
                                        "shipments", "item", "items", "purchase", "purchases", "delivery", "box"])
    }

    /// The store or carrier, from the sender: a name Hammer knows (by domain, see
    /// knownShipper), or else the sender's domain ("tinyshop.co"). The name an email
    /// shows isn't used: anyone can call themselves "Amazon" or "USPS".
    static func store(from raw: String, authentication: String? = nil) -> String {
        knownShipper(from: raw, authentication: authentication) ?? senderDomain(raw)
    }

    static func senderDomain(_ raw: String) -> String {
        let domain = registeredDomain(domain(of: raw))
        return domain.isEmpty ? "Unknown sender" : shorten(domain, to: 40)
    }

    /// Which package an email is about, so "Delivered" can replace its "Out for
    /// delivery": a tracking or order number in the subject, or else the quoted item
    /// name. Nil if there's neither (then each email gets its own notification).
    static func packageKey(subject: String, store: String) -> String? {
        let text = tidy(subject)
        let prefix = store.lowercased() + ":"
        if let order = text.range(of: #"\b\d{3}-\d{7}-\d{7}\b"#, options: .regularExpression) {
            return prefix + text[order]                                       // Amazon's order numbers
        }
        if let number = trackingNumbers(in: text).first { return prefix + number.lowercased() }
        if let quoted = quotedName(text) {
            let name = quoted.name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !name.isEmpty { return prefix + String(name.prefix(80)) }
        }
        return nil
    }

    /// Words of 10 or more letters and digits with at least 8 digits: "9400111899223344556677",
    /// "771234567890", "1Z999AA10123456784".
    static func trackingNumbers(in text: String) -> [String] {
        text.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .filter { $0.count >= 10 && $0.filter(\.isNumber).count >= 8 }.map(String.init)
    }

    /// The notification text when no item is named: the subject without the store's
    /// name in front ("UPS Update: Delivery Attempted" from UPS → "Delivery Attempted",
    /// as the title already says UPS), and long tracking numbers cut to their last digits.
    static func bodyText(_ subject: String, store: String) -> String {
        var text = tidy(subject)
        if !store.isEmpty, let name = text.range(of: store, options: [.caseInsensitive, .anchored]) {
            var rest = text[name.upperBound...].drop(while: { "®™:-–—|•, ".contains($0) })
            for word in ["update", "my choice", "notification", "alert", "notice"] {
                if let found = rest.range(of: word, options: [.caseInsensitive, .anchored]) {
                    rest = rest[found.upperBound...].drop(while: { ":-–—|•, ".contains($0) })
                    break
                }
            }
            if rest.contains(where: { $0.isLetter }) { text = String(rest) }
        }
        for number in Set(trackingNumbers(in: text)) where number.count > 6 {
            text = text.replacingOccurrences(of: number, with: "…" + number.suffix(4))
        }
        if let first = text.first, first.isLowercase { text = first.uppercased() + text.dropFirst() }
        return shorten(text, to: 120)
    }

    // MARK: Text

    /// Subject without emoji, invisible characters, mail prefixes and extra spaces, for showing.
    static func tidy(_ raw: String) -> String {
        var text = HeaderText.decode(String(raw.prefix(4000)))      // a longer subject is junk; this keeps it quick
        var kept = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            let next = index + 1 < scalars.count ? scalars[index + 1].value : 0
            let emojiStyle = scalar.properties.isEmoji && !scalar.isASCII && (next == 0xFE0F || next == 0x20E3)
            if scalar.properties.isEmojiPresentation || emojiStyle || isInvisible(scalar) { continue }
            kept.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        text = String(kept)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let edges = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:|•"))
        text = text.trimmingCharacters(in: edges)
        while let prefix = ["fwd:", "fw:"].first(where: { text.lowercased().hasPrefix($0) }) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: edges)
        }
        return text
    }

    /// What's left of an emoji once it's gone (joiners, variation selectors, skin tones,
    /// keycaps, tags), and characters that change how text looks without showing:
    /// zero-width spaces, direction overrides.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x034F, 0x061C, 0x180E, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069,
             0x20E3, 0xFE00...0xFE0F, 0xFEFF, 0x1F3FB...0x1F3FF, 0xE0000...0xE007F, 0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }

    /// At most `limit` characters, with "…" at the end if it was cut.
    static func shorten(_ text: String, to limit: Int = 80) -> String {
        guard limit >= 1 else { return "" }
        return text.count <= limit ? text : String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func normalized(_ raw: String) -> String {
        String(tidy(raw).lowercased().prefix(1000))
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The text with anything in quotes taken out: "…" (from the first to the last, so
    /// inch marks don't end it early), “…”, «…» and '…' (not apostrophes). An opening
    /// quote without its closing one takes the rest of the text.
    static func withoutQuotes(_ text: String) -> String {
        var chars = Array(text)
        if let open = chars.firstIndex(of: "\"") {
            let close = chars.lastIndex(of: "\"").flatMap { $0 > open ? $0 : nil } ?? chars.count - 1
            chars.replaceSubrange(open...close, with: [" "])
        }
        for (opening, closing) in [("“", "”"), ("«", "»")] as [(Character, Character)] {
            while let open = chars.firstIndex(of: opening) {
                let close = chars[open...].firstIndex(of: closing) ?? chars.count - 1
                chars.replaceSubrange(open...close, with: [" "])
            }
        }
        func isWordCharacter(_ index: Int) -> Bool {
            index >= 0 && index < chars.count && (chars[index].isLetter || chars[index].isNumber)
        }
        var index = 0
        while index < chars.count {
            if chars[index] == "'" && !isWordCharacter(index - 1),
               let close = chars[(index + 1)...].indices.first(where: { chars[$0] == "'" && !isWordCharacter($0 + 1) }) {
                chars.replaceSubrange(index...close, with: [" "])
            }
            index += 1
        }
        return String(chars)
    }

    /// The text without its questions, which ask rather than tell: "Was your package
    /// delivered? Tell us" → "Tell us". Sentences are split at . ! ? ; | and at a colon
    /// or a dash with spaces around it.
    static func withoutQuestions(_ text: String) -> String {
        var kept: [String] = []
        var current = ""
        func end(question: Bool) {
            let clause = current.trimmingCharacters(in: .whitespaces)
            if !clause.isEmpty && !question { kept.append(clause) }
            current = ""
        }
        let chars = Array(text)
        for (index, c) in chars.enumerated() {
            let atBreak = index + 1 >= chars.count || chars[index + 1].isWhitespace
            switch c {
            case "?": end(question: true)
            case "!", ";", "|": end(question: false)
            case "." where atBreak, ":" where atBreak: end(question: false)
            case "-" where atBreak && index > 0 && chars[index - 1].isWhitespace,
                 "–" where atBreak && index > 0 && chars[index - 1].isWhitespace,
                 "—" where atBreak && index > 0 && chars[index - 1].isWhitespace:
                end(question: false)
            default: current.append(c)
            }
        }
        end(question: false)
        return kept.joined(separator: ". ")
    }

    // MARK: Dates

    /// An email's Date header: "Sat, 17 Oct 2026 14:02:11 -0700 (PDT)". Also takes
    /// two-digit years, zone names (EST, PDT…), no seconds, and no weekday. Only the
    /// first 100 characters are read, up to the first "(".
    static func parseDate(_ raw: String) -> Date? {
        var text = String(String.UnicodeScalarView(raw.unicodeScalars.prefix(300).filter { $0.isASCII }))
        if let comment = text.firstIndex(of: "(") { text = String(text[..<comment]) }
        text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" || $0 == "\r" || $0 == "\n" })
            .map { $0.lowercased() }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        if let first = tokens.first, first.allSatisfy(\.isLetter), !months.contains(String(first.prefix(3))) {
            tokens.removeFirst()                                         // the weekday (not checked)
        }
        guard tokens.count >= 4, let day = Int(tokens[0]), (1...31).contains(day),
              tokens[1].count >= 3, let monthIndex = months.firstIndex(of: String(tokens[1].prefix(3))),
              tokens[2].count >= 2, tokens[2].count <= 4, var year = Int(tokens[2]) else { return nil }
        if tokens[2].count == 2 { year += year < 50 ? 2000 : 1900 } else if tokens[2].count == 3 { year += 1900 }
        let time = tokens[3].split(separator: ":", omittingEmptySubsequences: false)
        guard time.count == 2 || time.count == 3, let hour = Int(time[0]), let minute = Int(time[1]),
              (0...23).contains(hour), (0...59).contains(minute), time[1].count == 2 else { return nil }
        var second = 0
        if time.count == 3 {
            guard let whole = Int(time[2].split(separator: ".").first ?? ""), (0...60).contains(whole) else { return nil }
            second = min(whole, 59)
        }
        let month = monthIndex + 1
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][monthIndex]
        guard (1900...9999).contains(year), day <= days else { return nil }

        var offset = 0                                          // seconds east of UTC; no zone: UTC
        if tokens.count >= 5 {
            let zone = tokens[4]
            if let sign = zone.first, sign == "+" || sign == "-" {
                let digits = zone.dropFirst().filter(\.isNumber)
                guard digits.count == 4, let value = Int(digits), value % 100 < 60, value / 100 <= 14 else { return nil }
                offset = (value / 100 * 3600 + value % 100 * 60) * (sign == "-" ? -1 : 1)
            } else {
                let named = ["ut": 0, "gmt": 0, "utc": 0, "z": 0, "est": -5, "edt": -4, "cst": -6, "cdt": -5,
                             "mst": -7, "mdt": -6, "pst": -8, "pdt": -7]
                offset = (named[zone] ?? 0) * 3600                      // other names: treated as UTC
            }
        }
        // Days since 1970-01-01 (Howard Hinnant's days_from_civil).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let daysSince1970 = era * 146_097 + dayOfEra - 719_468
        let seconds = daysSince1970 * 86_400 + hour * 3600 + minute * 60 + second - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

// MARK: - Setup checks

enum DeliverySetup {
    /// A plain address like you@gmail.com (no spaces, quotes or other surprises).
    static func isPlainEmail(_ text: String) -> Bool {
        text.count <= 254
            && text.range(of: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
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
    /// Splits raw header lines into lowercase name → value, joining folded lines. The
    /// first of a repeated header wins (for Authentication-Results, that's Gmail's own,
    /// added on top). Each line is read as UTF-8, or as Latin-1 if it isn't valid UTF-8.
    static func parse(_ data: [UInt8]) -> [String: String] {
        var result: [String: String] = [:]
        var name: String?
        var start = 0
        while start <= data.count {
            let end = data[start...].firstIndex(of: 10) ?? data.count
            var bytes = Array(data[start..<end])
            start = end + 1
            if bytes.last == 13 { bytes.removeLast() }
            var line = String(decoding: bytes, as: UTF8.self)
            if !line.utf8.elementsEqual(bytes) { line = String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) })) }
            line = line.replacingOccurrences(of: "\r", with: " ")
            if let first = line.first, first == " " || first == "\t", let current = name {
                result[current, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard !key.isEmpty, !key.contains(" ") else { name = nil; continue }
                if result[key] == nil {
                    name = key
                    result[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                } else {
                    name = nil                                    // a repeat: its folded lines aren't added either
                }
            } else {
                name = nil
            }
        }
        return result
    }

    /// Decodes "=?UTF-8?B?…?=" / "=?utf-8?Q?…?=" words (RFC 2047), the way mail
    /// programs show subjects with emoji or accents. Neighbouring words in the same
    /// charset are joined before decoding, since mail programs split a character
    /// across two of them.
    static func decode(_ raw: String) -> String {
        guard raw.contains("=?") else { return raw }
        let pattern = #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return raw }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return raw }
        var out = ""
        var cursor = 0
        var pending: (charset: String, bytes: [UInt8], raw: String)?
        func flush() {
            guard let words = pending else { return }
            out += string(from: words.bytes, charset: words.charset) ?? words.raw
            pending = nil
        }
        var lastWasWord = false
        for match in matches {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let onlySpace = gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Spaces between two encoded words are dropped; other text is kept.
            if !(lastWasWord && onlySpace) {
                flush()
                out += gap
            }
            let whole = ns.substring(with: match.range)
            let charset = (ns.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init) ?? "")
                .lowercased()                                                // "UTF-8*en": RFC 2231 language
            let text = ns.substring(with: match.range(at: 3))
            let bytes: [UInt8]?
            if ns.substring(with: match.range(at: 2)).uppercased() == "B" {
                var padded = text
                while padded.count % 4 != 0 { padded += "=" }
                bytes = Data(base64Encoded: padded).map { [UInt8]($0) }
            } else {
                bytes = quotedPrintable(text)
            }
            if let bytes {
                if pending?.charset == charset {
                    pending?.bytes += bytes
                    pending?.raw += whole
                } else {
                    flush()
                    pending = (charset, bytes, whole)
                }
                lastWasWord = true
            } else {
                flush()
                out += whole
                lastWasWord = false
            }
            cursor = match.range.location + match.range.length
        }
        flush()
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
        switch charset {
        case "utf-8", "utf8":
            let text = String(decoding: bytes, as: UTF8.self)
            return text.utf8.elementsEqual(bytes) ? text : nil
        case "us-ascii", "ascii": return String(bytes: bytes, encoding: .ascii) ?? String(bytes: bytes, encoding: .utf8)
        case "iso-8859-1", "latin1", "iso-8859-15": return String(bytes: bytes, encoding: .isoLatin1)
        case "windows-1252", "cp1252": return String(bytes: bytes, encoding: .windowsCP1252)
        default: return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1)
        }
    }
}

// MARK: - Talking to Gmail (IMAP)

enum IMAPError: Error, Equatable {
    case badLogin(String)    // Gmail refused the email or app password; the text says why
    case notAllowed(String)  // Gmail refused the sign-in for another lasting reason (e.g. IMAP turned off)
    case offline             // couldn't reach Gmail (no internet, asleep, timed out)
    case failed(String)      // a passing problem; the text is for the menu
}

/// Moves bytes to and from the mail server. In the app it's a TLS connection to
/// imap.gmail.com (DeliveryAlerts.swift); in tests it's a plain socket to a fake server.
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
            if IMAPConnection.isPassing(reply.text) { throw IMAPError.failed("Gmail is having trouble right now.") }
            // e.g. "Your account is not enabled for IMAP use": retrying won't fix it
            throw IMAPError.notAllowed(reply.text)
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

    /// A passing problem on Gmail's side: worth trying again later.
    static func isPassing(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["unavailable", "inuse", "[limit]", "overquota", "temporar", "try again", "too many", "simultaneous",
                "later", "busy", "throttl"].contains { t.contains($0) }
    }

    /// "… {123}" → 123 (also "{123+}"). A number too big for Int gives Int.max, which
    /// readBytes refuses.
    static func literalSize(at line: [UInt8]) -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = line[(open + 1)..<(line.count - 1)]
        if digits.last == UInt8(ascii: "+") { digits = digits.dropLast() }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(String(decoding: digits, as: UTF8.self)) ?? Int.max
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

    /// "* 3 FETCH (UID 12 X-GM-MSGID 1278… BODY[HEADER.FIELDS (…)] {n}\r\n<n bytes>)" → [12: headers].
    /// Each response is read on its own, its literals by their length, so an unsolicited
    /// "* 2 FETCH (UID 50 FLAGS (\Seen))" between two emails can't move headers onto
    /// the wrong email, and text inside a literal is never read as a response. Gmail's
    /// own ID for the email (X-GM-MSGID, in hex as Gmail's links use it) is added as
    /// ":gmail-id", a name no real header can have.
    static func fetchedHeaders(_ bytes: [UInt8]) -> [Int: [String: String]] {
        var result: [Int: [String: String]] = [:]
        var index = 0
        while index < bytes.count {
            var text: [UInt8] = []                 // the response without its literals
            var headers: [UInt8]?
            while index < bytes.count {
                let lineEnd = bytes[index...].firstIndex(of: 10) ?? bytes.count
                var line = Array(bytes[index..<lineEnd])
                index = lineEnd < bytes.count ? lineEnd + 1 : bytes.count
                if line.last == 13 { line.removeLast() }
                text += line + [32]
                guard let size = IMAPConnection.literalSize(at: line) else { break }
                guard size >= 0, size <= bytes.count - index else {          // cut short: nothing more to read
                    index = bytes.count
                    headers = nil
                    break
                }
                let literal = Array(bytes[index..<(index + size)])
                index += size
                if headers == nil, let open = line.lastIndex(of: UInt8(ascii: "{")),
                   String(decoding: line[..<open], as: UTF8.self).uppercased().contains("BODY[HEADER") {
                    headers = literal
                }
            }
            let response = String(decoding: text, as: UTF8.self)
            guard response.hasPrefix("* "), response.uppercased().contains(" FETCH ("), let headers,
                  let uid = number(after: "UID", in: response) else { continue }
            var fields = HeaderText.parse(headers)
            fields[":gmail-id"] = nil
            if let found = response.range(of: #"\bX-GM-MSGID\s+\d{1,20}"#, options: [.regularExpression, .caseInsensitive]),
               let id = UInt64(response[found].split(separator: " ").last ?? "") {
                fields[":gmail-id"] = String(id, radix: 16)
            }
            result[uid] = fields
        }
        return result
    }

    private static func number(after key: String, in text: String) -> Int? {
        guard let range = text.range(of: #"\b"# + key + #"\s+(\d+)"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return Int(text[range].split(whereSeparator: { $0 == " " || $0 == "\t" }).last ?? "")
    }

    /// IMAP's date for SEARCH SINCE: "17-Oct-2026" (UTC).
    static func searchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d-MMM-yyyy"
        return formatter.string(from: date)
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
    /// Deliveries older than this aren't announced (e.g. an old email moved back to the
    /// inbox), and setting up again looks back at most this far.
    static let tooOld: TimeInterval = 3 * 24 * 3600
    /// What's fetched for each new email: Gmail's ID for it, and a few headers.
    static let fetchItems = "(X-GM-MSGID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID AUTHENTICATION-RESULTS)])"

    /// One check over an open, logged-in connection: returns the new deliveries and the
    /// updated state. The inbox is opened read-only (EXAMINE) and only headers are read
    /// (BODY.PEEK), so nothing is marked as read. The first check after setup only notes
    /// where the inbox is, so old mail isn't announced, unless `lookBack` says when the
    /// last good check was (setting up again after it stopped working): then mail since
    /// then (at most 3 days) is looked at too. The state only moves forward when the
    /// whole check succeeds.
    static func run(state: DeliveryState, now: Date = Date(), lookBack: Date? = nil,
                    command: (String) throws -> IMAPResponse) throws -> (deliveries: [Delivery], state: DeliveryState) {
        var next = state
        let inbox = try command("EXAMINE INBOX")
        guard inbox.status == "OK", let status = IMAPReply.status(inbox.untagged) else {
            throw IMAPError.failed("Couldn't open your inbox just now.")
        }
        let newest = status.uidNext - 1
        var notBefore: Date?
        let found: [Int]
        if let last = state.lastUID, state.uidValidity == status.uidValidity {
            guard newest > last else { return ([], next) }
            // Every new email, not a Gmail search: search results can lag behind new mail,
            // and the decision is made here anyway, from the subject and sender.
            let search = try command("UID SEARCH UID \(last + 1):*")
            guard search.status == "OK", let uids = IMAPReply.search(search.untagged) else {
                throw IMAPError.failed("Couldn't list new mail just now.")
            }
            found = uids.filter { $0 > last }.sorted()
        } else if let lookBack {
            let since = max(lookBack, now.addingTimeInterval(-tooOld))
            notBefore = since.addingTimeInterval(-15 * 60)
            let day = IMAPReply.searchDate(since.addingTimeInterval(-24 * 3600))     // whole days, any time zone
            let search = try command("UID SEARCH SINCE \(day)")
            guard search.status == "OK", let uids = IMAPReply.search(search.untagged) else {
                throw IMAPError.failed("Couldn't list new mail just now.")
            }
            found = uids.filter { $0 <= newest }.sorted()
        } else {
            next.uidValidity = status.uidValidity          // first check, or Gmail renumbered: start from here
            next.lastUID = newest
            return ([], next)
        }
        let checked = Array(found.suffix(maxPerCheck))

        var deliveries: [Delivery] = []
        if !checked.isEmpty {
            var headers: [Int: [String: String]] = [:]
            for start in stride(from: 0, to: checked.count, by: batch) {
                let list = checked[start..<min(start + batch, checked.count)].map(String.init).joined(separator: ",")
                let fetch = try command("UID FETCH \(list) \(fetchItems)")
                guard fetch.status == "OK" else { throw IMAPError.failed("Couldn't read new mail just now.") }
                headers.merge(IMAPReply.fetchedHeaders(fetch.untagged)) { _, newer in newer }
            }
            for uid in checked {
                guard let fields = headers[uid], var delivery = DeliveryMail.classify(headers: fields, uid: uid)
                else { continue }
                if let date = delivery.date {
                    if now.timeIntervalSince(date) > tooOld { continue }
                    if let notBefore, date < notBefore { continue }
                } else {
                    delivery.date = now                    // when Hammer saw it
                }
                let key = delivery.messageID ?? "uid:\(status.uidValidity):\(uid)"
                if next.announced.contains(key) { continue }
                next.announced.append(key)
                deliveries.append(delivery)
            }
            next.announced = Array(next.announced.suffix(200))
        }
        next.uidValidity = status.uidValidity
        next.lastUID = max(newest, found.max() ?? newest, state.uidValidity == status.uidValidity ? state.lastUID ?? 0 : 0)
        return (deliveries, next)
    }

    /// Connects, logs in, checks and logs out.
    static func run(state: DeliveryState, email: String, password: String, now: Date = Date(), lookBack: Date? = nil,
                    transport: () throws -> IMAPTransport) -> Result<(deliveries: [Delivery], state: DeliveryState), IMAPError> {
        do {
            let connection = IMAPConnection(transport: try transport())
            defer { connection.logout() }
            try connection.start()
            try connection.login(email: email, password: password)
            return .success(try run(state: state, now: now, lookBack: lookBack, command: connection.run))
        } catch let error as IMAPError {
            return .failure(error)
        } catch {
            return .failure(.offline)
        }
    }

    /// What went wrong and what to do, in words.
    static func explain(_ error: IMAPError) -> String { CheckFailure(error).setupMessage }
}

// MARK: - The Keychain (through macOS's `security` tool)
//
// Secrets are kept in your login Keychain by /usr/bin/security, so the items belong
// to that tool. Hammer can't keep them itself: its certificate isn't issued by
// Apple, so macOS ties an item Hammer makes to that exact build, and after every
// update asks for your login password before the new build may read it (checked on
// the build server, see Tests/Deliveries). The downside: any program running as you
// could ask `security` for them too. Secrets go to `security` on its standard input,
// never on a command line, and each call has a time limit.

/// What reading a secret from the Keychain gave.
enum KeychainRead: Equatable {
    case found(String)
    case missing                  // there's no such item
    case unavailable(String)      // locked, timed out or refused: try again later

    var value: String? { if case .found(let value) = self { return value }; return nil }
}

struct KeychainTool {
    var path = "/usr/bin/security"
    /// Long enough to type your password if macOS asks to unlock the Keychain.
    var timeout: TimeInterval = 60

    func find(service: String, account: String) -> KeychainRead {
        guard let (status, output) = run(["find-generic-password", "-s", service, "-a", account, "-w"]) else {
            return .unavailable("The Keychain didn't answer in time.")
        }
        switch status {
        case 0: return .found(output.trimmingCharacters(in: .newlines))
        case 44: return .missing                                   // errSecItemNotFound
        default: return .unavailable("The Keychain couldn't be read (\(status)).")
        }
    }

    /// Adds or replaces an item and reads it back. Values are limited to plain
    /// characters, since they go on a line `security -i` reads.
    @discardableResult
    func save(service: String, account: String, label: String, secret: String) -> Bool {
        let plain = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._@/:%+=-_")
        guard ![service, account, label, secret].contains(where: { $0.isEmpty || !$0.unicodeScalars.allSatisfy(plain.contains) })
        else { return false }
        _ = run(["-i"], input: "add-generic-password -U -s \(service) -a \(account) -l \(label) -w \(secret)\n")
        return find(service: service, account: account) == .found(secret)
    }

    /// True if the item is gone (or was never there).
    @discardableResult
    func delete(service: String, account: String) -> Bool {
        guard let (status, _) = run(["delete-generic-password", "-s", service, "-a", account]) else { return false }
        return status == 0 || status == 44
    }

    /// Runs the tool; nil if it couldn't start or didn't finish in time (then it's stopped).
    func run(_ arguments: [String], input: String? = nil) -> (Int32, String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        let data = KeychainOutput()
        let read = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {                       // so a full pipe can't hold the tool up
            data.bytes = output.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        _ = read.wait(timeout: .now() + 5)
        return (process.terminationStatus, String(decoding: data.bytes, as: UTF8.self))
    }
}

private final class KeychainOutput { var bytes = Data() }

// MARK: - The Google script route (no app password)
//
// Instead of logging in to Gmail, Hammer can ask a small Google Apps Script that
// runs in your own Google account. You paste the script (below) into
// script.google.com and deploy it as a web app; Hammer then asks its web address
// every few minutes, with a random key only the two of them know. The script
// answers with the sender, subject, date, Message-ID and Gmail ID of recent inbox
// emails whose subject mentions a delivery, plus your address, and Hammer decides
// which are deliveries (DeliveryMail).
//
// The request is a GET with the key in the address (doGet, ?key=…&v=2). Scripts
// already deployed answer that, so it stays as it is: a change here would mean
// everyone deploying the script again. The address and key are kept in the
// Keychain and only sent to script.google.com over HTTPS, with no cache or cookies.

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
        guard trimmed.count < 500, let parts = URLComponents(string: trimmed), parts.scheme == "https",
              parts.host == "script.google.com",
              parts.path.hasPrefix("/macros/") || parts.path.hasPrefix("/a/macros/"), parts.path.hasSuffix("/exec"),
              parts.query == nil || parts.query == "",
              parts.path.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "/._-".unicodeScalars.contains($0)) })
        else { return nil }
        return URL(string: "https://script.google.com" + parts.path)
    }

    /// Tests point Hammer at a stand-in server on this computer (http://127.0.0.1:…).
    static var allowsLocalServer = false

    /// A saved address Hammer will ask: a web app URL (or, in tests, the stand-in server).
    static func savedURL(_ text: String) -> URL? {
        if let url = webAppURL(text) { return url }
        guard allowsLocalServer, let url = URL(string: text), url.scheme == "http", url.host == "127.0.0.1" else { return nil }
        return url
    }

    /// The address Hammer asks: the web app, with the key, and (after the first
    /// time) when it last asked, so the script only searches newer mail.
    static func requestURL(base: URL, key: String, after: Date? = nil) -> URL? {
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var items = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "v", value: "2")]
        if let after { items.append(URLQueryItem(name: "after", value: String(Int(after.timeIntervalSince1970)))) }
        parts.queryItems = items
        return parts.url
    }

    /// How far back each check looks past the last one, in case Gmail's search
    /// hadn't caught up with an email yet (seen ones are skipped anyway).
    static let overlap: TimeInterval = 15 * 60

    static let template = #"""
    /**
     * Hammer delivery alerts. This runs in your own Google account.
     *
     * Every few minutes Hammer (the Mac app) asks this script for recent inbox emails
     * whose subject mentions a delivery. For each, the script answers with just the
     * sender, subject, date, Message-ID and Gmail ID, from the last 2 days (only those
     * since Hammer last asked), and with your Gmail address. It doesn't change, send
     * or delete anything, and it only answers requests that carry Hammer's key.
     */
    const HAMMER_KEY = '__HAMMER_KEY__';
    const SEARCH = 'in:inbox newer_than:2d subject:(delivered OR delivery OR deliver OR arrived OR ' +
        'undeliverable OR returned OR "dropped off" OR "return to sender" OR "returned to sender")';
    const MAX_THREADS = 20;

    function doGet(e) {
      const parameter = e && e.parameter ? e.parameter : {};
      if (parameter.key !== HAMMER_KEY) return answer({ ok: false, error: 'key' });
      try {
        return answer({
          ok: true,
          version: 2,
          account: Session.getEffectiveUser().getEmail(),
          emails: recentDeliveryEmails(Number(parameter.after) || 0)
        });
      } catch (error) {
        const permission = /permission|authoriz|scope/i.test(String(error));
        return answer({ ok: false, error: permission ? 'permission' : 'gmail', message: String(error) });
      }
    }

    /** Delivery emails from the last 2 days, or only since `after` (seconds) if given. */
    function recentDeliveryEmails(after) {
      const since = Math.max(Date.now() - 2 * 24 * 60 * 60 * 1000, after * 1000);
      const query = after > 0 ? SEARCH + ' after:' + Math.floor(after) : SEARCH;
      const emails = [];
      GmailApp.search(query, 0, MAX_THREADS).forEach(function (thread) {
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
      Logger.log(JSON.stringify(recentDeliveryEmails(0), null, 2));
    }
    """#
}

/// Why a check didn't work: one short line for the menu, and what to do about it
/// (shown by Fix… in the menu, and in the setup window).
struct CheckFailure: Error, Equatable {
    let message: String           // one short line, for the menu
    var advice: String = ""       // what to do; empty: nothing to do but wait (it's passing)
    var needsSetup = false        // Fix… offers to set Gmail up again
    var offline = false
    var stopChecking = false      // a refused app password: don't keep knocking (it can lock the account)
    var link: String? = nil       // a page that helps fix it

    static let offline = CheckFailure(message: "Can't reach Gmail right now.", offline: true)

    init(message: String, advice: String = "", needsSetup: Bool = false, offline: Bool = false,
         stopChecking: Bool = false, link: String? = nil) {
        self.message = message
        self.advice = advice
        self.needsSetup = needsSetup
        self.offline = offline
        self.stopChecking = stopChecking
        self.link = link
    }

    /// Whether the menu offers Fix….
    var hasFix: Bool { needsSetup || !advice.isEmpty }

    /// For the setup window, which doesn't try again by itself: what went wrong, and what to do now.
    var setupMessage: String {
        if !advice.isEmpty { return message + " " + advice }
        if offline { return message + " Check your internet connection, then try again." }
        return message + " Try again in a few minutes."
    }

    static let appPasswords = "https://myaccount.google.com/apppasswords"
    static let scripts = "https://script.google.com/home"

    /// From the app-password (IMAP) route.
    init(_ error: IMAPError) {
        switch error {
        case .badLogin(let text):
            if text.localizedCaseInsensitiveContains("application-specific") {
                self.init(message: "Gmail needs an app password.",
                          advice: "Your regular Google password doesn't work here. Make an app password "
                            + "(2-Step Verification has to be on) and set up Gmail again.",
                          needsSetup: true, stopChecking: true, link: CheckFailure.appPasswords)
            } else if text.localizedCaseInsensitiveContains("webalert") {
                self.init(message: "Google blocked the sign-in as unusual.",
                          advice: "Open Gmail in your browser once, then set up Gmail again.",
                          needsSetup: true, stopChecking: true)
            } else {
                self.init(message: "Gmail didn't accept the app password.",
                          advice: "Make a new app password and set up Gmail again.",
                          needsSetup: true, stopChecking: true, link: CheckFailure.appPasswords)
            }
        case .notAllowed(let text):
            let lower = text.lowercased()
            if lower.contains("imap") && (lower.contains("not enabled") || lower.contains("disabled")) {
                if lower.contains("domain") || lower.contains("administrator") {
                    self.init(message: "IMAP is turned off for your organization.",
                              advice: "Set up Gmail again with the Google script instead.", needsSetup: true)
                } else {
                    self.init(message: "IMAP is turned off for this Gmail account.",
                              advice: "Turn it on in Gmail's settings (Forwarding and POP/IMAP), or set up Gmail "
                                + "again with the Google script.", needsSetup: true)
                }
            } else {
                let said = text.replacingOccurrences(of: #"^(\[[^\]]*\]\s*)+|\s*\((Failure|Success)\)\s*$"#, with: "",
                                                     options: .regularExpression)
                self.init(message: "Gmail turned down the sign-in.",
                          advice: "Gmail said: “\(DeliveryMail.shorten(said, to: 160))” Set up Gmail again, "
                            + "or use the Google script instead.", needsSetup: true)
            }
        case .offline: self = .offline
        case .failed(let text): self.init(message: text)
        }
    }
}

/// What Hammer remembers between script checks.
struct ScriptState: Codable, Equatable {
    var started = false           // the first answer only notes what's already there
    var seen: [String] = []       // Gmail IDs already looked at (the last 500)
    var askedAt: Date? = nil      // when the last good answer was asked for

    /// What to send as `after`: a little before the last good check, or nil (look at 2 days).
    var searchFrom: Date? { askedAt.map { $0.addingTimeInterval(-DeliveryScript.overlap) } }
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
    /// `finalURL` is where the request ended up after Google's redirects.
    static func read(status: Int, body: Data, finalURL: URL? = nil) -> Result<Reply, CheckFailure> {
        let scripts = CheckFailure.scripts
        if status == 404 {
            return .failure(CheckFailure(message: "Can't find the script at that address.",
                                         advice: "Copy the Web app URL again from Deploy → Manage deployments. "
                                            + "It ends in /exec.", needsSetup: true, link: scripts))
        }
        if status == 429 || status >= 500 {
            return .failure(CheckFailure(message: "Google is busy right now."))
        }
        if let reply = try? JSONDecoder().decode(Reply.self, from: body) {
            if reply.ok { return .success(reply) }
            if reply.error == "key" {
                return .failure(CheckFailure(message: "The script's key doesn't match Hammer's.",
                                             advice: "Set up Gmail again: Hammer makes a fresh script with a new key.",
                                             needsSetup: true))
            }
            if reply.error == "permission" {
                return .failure(CheckFailure(message: "The script isn't allowed to read Gmail.",
                                             advice: "Open it at script.google.com, choose test, click Run, tick "
                                                + "Select all, and click Continue.", needsSetup: true, link: scripts))
            }
            return .failure(CheckFailure(message: "The script couldn't read Gmail just now."))
        }
        let html = String(decoding: body.prefix(200_000), as: UTF8.self)
        let page = html.lowercased()
        let title = pageTitle(html)
        if page.contains("script function not found") {
            return .failure(CheckFailure(message: "The script wasn't saved before it was deployed.",
                                         advice: "Set up Gmail again, and press ⌘S in the editor before deploying.",
                                         needsSetup: true))
        }
        if page.contains("authorization is required") || page.contains("authorisation is required") {
            return .failure(CheckFailure(message: "The script needs your permission again.",
                                         advice: "Open it at script.google.com and click Run.", needsSetup: true,
                                         link: scripts))
        }
        let signIn = finalURL?.host?.hasSuffix("accounts.google.com") == true
            || title?.lowercased().contains("sign in") == true || status == 401 || status == 403
        if signIn {
            return .failure(CheckFailure(message: "The script isn't open to Anyone.",
                                         advice: "In the script, click Deploy → Manage deployments, click the pencil, "
                                            + "set Who has access to Anyone and Version to New version, then click Deploy.",
                                         needsSetup: true, link: scripts))
        }
        if page.contains("unable to open the file") || page.contains("page not found") {
            return .failure(CheckFailure(message: "Google can't find a script at that address.",
                                         advice: "Copy the Web app URL again from Deploy → Manage deployments.",
                                         needsSetup: true, link: scripts))
        }
        let said = title.map { "Google's page said “\($0)”. " } ?? ""
        return .failure(CheckFailure(message: "The script sent back a page instead of its answer.",
                                     advice: said + "If it keeps happening, check the deployment at script.google.com.",
                                     link: scripts))
    }

    /// The <title> of an HTML page, tidied up; nil if there isn't one. Reads at most the
    /// first 200 KB, in one pass.
    static func pageTitle(_ html: String) -> String? {
        let head = html.prefix(200_000)
        guard let open = head.range(of: "<title", options: .caseInsensitive),
              let tagEnd = head[open.upperBound...].firstIndex(of: ">") else { return nil }
        let rest = head[head.index(after: tagEnd)...]
        guard let close = rest.range(of: "</title", options: .caseInsensitive) else { return nil }
        var title = String(rest[..<close.lowerBound].prefix(1000))
        for (entity, text) in [("&amp;", "&"), ("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            title = title.replacingOccurrences(of: entity, with: text)
        }
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : DeliveryMail.shorten(title, to: 80)
    }

    /// New deliveries in the script's answer, oldest first, and what to remember.
    /// Emails whose Message-ID is in `shown` were already announced (e.g. by the other route).
    static func process(_ emails: [Email], state: ScriptState, now: Date = Date(), askedAt: Date? = nil,
                        shown: Set<String> = []) -> (deliveries: [Delivery], state: ScriptState) {
        var next = state
        if let askedAt { next.askedAt = askedAt }
        var known = Set(state.seen)
        var announced = shown
        var deliveries: [Delivery] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        for email in emails where !email.id.isEmpty && !known.contains(email.id) {
            known.insert(email.id)
            next.seen.append(email.id)
            guard state.started else { continue }
            let messageID = (email.messageID ?? "").isEmpty ? nil : email.messageID
            if let messageID, announced.contains(messageID) { continue }
            var headers = ["from": email.from ?? "", "subject": email.subject ?? ""]
            if let messageID { headers["message-id"] = messageID }
            guard let found = DeliveryMail.classify(headers: headers, uid: 0) else { continue }
            let date = email.date.flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            if let date, now.timeIntervalSince(date) > DeliveryCheck.tooOld { continue }
            if let messageID { announced.insert(messageID) }
            deliveries.append(Delivery(kind: found.kind, store: found.store, item: found.item, subject: found.subject,
                                       messageID: messageID, date: date ?? now, uid: 0, gmailID: email.id,
                                       package: found.package))
        }
        next.started = true
        next.seen = Array(next.seen.suffix(500))
        deliveries.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        return (deliveries, next)
    }
}

// MARK: - Settings kept differently than before

enum DeliveryMigration {
    /// The script's web address used to be kept in Hammer's settings; now it's in the
    /// Keychain. Given what each says, returns the address to use, and whether the
    /// old setting can go (it has been copied into the Keychain, or is already there).
    /// `save` copies it into the Keychain and says whether that worked.
    static func scriptAddress(keychain: KeychainRead, setting: String?, save: (URL) -> Bool)
    -> (url: URL?, forgetSetting: Bool) {
        if let stored = keychain.value, let url = DeliveryScript.savedURL(stored) {
            return (url, setting != nil)
        }
        guard let setting, let url = DeliveryScript.savedURL(setting) else { return (nil, false) }
        guard case .missing = keychain else { return (url, false) }         // can't tell yet: keep both, try again later
        return (url, save(url))
    }
}

// MARK: - The recent deliveries in the menu

enum DeliveryList {
    /// Deliveries older than this drop off the menu.
    static let keep: TimeInterval = 7 * 24 * 3600
    static let maxCount = 8

    /// Only the last 7 days' deliveries, newest first. Ones without a date (from
    /// before Hammer noted when it saw them) are dropped too.
    static func current(_ list: [Delivery], now: Date = Date()) -> [Delivery] {
        Array(list.filter { delivery in
            guard let date = delivery.date else { return false }
            return now.timeIntervalSince(date) <= keep
        }.prefix(maxCount))
    }

    /// The list with new deliveries (oldest first) added at the top. A package's newer
    /// email replaces its older one: "Delivered" takes the place of "Out for delivery".
    static func adding(_ new: [Delivery], to list: [Delivery], now: Date = Date()) -> [Delivery] {
        var result = list
        for delivery in new {
            if let package = delivery.package { result.removeAll { $0.package == package } }
            result.removeAll { $0.key == delivery.key }
            result.insert(delivery, at: 0)
        }
        return current(result, now: now)
    }
}
