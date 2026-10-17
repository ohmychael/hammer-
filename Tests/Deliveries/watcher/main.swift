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
// MARK: The Google script route

let scriptPort = UInt16(CommandLine.arguments[4])!, scriptStatePath = CommandLine.arguments[5]
let scriptLogPath = CommandLine.arguments[6]
let scriptKey = DeliveryScript.newKey()
var scriptBox: [String: Any] = ["key": scriptKey, "account": "you@gmail.com", "mode": "ok", "emails": [[String: Any]]()]
func saveScriptBox() { try! JSONSerialization.data(withJSONObject: scriptBox).write(to: URL(fileURLWithPath: scriptStatePath)) }
func scriptMail(_ id: String, _ subject: String, from: String = "\"eBay\" <ebay@ebay.com>", messageID: String? = nil) {
    var emails = scriptBox["emails"] as! [[String: Any]]
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    emails.append(["id": id, "messageID": messageID ?? "<\(id)@mail>", "from": from, "subject": subject,
                   "date": iso.string(from: Date())])
    scriptBox["emails"] = emails
    saveScriptBox()
}
func mode(_ value: String) { scriptBox["mode"] = value; saveScriptBox() }
let scriptAddress = URL(string: "http://127.0.0.1:\(scriptPort)/macros/s/AKfycbTEST/exec")!
scriptMail("old", "Your package was delivered")

print("[script: wrong key]")
answer = .none
watcher.turnOn(scriptURL: scriptAddress, key: DeliveryScript.newKey()) { answer = .some($0) }
wait(2)
check(answer != nil && (answer!)?.contains("key") == true && !watcher.isOn, "refused: \(String(describing: answer))")

print("[script: set up]")
answer = .none
watcher.turnOn(scriptURL: scriptAddress, key: scriptKey) { answer = .some($0) }
wait(2)
check(answer != nil && answer! == nil, "accepted")
check(watcher.isOn && watcher.source == .script && watcher.email == "you@gmail.com", "on, through the script")
check(GmailKeychain.scriptKey() == scriptKey, "key in the Keychain")
let postedBefore = simPosted.count
check(watcher.recent.isEmpty, "the email already there isn't announced")
let scriptLog = (try? String(contentsOfFile: scriptLogPath, encoding: .utf8)) ?? ""
check(scriptLog.contains("/macros/echo"), "followed Google's redirect")

print("[script: a delivery arrives]")
scriptMail("new1", "Your package was delivered: Apple iPhone 15 Pro Max")
scriptMail("new2", #"Out for delivery: "Lamp""#, from: "Target <t@target.com>")
watcher.checkNow()
wait(2)
check(simPosted.count == postedBefore + 1 && simPosted.last?.1 == "Apple iPhone 15 Pro Max", "one notification: \(simPosted.suffix(2))")
check(simPosted.last?.2 == "https://mail.google.com/mail/?authuser=you@gmail.com#search/rfc822msgid%3Anew1@mail",
      "opens the email: \(simPosted.last?.2 ?? "-")")
watcher.checkNow()
wait(2)
check(simPosted.count == postedBefore + 1, "not announced twice")
let askedLines = ((try? String(contentsOfFile: scriptLogPath, encoding: .utf8)) ?? "").split(separator: "\n")
    .filter { $0.contains("/exec") }
check(askedLines.suffix(2).allSatisfy { $0.contains("after=") }, "later checks only ask for newer mail")

print("[script: deployment not open to Anyone]")
mode("signin")
watcher.checkNow()
wait(2)
check(watcher.needsSetup && watcher.problem?.contains("Anyone") == true, "says how to fix it: \(watcher.problem ?? "-")")
mode("ok")
scriptMail("new3", #"Delivered: "Cable""#, from: "Amazon.com <a@amazon.com>", messageID: "")
watcher.checkNow()
wait(2)
check(!watcher.needsSetup && watcher.problem == nil && simPosted.last?.1 == "Cable",
      "fixing the deployment fixes it, no new setup needed")
check(simPosted.last?.2 == "https://mail.google.com/mail/?authuser=you@gmail.com#all/new3", "link by Gmail's ID")

print("[script: other problems]")
for (name, expected, setup) in [("busy", "busy", false), ("gmail", "couldn't read Gmail", false),
                                ("permission", "Select all", true),
                                ("unsaved", "saved", true), ("notfound", "can't find", true)] {
    mode(name)
    watcher.checkNow()
    wait(2)
    check(watcher.problem?.contains(expected) == true && watcher.needsSetup == setup,
          "\(name): \(watcher.problem ?? "-")")
}
mode("ok")
let realFetch = DeliveryWatcher.fetch
DeliveryWatcher.fetch = { _ in nil }
watcher.checkNow()
wait(1)
check(watcher.problem?.contains("Can't reach") == true && !watcher.needsSetup,
      "offline: keeps trying: \(watcher.problem ?? "-") setup=\(watcher.needsSetup) checking=\(watcher.isChecking)")
DeliveryWatcher.fetch = realFetch
watcher.checkNow()
wait(2)
check(watcher.problem == nil, "back online: fine")

print("[script: Keychain key missing at launch]")
let launched = DeliveryWatcher()
GmailKeychain.deleteScriptKey()
launched.checkNow()
wait(1)
check(launched.needsSetup && launched.problem?.contains("script's key") == true, "says so")
GmailKeychain.saveScriptKey(scriptKey)

print("[switching routes]")
setPassword("abcdefghijklmnop")                                // the fake Gmail's password was changed above
answer = .none
watcher.turnOn(email: "you@gmail.com", password: "abcdefghijklmnop") { answer = .some($0) }
wait(2)
check(answer != nil && answer! == nil && watcher.source == .appPassword, "to the app password")
check(GmailKeychain.scriptKey() == nil, "the script's key is removed")
answer = .none
watcher.turnOn(scriptURL: scriptAddress, key: scriptKey) { answer = .some($0) }
wait(2)
check(answer != nil && answer! == nil && watcher.source == .script, "back to the script")
check(GmailKeychain.password(for: "you@gmail.com") == nil, "the app password is removed")
watcher.turnOff()
wait(0.5)
check(!watcher.isOn && GmailKeychain.scriptKey() == nil && watcher.scriptURL == nil, "turned off: all gone")

print(failures == 0 ? "passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
