// Runs DeliveryWatcher (DeliveryAlerts.swift) for real against fake_gmail.py, with
// fake_security.py in place of macOS's Keychain tool and AppleStandIns.swift in
// place of AppKit/Network/UserNotifications. Run by Tests/Deliveries/run.sh.
import Foundation
var failures = 0
func check(_ ok: Bool, _ what: String) { print("  \(ok ? "ok  " : "FAIL") \(what)"); if !ok { failures += 1 } }
func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
let port = UInt16(CommandLine.arguments[1])!, boxPath = CommandLine.arguments[2]
var box: [String: Any] = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: boxPath))) as! [String: Any]
func addMail(_ subject: String, from: String = "\"eBay\" <ebay@ebay.com>") {
    var messages = box["messages"] as! [[String: Any]]
    let uid = (messages.compactMap { $0["uid"] as? Int }.max() ?? 100) + 1
    let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
    messages.append(["uid": uid, "headers": "From: \(from)\r\nSubject: \(subject)\r\nDate: \(date.string(from: Date()))\r\nMessage-ID: <m\(uid)@x>\r\n"])
    box["messages"] = messages
    try! JSONSerialization.data(withJSONObject: box).write(to: URL(fileURLWithPath: boxPath))
}
func setPassword(_ p: String) { box["password"] = p; try! JSONSerialization.data(withJSONObject: box).write(to: URL(fileURLWithPath: boxPath)) }

DeliveryWatcher.connect = { try SocketTransport(port: port) }
DeliveryWatcher.useNotificationCenter = true        // the stand-in Notification Center records what's shown
GmailKeychain.tool = CommandLine.arguments[3]
let watcher = DeliveryWatcher.shared
var changes = 0
watcher.onChange = { changes += 1 }
watcher.start()
check(!watcher.isOn, "off until set up")

print("[wrong password]")
var answer: String?? = .none
watcher.turnOn(email: "you@gmail.com", password: "wrongwrongwrongw") { answer = .some($0) }
wait(2)
check(answer != nil && (answer!)?.contains("app password") == true, "refused, with the reason: \(String(describing: answer))")
check(!watcher.isOn && GmailKeychain.password(for: "you@gmail.com") == nil, "nothing saved")

print("[set up]")
answer = .none
watcher.turnOn(email: "you@gmail.com", password: "abcdefghijklmnop") { answer = .some($0) }
wait(2)
check(answer != nil && answer! == nil, "accepted")
check(watcher.isOn && watcher.email == "you@gmail.com", "on, for that account")
check(GmailKeychain.password(for: "you@gmail.com") == "abcdefghijklmnop", "app password in the Keychain")
check(simAsked == 1, "asked for permission to show notifications")
check(watcher.recent.isEmpty && simPosted.isEmpty, "old mail not announced")

print("[a delivery arrives]")
addMail("Your package was delivered: Apple iPhone 15 Pro Max")
addMail("lunch?", from: "f@gmail.com")
watcher.checkNow()
wait(2)
check(simPosted.count == 1 && simPosted.first?.0 == "Delivered · eBay" && simPosted.first?.1 == "Apple iPhone 15 Pro Max",
      "one notification: \(simPosted)")
check(simPosted.first?.2?.hasPrefix("https://mail.google.com/mail/?authuser=you@gmail.com#search/rfc822msgid%3A") == true,
      "clicking it opens the email")
check(watcher.recent.map(\.body) == ["Apple iPhone 15 Pro Max"] && watcher.problem == nil && watcher.lastChecked != nil,
      "listed in the menu")
watcher.checkNow()
wait(2)
check(simPosted.count == 1, "not announced again")

print("[two at once, newest first in the menu]")
addMail(#"Delivered: "Cable""#, from: "Amazon.com <a@amazon.com>")
addMail(#"Delivered: "Lamp""#, from: "Target <t@target.com>")
watcher.checkNow()
wait(2)
check(simPosted.suffix(2).map(\.1) == ["Cable", "Lamp"], "both announced")
check(watcher.recent.map(\.body) == ["Lamp", "Cable", "Apple iPhone 15 Pro Max"], "newest first: \(watcher.recent.map(\.body))")

print("[opening a delivery from the menu]")
if let first = watcher.recent.last {
    watcher.open(key: first.key)
    check(simOpened.last?.absoluteString.hasSuffix("rfc822msgid%3A\(first.messageID!.dropFirst().dropLast())") == true,
          "opens that email: \(simOpened.last?.absoluteString ?? "-")")
}

print("[a passing Gmail problem]")
box["login_error"] = "[UNAVAILABLE] Temporary System Problem. Try again later (Failure)"
try! JSONSerialization.data(withJSONObject: box).write(to: URL(fileURLWithPath: boxPath))
watcher.checkNow()
wait(2)
check(watcher.problem?.contains("keep trying") == true && !watcher.needsSetup, "shown, but not treated as a wrong password")
box["login_error"] = nil
addMail(#"Delivered: "Mug""#)
watcher.checkNow()
wait(2)
check(watcher.problem == nil && simPosted.last?.1 == "Mug", "and the next check works normally")

print("[Keychain entry missing]")
let fresh = DeliveryWatcher()                                  // like the next launch
GmailKeychain.delete(email: "you@gmail.com")
fresh.checkNow()
wait(1)
check(fresh.needsSetup && fresh.problem?.contains("Keychain") == true, "says so and offers setup")
GmailKeychain.save(email: "you@gmail.com", password: "abcdefghijklmnop")

print("[app password revoked]")
setPassword("somethingelseeee")
watcher.checkNow()
wait(2)
check(watcher.problem?.contains("app password") == true, "menu says so: \(watcher.problem ?? "-")")
check(watcher.needsSetup, "and offers to set Gmail up again")
let posted = simPosted.count
addMail(#"Delivered: "Rug""#)
wait(1)
check(simPosted.count == posted, "and stops checking until set up again")

print("[test notification]")
watcher.sendTest()
check(simPosted.last?.0 == "Delivered · Hammer" && simPosted.last?.2 == nil, "test alert, no link")

print("[turn off]")
watcher.turnOff()
wait(0.5)                                                       // the Keychain item is deleted in the background
check(!watcher.isOn && watcher.recent.isEmpty && GmailKeychain.password(for: "you@gmail.com") == nil,
      "off: account, list and Keychain item gone")
check(!watcher.needsSetup && watcher.problem == nil, "and no leftover warnings")
watcher.checkNow()
check(!watcher.isChecking, "checks nothing when off")
print(failures == 0 ? "passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
