import AppKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - Matching

/// Lowercased search keys for a name: the name itself, its pinyin/latin form, and word initials.
func matchKeys(_ name: String) -> [String] {
    let lower = name.lowercased()
    let m = NSMutableString(string: name)
    CFStringTransform(m, nil, kCFStringTransformToLatin, false)
    CFStringTransform(m, nil, kCFStringTransformStripDiacritics, false)
    let latin = (m as String).lowercased()
    let words = latin.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    let initials = String(words.compactMap(\.first))
    return Array(Set([lower, latin, words.joined(), initials]))
}

func score(_ q: String, _ s: String) -> Int? {
    if s == q { return 1000 }
    if s.hasPrefix(q) { return 500 }
    if s.contains(" " + q) { return 300 }
    if s.contains(q) { return 200 }
    var i = s.startIndex
    for c in q {
        guard let f = s[i...].firstIndex(of: c) else { return nil }
        i = s.index(after: f)
    }
    return 100
}

// MARK: - Items

final class Item {
    let title: String
    let subtitle: String
    let keys: [String]
    let action: () -> Void
    /// Bundle that can be moved to the Trash from the results list (nil for commands and system apps).
    let trashURL: URL?
    private let makeIcon: () -> NSImage
    lazy var icon: NSImage = makeIcon()

    init(title: String, subtitle: String, aliases: [String] = [], icon: @escaping () -> NSImage, trashURL: URL? = nil, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.keys = Array(Set(([title] + aliases).flatMap(matchKeys)))
        self.makeIcon = icon
        self.action = action
        self.trashURL = trashURL
    }
}

enum AppIndex {
    static let roots = ["/Applications", "/System/Applications", "~/Applications"]
    static let extras = ["/System/Library/CoreServices/Finder.app"]

    static func scan() -> [Item] {
        let fm = FileManager.default
        var seen = Set<String>()
        var urls: [URL] = extras.map { URL(fileURLWithPath: $0) }
        for root in roots {
            let url = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
            guard let e = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in e {
                if u.pathExtension == "app" {
                    urls.append(u)
                    e.skipDescendants()
                    // Helper apps embedded in bundles (e.g. Xcode's DeviceHub, Instruments).
                    let nested = u.appendingPathComponent("Contents/Applications")
                    if let inner = try? fm.contentsOfDirectory(at: nested, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                        urls += inner.filter { $0.pathExtension == "app" }
                    }
                } else if e.level >= 2 {
                    e.skipDescendants()
                }
            }
        }
        return urls.compactMap { url in
            guard seen.insert(url.path).inserted else { return nil }
            let file = url.deletingPathExtension().lastPathComponent
            let display = (fm.displayName(atPath: url.path) as NSString).deletingPathExtension
            return Item(title: display, subtitle: url.path, aliases: [file],
                        icon: { NSWorkspace.shared.icon(forFile: url.path) },
                        trashURL: url.path.hasPrefix("/System/") ? nil : url,
                        action: { NSWorkspace.shared.openApplication(at: url, configuration: .init()) })
        }
    }
}

// MARK: - Caffeinate

final class Caffeinate {
    private var process: Process?
    var onChange: (() -> Void)?
    var isOn: Bool { process?.isRunning == true }

    func toggle() { isOn ? stop() : start() }

    func start() {
        guard !isOn else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w: caffeinate exits by itself if Launcher dies.
        p.arguments = ["-dims", "-w", String(getpid())]
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.onChange?() } }
        try? p.run()
        process = p
        onChange?()
    }

    func stop() {
        process?.terminate()
        process = nil
        onChange?()
    }
}

// MARK: - Global hotkey

final class HotKey {
    nonisolated(unsafe) private static var handler: (() -> Void)?
    private var ref: EventHotKeyRef?

    init?(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        HotKey.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4C4E4348), id: 1)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { return nil }
    }
}

// MARK: - UI

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The table refuses first responder (the search field keeps focus), which stops it from
/// forwarding clicks to buttons inside its cells, so route trash-button clicks by hand.
final class ResultsTable: NSTableView {
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let row = self.row(at: p)
        if row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell,
           !cell.trash.isHidden, cell.trash.bounds.contains(cell.trash.convert(event.locationInWindow, from: nil)) {
            cell.onTrash?()
            return
        }
        super.mouseDown(with: event)
    }
}

final class RowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
}

final class Cell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let sub = NSTextField(labelWithString: "")
    let trash = NSButton()
    var onTrash: (() -> Void)?

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 15)
        title.lineBreakMode = .byTruncatingTail
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingMiddle
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .labelColor
        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Move to Trash")
        trash.isBordered = false
        trash.bezelStyle = .regularSquare
        trash.contentTintColor = .labelColor
        trash.toolTip = "Move to Trash"
        trash.target = self
        trash.action = #selector(trashClicked)
        trash.isHidden = true
        for v in [icon, title, sub, trash] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trash.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trash.leadingAnchor, constant: -8),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            trash.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trash.centerYAnchor.constraint(equalTo: centerYAnchor),
            trash.widthAnchor.constraint(equalToConstant: 28),
            trash.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func trashClicked() { onTrash?() }

    required init?(coder: NSCoder) { fatalError() }
}

final class LauncherController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let width: CGFloat = 680, header: CGFloat = 56, rowH: CGFloat = 46, maxRows = 8

    private let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let field = NSTextField()
    private let table = ResultsTable()
    private let scroll = NSScrollView()
    private let commands: () -> [Item]
    private var apps: [Item] = []
    private var results: [Item] = []
    private var anchorTop: CGFloat = 0
    private var screenFrame = NSRect.zero
    private var confirming = false

    init(commands: @escaping () -> [Item]) {
        self.commands = commands
        super.init()

        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .light)
        field.placeholderString = "Search apps and commands…"
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        bg.addSubview(field)

        let col = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = rowH
        table.style = .inset
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(runSelected)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        bg.addSubview(scroll)

        reindex()
    }

    func reindex() {
        DispatchQueue.global(qos: .userInitiated).async {
            let items = AppIndex.scan()
            DispatchQueue.main.async { self.apps = items }
        }
    }

    // isVisible can be true while the window server never actually showed the panel,
    // so key status is the reliable "is it open" signal (we hide on resign key anyway).
    func toggle() { panel.isKeyWindow ? hide() : show() }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        screenFrame = screen.visibleFrame
        anchorTop = screenFrame.maxY - screenFrame.height * 0.2
        field.stringValue = ""
        refresh()
        // makeKeyAndOrderFront only orders front "conditionally" while another app is
        // active, which the window server sometimes refuses; force it.
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)
        reindex()
    }

    func hide() { panel.orderOut(nil) }

    private func refresh() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            results = []
        } else {
            results = (commands() + apps)
                .compactMap { item -> (Item, Int)? in
                    guard let s = item.keys.compactMap({ score(q, $0) }).max() else { return nil }
                    return (item, s)
                }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.count < $1.0.title.count }
                .prefix(30)
                .map(\.0)
        }
        table.reloadData()
        if !results.isEmpty { select(0) }
        layout()
    }

    private func layout() {
        let rows = min(results.count, maxRows)
        let listH = rows > 0 ? CGFloat(rows) * rowH + 12 : 0
        let h = header + listH
        panel.setFrame(NSRect(x: screenFrame.midX - width / 2, y: anchorTop - h, width: width, height: h), display: true)
        field.frame = NSRect(x: 18, y: h - header + (header - 32) / 2, width: width - 36, height: 32)
        scroll.frame = NSRect(x: 0, y: 6, width: width, height: max(0, listH - 6))
        scroll.isHidden = rows == 0
    }

    private func select(_ row: Int) {
        guard !results.isEmpty else { return }
        let r = (row + results.count) % results.count
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc private func runSelected() {
        let r = table.selectedRow
        guard results.indices.contains(r) else { return }
        let item = results[r]
        hide()
        item.action()
    }

    private func trash(_ item: Item) {
        guard let url = item.trashURL else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(item.title)” to the Trash?"
        alert.informativeText = url.path
        alert.icon = item.icon
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        // The alert takes key status from the panel; don't treat that as "dismissed".
        confirming = true
        NSApp.activate(ignoringOtherApps: true)
        let ok = alert.runModal() == .alertFirstButtonReturn
        confirming = false
        panel.makeKey()
        panel.makeFirstResponder(field)
        guard ok else { return }
        NSLog("Launcher: moving \(url.path) to Trash")
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    NSLog("Launcher: could not move \(url.path) to Trash: \(error)")
                    NSSound.beep()
                    return
                }
                let row = self.table.selectedRow
                self.apps.removeAll { $0 === item }
                self.results.removeAll { $0 === item }
                self.table.reloadData()
                if !self.results.isEmpty { self.select(min(row, self.results.count - 1)) }
                self.layout()
            }
        }
    }

    private func updateTrashButtons() {
        let selected = table.selectedRow
        table.enumerateAvailableRowViews { rowView, row in
            guard let cell = rowView.view(atColumn: 0) as? Cell, results.indices.contains(row) else { return }
            cell.trash.isHidden = row != selected || results[row].trashURL == nil
        }
    }

    // MARK: Text field

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1)
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty { hide() } else { field.stringValue = ""; refresh() }
        default: return false
        }
        return true
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? Cell ?? {
            let c = Cell()
            c.identifier = .init("cell")
            return c
        }()
        let item = results[row]
        cell.icon.image = item.icon
        cell.title.stringValue = item.title
        cell.sub.stringValue = item.subtitle
        cell.trash.isHidden = row != tableView.selectedRow || item.trashURL == nil
        cell.onTrash = { [weak self] in self?.trash(item) }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateTrashButtons() }

    // MARK: Window

    func windowDidResignKey(_ notification: Notification) { if !confirming { hide() } }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let caffeinate = Caffeinate()
    private var controller: LauncherController!
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?

    private var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = editMenu()
        controller = LauncherController(commands: { [unowned self] in commands() })
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        caffeinate.onChange = { [unowned self] in updateStatusItem() }
        updateStatusItem()

        hotKey = HotKey(keyCode: kVK_Space, modifiers: cmdKey) { [unowned self] in controller.toggle() }
        if hotKey == nil { NSLog("Launcher: failed to register ⌘Space") }
        if CommandLine.arguments.contains("--show") { controller.show() }
    }

    func applicationWillTerminate(_ notification: Notification) { caffeinate.stop() }

    private func commands() -> [Item] {
        let symbol = { (name: String) in { NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage() } }
        let awake = caffeinate.isOn
        let login = loginEnabled
        return [
            Item(title: awake ? "Turn Off Keep Awake" : "Turn On Keep Awake",
                 subtitle: awake ? "caffeinate is running — press Return to stop" : "Prevent display and system sleep (caffeinate -dims)",
                 aliases: ["awake", "caffeinate", "coffee", "保持唤醒", "不锁屏", "防休眠"],
                 icon: symbol(awake ? "cup.and.saucer.fill" : "cup.and.saucer"),
                 action: { [unowned self] in caffeinate.toggle() }),
            Item(title: login ? "Disable Launch at Login" : "Enable Launch at Login",
                 subtitle: "Start Launcher automatically when you log in",
                 aliases: ["login", "startup", "开机启动"],
                 icon: symbol("power.circle"),
                 action: { [unowned self] in toggleLogin() }),
            Item(title: "Quit Launcher", subtitle: "", aliases: ["exit", "退出"],
                 icon: symbol("xmark.circle"),
                 action: { NSApp.terminate(nil) }),
        ]
    }

    private func toggleLogin() {
        do {
            if loginEnabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Launcher: login item error: \(error)")
        }
        updateStatusItem()
    }

    private func updateStatusItem() {
        let awake = caffeinate.isOn
        statusItem.button?.image = NSImage(systemSymbolName: awake ? "cup.and.saucer.fill" : "magnifyingglass",
                                           accessibilityDescription: "Launcher")
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Launcher  ⌘Space", action: #selector(showLauncher), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let awakeItem = menu.addItem(withTitle: "Keep Awake", action: #selector(toggleAwake), keyEquivalent: "")
        awakeItem.target = self
        awakeItem.state = awake ? .on : .off
        let loginItem = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLoginMenu), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = loginEnabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func showLauncher() { controller.show() }
    @objc private func toggleAwake() { caffeinate.toggle() }
    @objc private func toggleLoginMenu() { toggleLogin() }

    /// Without a main menu, ⌘C/⌘V/⌘A don't reach the search field.
    private func editMenu() -> NSMenu {
        let main = NSMenu()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        main.addItem(item)
        return main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
