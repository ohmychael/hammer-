// End-to-end test of the delivery checker: Hammer's IMAP code (Deliveries.swift)
// talking over a real socket (SocketTransport.swift) to fake_gmail.py. Run by
// Tests/Deliveries/run.sh. The app uses a TLS connection to imap.gmail.com instead
// of this plain socket; everything above the socket is the same code.
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("  \(ok ? "ok  " : "FAIL") \(what)")
    if !ok { failures += 1 }
}

let args = CommandLine.arguments
let port = UInt16(args[1])!, boxPath = args[2], logPath = args[3], deadPort = UInt16(args[4])!, silentPort = UInt16(args[5])!
let now = Date(timeIntervalSince1970: 1_792_250_000)            // Sat 17 Oct 2026, ~15:13 UTC

var box: [String: Any] = ["password": "abcdefghijklmnop", "uidvalidity": 7, "messages": [[String: Any]]()]
func addMail(_ subject: String, from: String = "\"eBay\" <ebay@ebay.com>", id: String? = nil) {
    var messages = box["messages"] as! [[String: Any]]
    let uid = (messages.compactMap { $0["uid"] as? Int }.max() ?? 500) + 1
    let headers = "From: \(from)\r\nTo: you@gmail.com\r\nSubject: \(subject)\r\nDate: Sat, 17 Oct 2026 14:00:00 +0000\r\nMessage-ID: <\(id ?? "m\(uid)")@mail>\r\nContent-Type: text/plain\r\n"
    messages.append(["uid": uid, "headers": headers])
    box["messages"] = messages
    let data = try! JSONSerialization.data(withJSONObject: box)
    try! data.write(to: URL(fileURLWithPath: boxPath))
}
func check(_ state: DeliveryState, password: String = "abcdefghijklmnop", port: UInt16 = port)
-> Result<(deliveries: [Delivery], state: DeliveryState), IMAPError> {
    DeliveryCheck.run(state: state, email: "you@gmail.com", password: password, now: now) {
        try SocketTransport(port: port)
    }
}

for i in 0..<30 { addMail("Newsletter \(i)", from: "News <news@example.com>") }
addMail("Your package was delivered")                         // old mail: never announced

print("[setup]")
var state = DeliveryState()
switch check(state) {
case .success(let result):
    check(result.deliveries.isEmpty, "first check announces nothing")
    check(result.state.lastUID == 531 && result.state.uidValidity == 7, "and notes where the inbox is: \(String(describing: result.state.lastUID))")
    state = result.state
case .failure(let error):
    check(false, "first check failed: \(error)")
}

print("[new mail]")
addMail("=?UTF-8?B?8J+TpiBZb3VyIHBhY2thZ2Ugd2FzIGRlbGl2ZXJlZA==?=")
addMail(#"Delivered: "Anker 735 Charger" and 1 more item"#, from: "Amazon.com <shipment-tracking@amazon.com>")
addMail(#"Out for delivery: "Cable""#, from: "Amazon.com <shipment-tracking@amazon.com>")
addMail("lunch?", from: "Friend <f@gmail.com>")
addMail("UPS Update: Delivery Attempted", from: "UPS <mcinfo@ups.com>")
switch check(state) {
case .success(let result):
    let shown = result.deliveries.map { "\($0.title) | \($0.body)" }
    check(shown == ["Delivered · eBay | Your package was delivered",
                    "Delivered · Amazon | Anker 735 Charger +1 more",
                    "Delivery problem · UPS | UPS Update: Delivery Attempted"], "the right three, in order: \(shown)")
    check(result.state.lastUID == 536, "moved past all new mail")
    state = result.state
case .failure(let error):
    check(false, "check failed: \(error)")
}

print("[again]")
switch check(state) {
case .success(let result):
    check(result.deliveries.isEmpty, "nothing announced twice")
    state = result.state
case .failure(let error):
    check(false, "check failed: \(error)")
}

print("[read flags]")
let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
check(!log.contains("SEEN-SET"), "no email was marked as read")
check(!log.contains("SELECT") && log.contains("EXAMINE INBOX"), "the inbox was only opened read-only")
check(log.contains("LOGOUT"), "logs out each time")

print("[wrong password]")
if case .failure(let error) = check(state, password: "wrongwrongwrongw") {
    check({ if case .badLogin = error { return true }; return false }(), "reported as a bad login: \(error)")
    check(DeliveryCheck.explain(error).contains("app password"), "with a helpful message")
} else {
    check(false, "a wrong password should fail")
}

print("[Gmail unreachable]")
if case .failure(let error) = check(state, port: deadPort) {
    check(error == .offline, "nothing listening: offline")
} else { check(false, "should fail") }

print("[Gmail never answers]")
let started = Date()
if case .failure(let error) = check(state, port: silentPort) {
    check(error == .offline, "a server that accepts but never speaks: offline")
    check(Date().timeIntervalSince(started) < 10, "and gives up within the timeout")
} else { check(false, "should fail") }

print("[after failures]")
addMail(#"Delivered: "Lamp""#, from: "Target <orders@target.com>")
if case .success(let result) = check(state) {
    check(result.deliveries.map(\.body) == ["Lamp"], "the next good check still finds new deliveries")
} else { check(false, "check failed") }

print(failures == 0 ? "passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
