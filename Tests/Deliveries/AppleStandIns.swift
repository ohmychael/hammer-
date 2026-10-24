// Stand-ins for the Apple APIs DeliveryAlerts.swift and the Deliveries menu use
// (Network, UserNotifications, a little AppKit), so that code can be type-checked
// and run on Linux. They mirror Apple's names, labels and types, as far as Hammer
// uses them; they can't prove Apple's real API matches. simPosted records the
// notifications that would have been shown.
import Foundation
// Network
enum NWEndpoint {
    struct Host { init(_ name: String) {} }
    struct Port { init?(rawValue: UInt16) {} }
}
struct NWError: Error {}
final class NWParameters { static let tls = NWParameters() }
final class NWConnection {
    enum State { case setup, waiting(NWError), preparing, ready, failed(NWError), cancelled }
    final class ContentContext { static let defaultMessage = ContentContext() }
    enum SendCompletion { case contentProcessed((NWError?) -> Void), idempotent }
    var stateUpdateHandler: ((State) -> Void)?
    init(host: NWEndpoint.Host, port: NWEndpoint.Port, using parameters: NWParameters) {}
    func start(queue: DispatchQueue) {}
    func cancel() {}
    func send(content: Data?, contentContext: ContentContext = .defaultMessage, isComplete: Bool = true,
              completion: SendCompletion) {}
    func receive(minimumIncompleteLength: Int, maximumLength: Int,
                 completion: @escaping (Data?, ContentContext?, Bool, NWError?) -> Void) {}
}
// UserNotifications
struct UNAuthorizationOptions: OptionSet { let rawValue: UInt; static let alert = Self(rawValue: 1), sound = Self(rawValue: 2) }
enum UNAuthorizationStatus: Int { case notDetermined, denied, authorized, provisional }
class UNNotificationSettings { var authorizationStatus: UNAuthorizationStatus { .authorized } }
struct UNNotificationPresentationOptions: OptionSet {
    let rawValue: UInt
    static let banner = Self(rawValue: 1), list = Self(rawValue: 2), sound = Self(rawValue: 4)
}
class UNNotificationSound { static var `default`: UNNotificationSound { UNNotificationSound() } }
class UNNotificationContent { var title: String { "" }; var body: String { "" }; var userInfo: [AnyHashable: Any] { [:] } }
class UNMutableNotificationContent: UNNotificationContent {
    var _title = "", _body = "", _info: [AnyHashable: Any] = [:]
    override var title: String { get { _title } set { _title = newValue } }
    override var body: String { get { _body } set { _body = newValue } }
    override var userInfo: [AnyHashable: Any] { get { _info } set { _info = newValue } }
    var sound: UNNotificationSound?
    var threadIdentifier = ""
}
class UNNotificationTrigger {}
class UNNotificationRequest {
    let content: UNNotificationContent
    let identifier: String
    init(identifier: String, content: UNNotificationContent, trigger: UNNotificationTrigger?) {
        self.content = content; self.identifier = identifier }
}
class UNNotification { var request: UNNotificationRequest { fatalError() } }
class UNNotificationResponse { var notification: UNNotification { fatalError() } }
protocol UNUserNotificationCenterDelegate: NSObjectProtocol {}
class UNUserNotificationCenter {
    static func current() -> UNUserNotificationCenter { UNUserNotificationCenter() }
    weak var delegate: UNUserNotificationCenterDelegate?
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping (Bool, Error?) -> Void) {
        simAsked += 1; completionHandler(true, nil) }
    func getNotificationSettings(completionHandler: @escaping (UNNotificationSettings) -> Void) { completionHandler(UNNotificationSettings()) }
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: ((Error?) -> Void)? = nil) {
        simPosted.append((request.content.title, request.content.body, request.content.userInfo["link"] as? String))
        simPostedIDs.append(request.identifier); completionHandler?(nil) }
}
// AppKit
struct Selector { init(_ name: String) {} }
class NSWorkspace {
    static let shared = NSWorkspace()
    let notificationCenter = NotificationCenter.default
    static let didWakeNotification = Notification.Name("NSWorkspaceDidWakeNotification")
    static let willSleepNotification = Notification.Name("NSWorkspaceWillSleepNotification")
    @discardableResult func open(_ url: URL) -> Bool { simOpened.append(url); return true }
}
extension NotificationCenter {
    func addObserver(_ observer: Any, selector: Selector, name: Notification.Name?, object: Any?) {}
}
struct NSRect {
    var size = NSSize()
    var maxX = 1440.0, maxY = 900.0
    init(x: Int, y: Int, width: Int, height: Int) {}
}
struct NSSize { var width = 400.0, height = 300.0 }
struct NSPoint { init(x: Double, y: Double) {} }
final class NSScreen { static let main: NSScreen? = NSScreen(); var visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900) }
class NSView { init(frame: NSRect) {}; func addSubview(_ view: NSView) {} }
class NSTextField: NSView { var stringValue = ""; var placeholderString: String? }
class NSSecureTextField: NSTextField {}
class NSWindow {
    struct Level: Equatable { let raw: Int; static let floating = Level(raw: 3), normal = Level(raw: 0) }
    var initialFirstResponder: NSView?
    var level = Level.normal
    var frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    func setFrameTopLeftPoint(_ point: NSPoint) {}
}
final class NSPasteboard {
    struct PasteboardType: Hashable {
        let raw: String
        init(raw: String) { self.raw = raw }
        init(_ raw: String) { self.raw = raw }
        static let string = PasteboardType(raw: "public.utf8-plain-text")
    }
    struct ContentsOptions: OptionSet { let rawValue: UInt; static let currentHostOnly = Self(rawValue: 1) }
    static let general = NSPasteboard()
    private(set) var changeCount = 0
    var items: [PasteboardType: Data] = [:]
    var options: ContentsOptions = []
    var contents: String? { items[.string].map { String(decoding: $0, as: UTF8.self) } }
    @discardableResult func clearContents() -> Int { prepareForNewContents(with: []) }
    func prepareForNewContents(with options: ContentsOptions) -> Int {
        items = [:]; self.options = options; changeCount += 1; return changeCount }
    @discardableResult func setString(_ string: String, forType type: PasteboardType) -> Bool { items[type] = Data(string.utf8); return true }
    @discardableResult func setData(_ data: Data?, forType type: PasteboardType) -> Bool { items[type] = data; return true }
    func string(forType type: PasteboardType) -> String? { items[type].map { String(decoding: $0, as: UTF8.self) } }
}
struct NSModalResponse: Equatable { let raw: Int
    static let alertFirstButtonReturn = Self(raw: 1000), alertSecondButtonReturn = Self(raw: 1001),
               alertThirdButtonReturn = Self(raw: 1002) }
class NSAlert {
    var messageText = "", informativeText = ""
    var accessoryView: NSView?
    let window = NSWindow()
    @discardableResult func addButton(withTitle title: String) -> AnyObject { NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 0)) }
    func runModal() -> NSModalResponse { .alertFirstButtonReturn }
    func layout() {}
}
class NSApplication { func activate() {}; func activate(ignoringOtherApps: Bool) {} }
let NSApp = NSApplication()
class NSMenu { func addItem(_ item: NSMenuItem) {} }
enum NSControl { enum StateValue { case on, off, mixed } }
class NSMenuItem {
    var title: String; var target: AnyObject?; var tag = 0; var toolTip: String?; var submenu: NSMenu?; var isEnabled = true
    var state = NSControl.StateValue.off
    var representedObject: Any?
    init(title: String, action: Selector?, keyEquivalent: String) { self.title = title }
    static func separator() -> NSMenuItem { NSMenuItem(title: "", action: nil, keyEquivalent: "") }
}

var simPosted: [(String, String, String?)] = []
var simPostedIDs: [String] = []
var simAsked = 0
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
var simOpened: [URL] = []
