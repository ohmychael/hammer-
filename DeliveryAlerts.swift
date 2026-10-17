// DeliveryAlerts.swift — the Mac side of delivery alerts: the secure connection to
// Gmail, the app password in the Keychain, the notifications, and checking every
// few minutes. What counts as a delivery, and the IMAP conversation itself, are in
// Deliveries.swift (tested in Tests/).

import AppKit
import Network
import UserNotifications
#if canImport(FoundationNetworking)
import FoundationNetworking      // URLSession on Linux, where the tests run
#endif

// MARK: - TLS connection to imap.gmail.com

/// A TLS connection using macOS's own certificate checks. Blocking: use it off the main thread.
final class TLSTransport: IMAPTransport {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "local.hammer.imap")
    private let timeout: TimeInterval

    init(host: String, port: UInt16, timeout: TimeInterval = 20) throws {
        self.timeout = timeout
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw IMAPError.offline }
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tls)
        let settled = DispatchSemaphore(value: 0)
        let outcome = Box(false)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.value = true
                settled.signal()
            case .failed, .waiting, .cancelled:      // .waiting: no network right now
                settled.signal()
            default:
                break
            }
        }
        connection.start(queue: queue)
        guard settled.wait(timeout: .now() + timeout) == .success, outcome.value else {
            connection.cancel()
            throw IMAPError.offline
        }
    }

    func send(_ bytes: [UInt8]) throws {
        let done = DispatchSemaphore(value: 0)
        let failed = Box(false)
        connection.send(content: Data(bytes), completion: .contentProcessed { error in
            failed.value = error != nil
            done.signal()
        })
        guard done.wait(timeout: .now() + timeout) == .success, !failed.value else { throw IMAPError.offline }
    }

    func receive() throws -> [UInt8] {
        let done = DispatchSemaphore(value: 0)
        let received = Box(Data())
        let failed = Box(false)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
            if let data { received.value = data }
            failed.value = error != nil && received.value.isEmpty
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success, !failed.value else { throw IMAPError.offline }
        return [UInt8](received.value)                                 // empty: the server closed the connection
    }

    func close() { connection.cancel() }
}

// MARK: - The app password or script key, in your login Keychain

/// Stored with the `security` tool that comes with macOS, so the Keychain item
/// belongs to that tool. Hammer is rebuilt on every update, and an item owned by
/// Hammer itself would make macOS ask for your password after each one.
/// Secrets go to `security` on its standard input, never on a command line.
enum GmailKeychain {
    static let service = "local.hammer.gmail"
    static let scriptAccount = "script-key"
    static var tool = "/usr/bin/security"                  // tests swap in a stand-in

    /// The key Hammer shares with your Google script.
    @discardableResult
    static func saveScriptKey(_ key: String) -> Bool {
        guard DeliveryScript.isKey(key) else { return false }
        _ = run(["-i"], input: "add-generic-password -U -s \(service) -a \(scriptAccount) -l Hammer-Gmail-script -w \(key)\n")
        return scriptKey() == key
    }

    static func scriptKey() -> String? {
        let (status, output) = run(["find-generic-password", "-s", service, "-a", scriptAccount, "-w"])
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && DeliveryScript.isKey(value) ? value : nil
    }

    static func deleteScriptKey() {
        _ = run(["delete-generic-password", "-s", service, "-a", scriptAccount])
    }

    @discardableResult
    static func save(email: String, password: String) -> Bool {
        guard DeliverySetup.isPlainEmail(email), DeliverySetup.cleanPassword(password) == password else { return false }
        _ = run(["-i"], input: "add-generic-password -U -s \(service) -a \(email) -l Hammer-Gmail -w \(password)\n")
        return self.password(for: email) == password
    }

    static func password(for email: String) -> String? {
        guard DeliverySetup.isPlainEmail(email) else { return nil }
        let (status, output) = run(["find-generic-password", "-s", service, "-a", email, "-w"])
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && !value.isEmpty ? value : nil
    }

    static func delete(email: String) {
        guard DeliverySetup.isPlainEmail(email) else { return }
        _ = run(["delete-generic-password", "-s", service, "-a", email])
    }

    private static func run(_ arguments: [String], input: String? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = stdin
        do { try process.run() } catch { return (-1, "") }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Checking and notifying

/// Where Hammer reads your delivery emails from.
enum DeliverySource: String {
    case script          // your Google Apps Script (no app password)
    case appPassword     // Gmail itself, over IMAP, with an app password
}

/// Checks for new delivery emails every few minutes and shows a notification for
/// each delivery. Everything here happens on the main thread except the check itself.
final class DeliveryWatcher: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DeliveryWatcher()
    static let checkEvery: TimeInterval = 180
    /// How to reach Gmail with an app password (tests swap in a fake server).
    static var connect: () throws -> IMAPTransport = { try TLSTransport(host: "imap.gmail.com", port: 993) }
    /// How to ask the Google script; nil if it couldn't be reached (tests swap in a fake).
    static var fetch: (URL) -> (status: Int, body: Data)? = { DeliveryWatcher.download($0) }

    /// Called on the main thread when something the menu shows has changed.
    var onChange: (() -> Void)?

    private(set) var lastChecked: Date?
    private(set) var problem: String?
    private(set) var notificationsOff = false
    private(set) var isChecking = false
    private(set) var needsSetup = false        // e.g. Gmail refused the app password, or the script's key is wrong
    private var secret: String?                // the app password or script key, once read from the Keychain
    private var generation = 0                 // changes when alerts are set up or turned off
    private var timer: Timer?
    private let queue = DispatchQueue(label: "local.hammer.deliveries")

    // Saved between launches. The app password or script key itself is only in the Keychain.
    private(set) var source: DeliverySource? {
        get {
            if let raw = UserDefaults.standard.string(forKey: "deliverySource") { return DeliverySource(rawValue: raw) }
            return UserDefaults.standard.string(forKey: "deliveryEmail") != nil ? .appPassword : nil
        }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "deliverySource") }
    }
    /// Your Gmail address: the one you typed (app password), or the one the script reports.
    private(set) var email: String? {
        get { UserDefaults.standard.string(forKey: "deliveryEmail") }
        set { UserDefaults.standard.set(newValue, forKey: "deliveryEmail") }
    }
    private(set) var scriptURL: URL? {
        get { UserDefaults.standard.string(forKey: "deliveryScriptURL").flatMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: "deliveryScriptURL") }
    }
    private var state: DeliveryState {
        get { load(DeliveryState.self, "deliveryState") ?? DeliveryState() }
        set { save(newValue, "deliveryState") }
    }
    private var scriptState: ScriptState {
        get { load(ScriptState.self, "deliveryScriptState") ?? ScriptState() }
        set { save(newValue, "deliveryScriptState") }
    }
    private(set) var recent: [Delivery] {
        get { load([Delivery].self, "recentDeliveries") ?? [] }
        set { save(Array(newValue.prefix(8)), "recentDeliveries") }
    }

    var isOn: Bool { source != nil }

    /// macOS only lets an app bundle (Hammer.app) use Notification Center; the bare
    /// binary falls back to plain notifications. Tests turn this on to use stand-ins.
    static var useNotificationCenter = Bundle.main.bundleIdentifier != nil

    /// At launch: listen for notification clicks and sleep/wake, and start checking if it's set up.
    func start() {
        if Self.useNotificationCenter { UNUserNotificationCenter.current().delegate = self }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(macWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(macWoke), name: NSWorkspace.didWakeNotification, object: nil)
        guard isOn else { return }
        refreshNotificationSetting()
        scheduleChecks()
        checkNow()
    }

    // MARK: Setting up

    /// Asks the Google script; if it answers properly, saves its address and key and
    /// starts. Emails already there aren't announced. Calls back on the main thread
    /// with nil, or with what went wrong. The Keychain is only used off the main
    /// thread (it can stop to ask for your Mac password).
    func turnOn(scriptURL: URL, key: String, done: @escaping (String?) -> Void) {
        let previous = (source: source, email: email)
        queue.async {
            let answer: (failure: String?, account: String, start: ScriptState?)
            switch Self.askScript(scriptURL, key: key) {
            case .failure(let failure):
                answer = (failure.message, "", nil)
            case .success(let reply):
                if GmailKeychain.saveScriptKey(key) {
                    if previous.source == .appPassword, let old = previous.email { GmailKeychain.delete(email: old) }
                    answer = (nil, reply.account ?? "", ScriptCheck.process(reply.emails ?? [], state: ScriptState()).state)
                } else {
                    answer = ("The script works, but Hammer couldn't save its key to your Keychain.", "", nil)
                }
            }
            DispatchQueue.main.async {
                guard let start = answer.start else {
                    done(answer.failure)
                    return
                }
                self.source = .script
                self.scriptURL = scriptURL
                self.email = answer.account
                self.scriptState = start
                self.started(secret: key)
                done(nil)
            }
        }
    }

    /// Tries the email and app password; if Gmail accepts them, saves them and starts.
    func turnOn(email: String, password: String, done: @escaping (String?) -> Void) {
        let previous = (source: source, email: self.email)
        queue.async {
            let result = DeliveryCheck.run(state: DeliveryState(), email: email, password: password,
                                           transport: Self.connect)
            let answer: (failure: String?, start: DeliveryState?)
            switch result {
            case .failure(let error):
                answer = (DeliveryCheck.explain(error), nil)
            case .success(let outcome):
                if GmailKeychain.save(email: email, password: password) {
                    if previous.source == .appPassword, let old = previous.email, old != email {
                        GmailKeychain.delete(email: old)
                    }
                    if previous.source == .script { GmailKeychain.deleteScriptKey() }
                    answer = (nil, outcome.state)          // starts from the newest email: old mail isn't announced
                } else {
                    answer = ("Gmail accepted it, but Hammer couldn't save it to your Keychain.", nil)
                }
            }
            DispatchQueue.main.async {
                guard let start = answer.start else {
                    done(answer.failure)
                    return
                }
                self.source = .appPassword
                self.email = email
                self.state = start
                self.started(secret: password)
                done(nil)
            }
        }
    }

    private func started(secret: String) {
        generation += 1
        self.secret = secret
        recent = []
        problem = nil
        needsSetup = false
        lastChecked = Date()
        scheduleChecks()
        askForNotifications()
        onChange?()
    }

    func turnOff() {
        let old = (source: source, email: email)
        generation += 1
        timer?.invalidate()
        timer = nil
        source = nil
        email = nil
        scriptURL = nil
        secret = nil
        problem = nil
        needsSetup = false
        lastChecked = nil
        for key in ["deliveryState", "deliveryScriptState", "recentDeliveries"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        queue.async {
            if old.source == .appPassword, let email = old.email { GmailKeychain.delete(email: email) }
            if old.source == .script { GmailKeychain.deleteScriptKey() }
        }
        onChange?()
    }

    // MARK: Checking

    private struct Outcome {
        let result: Result<[Delivery], CheckFailure>
        var imapState: DeliveryState? = nil
        var scriptState: ScriptState? = nil
        var account: String? = nil
    }

    func checkNow() {
        guard let source, !isChecking else { return }
        isChecking = true
        let cached = secret, email = self.email ?? "", url = scriptURL
        let imapState = state, savedScriptState = scriptState, generation = self.generation
        queue.async {
            let secret: String?
            switch source {
            case .appPassword: secret = cached ?? GmailKeychain.password(for: email)
            case .script: secret = cached ?? GmailKeychain.scriptKey()
            }
            guard let secret else {
                DispatchQueue.main.async { self.secretMissing(generation: generation) }
                return
            }
            let outcome: Outcome
            switch source {
            case .appPassword:
                switch DeliveryCheck.run(state: imapState, email: email, password: secret, transport: Self.connect) {
                case .success(let checked): outcome = Outcome(result: .success(checked.deliveries), imapState: checked.state)
                case .failure(let error): outcome = Outcome(result: .failure(CheckFailure(error)))
                }
            case .script:
                let asked = url.map { Self.askScript($0, key: secret) }
                    ?? .failure(CheckFailure(message: "Hammer lost the script's address.", needsSetup: true))
                switch asked {
                case .success(let reply):
                    let checked = ScriptCheck.process(reply.emails ?? [], state: savedScriptState)
                    outcome = Outcome(result: .success(checked.deliveries), scriptState: checked.state,
                                      account: reply.account)
                case .failure(let failure):
                    outcome = Outcome(result: .failure(failure))
                }
            }
            DispatchQueue.main.async { self.finish(outcome, secret: secret, generation: generation) }
        }
    }

    private func secretMissing(generation: Int) {
        isChecking = false
        guard generation == self.generation, let source else { return }
        problem = source == .script ? "Hammer can't find the script's key in your Keychain."
                                    : "Hammer can't find your app password in the Keychain."
        needsSetup = true
        timer?.invalidate()                            // don't ask the Keychain again every 3 minutes
        timer = nil
        onChange?()
    }

    private func finish(_ outcome: Outcome, secret: String, generation: Int) {
        isChecking = false
        guard generation == self.generation, let source else { return }      // set up again or turned off meanwhile
        switch outcome.result {
        case .success(let deliveries):
            self.secret = secret
            if let checked = outcome.imapState { state = checked }
            if let checked = outcome.scriptState { scriptState = checked }
            if let account = outcome.account, !account.isEmpty { email = account }
            lastChecked = Date()
            problem = nil
            needsSetup = false
            if timer == nil { scheduleChecks() }               // back to normal after a Check Now
            for delivery in deliveries { post(delivery) }
            if !deliveries.isEmpty { recent = deliveries.reversed() + recent }
        case .failure(let failure):
            problem = failure.message
            if failure.needsSetup && source == .appPassword {
                // Don't keep knocking with a password Gmail refuses (it can lock the account).
                // The script, though, is asked as usual: fixing its deployment fixes this by itself.
                timer?.invalidate()
                timer = nil
                self.secret = nil
            }
            // Offer setup for this problem, or while a refused app password is still the one on file.
            needsSetup = failure.needsSetup || (source == .appPassword && timer == nil)
        }
        refreshNotificationSetting()
        onChange?()
    }

    private static func askScript(_ base: URL, key: String) -> Result<ScriptCheck.Reply, CheckFailure> {
        guard let url = DeliveryScript.requestURL(base: base, key: key) else {
            return .failure(CheckFailure(message: "That web app address doesn't look right.", needsSetup: true))
        }
        guard let answer = fetch(url) else { return .failure(.offline) }
        return ScriptCheck.read(status: answer.status, body: answer.body)
    }

    /// One HTTPS request, waiting for the answer (off the main thread). Google answers
    /// with a redirect to googleusercontent.com, which URLSession follows.
    private static func download(_ url: URL) -> (status: Int, body: Data)? {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let done = DispatchSemaphore(value: 0)
        let result = Box<(status: Int, body: Data)?>(nil)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result.value = (http.statusCode, data ?? Data()) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 40)
        return result.value
    }

    private func scheduleChecks() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.checkEvery, repeats: true) { [weak self] _ in self?.checkNow() }
        timer.tolerance = 20
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // No checks while asleep; the first one comes 10 seconds after waking, once the
    // network is back, then every 3 minutes as usual.
    @objc private func macWillSleep() { timer?.fireDate = .distantFuture }
    @objc private func macWoke() { timer?.fireDate = Date().addingTimeInterval(10) }

    // MARK: Notifications

    func askForNotifications() {
        guard Self.useNotificationCenter else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            DispatchQueue.main.async {
                UserDefaults.standard.set(true, forKey: "askedForNotifications")
                self.refreshNotificationSetting()
            }
        }
    }

    private func refreshNotificationSetting() {
        guard Self.useNotificationCenter else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                // Off: turned off in System Settings, or Hammer asked and macOS never let it.
                let asked = UserDefaults.standard.bool(forKey: "askedForNotifications")
                self.setNotificationsOff(status == .denied || (status == .notDetermined && asked))
            }
        }
    }

    private func setNotificationsOff(_ off: Bool) {
        guard off != notificationsOff else { return }
        notificationsOff = off
        onChange?()
    }

    func sendTest() {
        post(Delivery(kind: .delivered, store: "Hammer", item: "This is what a delivery alert looks like.",
                      subject: "", messageID: nil, date: Date(), uid: 0))
    }

    private func post(_ delivery: Delivery) {
        guard Self.useNotificationCenter else {
            Self.plainNotification(title: delivery.title, body: delivery.body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = delivery.title
        content.body = delivery.body
        content.sound = .default
        content.threadIdentifier = "deliveries"
        if let link = delivery.gmailLink(account: email ?? "") {           // none for the test alert
            content.userInfo = ["link": link.absoluteString]
        }
        let id = "delivery-" + (delivery.messageID ?? UUID().uuidString)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard error != nil else { return }
            // macOS wouldn't show it: notifications are off for Hammer. Say so in the menu
            // (the delivery is still listed there).
            DispatchQueue.main.async { self.setNotificationsOff(true) }
        }
    }

    private static func plainNotification(title: String, body: String) {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title))"]
        try? process.run()
    }

    // Show banners even while Hammer's menu is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // Clicking a delivery alert opens that email in Gmail.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let text = response.notification.request.content.userInfo["link"] as? String, let url = URL(string: text) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }

    /// Opens one of the recent deliveries (by Delivery.key) in Gmail.
    func open(key: String) {
        guard let delivery = recent.first(where: { $0.key == key }),
              let url = delivery.gmailLink(account: email ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Saving

    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
