// DeliveryAlerts.swift — the Mac side of delivery alerts: the secure connection to
// Gmail, the app password in the Keychain, the notifications, and checking every
// few minutes. What counts as a delivery, and the IMAP conversation itself, are in
// Deliveries.swift (tested in Tests/).

import AppKit
import Network
import UserNotifications

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

// MARK: - The app password, in your login Keychain

/// Stored with the `security` tool that comes with macOS, so the Keychain item
/// belongs to that tool. Hammer is rebuilt on every update, and an item owned by
/// Hammer itself would make macOS ask for your password after each one.
/// The password goes to `security` on its standard input, never on a command line.
enum GmailKeychain {
    static let service = "local.hammer.gmail"
    static var tool = "/usr/bin/security"                  // tests swap in a stand-in

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

/// Checks Gmail every few minutes and shows a notification for each delivery.
/// Everything here happens on the main thread except the check itself.
final class DeliveryWatcher: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DeliveryWatcher()
    static let checkEvery: TimeInterval = 180
    /// How to reach Gmail (tests swap in a fake server).
    static var connect: () throws -> IMAPTransport = { try TLSTransport(host: "imap.gmail.com", port: 993) }

    /// Called on the main thread when something the menu shows has changed.
    var onChange: (() -> Void)?

    private(set) var lastChecked: Date?
    private(set) var problem: String?
    private(set) var notificationsOff = false
    private(set) var isChecking = false
    private(set) var needsSetup = false        // Gmail refused the app password, or it's missing
    private var password: String?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "local.hammer.deliveries")

    // Saved between launches. The app password itself is only in the Keychain.
    private(set) var email: String? {
        get { UserDefaults.standard.string(forKey: "deliveryEmail") }
        set { UserDefaults.standard.set(newValue, forKey: "deliveryEmail") }
    }
    private var state: DeliveryState {
        get { load(DeliveryState.self, "deliveryState") ?? DeliveryState() }
        set { save(newValue, "deliveryState") }
    }
    private(set) var recent: [Delivery] {
        get { load([Delivery].self, "recentDeliveries") ?? [] }
        set { save(Array(newValue.prefix(8)), "recentDeliveries") }
    }

    var isOn: Bool { email != nil }

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

    /// Tries the email and app password; if Gmail accepts them, saves them and starts.
    /// Calls back on the main thread with nil, or with what went wrong. The Keychain is
    /// only touched off the main thread (it can stop to ask for your Mac password).
    func turnOn(email: String, password: String, done: @escaping (String?) -> Void) {
        let previous = self.email
        queue.async {
            let result = DeliveryCheck.run(state: DeliveryState(), email: email, password: password,
                                           transport: Self.connect)
            let answer: (failure: String?, start: DeliveryState?)
            switch result {
            case .failure(let error):
                answer = (DeliveryCheck.explain(error), nil)
            case .success(let outcome):
                if GmailKeychain.save(email: email, password: password) {
                    if let previous, previous != email { GmailKeychain.delete(email: previous) }
                    answer = (nil, outcome.state)          // starts from the newest email: old mail isn't announced
                } else {
                    answer = ("Gmail accepted it, but Hammer couldn't save it to your Keychain.", nil)
                }
            }
            DispatchQueue.main.async {
                guard let startState = answer.start else {
                    done(answer.failure)
                    return
                }
                self.email = email
                self.password = password
                self.state = startState
                self.recent = []
                self.problem = nil
                self.needsSetup = false
                self.lastChecked = Date()
                self.scheduleChecks()
                self.askForNotifications()
                self.onChange?()
                done(nil)
            }
        }
    }

    func turnOff() {
        let old = email
        timer?.invalidate()
        timer = nil
        email = nil
        password = nil
        problem = nil
        needsSetup = false
        lastChecked = nil
        UserDefaults.standard.removeObject(forKey: "deliveryState")
        UserDefaults.standard.removeObject(forKey: "recentDeliveries")
        if let old { queue.async { GmailKeychain.delete(email: old) } }
        onChange?()
    }

    func checkNow() {
        guard let email, !isChecking else { return }
        isChecking = true
        let cached = password, saved = state
        queue.async {
            guard let password = cached ?? GmailKeychain.password(for: email) else {
                DispatchQueue.main.async {
                    self.isChecking = false
                    guard self.email == email else { return }
                    self.problem = "Hammer can't find your app password in the Keychain."
                    self.needsSetup = true
                    self.timer?.invalidate()               // don't ask the Keychain again every 3 minutes
                    self.timer = nil
                    self.onChange?()
                }
                return
            }
            let result = DeliveryCheck.run(state: saved, email: email, password: password, transport: Self.connect)
            DispatchQueue.main.async {
                if self.email == email { self.password = password }
                self.finish(result, for: email)
            }
        }
    }

    private func finish(_ result: Result<(deliveries: [Delivery], state: DeliveryState), IMAPError>, for checked: String) {
        isChecking = false
        guard email == checked else { return }                 // turned off or switched accounts meanwhile
        switch result {
        case .success(let outcome):
            state = outcome.state
            lastChecked = Date()
            problem = nil
            needsSetup = false
            if timer == nil { scheduleChecks() }               // back to normal after a Check Now
            for delivery in outcome.deliveries { post(delivery) }
            if !outcome.deliveries.isEmpty { recent = outcome.deliveries.reversed() + recent }
        case .failure(let error):
            problem = DeliveryCheck.explain(error)
            if case .badLogin = error {
                // Don't keep knocking with a password Gmail refuses (it can lock the account).
                timer?.invalidate()
                timer = nil
                password = nil
                needsSetup = true
            }
        }
        refreshNotificationSetting()
        onChange?()
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
        if let email, let link = delivery.gmailLink(account: email), delivery.uid != 0 {
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
        guard let email, let delivery = recent.first(where: { $0.key == key }),
              let url = delivery.gmailLink(account: email) else { return }
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
