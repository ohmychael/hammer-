// DeliveryAlerts.swift — the Mac side of delivery alerts: the secure connection to
// Gmail, the app password, script key and script address in the Keychain, the
// notifications, and checking every few minutes. What counts as a delivery, the IMAP
// conversation and the Keychain tool itself are in Deliveries.swift (tested in
// Tests/); this file runs end to end in Tests/Deliveries.

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

// MARK: - The app password, script key and script address, in your login Keychain

/// Kept by macOS's `security` tool (see KeychainTool in Deliveries.swift for why),
/// always off the main thread: it can stop to ask for your Mac password.
enum GmailKeychain {
    static let service = "local.hammer.gmail"
    static let scriptAccount = "script-key"
    static let scriptURLAccount = "script-url"
    static var tool = KeychainTool()                  // tests swap in a stand-in

    /// The key Hammer shares with your Google script.
    @discardableResult
    static func saveScriptKey(_ key: String) -> Bool {
        guard DeliveryScript.isKey(key) else { return false }
        return tool.save(service: service, account: scriptAccount, label: "Hammer-Gmail-script", secret: key)
    }

    static func scriptKey() -> KeychainRead {
        let read = tool.find(service: service, account: scriptAccount)
        if let value = read.value, !DeliveryScript.isKey(value) { return .missing }
        return read
    }

    static func deleteScriptKey() { tool.delete(service: service, account: scriptAccount) }

    /// The script's web address. Anyone with it and the key could ask your script for
    /// your delivery emails, so it's kept with the key rather than in Hammer's settings.
    @discardableResult
    static func saveScriptURL(_ url: URL) -> Bool {
        tool.save(service: service, account: scriptURLAccount, label: "Hammer-Gmail-script-URL", secret: url.absoluteString)
    }

    static func scriptURL() -> KeychainRead {
        let read = tool.find(service: service, account: scriptURLAccount)
        if let value = read.value, DeliveryScript.savedURL(value) == nil { return .missing }
        return read
    }

    static func deleteScriptURL() { tool.delete(service: service, account: scriptURLAccount) }

    @discardableResult
    static func save(email: String, password: String) -> Bool {
        guard DeliverySetup.isPlainEmail(email), DeliverySetup.cleanPassword(password) == password else { return false }
        return tool.save(service: service, account: email, label: "Hammer-Gmail", secret: password)
    }

    static func password(for email: String) -> KeychainRead {
        guard DeliverySetup.isPlainEmail(email) else { return .missing }
        let read = tool.find(service: service, account: email)
        if let value = read.value, value.isEmpty { return .missing }
        return read
    }

    static func delete(email: String) {
        guard DeliverySetup.isPlainEmail(email) else { return }
        tool.delete(service: service, account: email)
    }
}

/// `Hammer keychain-check`: stores, reads and deletes a test item the way delivery
/// alerts keep their secrets, under a service name of its own. The build server runs
/// it on a real Mac.
enum KeychainCheck {
    static let service = "local.hammer.keychain-check"

    static func run() -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        let tool = KeychainTool(path: GmailKeychain.tool.path, timeout: 20)
        let account = "test", value = "hammer-check-" + UUID().uuidString.lowercased()
        var passed = true
        func step(_ name: String, _ ok: Bool) {
            print("\(name): \(ok ? "ok" : "FAILED")")
            passed = passed && ok
        }
        tool.delete(service: service, account: account)                 // left over from an earlier run
        step("store a test item", tool.save(service: service, account: account, label: "Hammer-keychain-check", secret: value))
        step("read it back", tool.find(service: service, account: account) == .found(value))
        step("delete it", tool.delete(service: service, account: account))
        step("it's gone (reads as missing)", tool.find(service: service, account: account) == .missing)
        print(passed ? "Keychain check passed." : "Keychain check failed.")
        return passed ? 0 : 1
    }
}

// MARK: - Copying the script

/// The script carries its key, so it's copied for this Mac only (not to your other
/// devices through Universal Clipboard), marked so clipboard managers neither keep
/// nor show it (nspasteboard.org), and cleared once Hammer has it set up.
enum ScriptClipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static var copied: (change: Int, text: String)?

    static func copy(_ script: String) {
        let board = NSPasteboard.general
        _ = board.prepareForNewContents(with: .currentHostOnly)
        _ = board.setString(script, forType: .string)
        _ = board.setData(Data(), forType: concealed)
        _ = board.setData(Data(), forType: transient)
        copied = (board.changeCount, script)
    }

    /// Clears the clipboard, but only if it still holds the script Hammer copied.
    static func clearIfOurs() {
        guard let copied else { return }
        self.copied = nil
        let board = NSPasteboard.general
        guard board.changeCount == copied.change, board.string(forType: .string) == copied.text else { return }
        board.clearContents()
    }
}

// MARK: - Checking and notifying

/// Where Hammer reads your delivery emails from.
enum DeliverySource: String {
    case script          // your Google Apps Script (no app password)
    case appPassword     // Gmail itself, over IMAP, with an app password
}

/// Checks for new delivery emails every few minutes and shows a notification for
/// each delivery. Everything here happens on the main thread except the check
/// itself and the Keychain.
final class DeliveryWatcher: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DeliveryWatcher()
    static let checkEvery: TimeInterval = 180
    /// After a first "can't reach Gmail" (say, just after waking, before Wi-Fi is back),
    /// Hammer quietly tries again this much later before saying so.
    static var retryAfter: TimeInterval = 30
    /// How to reach Gmail with an app password (tests swap in a fake server).
    static var connect: () throws -> IMAPTransport = { try TLSTransport(host: "imap.gmail.com", port: 993) }
    /// How to ask the Google script; nil if it couldn't be reached (tests swap in a fake).
    static var fetch: (URL) -> (status: Int, body: Data, finalURL: URL?)? = { DeliveryWatcher.download($0) }

    /// Called on the main thread when something the menu shows has changed.
    var onChange: (() -> Void)?

    private(set) var lastChecked: Date?
    /// What's wrong, if anything: one line for the menu, and what to do (Fix…).
    private(set) var failure: CheckFailure?
    var problem: String? { failure?.message }
    private(set) var notificationsOff = false
    private(set) var isChecking = false
    private(set) var needsSetup = false        // e.g. Gmail refused the app password, or the script's key is wrong
    private(set) var isSettingUp = false       // the first check after Turn On is running
    private var secret: String?                // the app password or script key, once read from the Keychain
    private(set) var scriptURL: URL?           // the script's address, once read from the Keychain
    private var generation = 0                 // changes when alerts are set up or turned off
    private var offlineStreak = 0              // checks in a row that couldn't reach Gmail
    private var timer: Timer?
    private let queue = DispatchQueue(label: "local.hammer.deliveries")

    // Saved between launches. The app password, script key and script address are only in the Keychain.
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
    /// Where the script's address was kept before it moved to the Keychain.
    private static let oldScriptURLSetting = "deliveryScriptURL"
    private var state: DeliveryState {
        get { load(DeliveryState.self, "deliveryState") ?? DeliveryState() }
        set { save(newValue, "deliveryState") }
    }
    private var scriptState: ScriptState {
        get { load(ScriptState.self, "deliveryScriptState") ?? ScriptState() }
        set { save(newValue, "deliveryScriptState") }
    }
    /// When a check last worked. Setting up again looks back to here (at most 3 days).
    private var lastSuccess: Date? {
        get { UserDefaults.standard.object(forKey: "deliveryLastSuccess") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "deliveryLastSuccess") }
    }
    /// The last 7 days' deliveries, newest first.
    private(set) var recent: [Delivery] {
        get { DeliveryList.current(load([Delivery].self, "recentDeliveries") ?? []) }
        set { save(DeliveryList.current(newValue), "recentDeliveries") }
    }
    /// Whether "Out for delivery" emails show a notification too (on unless turned off).
    var outForDeliveryAlerts: Bool {
        get { UserDefaults.standard.object(forKey: "deliveryOutForDelivery") == nil
                || UserDefaults.standard.bool(forKey: "deliveryOutForDelivery") }
        set {
            UserDefaults.standard.set(newValue, forKey: "deliveryOutForDelivery")
            onChange?()
        }
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
    /// starts. Emails already there aren't announced, unless this is the same Gmail
    /// account set up again: then what arrived since the last good check is. Calls back
    /// on the main thread with nil, or with what went wrong. The Keychain is only used
    /// off the main thread (it can stop to ask for your Mac password).
    func turnOn(scriptURL: URL, key: String, done: @escaping (CheckFailure?) -> Void) {
        let previous = (source: source, email: email ?? "", scriptState: scriptState)
        let lookBack = lastSuccess
        let shown = Set(state.announced + recent.compactMap(\.messageID))
        settingUp(true)
        queue.async {
            let asked = Date()
            let after = lookBack.map { max($0, asked.addingTimeInterval(-DeliveryCheck.tooOld)) }
                .map { $0.addingTimeInterval(-DeliveryScript.overlap) }
            var failure: CheckFailure?
            var outcome: (account: String, state: ScriptState, found: [Delivery], sameAccount: Bool)?
            switch Self.askScript(scriptURL, key: key, after: after) {
            case .failure(let problem):
                failure = problem
            case .success(let reply):
                let account = reply.account ?? ""
                let same = !account.isEmpty && account.lowercased() == previous.email.lowercased()
                if GmailKeychain.saveScriptKey(key) && GmailKeychain.saveScriptURL(scriptURL) {
                    if previous.source == .appPassword, !previous.email.isEmpty { GmailKeychain.delete(email: previous.email) }
                    var start = ScriptState()
                    if same && lookBack != nil {                       // set up again: catch up on what was missed
                        start = ScriptState(started: true, seen: previous.scriptState.seen)
                    }
                    let processed = ScriptCheck.process(reply.emails ?? [], state: start, now: asked, askedAt: asked,
                                                        shown: same ? shown : [])
                    outcome = (account, processed.state, processed.deliveries, same)
                } else {
                    failure = CheckFailure(message: "The script works, but Hammer couldn't save its key to your Keychain.",
                                           advice: "Make sure your login Keychain is unlocked, then try again.")
                }
            }
            DispatchQueue.main.async {
                self.settingUp(false)
                guard let outcome else {
                    done(failure)
                    return
                }
                self.source = .script
                self.scriptURL = scriptURL
                UserDefaults.standard.removeObject(forKey: Self.oldScriptURLSetting)
                self.email = outcome.account
                self.scriptState = outcome.state
                self.started(secret: key, keepRecent: outcome.sameAccount)
                self.announce(outcome.found)
                done(nil)
            }
        }
    }

    /// Tries the email and app password; if Gmail accepts them, saves them and starts.
    func turnOn(email: String, password: String, done: @escaping (CheckFailure?) -> Void) {
        let previous = (source: source, email: self.email ?? "")
        let sameAccount = previous.email.lowercased() == email.lowercased()
        var start = DeliveryState()
        var lookBack: Date?
        if sameAccount {                     // set up again: catch up on what arrived since the last good check
            lookBack = lastSuccess
            start.announced = Array((state.announced + recent.compactMap(\.messageID)).suffix(200))
            if previous.source == .appPassword {
                start.uidValidity = state.uidValidity
                start.lastUID = state.lastUID
            }
        }
        settingUp(true)
        queue.async {
            let result = DeliveryCheck.run(state: start, email: email, password: password, lookBack: lookBack,
                                           transport: Self.connect)
            var failure: CheckFailure?
            var outcome: (deliveries: [Delivery], state: DeliveryState)?
            switch result {
            case .failure(let error):
                failure = CheckFailure(error)
            case .success(let checked):
                if GmailKeychain.save(email: email, password: password) {
                    if previous.source == .appPassword, !previous.email.isEmpty, !sameAccount {
                        GmailKeychain.delete(email: previous.email)
                    }
                    if previous.source == .script {
                        GmailKeychain.deleteScriptKey()
                        GmailKeychain.deleteScriptURL()
                    }
                    outcome = checked
                } else {
                    failure = CheckFailure(message: "Gmail accepted it, but Hammer couldn't save it to your Keychain.",
                                           advice: "Make sure your login Keychain is unlocked, then try again.")
                }
            }
            DispatchQueue.main.async {
                self.settingUp(false)
                guard let outcome else {
                    done(failure)
                    return
                }
                self.source = .appPassword
                self.email = email
                self.scriptURL = nil
                UserDefaults.standard.removeObject(forKey: Self.oldScriptURLSetting)
                self.state = outcome.state
                self.started(secret: password, keepRecent: sameAccount)
                self.announce(outcome.deliveries)
                done(nil)
            }
        }
    }

    private func settingUp(_ busy: Bool) {
        isSettingUp = busy
        onChange?()
    }

    /// The recent list stays when it's the same Gmail account set up again.
    private func started(secret: String, keepRecent: Bool) {
        generation += 1
        self.secret = secret
        if !keepRecent { recent = [] }
        failure = nil
        needsSetup = false
        offlineStreak = 0
        lastChecked = Date()
        lastSuccess = lastChecked
        scheduleChecks()
        askForNotifications()
        onChange?()
    }

    /// Turns alerts off and forgets the account. Returns the route that was in use (the
    /// Google script stays deployed in your account until you delete it there).
    @discardableResult
    func turnOff() -> DeliverySource? {
        let old = (source: source, email: email)
        generation += 1
        timer?.invalidate()
        timer = nil
        source = nil
        email = nil
        scriptURL = nil
        secret = nil
        failure = nil
        needsSetup = false
        offlineStreak = 0
        lastChecked = nil
        for key in ["deliveryState", "deliveryScriptState", "recentDeliveries", "deliveryLastSuccess", Self.oldScriptURLSetting] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        queue.async {
            if old.source == .appPassword, let email = old.email { GmailKeychain.delete(email: email) }
            if old.source == .script {
                GmailKeychain.deleteScriptKey()
                GmailKeychain.deleteScriptURL()
            }
        }
        onChange?()
        return old.source
    }

    // MARK: Checking

    private struct Outcome {
        let result: Result<[Delivery], CheckFailure>
        var imapState: DeliveryState? = nil
        var scriptState: ScriptState? = nil
        var account: String? = nil
    }

    /// The secret (and for the script, its address) from memory or the Keychain. The
    /// address moves out of Hammer's settings into the Keychain here, once.
    private static func secrets(source: DeliverySource, email: String, cached: (secret: String?, url: URL?),
                                oldSetting: String?) -> Result<(secret: String, url: URL?, forgetSetting: Bool), CheckFailure> {
        let keychainBusy = CheckFailure(message: "Can't open the Keychain right now.")
        switch source {
        case .appPassword:
            if let secret = cached.secret { return .success((secret, nil, false)) }
            switch GmailKeychain.password(for: email) {
            case .found(let password): return .success((password, nil, false))
            case .unavailable: return .failure(keychainBusy)
            case .missing:
                return .failure(CheckFailure(message: "Hammer can't find your app password in the Keychain.",
                                             advice: "Paste it below, or make a new one.", needsSetup: true, stopChecking: true))
            }
        case .script:
            var key = cached.secret
            if key == nil {
                switch GmailKeychain.scriptKey() {
                case .found(let found): key = found
                case .unavailable: return .failure(keychainBusy)
                case .missing:
                    return .failure(CheckFailure(message: "Hammer can't find the script's key in the Keychain.",
                                                 advice: "Set up Gmail again.", needsSetup: true, stopChecking: true))
                }
            }
            if let url = cached.url, let key { return .success((key, url, false)) }
            let stored = GmailKeychain.scriptURL()
            let found = DeliveryMigration.scriptAddress(keychain: stored, setting: oldSetting) { GmailKeychain.saveScriptURL($0) }
            guard let url = found.url, let key else {
                if case .unavailable = stored { return .failure(keychainBusy) }
                return .failure(CheckFailure(message: "Hammer can't find the script's address.",
                                             advice: "Set up Gmail again.", needsSetup: true, stopChecking: true))
            }
            return .success((key, url, found.forgetSetting))
        }
    }

    func checkNow() {
        guard let source, !isChecking else { return }
        isChecking = true
        let cached = (secret: secret, url: scriptURL), email = self.email ?? ""
        let oldSetting = UserDefaults.standard.string(forKey: Self.oldScriptURLSetting)
        let imapState = state, savedScriptState = scriptState, generation = self.generation
        queue.async {
            let secrets: (secret: String, url: URL?, forgetSetting: Bool)
            switch Self.secrets(source: source, email: email, cached: cached, oldSetting: oldSetting) {
            case .failure(let failure):
                DispatchQueue.main.async { self.secretTrouble(failure, generation: generation) }
                return
            case .success(let found):
                secrets = found
            }
            let outcome: Outcome
            switch source {
            case .appPassword:
                switch DeliveryCheck.run(state: imapState, email: email, password: secrets.secret, transport: Self.connect) {
                case .success(let checked): outcome = Outcome(result: .success(checked.deliveries), imapState: checked.state)
                case .failure(let error): outcome = Outcome(result: .failure(CheckFailure(error)))
                }
            case .script:
                let askedAt = Date()
                switch Self.askScript(secrets.url!, key: secrets.secret, after: savedScriptState.searchFrom) {
                case .success(let reply):
                    let checked = ScriptCheck.process(reply.emails ?? [], state: savedScriptState, askedAt: askedAt)
                    outcome = Outcome(result: .success(checked.deliveries), scriptState: checked.state, account: reply.account)
                case .failure(let failure):
                    outcome = Outcome(result: .failure(failure))
                }
            }
            DispatchQueue.main.async {
                if secrets.forgetSetting { UserDefaults.standard.removeObject(forKey: Self.oldScriptURLSetting) }
                self.finish(outcome, secret: secrets.secret, url: secrets.url, generation: generation)
            }
        }
    }

    private func secretTrouble(_ failure: CheckFailure, generation: Int) {
        isChecking = false
        guard generation == self.generation, source != nil else { return }
        self.failure = failure
        needsSetup = failure.needsSetup
        if failure.stopChecking {                       // don't ask the Keychain again every 3 minutes
            timer?.invalidate()
            timer = nil
        }
        onChange?()
    }

    private func finish(_ outcome: Outcome, secret: String, url: URL?, generation: Int) {
        isChecking = false
        guard generation == self.generation, let source else { return }      // set up again or turned off meanwhile
        switch outcome.result {
        case .success(let deliveries):
            self.secret = secret
            if let url { scriptURL = url }
            if let checked = outcome.imapState { state = checked }
            if let checked = outcome.scriptState { scriptState = checked }
            if let account = outcome.account, !account.isEmpty { email = account }
            lastChecked = Date()
            lastSuccess = lastChecked
            failure = nil
            needsSetup = false
            offlineStreak = 0
            if timer == nil { scheduleChecks() }               // back to normal after a Check Now
            announce(deliveries)
        case .failure(let failure):
            offlineStreak = failure.offline ? offlineStreak + 1 : 0
            if failure.offline && offlineStreak == 1 && self.failure == nil, let timer {
                // Maybe the network isn't back yet: try once more, quietly, before saying so.
                timer.fireDate = Date().addingTimeInterval(Self.retryAfter)
                break
            }
            self.failure = failure
            if failure.stopChecking && source == .appPassword {
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

    /// Shows new deliveries (oldest first) and lists them in the menu. Their Message-IDs
    /// are remembered for both routes, so switching routes doesn't announce them again.
    private func announce(_ deliveries: [Delivery]) {
        guard !deliveries.isEmpty else { return }
        var memory = state
        let known = Set(memory.announced)
        memory.announced = Array((memory.announced + deliveries.compactMap(\.messageID).filter { !known.contains($0) }).suffix(200))
        state = memory
        let shown = deliveries.filter { $0.kind != .outForDelivery || outForDeliveryAlerts }
        guard !shown.isEmpty else { return }
        for delivery in shown { post(delivery) }
        recent = DeliveryList.adding(shown, to: recent)
    }

    private static func askScript(_ base: URL, key: String, after: Date?) -> Result<ScriptCheck.Reply, CheckFailure> {
        guard let url = DeliveryScript.requestURL(base: base, key: key, after: after) else {
            return .failure(CheckFailure(message: "That web app address doesn't look right.",
                                         advice: "Set up Gmail again.", needsSetup: true))
        }
        guard let answer = fetch(url) else { return .failure(.offline) }
        return ScriptCheck.read(status: answer.status, body: answer.body, finalURL: answer.finalURL)
    }

    /// No disk cache or cookies: the request carries the script's key.
    private static let session = URLSession(configuration: .ephemeral)

    /// One HTTPS request, waiting for the answer (off the main thread). Google answers
    /// with a redirect to googleusercontent.com, which URLSession follows.
    private static func download(_ url: URL) -> (status: Int, body: Data, finalURL: URL?)? {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        let done = DispatchSemaphore(value: 0)
        let result = Box<(status: Int, body: Data, finalURL: URL?)?>(nil)
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { result.value = (http.statusCode, data ?? Data(), http.url) }
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

    // No checks while asleep; the first one comes 10 seconds after waking, then every
    // 3 minutes as usual. If the network isn't back by then, the next try is quiet.
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
        // One per package: a package's "Delivered" replaces its "Out for delivery".
        let request = UNNotificationRequest(identifier: delivery.notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard error != nil else { return }
            // macOS wouldn't show it: notifications are off for Hammer. Say so in the menu
            // (the delivery is still listed there).
            DispatchQueue.main.async { self.setNotificationsOff(true) }
        }
    }

    /// Without Notification Center (the bare binary): AppleScript's notification. The
    /// text goes in as arguments to a fixed script, never into the script itself.
    private static func plainNotification(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-", title, body]
        let script = Pipe()
        process.standardInput = script
        guard (try? process.run()) != nil else { return }
        script.fileHandleForWriting.write(Data("on run argv\ndisplay notification (item 2 of argv) with title (item 1 of argv)\nend run\n".utf8))
        try? script.fileHandleForWriting.close()
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
