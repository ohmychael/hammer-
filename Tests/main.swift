// Tests for HammerCore.swift. Run by build.sh before every install:
//   swiftc HammerCore.swift Tests/main.swift -o hammer-tests && ./hammer-tests
// Exits with 1 if anything fails, which stops the update.

import Foundation

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ what: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(what)")
    }
}

func padded(_ bytes: [UInt8], checksum: UInt8) -> [UInt8] {
    bytes + [UInt8](repeating: 0, count: 19 - bytes.count) + [checksum]
}

// MARK: Govee packets — checked against packets traced from the Govee app

expect(GoveePacket.make([0x33, 0x04, 0x64]) == padded([0x33, 0x04, 0x64], checksum: 0x53),
       "full brightness packet matches the traced one")
expect(GoveePacket.make([0x33, 0x05, 0x0D, 0xFF, 0xFF, 0xFF, 0x0A, 0x8C, 0xFF, 0xAE, 0x54])
       == padded([0x33, 0x05, 0x0D, 0xFF, 0xFF, 0xFF, 0x0A, 0x8C, 0xFF, 0xAE, 0x54], checksum: 0x47),
       "2700 K packet matches the traced one")
expect(GoveePacket.make([0x33, 0x05, 0x0D, 0xFF, 0xFF, 0xFF, 0x19, 0x64, 0xFF, 0xF9, 0xFB])
       == padded([0x33, 0x05, 0x0D, 0xFF, 0xFF, 0xFF, 0x19, 0x64, 0xFF, 0xF9, 0xFB], checksum: 0x44),
       "6500 K packet matches the traced one")
expect(GoveePacket.make([0x33, 0x05, 0x0D, 0xFF, 0x00, 0x00]).last == 0xC4, "red color checksum")
expect(GoveePacket.make([0x33, 0x01, 0x01]).last == 0x33, "power on checksum")
expect(GoveePacket.make([0x33, 0x01, 0x00]).last == 0x32, "power off checksum")
expect(GoveePacket.statusRead == padded([0xAA, 0x01], checksum: 0xAB), "status read packet")

// Edge cases: size is always 20, long payloads are cut at 19 bytes, empty is all zeros.
expect(GoveePacket.make([]).count == 20 && GoveePacket.make([]).allSatisfy { $0 == 0 }, "empty payload")
let long = GoveePacket.make(Array(1...30))
expect(long.count == 20 && Array(long[0..<19]) == Array(1...19) && long[19] == 0x00,
       "payload longer than 19 bytes is cut, checksum covers the first 19")
expect(GoveePacket.isCommand(GoveePacket.make([0x33, 0x01, 0x01])), "0x33 is a command")
expect(!GoveePacket.isCommand(GoveePacket.statusRead), "a status read isn't a command")

// Power-state replies
expect(GoveePacket.powerState(in: [0xAA, 0x01, 0x01]) == true, "reply: on")
expect(GoveePacket.powerState(in: [0xAA, 0x01, 0x00]) == false, "reply: off")
expect(GoveePacket.powerState(in: padded([0xAA, 0x01, 0x01], checksum: 0xAA)) == true, "full 20-byte reply: on")
expect(GoveePacket.powerState(in: [0xAA, 0x05, 0x01]) == nil, "other status replies aren't power")
expect(GoveePacket.powerState(in: [0x33, 0x01, 0x01]) == nil, "an echoed command isn't a reply")
expect(GoveePacket.powerState(in: [0xAA, 0x01]) == nil, "too short")
expect(GoveePacket.powerState(in: []) == nil, "empty")

// MARK: Command queue

let start = Date(timeIntervalSince1970: 1_000_000)
func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
func kinds(_ queue: CommandQueue) -> [String] {
    queue.items.map { item -> String in
        switch item.key {
        case 0x3301: return item.packet[2] == 1 ? "on" : "off"
        case 0x3304: return "brightness \(item.packet[2])"
        case 0x3305: return "color"
        case 0xAA01: return "status"
        default: return "other"
        }
    }
}

// Five brightness changes, then off and on again, while the bulb is busy.
var queue = CommandQueue()
for (step, level) in [10, 30, 50, 70, 90].enumerated() {
    queue.add(GoveePacket.make([0x33, 0x04, UInt8(level)]), at: at(Double(step) * 0.2))
}
queue.add(GoveePacket.make([0x33, 0x01, 0x00]), at: at(1))
queue.add(GoveePacket.make([0x33, 0x01, 0x01]), at: at(1.1))
expect(kinds(queue) == ["brightness 90", "on"], "only the latest of each kind is kept: \(kinds(queue))")

// Order follows the last request of each kind.
queue = CommandQueue()
queue.add(GoveePacket.make([0x33, 0x01, 0x01]), at: at(0))
queue.add(GoveePacket.make([0x33, 0x05, 0x0D, 255, 0, 0]), at: at(0))
queue.add(GoveePacket.make([0x33, 0x04, 40]), at: at(0))
queue.add(GoveePacket.statusRead, at: at(0))
expect(kinds(queue) == ["on", "color", "brightness 40", "status"], "order kept: \(kinds(queue))")
queue.add(GoveePacket.make([0x33, 0x01, 0x00]), at: at(1))
expect(kinds(queue) == ["color", "brightness 40", "status", "off"], "a newer power command moves to the end")

// Stale commands are dropped; fresh ones stay.
queue = CommandQueue(freshFor: 15)
queue.add(GoveePacket.make([0x33, 0x01, 0x00]), at: at(0))
queue.add(GoveePacket.make([0x33, 0x04, 20]), at: at(5))
queue.dropStale(now: at(14.9))
expect(kinds(queue) == ["off", "brightness 20"], "nothing dropped before 15 s")
queue.dropStale(now: at(15))
expect(kinds(queue) == ["brightness 20"], "the 15 s old one is dropped")
queue.dropStale(now: at(60))
expect(queue.isEmpty && queue.first == nil, "everything dropped after a minute")

// first / removeFirst, and bad input.
queue = CommandQueue()
queue.add(GoveePacket.make([0x33, 0x01, 0x01]), at: at(0))
expect(queue.first == GoveePacket.make([0x33, 0x01, 0x01]), "first is the oldest")
queue.removeFirst()
queue.removeFirst()                                       // removing from an empty queue is harmless
expect(queue.isEmpty, "empty after removing")
queue.add([0x33], at: at(0))
queue.add([], at: at(0))
expect(queue.isEmpty, "packets shorter than 2 bytes are ignored")

// Restoring commands lost with a dying link.
func item(_ payload: [UInt8], _ seconds: Double) -> CommandQueue.Item {
    let packet = GoveePacket.make(payload)
    return CommandQueue.Item(key: UInt16(packet[0]) << 8 | UInt16(packet[1]), packet: packet, at: at(seconds))
}
queue = CommandQueue()
queue.add(GoveePacket.make([0x33, 0x04, 30]), at: at(5))                       // queued after the link died
queue.restore([item([0x33, 0x01, 0x00], 1), item([0x33, 0x04, 90], 2), item([0x33, 0x05, 0x0D, 255, 0, 0], 3)])
expect(kinds(queue) == ["off", "color", "brightness 30"],
       "lost commands go first; a newer brightness wins over the lost one: \(kinds(queue))")
queue = CommandQueue()
queue.restore([item([0x33, 0x01, 0x00], 1), item([0x33, 0x01, 0x01], 2)])
expect(kinds(queue) == ["on"], "only the last of each kind comes back: \(kinds(queue))")
queue = CommandQueue(freshFor: 15)
queue.restore([item([0x33, 0x01, 0x00], 0)])
queue.dropStale(now: at(16))
expect(queue.isEmpty, "restored commands still expire 15 s after they were asked for")
queue.restore([])
expect(queue.isEmpty, "restoring nothing is harmless")

// MARK: Reconnect timing

expect(ConnectBackoff.delay(afterFailures: 0) == 0, "no failures, no wait")
expect([1, 2, 3, 4, 5, 6, 7, 8].map { ConnectBackoff.delay(afterFailures: $0) } == [0, 3, 6, 12, 24, 48, 60, 60],
       "first retry at once, then waits double up to a minute")
expect(ConnectBackoff.delay(afterFailures: 10_000) == 60, "a huge failure count stays at a minute")
expect(ConnectBackoff.delay(afterFailures: -5) == 0, "a negative count is harmless")

let bulbA = UUID(), bulbB = UUID()
var backoff = ConnectBackoff()
expect(backoff.canTry(bulbA, now: at(0)) && backoff.wait(bulbA, now: at(0)) == 0, "a new bulb can be tried right away")
expect(backoff.failed(bulbA, now: at(0)) == 0 && backoff.canTry(bulbA, now: at(0)), "first failure: try again at once")
expect(backoff.failed(bulbA, now: at(0)) == 3, "second failure in a row waits 3 s")
expect(!backoff.canTry(bulbA, now: at(2.9)) && backoff.canTry(bulbA, now: at(3)), "allowed again after 3 s")
expect(abs(backoff.wait(bulbA, now: at(1)) - 2) < 0.001, "2 s left after 1 s")
expect(backoff.canTry(bulbB, now: at(0)), "one bulb's failures don't hold up another")
expect(backoff.failed(bulbA, now: at(3)) == 6, "third failure in a row waits 6 s")

// 200 quick failures (the old retry storm) end up a minute apart, not milliseconds.
var storm = ConnectBackoff()
var elapsed = 0.0, attempts = 0
while elapsed < 600 {
    if storm.canTry(bulbA, now: at(elapsed)) { attempts += 1; storm.failed(bulbA, now: at(elapsed)) }
    elapsed += 0.05
}
expect(attempts <= 15, "a bulb that always fails is tried at most ~15 times in 10 minutes: \(attempts)")

// Tapping a light while Hammer is waiting: try within 2 s, but never later than planned.
backoff = ConnectBackoff()
for _ in 1...7 { backoff.failed(bulbA, now: at(0)) }         // waiting a minute now
backoff.hurry(bulbA, within: 2, now: at(0))
expect(backoff.canTry(bulbA, now: at(2)) && !backoff.canTry(bulbA, now: at(1.9)), "a tap brings the next try forward to 2 s")
backoff.hurry(bulbA, within: 30, now: at(0))
expect(backoff.canTry(bulbA, now: at(2)), "hurrying never pushes a try later")
backoff.hurry(bulbB, within: 2, now: at(0))
expect(backoff.canTry(bulbB, now: at(0)), "hurrying a bulb that isn't waiting changes nothing")

// A pause for a bulb that doesn't take Hammer's commands, and a lasting link resetting everything.
backoff.pause(bulbA, for: 300, now: at(0))
expect(!backoff.canTry(bulbA, now: at(299)) && backoff.canTry(bulbA, now: at(300)), "5 minute pause")
backoff.pause(bulbA, for: 10, now: at(0))
expect(!backoff.canTry(bulbA, now: at(100)), "a shorter pause doesn't cut a longer one short")
backoff.succeeded(bulbA)
expect(backoff.canTry(bulbA, now: at(0)) && backoff.failures[bulbA] == nil, "success clears the wait")
expect(backoff.failed(bulbA, now: at(0)) == 0, "and the count starts over")

// MARK: Bulb names

expect(GoveeName.model(in: "ihoment_H6006_0FC3") == "H6006", "model from a Govee name")
expect(GoveeName.model(in: "ihoment_h6006_abcd") == "H6006", "lowercase names work")
expect(GoveeName.model(in: "Govee_H600D_1234") == "H600D", "hex digits in the model")
expect(GoveeName.model(in: "Magic Keyboard") == nil, "other devices are ignored")
expect(GoveeName.model(in: "") == nil, "empty name")
expect(GoveeName.displayName(model: "H6006", advertised: "ihoment_H6006_0FC3") == "H6006 bulb 0FC3",
       "name keeps the bulb's code")
expect(GoveeName.displayName(model: "H6006", advertised: "Govee_H6006") == "H6006 bulb", "no code")
expect(GoveeName.displayName(model: "H6006", advertised: "ihoment_H6006_") == "H6006 bulb", "empty code")
expect(GoveeName.distance(dBm: -50) == "very close" && GoveeName.distance(dBm: -60) == "very close",
       "strong signal")
expect(GoveeName.distance(dBm: -61) == "nearby" && GoveeName.distance(dBm: -75) == "nearby", "medium signal")
expect(GoveeName.distance(dBm: -76) == "far away" && GoveeName.distance(dBm: -100) == "far away", "weak signal")

// MARK: DDC/CI (monitor) packets

expect(DDCPacket.set(code: 0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A], "set brightness 50")
expect(DDCPacket.set(code: 0x12, value: 300) == [0x84, 0x03, 0x12, 0x01, 0x2C, 0x87], "values over 255 use both bytes")
expect(DDCPacket.get(code: 0x10) == [0x82, 0x01, 0x10, 0xAC], "get brightness")

let goodReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
let parsed = DDCPacket.parseReply(goodReply, code: 0x10)
expect(parsed?.current == 50 && parsed?.max == 100, "reads current 50 of max 100")
var corrupt = goodReply
corrupt[9] = 0x33
expect(DDCPacket.parseReply(corrupt, code: 0x10) == nil, "a bad checksum is rejected")
expect(DDCPacket.parseReply(goodReply, code: 0x12) == nil, "an answer about another setting is rejected")
var unsupported = goodReply
unsupported[3] = 0x01
unsupported[10] ^= 0x01                                    // keep the checksum valid
expect(DDCPacket.parseReply(unsupported, code: 0x10) == nil, "\"unsupported\" result is rejected")
expect(DDCPacket.parseReply(Array(goodReply.prefix(10)), code: 0x10) == nil, "too short")
expect(DDCPacket.parseReply([], code: 0x10) == nil, "empty")

// MARK: Text

expect(TimerText.describe(minutes: 5) == "5 min", "5 min")
expect(TimerText.describe(minutes: 45) == "45 min", "45 min")
expect(TimerText.describe(minutes: 60) == "1 hr", "1 hr")
expect(TimerText.describe(minutes: 90) == "1 hr 30 min", "1 hr 30 min")
expect(TimerText.describe(minutes: 480) == "8 hr", "8 hr")

// MARK: Delivery emails: which subjects count

let deliveredSubjects = [
    #"Delivered: "Anker 735 Charger (Nano II 65W)" and 1 more item"#,
    "=?UTF-8?B?8J+TpiBZb3VyIHBhY2thZ2Ugd2FzIGRlbGl2ZXJlZA==?=",            // "📦 Your package was delivered"
    "Your package was delivered: Apple iPhone 15 Pro Max - 256GB - Black (Unlocked)",
    "UPS Update: Package Delivered",
    "USPS® Item Delivered, Front/Back Door/Porch 9400111899223344556677",
    "FedEx Shipment 771234567890 Delivered",
    "Your order has arrived!",
    "Fwd: Your package has been delivered",
    "Your Walmart order was delivered",
    "=?utf-8?Q?Your_package_was_delivered_=E2=9C=85?=",
    "Your package was delivered earlier than expected",
    "DELIVERED: \"Phone case\"",
    "Your package has been dropped off",
    "Your order from Target has arrived",
    "Your items have arrived",
]
for subject in deliveredSubjects {
    expect(DeliveryMail.kind(ofSubject: subject) == .delivered, "delivered: \(subject)")
}
let problemSubjects = [
    "Delivery attempted - we'll try again tomorrow",
    "UPS Update: Delivery Attempted",
    "Your package couldn't be delivered",
    "Action needed: delivery exception for your order",
    "Your parcel is being returned to sender",
    "We were unable to deliver your package",
]
for subject in problemSubjects {
    expect(DeliveryMail.kind(ofSubject: subject) == .problem, "problem: \(subject)")
}
let otherSubjects = [
    #"Out for delivery: "Anker 735 Charger""#,
    "Arriving today: Anker 735 Charger",
    "USPS® Expected Delivery on Saturday, October 17, 2026 arriving by 9:00pm",
    "Your package will be delivered tomorrow",
    #"Shipped: "Anker 735 Charger""#,
    "Get it delivered in 2 hours with Instacart",
    "Re: Package delivered",
    "RE: has the couch arrived?",
    "Sign-in attempted from a new device",
    "Your order is confirmed",
    "Free delivery on orders over $35",
    "Delivered fresh: 20% off this week",
    "The Delivered Collection: new arrivals",
    "lunch?",
    "",
    "=?UTF-8?B?invalid!!?=",
    // Marketing and bounces that look a bit like deliveries (found in review):
    "Your statement has arrived",
    "Fall has arrived: 30% off everything",
    "The new iPhone has arrived. Order now",
    "Delivered to your door in 30 minutes",
    "Undelivered Mail Returned to Sender",
    "Undeliverable: Lunch on Friday?",
    "Mail delivery failed: returning message to sender",
    "Fresh flowers delivered today",
]
for subject in otherSubjects {
    expect(DeliveryMail.kind(ofSubject: subject) == nil, "not a delivery: \(subject)")
}

// What was delivered, and from where
expect(DeliveryMail.item(in: #"Delivered: "Anker 735 Charger (Nano II 65W)" and 1 more item"#)
       == "Anker 735 Charger (Nano II 65W) +1 more", "Amazon item with more")
expect(DeliveryMail.item(in: "Delivered: “Phone case”") == "Phone case", "curly quotes")
expect(DeliveryMail.item(in: "Your package was delivered: Apple iPhone 15 Pro Max - 256GB")
       == "Apple iPhone 15 Pro Max - 256GB", "item after the colon")
expect(DeliveryMail.item(in: "UPS Update: Package Delivered") == nil, "no item in a carrier update")
expect(DeliveryMail.item(in: "Your package was delivered") == nil, "no item named")
expect(DeliveryMail.item(in: "Delivered: Your package") == nil, "'your package' isn't an item")
expect(DeliveryMail.item(in: "Delivered: " + String(repeating: "x", count: 200))?.count == 80, "long names are cut to 80")
expect(DeliveryMail.item(in: "Delivered: \"\"") == nil, "empty quotes")

expect(DeliveryMail.store(from: "\"eBay\" <ebay@ebay.com>") == "eBay", "eBay")
expect(DeliveryMail.store(from: "Amazon.com <shipment-tracking@amazon.com>") == "Amazon", "Amazon")
expect(DeliveryMail.store(from: "UPS <mcinfo@ups.com>") == "UPS", "UPS")
expect(DeliveryMail.store(from: "USPS Informed Delivery <USPSInformeddelivery@email.informeddelivery.usps.com>")
       == "USPS", "USPS on a subdomain")
expect(DeliveryMail.store(from: "Google Groups <noreply@groups.com>") == "Google Groups", "groups.com isn't UPS")
expect(DeliveryMail.store(from: "Shop <no-reply@shop.app>") == "Shop", "Shop app")
expect(DeliveryMail.store(from: "=?UTF-8?Q?Caf=C3=A9_Store?= <orders@cafe-store.com>") == "Café Store", "encoded name")
expect(DeliveryMail.store(from: "orders@weirdshop.co.uk") == "Weirdshop", "no name: from the domain")
expect(DeliveryMail.store(from: "") == "Package", "nothing to go on")

expect(DeliveryMail.tidy("📦 Your package was delivered") == "Your package was delivered", "emoji removed")
expect(DeliveryMail.tidy("Fwd:   Your  order\thas arrived ") == "Your order has arrived", "prefix and spaces")
expect(HeaderText.decode("=?UTF-8?B?SGVs?= =?UTF-8?B?bG8=?= world") == "Hello world", "adjacent encoded words join")
expect(HeaderText.decode("=?ISO-8859-1?Q?Caf=E9?=") == "Café", "Latin-1")
expect(HeaderText.decode("plain text") == "plain text", "plain text unchanged")
expect(HeaderText.decode("=?UTF-8?B?8J+Tpg?=") == "📦", "unpadded base64")

let rawHeaders = Array("From: \"eBay\" <ebay@ebay.com>\r\nSubject: Your package\r\n was delivered\r\nDate: Sat, 17 Oct 2026 14:02:11 +0000\r\nMessage-ID: <a@b>\r\n\r\n".utf8)
let parsedHeaders = HeaderText.parse(rawHeaders)
expect(parsedHeaders["subject"] == "Your package was delivered", "folded subject joined: \(parsedHeaders["subject"] ?? "-")")
expect(parsedHeaders["from"] == "\"eBay\" <ebay@ebay.com>" && parsedHeaders["message-id"] == "<a@b>", "other headers")
expect(HeaderText.parse(Array("Subject: Caf\u{E9}\r\n".unicodeScalars.map { UInt8($0.value) }))["subject"] == "Café",
       "8-bit Latin-1 header")
expect(HeaderText.parse([]).isEmpty, "no headers")

expect(DeliveryMail.parseDate("Sat, 17 Oct 2026 14:02:11 +0000") == Date(timeIntervalSince1970: 1_792_245_731),
       "RFC 2822 date")
expect(DeliveryMail.parseDate("Sat, 17 Oct 2026 07:02:11 -0700 (PDT)") == Date(timeIntervalSince1970: 1_792_245_731),
       "date with zone comment")
expect(DeliveryMail.parseDate("17 Oct 2026 14:02:11 +0000") != nil, "date without weekday")
expect(DeliveryMail.parseDate("yesterday") == nil, "not a date")

let sample = DeliveryMail.classify(headers: parsedHeaders, uid: 9)
expect(sample?.title == "Delivered · eBay" && sample?.body == "Your package was delivered", "notification text")
expect(sample?.gmailLink(account: "you@gmail.com")?.absoluteString
       == "https://mail.google.com/mail/?authuser=you@gmail.com#search/rfc822msgid%3Aa@b", "link to the email")
expect(DeliveryMail.classify(headers: ["subject": "Undeliverable: Your order #123 update",
                                       "from": "Mail Delivery Subsystem <mailer-daemon@googlemail.com>"], uid: 1) == nil,
       "a bounce of your own email isn't a delivery problem")
expect(DeliveryMail.classify(headers: ["subject": "Undeliverable: Re: your order",
                                       "from": "postmaster@outlook.com"], uid: 1) == nil, "Outlook bounce")
let problem = DeliveryMail.classify(headers: ["subject": "UPS Update: Delivery Attempted", "from": "UPS <mcinfo@ups.com>"], uid: 1)
expect(problem?.title == "Delivery problem · UPS" && problem?.item == nil, "problem text")

// Setup input
expect(DeliverySetup.isPlainEmail("you@gmail.com") && DeliverySetup.isPlainEmail("first.last+tag@googlemail.com"),
       "plain emails")
for bad in ["", "you", "you@", "@gmail.com", "you @gmail.com", "you@gmail", "a\"b@gmail.com", "you@gmail.com -w x"] {
    expect(!DeliverySetup.isPlainEmail(bad), "not an email: \(bad)")
}
expect(DeliverySetup.cleanPassword("abcd efgh ijkl mnop") == "abcdefghijklmnop", "spaces removed")
expect(DeliverySetup.cleanPassword(" abcdefghijklmnop\n") == "abcdefghijklmnop", "pasted with a newline")
for bad in ["", "abcdefghijklmno", "abcdefghijklmnopq", "abcd-efgh-ijkl-mnop", "My-Real-Password!", "abcdefghijklmnö1",
            "abcdefghijklmn\"x"] {
    expect(DeliverySetup.cleanPassword(bad) == nil, "not an app password: \(bad)")
}

// MARK: IMAP: reading answers

/// Plays back a server's bytes in awkward pieces and records what was sent.
final class ScriptedTransport: IMAPTransport {
    var chunks: [[UInt8]]
    var sent: [String] = []
    var closed = false
    init(_ text: String, pieceSize: Int = 7) {
        let bytes = Array(text.utf8)
        chunks = stride(from: 0, to: bytes.count, by: pieceSize).map { Array(bytes[$0..<min($0 + pieceSize, bytes.count)]) }
    }
    func send(_ bytes: [UInt8]) throws { sent.append(String(decoding: bytes, as: UTF8.self)) }
    func receive() throws -> [UInt8] { chunks.isEmpty ? [] : chunks.removeFirst() }
    func close() { closed = true }
}

let headerBlock = "Subject: Delivered: \"Cable\"\r\nFrom: Amazon.com <a@amazon.com>\r\n\r\n"
let fetchAnswer = "* 1 FETCH (UID 41 BODY[HEADER.FIELDS (FROM SUBJECT)] {\(headerBlock.utf8.count)}\r\n\(headerBlock))\r\n"
let script = ScriptedTransport("* OK Gimap ready\r\nH001 OK logged in\r\n" + fetchAnswer + "H002 OK Success\r\n")
let connection = IMAPConnection(transport: script)
do {
    try connection.start()
    try connection.login(email: "you@gmail.com", password: "abcd\"efgh")
    expect(script.sent.first == "H001 LOGIN \"you@gmail.com\" \"abcd\\\"efgh\"\r\n", "login quotes and escapes")
    let reply = try connection.run("UID FETCH 41 (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT)])")
    expect(reply.status == "OK", "tagged OK")
    let fetched = IMAPReply.fetchedHeaders(reply.untagged)
    expect(fetched[41]?["subject"] == "Delivered: \"Cable\"", "literal read across pieces: \(fetched)")
} catch {
    expect(false, "scripted conversation failed: \(error)")
}

let refused = IMAPConnection(transport: ScriptedTransport("* OK hi\r\nH001 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n"))
do {
    try refused.start()
    try refused.login(email: "a", password: "b")
    expect(false, "a refused login throws")
} catch IMAPError.badLogin(let text) {
    expect(text.contains("AUTHENTICATIONFAILED"), "bad login reported with Gmail's reason")
} catch {
    expect(false, "wrong error for a refused login: \(error)")
}

let busy = IMAPConnection(transport: ScriptedTransport("* OK hi\r\nH001 NO [UNAVAILABLE] Temporary System Problem. Try again later (Failure)\r\n"))
do {
    try busy.start()
    try busy.login(email: "a", password: "b")
    expect(false, "a refused login throws")
} catch IMAPError.failed {
    expect(true, "a passing Gmail problem isn't treated as a wrong password")
} catch {
    expect(false, "wrong error for a temporary problem: \(error)")
}
expect(IMAPConnection.isRefusedLogin("[AUTHENTICATIONFAILED] Invalid credentials (Failure)"), "refused: wrong password")
expect(IMAPConnection.isRefusedLogin("[ALERT] Application-specific password required: https://…"), "refused: needs an app password")
expect(IMAPConnection.isRefusedLogin("[WEBALERT https://…] Web login required."), "refused: Google wants a browser sign-in")
expect(!IMAPConnection.isRefusedLogin("[UNAVAILABLE] Temporary System Problem"), "not refused: temporary")
expect(!IMAPConnection.isRefusedLogin("[ALERT] Too many simultaneous connections. (Failure)"), "not refused: too many connections")
expect(DeliveryCheck.explain(.badLogin("[WEBALERT x] Web login required")).contains("browser"), "browser sign-in message")

let hungUp = IMAPConnection(transport: ScriptedTransport("* OK hi\r\nH001 OK\r\n* 1 FETCH (UID 1 BODY[] {500}\r\nshort"))
do {
    try hungUp.start()
    _ = try hungUp.run("NOOP")
    _ = try hungUp.run("UID FETCH 1 BODY.PEEK[]")
    expect(false, "a connection that closes mid-answer throws")
} catch let error as IMAPError {
    expect(error == .offline, "hang-up mid-literal is 'offline'")
} catch {
    expect(false, "unexpected error \(error)")
}
let notIMAP = IMAPConnection(transport: ScriptedTransport("HTTP/1.1 400 Bad Request\r\n"))
expect((try? notIMAP.start()) == nil, "a server that isn't IMAP is rejected")
let huge = IMAPConnection(transport: ScriptedTransport("* OK hi\r\n* 1 FETCH (UID 1 BODY[] {99999999999}\r\n", pieceSize: 64))
do {
    try huge.start()
    _ = try huge.run("NOOP")
    expect(false, "an absurd literal size is refused")
} catch let error as IMAPError {
    expect(error != .offline, "refused before trying to read it")
} catch { expect(false, "\(error)") }

expect(IMAPConnection.literalSize(at: Array("* 1 FETCH (BODY[] {12}".utf8)) == 12, "literal size")
expect(IMAPConnection.literalSize(at: Array("x {12+}".utf8)) == 12, "non-synchronizing literal")
expect(IMAPConnection.literalSize(at: Array("subject {not}".utf8)) == nil, "not a literal")
expect(IMAPConnection.literalSize(at: Array("{}".utf8)) == nil, "empty braces")

let examine = Array("* FLAGS (\\Seen)\r\n* OK [UIDVALIDITY 7] UIDs valid.\r\n* 42 EXISTS\r\n* OK [UIDNEXT 1235] Predicted next UID.\r\n".utf8)
expect(IMAPReply.status(examine).map { [$0.uidNext, $0.uidValidity] } == [1235, 7], "UIDNEXT and UIDVALIDITY")
expect(IMAPReply.status(Array("* 42 EXISTS\r\n".utf8)) == nil, "missing numbers")
expect(IMAPReply.search(Array("* SEARCH 12 15 99\r\n".utf8)) == [12, 15, 99], "search hits")
expect(IMAPReply.search(Array("* SEARCH\r\n".utf8)) == [], "no hits")
expect(IMAPReply.search(Array("* OK nothing\r\n".utf8)) == nil, "no SEARCH line")
let afterBlock = "Subject: x\r\n\r\n"
let uidAfter = "* 3 FETCH (BODY[HEADER.FIELDS (SUBJECT)] {\(afterBlock.utf8.count)}\r\n\(afterBlock) UID 77)\r\n"
expect(IMAPReply.fetchedHeaders(Array(uidAfter.utf8))[77]?["subject"] == "x", "UID after the headers")

// MARK: Checking for deliveries

/// An in-memory inbox that answers the commands DeliveryCheck sends.
final class FakeInbox {
    var validity = 7
    var messages: [(uid: Int, headers: String)] = []
    var log: [String] = []
    var failOn: String?
    func add(_ subject: String, from: String = "\"eBay\" <ebay@ebay.com>", date: String = "Sat, 17 Oct 2026 14:00:00 +0000",
             id: String? = nil) {
        let uid = (messages.map(\.uid).max() ?? 100) + 1
        messages.append((uid, "From: \(from)\r\nSubject: \(subject)\r\nDate: \(date)\r\nMessage-ID: <\(id ?? "m\(uid)")@x>\r\n\r\n"))
    }
    func answer(_ command: String) throws -> IMAPResponse {
        log.append(command)
        if let failOn, command.hasPrefix(failOn) { throw IMAPError.offline }
        let top = messages.map(\.uid).max() ?? 100
        if command == "EXAMINE INBOX" {
            return IMAPResponse(status: "OK", text: "[READ-ONLY]",
                                untagged: Array("* OK [UIDVALIDITY \(validity)] ok\r\n* OK [UIDNEXT \(top + 1)] ok\r\n".utf8))
        }
        if command.hasPrefix("UID SEARCH UID ") {
            let from = Int(command.dropFirst(15).prefix { $0 != ":" }) ?? 0
            var hits = messages.filter { $0.uid >= from }.map(\.uid)
            if hits.isEmpty, let last = messages.last, from > last.uid { hits = [last.uid] }   // IMAP: n:* always includes the newest
            return IMAPResponse(status: "OK", text: "", untagged: Array("* SEARCH \(hits.map(String.init).joined(separator: " "))\r\n".utf8))
        }
        if command.hasPrefix("UID FETCH ") {
            let wanted = Set(command.dropFirst(10).prefix { $0 != " " }.split(separator: ",").compactMap { Int($0) })
            var out: [UInt8] = []
            for (index, message) in messages.enumerated() where wanted.contains(message.uid) {
                out += Array("* \(index + 1) FETCH (UID \(message.uid) BODY[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)] {\(message.headers.utf8.count)}\r\n".utf8)
                out += Array(message.headers.utf8) + Array(")\r\n".utf8)
            }
            return IMAPResponse(status: "OK", text: "", untagged: out)
        }
        return IMAPResponse(status: "BAD", text: "unknown", untagged: [])
    }
}

let now = Date(timeIntervalSince1970: 1_792_250_000)          // Sat 17 Oct 2026, ~15:13 UTC
let inbox = FakeInbox()
inbox.add("Your package was delivered")                         // already there when alerts are turned on
var deliveryState = DeliveryState()
do {
    var result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
    expect(result.deliveries.isEmpty && result.state.lastUID == 101 && result.state.uidValidity == 7,
           "first check only notes where the inbox is")
    deliveryState = result.state

    inbox.add("Your package was delivered: Apple iPhone 15 Pro Max")
    inbox.add("lunch?", from: "Friend <f@gmail.com>")
    inbox.add(#"Out for delivery: "Cable""#, from: "Amazon.com <a@amazon.com>")
    inbox.add(#"Delivered: "Cable""#, from: "Amazon.com <a@amazon.com>")
    inbox.add("Your package was delivered", date: "Mon, 12 Oct 2026 10:00:00 +0000")        // 5 days old
    inbox.log = []
    result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
    expect(result.deliveries.map(\.body) == ["Apple iPhone 15 Pro Max", "Cable"],
           "announces the two new deliveries in order: \(result.deliveries.map(\.body))")
    expect(result.deliveries.map(\.store) == ["eBay", "Amazon"], "with their stores")
    expect(result.state.lastUID == 106, "moves past everything it looked at")
    expect(!inbox.log.contains { $0.hasPrefix("SELECT") } && !inbox.log.contains { $0.contains("BODY[") },
           "never opens the inbox for writing or reads in a way that marks mail read: \(inbox.log)")
    expect(inbox.log.contains { $0.contains("BODY.PEEK[HEADER.FIELDS") }, "reads headers with PEEK")
    deliveryState = result.state

    inbox.log = []
    result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
    expect(result.deliveries.isEmpty && inbox.log == ["EXAMINE INBOX"], "nothing new: one quick look, no search")

    inbox.add("Your package was delivered: Apple iPhone 15 Pro Max", id: "m102")             // same email again (moved back)
    result = try DeliveryCheck.run(state: result.state, now: now, command: inbox.answer)
    expect(result.deliveries.isEmpty, "the same email isn't announced twice")
    deliveryState = result.state

    inbox.add("lunch?", from: "Friend <f@gmail.com>")
    inbox.log = []
    result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
    let newest = inbox.messages.map(\.uid).max() ?? 0
    expect(result.deliveries.isEmpty && inbox.log.filter { $0.hasPrefix("UID FETCH") }
               == ["UID FETCH \(newest) (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE MESSAGE-ID)])"],
           "only the one new email is read, nothing older: \(inbox.log)")
    deliveryState = result.state

    inbox.add("Delivered: \"Lamp\"", from: "Target <orders@target.com>")
    inbox.failOn = "UID FETCH"
    do {
        _ = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
        expect(false, "a failed fetch throws")
    } catch {
        inbox.failOn = nil
        result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
        expect(result.deliveries.map(\.body) == ["Lamp"], "after a failed check, the next one still finds it")
        deliveryState = result.state
    }

    inbox.validity = 8
    inbox.add("Delivered: \"Rug\"")
    result = try DeliveryCheck.run(state: deliveryState, now: now, command: inbox.answer)
    expect(result.deliveries.isEmpty && result.state.uidValidity == 8, "Gmail renumbering starts over quietly")
} catch {
    expect(false, "delivery checks threw: \(error)")
}

// Scale: a big inbox with hundreds of new matching emails.
let bigInbox = FakeInbox()
for i in 0..<5_000 { bigInbox.messages.append((101 + i, "From: x@y.com\r\nSubject: newsletter \(i)\r\n\r\n")) }
var bigState = (try? DeliveryCheck.run(state: DeliveryState(), now: now, command: bigInbox.answer).state) ?? DeliveryState()
for i in 0..<400 { bigInbox.add("Delivered: \"Thing \(i)\"", from: "Amazon.com <a@amazon.com>") }
let started = Date()
if let result = try? DeliveryCheck.run(state: bigState, now: now, command: bigInbox.answer) {
    expect(result.deliveries.count == 400, "400 deliveries found in a 5,400-email inbox")
    expect(result.state.announced.count == 200, "only the last 200 are remembered")
    bigState = result.state
} else {
    expect(false, "big inbox check failed")
}
expect(Date().timeIntervalSince(started) < 5, "and quickly: \(Date().timeIntervalSince(started)) s")
expect(bigInbox.log.filter { $0.hasPrefix("UID FETCH") }.count >= 4, "headers fetched in batches")

// After a long time offline: only the newest 500 are looked at, but all are passed.
let backlog = FakeInbox()
backlog.add("old")
var backlogState = (try? DeliveryCheck.run(state: DeliveryState(), now: now, command: backlog.answer).state) ?? DeliveryState()
backlog.add(#"Delivered: "Early""#)
for i in 0..<700 { backlog.add("newsletter \(i)", from: "x@y.com") }
backlog.add(#"Delivered: "Late""#)
if let result = try? DeliveryCheck.run(state: backlogState, now: now, command: backlog.answer) {
    expect(result.deliveries.map(\.body) == ["Late"], "only the newest 500 checked: \(result.deliveries.map(\.body))")
    expect(result.state.lastUID == backlog.messages.map(\.uid).max(), "and none of the rest are looked at again")
    backlogState = result.state
} else {
    expect(false, "backlog check failed")
}

// MARK: The Google script route

let scriptKey = DeliveryScript.newKey()
expect(DeliveryScript.isKey(scriptKey) && DeliveryScript.newKey() != scriptKey, "random 64-character keys")
expect(!DeliveryScript.isKey("") && !DeliveryScript.isKey(String(repeating: "g", count: 64))
       && !DeliveryScript.isKey(String(repeating: "A", count: 64)), "not keys")
let scriptText = DeliveryScript.source(key: scriptKey)
expect(scriptText.contains("const HAMMER_KEY = '\(scriptKey)';") && !scriptText.contains(DeliveryScript.keyPlaceholder),
       "the script carries the key")
expect(scriptText.hasPrefix("/**") && scriptText.contains("function doGet(e)"), "and starts cleanly (no stray indentation)")

let deployed = "https://script.google.com/macros/s/AKfycbx1234567890abcdef/exec"
expect(DeliveryScript.webAppURL(deployed)?.absoluteString == deployed, "a web app URL")
expect(DeliveryScript.webAppURL("  \(deployed)\n")?.absoluteString == deployed, "pasted with spaces")
for bad in ["", "script.google.com/macros/s/x/exec", "http://script.google.com/macros/s/x/exec",
            "https://script.google.com/macros/s/x/dev", "https://evil.example.com/macros/s/x/exec",
            "https://script.google.com.evil.com/macros/s/x/exec", "https://script.google.com/home/projects/x/edit",
            "https://script.google.com/macros/s/x/exec?key=abc"] {
    expect(DeliveryScript.webAppURL(bad) == nil, "not a web app URL: \(bad)")
}
let asked = DeliveryScript.requestURL(base: URL(string: deployed)!, key: scriptKey)?.absoluteString
expect(asked == deployed + "?key=\(scriptKey)&v=1", "asks with the key: \(asked ?? "-")")

func reply(_ json: String, status: Int = 200) -> Result<ScriptCheck.Reply, CheckFailure> {
    ScriptCheck.read(status: status, body: Data(json.utf8))
}
let good = #"{"ok":true,"version":1,"account":"you@gmail.com","emails":[{"id":"m1","messageID":"<m1@mail>","from":"\"eBay\" <ebay@ebay.com>","subject":"Your package was delivered: Apple iPhone 15 Pro Max","date":"2026-10-17T15:00:00.000Z"}]}"#
if case .success(let r) = reply(good) {
    expect(r.account == "you@gmail.com" && r.emails?.count == 1 && r.emails?.first?.id == "m1", "reads the script's answer")
} else { expect(false, "good answer rejected") }
func failure(_ result: Result<ScriptCheck.Reply, CheckFailure>) -> CheckFailure? {
    if case .failure(let f) = result { return f }
    return nil
}
expect(failure(reply(#"{"ok":false,"error":"key"}"#))?.needsSetup == true, "wrong key: set up again")
let gmailBusy = failure(reply(#"{"ok":false,"error":"gmail","message":"Service invoked too many times"}"#))
expect(gmailBusy?.needsSetup == false && gmailBusy?.message.contains("keep trying") == true, "Gmail error: retried")
let signIn = failure(reply("<html><body>Sign in - Google Accounts <a href='https://accounts.google.com/'>", status: 200))
expect(signIn?.needsSetup == true && signIn?.message.contains("Anyone") == true, "sign-in page: access must be Anyone")
expect(failure(reply("<html>Script function not found: doGet</html>"))?.message.contains("saved") == true, "not saved")
expect(failure(reply("<html>Authorization is required to perform that action.</html>"))?.message.contains("Run") == true,
       "needs permission again")
expect(failure(reply("Not Found", status: 404))?.needsSetup == true, "wrong address")
expect(failure(reply("<html>Error</html>", status: 503))?.needsSetup == false, "Google busy: retried")
expect(failure(reply("garbage"))?.needsSetup == false, "nonsense: retried")
expect(failure(reply(""))?.needsSetup == false, "empty: retried")

func email(_ id: String, _ subject: String, from: String = "\"eBay\" <ebay@ebay.com>", hoursAgo: Double = 1,
           messageID: String? = nil) -> ScriptCheck.Email {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return ScriptCheck.Email(id: id, messageID: messageID ?? "<\(id)@mail>", from: from, subject: subject,
                             date: formatter.string(from: now.addingTimeInterval(-hoursAgo * 3600)))
}
var scriptState = ScriptState()
var processed = ScriptCheck.process([email("old1", "Your package was delivered")], state: scriptState, now: now)
expect(processed.deliveries.isEmpty && processed.state.started && processed.state.seen == ["old1"],
       "first answer: notes what's there, announces nothing")
scriptState = processed.state
let batch = [
    email("old1", "Your package was delivered"),
    email("n2", #"Delivered: "Cable""#, from: "Amazon.com <a@amazon.com>", hoursAgo: 0.5, messageID: ""),
    email("n1", "Your package was delivered: Apple iPhone 15 Pro Max", hoursAgo: 2),
    email("n3", #"Out for delivery: "Lamp""#, from: "Target <t@target.com>"),
    email("n4", "Your package was delivered", hoursAgo: 24 * 5),
]
processed = ScriptCheck.process(batch, state: scriptState, now: now)
expect(processed.deliveries.map(\.body) == ["Apple iPhone 15 Pro Max", "Cable"],
       "new deliveries only, oldest first: \(processed.deliveries.map(\.body))")
expect(processed.deliveries.map(\.store) == ["eBay", "Amazon"] && processed.deliveries[1].messageID == nil
       && processed.deliveries[1].gmailID == "n2", "store, and Gmail's ID when there's no Message-ID")
expect(processed.state.seen == ["old1", "n2", "n1", "n3", "n4"], "everything looked at is remembered")
expect(processed.deliveries[1].gmailLink(account: "you@gmail.com")?.absoluteString
       == "https://mail.google.com/mail/?authuser=you@gmail.com#all/n2", "link by Gmail's ID")
scriptState = processed.state
processed = ScriptCheck.process(batch, state: scriptState, now: now)
expect(processed.deliveries.isEmpty, "nothing announced twice")
processed = ScriptCheck.process([ScriptCheck.Email(id: "", messageID: nil, from: nil, subject: "Delivered: x", date: nil)],
                                state: scriptState, now: now)
expect(processed.deliveries.isEmpty, "an email without an ID is ignored")
var bigScript = ScriptState(started: true, seen: [])
for chunk in 0..<6 {
    bigScript = ScriptCheck.process((0..<100).map { email("x\(chunk)-\($0)", "newsletter") }, state: bigScript, now: now).state
}
expect(bigScript.seen.count == 500 && bigScript.seen.last == "x5-99", "only the last 500 IDs are kept")

let noLink = Delivery(kind: .delivered, store: "Hammer", item: "test", subject: "", messageID: nil, date: nil, uid: 0)
expect(noLink.gmailLink(account: "you@gmail.com") == nil, "the test notification has no email to open")
let noAccount = Delivery(kind: .delivered, store: "eBay", item: nil, subject: "s", messageID: "<a@b>", date: nil, uid: 0)
expect(noAccount.gmailLink(account: "")?.absoluteString == "https://mail.google.com/mail/u/0/#search/rfc822msgid%3Aa@b",
       "no account known: the first Gmail account")
expect(CheckFailure(.badLogin("[AUTHENTICATIONFAILED] x")).needsSetup && CheckFailure(.offline).offline
       && !CheckFailure(.failed("x")).needsSetup, "app-password errors map across")

// Saved deliveries from before this change still load.
let savedBefore = #"[{"kind":"delivered","store":"eBay","item":"x","subject":"s","messageID":"<a@b>","uid":3}]"#
expect((try? JSONDecoder().decode([Delivery].self, from: Data(savedBefore.utf8)))?.first?.gmailID == nil,
       "older saved deliveries still load")

print("\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
