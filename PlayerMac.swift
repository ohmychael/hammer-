// PlayerMac.swift — the YouTube mini player's windows: a dropdown from the menu
// bar corner with YouTube in it, and a small floating player the video pops out
// into, above every other window. The decisions (links, which pages stay, where
// windows go) are in Player.swift; PlayerScript.js runs inside the page.
//
// It's YouTube's own mobile site, signed in or not, ads and all: Hammer only
// gives it a window. Nothing is downloaded or blocked.

import AppKit
import WebKit

/// A panel that can take typing (YouTube's search box) and closes on Escape.
final class PlayerPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// Rounded, shadowed, no title or traffic lights; the content fills it.
    static func make(resizable: Bool, activating: Bool) -> PlayerPanel {
        var style: NSWindow.StyleMask = [.titled, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        if !activating { style.insert(.nonactivatingPanel) }
        let panel = PlayerPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 225), styleMask: style,
                                backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = resizable
        return panel
    }
}

/// Messages from the page go through this, so the page doesn't keep the player alive.
@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: YouTubePlayer?
    init(_ target: YouTubePlayer) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.received(message.body)
    }
}

@MainActor
final class YouTubePlayer: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    enum Place { case hidden, dropdown, mini }
    private(set) var place: Place = .hidden
    private(set) var playing = false
    private(set) var hasVideo = false
    private(set) var title = ""
    var onChange: (() -> Void)?                          // e.g. the menu shows what's playing

    /// The mobile site lays out for a narrow window; this asks for it.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    private let anchor: () -> (screen: NSScreen?, maxX: CGFloat?)   // the menu bar icon
    private let web: WKWebView
    private let dropdown = PlayerPanel.make(resizable: false, activating: true)
    private let mini = PlayerPanel.make(resizable: true, activating: false)
    private let webHolder = NSView()                     // the web view's place in the dropdown
    private let overlay = MiniOverlay()
    private let titleLabel = NSTextField(labelWithString: "YouTube")
    private var popOutButton: NSButton!
    private var pinButton: NSButton!
    private var backButton: NSButton!
    private var pinned = false
    private var miniFrame: NSRect?
    private var snapTimer: Timer?
    private var clickMonitor: Any?
    private var loaded = false

    init(anchor: @escaping () -> (screen: NSScreen?, maxX: CGFloat?)) {
        self.anchor = anchor
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()                 // stays signed in between launches
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 12.3, *) { config.preferences.isElementFullscreenEnabled = true }
        if let url = Self.scriptURL, let script = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 660), configuration: config)
        super.init()
        config.userContentController.add(WeakScriptHandler(self), name: "hammer")
        web.customUserAgent = Self.userAgent
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = self
        web.uiDelegate = self
        web.autoresizingMask = [.width, .height]
        buildDropdown()
        buildMini()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appResigned),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    /// PlayerScript.js: in the app's Resources (build.sh puts it there).
    static var scriptURL: URL? {
        if let url = Bundle.main.url(forResource: "PlayerScript", withExtension: "js") { return url }
        if let path = ProcessInfo.processInfo.environment["HAMMER_PLAYER_SCRIPT"] { return URL(fileURLWithPath: path) }
        return nil
    }

    /// Runs JavaScript in the page and returns a true/false result (for the self-test).
    func evaluateBool(_ script: String) async -> Bool? {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result as? Bool) }
        }
    }

    /// Runs JavaScript in the page and returns a text result (for the self-test).
    func evaluateString(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            web.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result as? String) }
        }
    }

    /// Pictures of the dropdown or the mini player, for the self-test.
    func snapshot(completion: @escaping (NSImage?) -> Void) {
        let window = place == .mini ? mini : dropdown
        guard let content = window.contentView else { completion(nil); return }
        let bounds = content.bounds
        let chrome = content.bitmapImageRepForCachingDisplay(in: bounds)
        if let chrome { content.cacheDisplay(in: bounds, to: chrome) }
        let webFrame = web.convert(web.bounds, to: content)
        let bar = place == .mini ? overlay.barImage() : nil
        web.takeSnapshot(with: nil) { image, _ in
            let picture = NSImage(size: bounds.size)
            picture.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
            chrome?.draw(in: bounds)
            image?.draw(in: webFrame)
            if let bar { bar.image.draw(in: bar.frame) }
            picture.unlockFocus()
            completion(picture)
        }
    }

    // MARK: Showing and hiding

    /// Control-Option-Y and the menu: open the dropdown; close it (a playing video
    /// pops out); from the mini player, back to the dropdown.
    func toggle() {
        switch place {
        case .hidden: showDropdown()
        case .dropdown: closeDropdown()
        case .mini: expand()
        }
    }

    func play(_ link: (id: String, start: Int?)) {
        if place == .mini { expand() } else if place == .hidden { showDropdown() }
        loaded = true
        web.load(URLRequest(url: YouTubeLink.watchURL(id: link.id, start: link.start)))
    }

    func showDropdown() {
        if !loaded {
            loaded = true
            web.load(URLRequest(url: YouTubeLink.home))
        }
        attachWeb(to: webHolder)
        let (screen, maxX) = anchor()
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = PlayerGeometry.dropdown(visible: visible, anchorMaxX: maxX)
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        dropdown.setFrame(frame.offsetBy(dx: 0, dy: 10), display: false)
        dropdown.alphaValue = 0
        dropdown.makeKeyAndOrderFront(nil)
        dropdown.makeFirstResponder(web)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            dropdown.animator().setFrame(frame, display: true)
            dropdown.animator().alphaValue = 1
        }
        mini.orderOut(nil)
        place = .dropdown
        watchOutsideClicks(true)
        onChange?()
    }

    /// Closing the dropdown while a video plays moves it to the mini player.
    func closeDropdown() {
        guard place == .dropdown else { return }
        if playing { popOut() } else { hideAll() }
    }

    /// Pops the video out into the floating mini player, if there is one.
    func popOut() {
        web.evaluateJavaScript("window.__hammer ? window.__hammer.mini(true) : false") { result, _ in
            let hadVideo = (result as? Bool) == true
            Task { @MainActor [weak self] in self?.finishPopOut(hadVideo: hadVideo) }
        }
    }

    private func finishPopOut(hadVideo: Bool) {
        guard place == .dropdown else { return }
        guard hadVideo else { hideAll(); return }
        attachWeb(to: mini.contentView!, below: overlay)
        let visible = (dropdown.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let frame = miniFrame.map { PlayerGeometry.clamp($0, in: visible) } ?? PlayerGeometry.miniDefault(visible: visible)
        mini.setFrame(frame, display: true)
        mini.orderFrontRegardless()
        dropdown.orderOut(nil)
        watchOutsideClicks(false)
        place = .mini
        NSApp.deactivate()                                   // back to what you were doing
        overlay.flash()
        onChange?()
    }

    /// From the mini player back to the dropdown.
    func expand() {
        web.evaluateJavaScript("window.__hammer && window.__hammer.mini(false)", completionHandler: nil)
        showDropdown()
    }

    /// The mini player's ✕: pauses and puts it away.
    func closeMini() {
        web.evaluateJavaScript("window.__hammer && (window.__hammer.pause(), window.__hammer.mini(false))",
                               completionHandler: nil)
        hideAll()
    }

    private func hideAll() {
        dropdown.orderOut(nil)
        mini.orderOut(nil)
        attachWeb(to: webHolder)
        watchOutsideClicks(false)
        place = .hidden
        onChange?()
    }

    private func attachWeb(to holder: NSView, below other: NSView? = nil) {
        guard web.superview !== holder else { return }
        web.removeFromSuperview()
        web.frame = holder.bounds
        if let other { holder.addSubview(web, positioned: .below, relativeTo: other) } else { holder.addSubview(web) }
    }

    /// While the dropdown is open, a click in another app (or switching apps) closes it, unless pinned.
    private func watchOutsideClicks(_ on: Bool) {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        clickMonitor = nil
        guard on else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor [weak self] in self?.clickedOutside() }
        }
    }

    private func clickedOutside() {
        if place == .dropdown && !pinned { closeDropdown() }
    }

    @objc private func appResigned() {
        if place == .dropdown && !pinned { closeDropdown() }
    }

    @objc private func screensChanged() {
        guard place == .mini, let visible = (mini.screen ?? NSScreen.main)?.visibleFrame else { return }
        let fixed = PlayerGeometry.clamp(mini.frame, in: visible)
        if fixed != mini.frame { mini.setFrame(fixed, display: true) }
        miniFrame = fixed
    }

    // MARK: From the page

    fileprivate func received(_ body: Any) {
        guard let report = body as? [String: Any] else { return }
        playing = report["playing"] as? Bool ?? false
        hasVideo = report["hasVideo"] as? Bool ?? false
        let pageTitle = report["title"] as? String ?? ""
        title = pageTitle.hasSuffix(" - YouTube") ? String(pageTitle.dropLast(10)) : pageTitle
        titleLabel.stringValue = title.isEmpty ? "YouTube" : title
        popOutButton.isEnabled = hasVideo
        overlay.setPlaying(playing)
        if place == .mini {
            // YouTube moves on to the next video in the same page: keep showing it.
            web.evaluateJavaScript("window.__hammer && window.__hammer.mini(true)", completionHandler: nil)
        }
        backButton.isEnabled = web.canGoBack
        onChange?()
    }

    // MARK: Pages: YouTube stays in the player, everything else opens in your browser

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async
        -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, navigationAction.targetFrame?.isMainFrame != false else {
            return .allow
        }
        if PlayerNavigation.decide(url) == .openInBrowser {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }

    /// Links that ask for a new window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if PlayerNavigation.decide(url) == .stay { webView.load(navigationAction.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        backButton.isEnabled = webView.canGoBack
    }

    // MARK: The dropdown

    private func buildDropdown() {
        let size = PlayerGeometry.dropdownSize
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        dropdown.contentView = background
        dropdown.setContentSize(size)
        dropdown.onEscape = { [weak self] in self?.closeDropdown() }

        let header = NSView(frame: NSRect(x: 0, y: size.height - 40, width: size.width, height: 40))
        header.autoresizingMask = [.width, .minYMargin]
        backButton = iconButton("chevron.left", "Back", #selector(goBack))
        let home = iconButton("house", "YouTube home", #selector(goHome))
        let browser = iconButton("safari", "Open in your browser", #selector(openInBrowser))
        popOutButton = iconButton("pip.exit", "Pop out into the mini player", #selector(popOutPressed))
        pinButton = iconButton("pin", "Keep open when you click elsewhere", #selector(togglePin))
        let close = iconButton("xmark", "Close (Esc)", #selector(closePressed))
        backButton.isEnabled = false
        popOutButton.isEnabled = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [backButton, home, titleLabel, browser, popOutButton, pinButton, close])
        row.orientation = .horizontal
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.setCustomSpacing(8, after: home)
        row.setCustomSpacing(8, after: titleLabel)
        row.frame = header.bounds
        row.autoresizingMask = [.width, .height]
        header.addSubview(row)

        let line = NSBox(frame: NSRect(x: 0, y: size.height - 41, width: size.width, height: 1))
        line.boxType = .separator
        line.autoresizingMask = [.width, .minYMargin]

        webHolder.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - 41)
        webHolder.autoresizingMask = [.width, .height]
        background.addSubview(webHolder)
        background.addSubview(line)
        background.addSubview(header)
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: tip)!
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.setButtonType(.momentaryChange)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    @objc private func goBack() { if web.canGoBack { web.goBack() } }
    @objc private func goHome() { web.load(URLRequest(url: YouTubeLink.home)) }
    @objc private func openInBrowser() {
        if let url = web.url { NSWorkspace.shared.open(url) }
        web.evaluateJavaScript("window.__hammer && window.__hammer.pause()", completionHandler: nil)
    }
    @objc private func popOutPressed() { popOut() }
    @objc private func closePressed() { closeDropdown() }
    @objc private func togglePin() {
        pinned.toggle()
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: "Pin")
        pinButton.contentTintColor = pinned ? .controlAccentColor : .secondaryLabelColor
    }

    // MARK: The mini player

    private func buildMini() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 225))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        mini.contentView = content
        mini.backgroundColor = .black
        mini.contentAspectRatio = NSSize(width: 16, height: 9)
        mini.minSize = NSSize(width: PlayerGeometry.minMiniWidth, height: PlayerGeometry.minMiniWidth * 9 / 16)
        mini.delegate = self
        mini.onEscape = { [weak self] in self?.closeMini() }
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay)
        overlay.onToggle = { [weak self] in
            self?.web.evaluateJavaScript("window.__hammer && window.__hammer.toggle()", completionHandler: nil)
        }
        overlay.onSeek = { [weak self] seconds in
            self?.web.evaluateJavaScript("window.__hammer && window.__hammer.seek(\(seconds))", completionHandler: nil)
        }
        overlay.onExpand = { [weak self] in self?.expand() }
        overlay.onClose = { [weak self] in self?.closeMini() }
    }

    /// After you drag the mini player, it settles into the nearest corner.
    func windowDidMove(_ notification: Notification) {
        guard place == .mini, (notification.object as? NSWindow) === mini else { return }
        snapTimer?.invalidate()
        snapTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
            Task { @MainActor [weak self] in self?.snapMini() }
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mini else { return }
        snapMini()
    }

    private func snapMini() {
        guard place == .mini, NSEvent.pressedMouseButtons == 0,
              let visible = (mini.screen ?? NSScreen.main)?.visibleFrame else { return }
        let snapped = PlayerGeometry.snap(mini.frame, in: visible)
        miniFrame = snapped
        guard snapped != mini.frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            mini.animator().setFrame(snapped, display: true)
        }
    }
}

/// The mini player's controls: they appear while the pointer is over it. Drag
/// anywhere to move it; double-click to go back to the dropdown.
final class MiniOverlay: NSView {
    var onToggle: (() -> Void)?
    var onSeek: ((Int) -> Void)?
    var onExpand: (() -> Void)?
    var onClose: (() -> Void)?

    private let bar = NSVisualEffectView()
    private var playButton: NSButton!
    private var tracking: NSTrackingArea?
    private var downEvent: NSEvent?
    private var dragging = false
    private var hideTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 10
        bar.layer?.masksToBounds = true
        bar.appearance = NSAppearance(named: .darkAqua)

        playButton = button("play.fill", "Play or pause") { [weak self] in self?.onToggle?() }
        let back = button("gobackward.10", "Back 10 seconds") { [weak self] in self?.onSeek?(-10) }
        let forward = button("goforward.10", "Forward 10 seconds") { [weak self] in self?.onSeek?(10) }
        let expand = button("arrow.up.left.and.arrow.down.right", "Back to the dropdown") { [weak self] in self?.onExpand?() }
        let close = button("xmark", "Close") { [weak self] in self?.onClose?() }
        let row = NSStackView(views: [back, playButton, forward, expand, close])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        bar.alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var actions: [ObjectIdentifier: () -> Void] = [:]

    private func button(_ symbol: String, _ tip: String, _ action: @escaping () -> Void) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: tip)!
        let button = NSButton(image: image, target: self, action: #selector(pressed(_:)))
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = .white
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        actions[ObjectIdentifier(button)] = action
        return button
    }

    @objc private func pressed(_ sender: NSButton) { actions[ObjectIdentifier(sender)]?() }

    /// The controls as a picture, where they sit (for the self-test's snapshot).
    func barImage() -> (image: NSImage, frame: NSRect)? {
        guard bar.bounds.width > 0, let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) else { return nil }
        bar.cacheDisplay(in: bar.bounds, to: rep)
        let image = NSImage(size: bar.bounds.size)
        image.addRepresentation(rep)
        return (image, bar.frame)
    }

    func setPlaying(_ playing: Bool) {
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
                                   accessibilityDescription: "Play or pause")
    }

    /// Shows the controls for a moment (when the player first appears).
    func flash() {
        show(true)
        scheduleHide()
    }

    private func show(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            bar.animator().alphaValue = on ? 1 : 0
        }
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                let inside = self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil))
                if !inside { self.show(false) }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hideTimer?.invalidate(); show(true) }
    override func mouseExited(with event: NSEvent) { show(false) }

    /// Buttons get their clicks; everywhere else is for moving the window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton { return current }
            view = current.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        dragging = false
        downEvent = event
        if event.clickCount == 2 { onExpand?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let down = downEvent else { return }
        dragging = true
        window?.performDrag(with: down)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Self-test (`Hammer player-check <folder>`, run by the macOS build check)

/// Opens the player on a real YouTube video, pops it out, checks only the video
/// shows, comes back, and saves pictures of both windows. Exits 0 if all went well.
@MainActor
final class PlayerCheck: NSObject, NSApplicationDelegate {
    private let folder: URL
    private var failed = false
    private lazy var player = YouTubePlayer(anchor: { (NSScreen.main, nil) })

    init(folder: URL) { self.folder = folder }

    static func run(_ args: [String]) -> Never {
        let folder = URL(fileURLWithPath: args.count >= 2 ? args[1] : NSTemporaryDirectory() + "hammer-player-check")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let check = PlayerCheck(folder: folder)
        app.delegate = check
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(check) { app.run() }
        exit(1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await self.steps() }
    }

    private func note(_ text: String) { print(text); fflush(stdout) }

    private func expect(_ ok: Bool, _ what: String) {
        note((ok ? "  ok   " : "  FAIL ") + what)
        if !ok { failed = true }
    }

    private func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return condition()
    }

    private func save(_ name: String) async {
        let image: NSImage? = await withCheckedContinuation { continuation in
            player.snapshot { continuation.resume(returning: $0) }
        }
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            note("  (no picture of \(name))")
            return
        }
        try? png.write(to: folder.appendingPathComponent(name + ".png"))
        note("  saved \(name).png")
    }

    private func steps() async {
        note("YouTube player check")
        expect(YouTubePlayer.scriptURL != nil, "PlayerScript.js found")
        player.play((id: "jNQXAC9IVRw", start: nil))                  // "Me at the zoo", 19 s
        expect(player.place == .dropdown, "the dropdown opens")
        let video = await wait(40) { self.player.hasVideo }
        expect(video, "the page script sees the video")
        let titled = await wait(10) { self.player.title.lowercased().contains("zoo") }
        expect(titled, "it knows the title: \(player.title)")
        _ = await player.evaluateBool("window.__hammer ? window.__hammer.toggle() : false")
        let playing = await wait(20) { self.player.playing }
        note(playing ? "  ok   it plays" : "  note it didn't start playing here (fine on a server with no sound)")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await save("dropdown")

        player.popOut()
        let popped = await wait(5) { self.player.place == .mini }
        expect(popped, "it pops out into the mini player")
        let onlyVideo = await player.evaluateBool("document.documentElement.classList.contains('hammer-mini')")
        expect(onlyVideo == true, "the mini player shows only the video")
        // On YouTube's real page: the video fills the window and nothing covers it.
        let fills = await player.evaluateBool("""
            (() => { const v = document.querySelector('video[data-hammer-main]'); if (!v) return false;
              const r = v.getBoundingClientRect();
              const at = (x, y) => document.elementFromPoint(x, y) === v;
              return r.width >= innerWidth - 1 && r.height >= innerHeight - 1
                && at(innerWidth / 2, innerHeight / 2) && at(5, 5) && at(innerWidth - 5, innerHeight - 5); })()
            """)
        expect(fills == true, "the video fills the mini player, nothing on top")
        if fills != true {
            let details = await player.evaluateString("""
                (() => { const v = document.querySelector('video[data-hammer-main]'); if (!v) return 'no marked video';
                  const r = v.getBoundingClientRect(), cs = getComputedStyle(v);
                  const name = (e) => e ? e.tagName.toLowerCase() + (e.id ? '#' + e.id : '') + (e.className && e.className.baseVal === undefined ? '.' + String(e.className).split(' ').slice(0, 2).join('.') : '') : 'none';
                  const traps = [];
                  for (let e = v.parentElement; e; e = e.parentElement) { const s = getComputedStyle(e);
                    const t = [s.transform !== 'none' && 'transform', s.filter !== 'none' && 'filter', s.contain !== 'none' && 'contain:' + s.contain,
                      s.willChange !== 'auto' && 'will-change:' + s.willChange, s.containerType && s.containerType !== 'normal' && 'container:' + s.containerType,
                      s.perspective !== 'none' && 'perspective'].filter(Boolean);
                    if (t.length) traps.push(name(e) + '(' + t.join(',') + ')'); }
                  return JSON.stringify({ rect: [r.x, r.y, r.width, r.height].map(Math.round), viewport: [innerWidth, innerHeight],
                    position: cs.position, visibility: cs.visibility, pointer: cs.pointerEvents, display: cs.display,
                    center: name(document.elementFromPoint(innerWidth / 2, innerHeight / 2)),
                    corner: name(document.elementFromPoint(5, 5)), traps }); })()
                """)
            note("       details: \(details ?? "none")")
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await save("mini")

        player.expand()
        expect(player.place == .dropdown, "back to the dropdown")
        try? await Task.sleep(nanoseconds: 500_000_000)
        let normal = await player.evaluateBool("document.documentElement.classList.contains('hammer-mini')")
        expect(normal == false, "the page looks normal again")

        player.popOut()
        _ = await wait(5) { self.player.place == .mini }
        player.closeMini()
        expect(player.place == .hidden, "closing the mini player puts it away")
        let paused = await player.evaluateBool("(() => { const v = document.querySelector('video'); return !v || v.paused })()")
        expect(paused == true, "and pauses the video")

        note(failed ? "Some checks failed." : "All player checks passed.")
        exit(failed ? 1 : 0)
    }
}
