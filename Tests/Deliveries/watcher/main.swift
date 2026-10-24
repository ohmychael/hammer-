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
    let verdict = "Authentication-Results: mx.google.com; dkim=pass header.i=@\(DeliveryMail.domain(of: from))\r\n"   // Gmail's, on top
    messages.append(["uid": uid, "headers": verdict + "From: \(from)\r\nSubject: \(subject)\r\nDate: \(date.string(from: Date()))\r\nMessage-ID: <m\(uid)@x>\r\n"])
    box["messages"] = messages
    try! JSONSerialization.data(withJSONObject: box).write(to: URL(fileURLWithPath: boxPath))
}
func setPassword(_ p: String) { box["password"] = p; try! JSONSerialization.data(withJSONObject: box).write(to: URL(fileURLWithPath: boxPath)) }

DeliveryWatcher.connect = { try SocketTransport(port: port) }
DeliveryWatcher.useNotificationCenter = true        // the stand-in Notification Center records what's shown
DeliveryWatcher.retryAfter = 0.5
DeliveryScript.allowsLocalServer = true             // the stand-in script server is plain http on this computer
let securityPath = CommandLine.arguments[3]
GmailKeychain.tool = KeychainTool(path: securityPath, timeout: 10)
let watcher = DeliveryWatcher.shared
var changes = 0
watcher.onChange = { changes += 1 }
watcher.start()
check(!watcher.isOn, "off until set up")

print("[wrong password]")
var answer: CheckFailure?? = .none
watcher.turnOn(email: "you@gmail.com", password: "wrongwrongwrongw") { answer = .some($0) }
wait(2)
check(answer != nil && (answer!)?.setupMessage.contains("app password") == true, "refused, with the reason: \(String(describing: answer))")
check(!watcher.isOn && GmailKeychain.password(for: "you@gmail.com") == .missing, "nothing saved")

print("[set up]")
answer = .none
watcher.turnOn(email: "you@gmail.com", password: "abcdefghijklmnop") { answer = .some($0) }
wait(2)
check(answer != nil && answer! == nil, "accepted")
check(watcher.isOn && watcher.email == "you@gmail.com", "on, for that account")
check(GmailKeychain.password(for: "you@gmail.com") == .found("abcdefghijklmnop"), "app password in the Keychain")
check(simAsked == 1, "asked for permission to show notifications")
check(watcher.recent.isEmpty && simPosted.isEmpty, "old mail not announced")
check(!watcher.hasSeenDeliveries, "the menu says 'No deliveries yet'")

print("[a delivery arrives]")
addMail("Your package was delivered: Apple iPhone 15 Pro Max")
addMail("lunch?", from: "f@gmail.com")
watcher.checkNow()
wait(2)
check(simPosted.count == 1 && simPosted.first?.0 == "Delivered · eBay" && simPosted.first?.1 == "Apple iPhone 15 Pro Max",
      "one notification: \(simPosted)")
check(simPosted.first?.2 == "https://mail.google.com/mail/?authuser=you@gmail.com#all/\(String(1_000_101, radix: 16))",
      "clicking it opens the email itself (by Gmail's ID): \(simPosted.first?.2 ?? "-")")
check(watcher.recent.map(\.body) == ["Apple iPhone 15 Pro Max"] && watcher.problem == nil && watcher.lastChecked != nil,
      "listed in the menu")
check(watcher.hasSeenDeliveries, "and from now on an empty list means 'none in the last 7 days'")
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
    check(simOpened.last?.absoluteString.hasSuffix("#all/\(first.gmailID ?? "?")") == true,
          "opens that email: \(simOpened.last?.absoluteString ?? "-")")
}

print("[a passing Gmail problem]")
box["login_error"] = "[UNAVAILABLE] Temporary System Problem. Try again later (Failure)"
try! JSONSerialization.data(withJSONObject: box).write(to: URL(fileURLWithPath: boxPath))
watcher.checkNow()
wait(2)
check(watcher.problem == "Gmail is having trouble right now." && !watcher.needsSetup && watcher.failure?.hasFix == false,
      "shown, but not treated as a wrong password: \(watcher.problem ?? "-")")
box["login_error"] = nil
addMail(#"Delivered: "Mug""#)
watcher.checkNow()
wait(2)
check(watcher.problem == nil && simPosted.last?.1 == "Mug", "and the next check works normally")

print("[out for delivery, then delivered]")
addMail(#"Out for delivery: "Desk lamp""#, from: "Amazon.com <a@amazon.com>")
watcher.checkNow()
wait(2)
check(simPosted.last?.0 == "Out for delivery · Amazon" && simPosted.last?.1 == "Desk lamp", "out for delivery: \(simPosted.last.map { $0.0 } ?? "-")")
let outID = simPostedIDs.last
addMail(#"Delivered: "Desk lamp""#, from: "Amazon.com <a@amazon.com>")
watcher.checkNow()
wait(2)
check(simPosted.last?.0 == "Delivered · Amazon" && simPostedIDs.last == outID && outID?.hasPrefix("delivery-<m") == true,
      "delivered replaces it (same notification): \(simPostedIDs.suffix(2))")
check(watcher.recent.first?.title == "Delivered · Amazon" && !watcher.recent.contains { $0.kind == .outForDelivery },
      "and in the menu, one line for the lamp")
watcher.outForDeliveryAlerts = false
let beforeOff = simPosted.count
addMail(#"Out for delivery: "Rug""#, from: "Amazon.com <a@amazon.com>")
watcher.checkNow()
wait(2)
check(simPosted.count == beforeOff && watcher.problem == nil, "out-for-delivery alerts can be turned off")
watcher.outForDeliveryAlerts = true

print("[can't reach Gmail: once quietly, then said]")
let realConnect = DeliveryWatcher.connect
DeliveryWatcher.connect = { throw IMAPError.offline }
watcher.checkNow()
wait(0.3)
check(watcher.problem == nil, "the first miss is quiet (e.g. just after waking)")
wait(1.5)                                                       // the quiet retry comes 0.5 s later here
check(watcher.problem == "Can't reach Gmail right now." && !watcher.needsSetup && watcher.failure?.hasFix == false,
      "then it's said, in one line: \(watcher.problem ?? "-")")
DeliveryWatcher.connect = realConnect
watcher.checkNow()
wait(2)
check(watcher.problem == nil, "back online: fine")

print("[Keychain slow or locked]")
let hungTool = FileManager.default.temporaryDirectory.appendingPathComponent("hung-security-\(getpid())").path
_ = FileManager.default.createFile(atPath: hungTool, contents: Data("#!/bin/sh\nsleep 20\n".utf8), attributes: [.posixPermissions: 0o755])
let lockedTool = FileManager.default.temporaryDirectory.appendingPathComponent("locked-security-\(getpid())").path
_ = FileManager.default.createFile(atPath: lockedTool, contents: Data("#!/bin/sh\nexit 36\n".utf8), attributes: [.posixPermissions: 0o755])
GmailKeychain.tool = KeychainTool(path: hungTool, timeout: 0.5)
let hung = DeliveryWatcher()                                   // like the next launch: nothing in memory
hung.checkNow()
wait(1.5)
check(hung.problem == "Can't open the Keychain right now." && !hung.needsSetup, "a hung Keychain times out: \(hung.problem ?? "-")")
GmailKeychain.tool = KeychainTool(path: lockedTool, timeout: 5)
let locked = DeliveryWatcher()
locked.checkNow()
wait(1)
check(locked.problem == "Can't open the Keychain right now." && !locked.needsSetup, "locked isn't 'missing'")
GmailKeychain.tool = KeychainTool(path: securityPath, timeout: 10)
try? FileManager.default.removeItem(atPath: hungTool)
try? FileManager.default.removeItem(atPath: lockedTool)

print("[Keychain entry missing]")
let fresh = DeliveryWatcher()                                  // like the next launch
GmailKeychain.delete(email: "you@gmail.com")
fresh.checkNow()
wait(1)
check(fresh.needsSetup && fresh.problem?.contains("Keychain") == true && fresh.failure?.hasFix == true, "says so and offers a fix")
GmailKeychain.save(email: "you@gmail.com", password: "abcdefghijklmnop")

print("[app password revoked]")
setPassword("somethingelseeee")
watcher.checkNow()
wait(2)
check(watcher.problem == "Gmail didn't accept the app password.", "menu says so: \(watcher.problem ?? "-")")
check(watcher.needsSetup && watcher.failure?.stopChecking == true, "and offers to set Gmail up again")
let posted = simPosted.count
addMail(#"Delivered: "Rug""#)
wait(1)
check(simPosted.count == posted, "and stops checking until set up again")

print("[set up again: nothing missed, list kept]")
let listBefore = watcher.recent.map(\.key)
setPassword("abcdefghijklmnop")
answer = .none
watcher.turnOn(email: "you@gmail.com", password: "abcdefghijklmnop") { answer = .some($0) }
wait(2)
check(answer != nil && answer! == nil, "accepted")
check(simPosted.count == posted + 1 && simPosted.last?.1 == "Rug", "the delivery that came while it was broken is announced")
check(Array(watcher.recent.map(\.key).dropFirst()) == Array(listBefore.prefix(DeliveryList.maxCount - 1)),
      "and the recent list is kept")

print("[test notification]")
watcher.sendTest()
check(simPosted.last?.0 == "Delivered · Hammer" && simPosted.last?.2 == nil, "test alert, no link")

print("[turn off]")
watcher.turnOff()
wait(0.5)                                                       // the Keychain item is deleted in the background
check(!watcher.isOn && watcher.recent.isEmpty && GmailKeychain.password(for: "you@gmail.com") == .missing,
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
check(answer != nil && (answer!)?.setupMessage.contains("key") == true && !watcher.isOn, "refused: \(String(describing: answer))")

print("[script: set up]")
answer = .none
watcher.turnOn(scriptURL: scriptAddress, key: scriptKey) { answer = .some($0) }
wait(2)
check(answer != nil && answer! == nil, "accepted")
check(watcher.isOn && watcher.source == .script && watcher.email == "you@gmail.com", "on, through the script")
check(GmailKeychain.scriptKey() == .found(scriptKey), "key in the Keychain")
check(GmailKeychain.scriptURL() == .found(scriptAddress.absoluteString) && UserDefaults.standard.string(forKey: "deliveryScriptURL") == nil,
      "and its address too, not in the settings")
let postedBefore = simPosted.count
check(watcher.recent.isEmpty, "the email already there isn't announced")
let scriptLog = (try? String(contentsOfFile: scriptLogPath, encoding: .utf8)) ?? ""
check(scriptLog.contains("/macros/echo"), "followed Google's redirect")

print("[script: a delivery arrives]")
scriptMail("new1", "Your package was delivered: Apple iPhone 15 Pro Max")
scriptMail("new2", #"Out for delivery: "Lamp""#, from: "Target <t@target.com>")
watcher.checkNow()
wait(2)
check(simPosted.count == postedBefore + 2 && simPosted.suffix(2).map(\.1) == ["Apple iPhone 15 Pro Max", "Lamp"]
      && simPosted.last?.0 == "Out for delivery · Target", "two notifications, oldest first: \(simPosted.suffix(2))")
check(simPosted.suffix(2).first?.2 == "https://mail.google.com/mail/?authuser=you@gmail.com#all/new1",
      "opens the email: \(simPosted.suffix(2).first?.2 ?? "-")")
watcher.checkNow()
wait(2)
check(simPosted.count == postedBefore + 2, "not announced twice")
let askedLines = ((try? String(contentsOfFile: scriptLogPath, encoding: .utf8)) ?? "").split(separator: "\n")
    .filter { $0.contains("/exec") }
check(askedLines.suffix(2).allSatisfy { $0.contains("after=") }, "later checks only ask for newer mail")

print("[script: deployment not open to Anyone]")
mode("signin")
watcher.checkNow()
wait(2)
check(watcher.needsSetup && watcher.problem == "The script isn't open to Anyone." && watcher.failure?.advice.contains("Who has access") == true,
      "says how to fix it: \(watcher.problem ?? "-")")
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
    let said = (watcher.failure?.message ?? "") + " " + (watcher.failure?.advice ?? "")
    check(said.localizedCaseInsensitiveContains(expected) && watcher.needsSetup == setup
          && (watcher.problem ?? "").count <= 60, "\(name): \(watcher.problem ?? "-")")
}
mode("ok")
let realFetch = DeliveryWatcher.fetch
DeliveryWatcher.fetch = { _ in nil }
watcher.checkNow()
wait(1.5)
check(watcher.problem == "Can't reach Gmail right now." && !watcher.needsSetup,
      "offline: the same words as the other route: \(watcher.problem ?? "-") setup=\(watcher.needsSetup) checking=\(watcher.isChecking)")
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

print("[script: an address kept in the settings moves to the Keychain, once]")
GmailKeychain.deleteScriptURL()
UserDefaults.standard.set(scriptAddress.absoluteString, forKey: "deliveryScriptURL")     // as an older Hammer left it
let upgraded = DeliveryWatcher()                                // the next launch, after the update
scriptMail("new4", #"Delivered: "Kettle""#, from: "Amazon.com <a@amazon.com>")
upgraded.checkNow()
wait(2)
check(upgraded.problem == nil && simPosted.last?.1 == "Kettle", "still works: \(upgraded.problem ?? "-")")
check(GmailKeychain.scriptURL() == .found(scriptAddress.absoluteString)
      && UserDefaults.standard.string(forKey: "deliveryScriptURL") == nil, "moved into the Keychain, and gone from the settings")
// A Keychain that won't take one account: the real stand-in, except that saves for it are dropped.
let refusals = FileManager.default.temporaryDirectory.appendingPathComponent("refused-\(getpid()).log").path
func refusing(_ account: String) -> KeychainTool {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("refusing-\(account)-\(getpid())").path
    let script = """
        #!/bin/sh
        if [ "$1" = "-i" ]; then
          line=$(cat)
          case "$line" in *" -a \(account) "*) echo "\(account)" >> '\(refusals)'; exit 0;; esac
          printf '%s\\n' "$line" | '\(securityPath)' -i; exit $?
        fi
        exec '\(securityPath)' "$@"

        """
    _ = FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
    return KeychainTool(path: path, timeout: 10)
}
GmailKeychain.deleteScriptURL()
UserDefaults.standard.set(scriptAddress.absoluteString, forKey: "deliveryScriptURL")
GmailKeychain.tool = refusing("script-url")                    // can't save the address now: keep using the setting
let lockedUpgrade = DeliveryWatcher()
scriptMail("new5", #"Delivered: "Toaster""#, from: "Amazon.com <a@amazon.com>")
lockedUpgrade.checkNow()
wait(2)
check(((try? String(contentsOfFile: refusals, encoding: .utf8)) ?? "").contains("script-url"), "it did try to move it")
check(lockedUpgrade.problem == nil && simPosted.last?.1 == "Toaster", "the check still works, with the setting's address")
check(UserDefaults.standard.string(forKey: "deliveryScriptURL") != nil && GmailKeychain.scriptURL() == .missing,
      "if the Keychain can't take it yet, the setting stays")
GmailKeychain.tool = KeychainTool(path: securityPath, timeout: 10)
lockedUpgrade.checkNow()
wait(2)
check(UserDefaults.standard.string(forKey: "deliveryScriptURL") == nil && GmailKeychain.scriptURL() == .found(scriptAddress.absoluteString),
      "and it moves at the next check that can")

print("[script: set up again, but the key can't be saved]")
let otherAddress = URL(string: "http://127.0.0.1:\(scriptPort)/macros/s/AKfycbOTHER/exec")!
let freshKey = DeliveryScript.newKey()
scriptBox["key"] = freshKey; saveScriptBox()                    // a new script, with a new key
GmailKeychain.tool = refusing("script-key")
answer = .none
watcher.turnOn(scriptURL: otherAddress, key: freshKey) { answer = .some($0) }
wait(2)
scriptBox["key"] = scriptKey; saveScriptBox()
check(answer != nil && (answer!)?.message.contains("Keychain") == true, "says so: \(String(describing: answer))")
check(GmailKeychain.scriptURL() == .found(scriptAddress.absoluteString) && GmailKeychain.scriptKey() == .found(scriptKey),
      "the address in use is put back, with its key")
GmailKeychain.tool = KeychainTool(path: securityPath, timeout: 10)
try? FileManager.default.removeItem(atPath: refusals)

print("[the script on the clipboard]")
let board = NSPasteboard.general
ScriptClipboard.copy(DeliveryScript.source(key: scriptKey))
check(board.options.contains(.currentHostOnly) && board.items[NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")] != nil
      && board.items[NSPasteboard.PasteboardType("org.nspasteboard.TransientType")] != nil && board.contents?.contains(scriptKey) == true,
      "copied for this Mac only, marked concealed and transient")
ScriptClipboard.clearIfOurs()
check(board.contents == nil, "cleared once set up")
ScriptClipboard.copy(DeliveryScript.source(key: scriptKey))
board.clearContents()
board.setString("something you copied since", forType: .string)
ScriptClipboard.clearIfOurs()
check(board.contents == "something you copied since", "but never what you copied since")

print("[switching routes]")
setPassword("abcdefghijklmnop")                                // the fake Gmail's password was changed above
answer = .none
watcher.turnOn(email: "you@gmail.com", password: "abcdefghijklmnop") { answer = .some($0) }
wait(2)
check(answer != nil && answer! == nil && watcher.source == .appPassword, "to the app password")
check(GmailKeychain.scriptKey() == .missing && GmailKeychain.scriptURL() == .missing, "the script's key and address are removed")
answer = .none
watcher.turnOn(scriptURL: scriptAddress, key: scriptKey) { answer = .some($0) }
wait(2)
check(answer != nil && answer! == nil && watcher.source == .script, "back to the script")
check(GmailKeychain.password(for: "you@gmail.com") == .missing, "the app password is removed")
check(watcher.turnOff() == .script, "turning off says the script was in use (it stays deployed in Google)")
wait(0.5)
check(!watcher.isOn && GmailKeychain.scriptKey() == .missing && GmailKeychain.scriptURL() == .missing && watcher.scriptURL == nil,
      "turned off: all gone")

print(failures == 0 ? "passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
