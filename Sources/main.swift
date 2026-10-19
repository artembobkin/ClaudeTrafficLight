// Claude Traffic Light: a floating panel with one lamp per Claude Code session, each
// labelled with the session, so you see which agent works, which one waits for you
// and which one is done.
//
// It draws nothing on its own authority: the state comes from the files that the
// Claude Code hooks write into ~/.claude/traffic-light/sessions/, one file per session.
// The app watches that directory. Each lamp:
//   red     the session is working
//   yellow  the session asks for input (permission, question, elicitation)
//   green   the session is idle, the agent finished and waits for a prompt
// A session whose claude process has exited is dropped, so a crash leaves no stale lamp.
// The label is the project folder (or the session title set with /rename, which the
// SessionStart hook receives) followed by the last message you sent to that session,
// which the UserPromptSubmit hook receives, cut to one line.
//
// The panel is borderless, stays above every window and on every Space, never takes the
// focus away from the app you work in, and can be dragged anywhere. Its position is
// remembered. A right click opens the menu with Quit.

import AppKit

enum SessionState: String {
    case working
    case attention
    case idle

    var color: NSColor {
        switch self {
        case .working: return NSColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1)
        case .attention: return NSColor(red: 1.00, green: 0.80, blue: 0.10, alpha: 1)
        case .idle: return NSColor(red: 0.25, green: 0.90, blue: 0.40, alpha: 1)
        }
    }

    var label: String {
        switch self {
        case .working: return "working"
        case .attention: return "needs you"
        case .idle: return "done"
        }
    }
}

struct Session {
    let id: String
    let state: SessionState
    let pid: Int32
    let cwd: String
    let title: String
    let prompt: String
    let updated: Date

    var folder: String { (cwd as NSString).lastPathComponent }
}

final class SessionStore {
    let directory: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        directory = home.appendingPathComponent(".claude/traffic-light/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Reads every session file, drops the ones whose claude process is gone and
    /// deletes their files so the directory does not grow. Oldest session first, so
    /// a row keeps its place while newer sessions are added below it.
    func liveSessions() -> [Session] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var sessions: [Session] = []
        for name in names where !name.contains(".tmp.") {
            let url = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var fields: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
            guard let state = fields["state"].flatMap(SessionState.init(rawValue:)) else { continue }
            let pid = fields["pid"].flatMap { Int32($0) } ?? 0
            let updated = fields["updated"].flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:)) ?? Date()
            if pid > 0 && !Self.isAlive(pid) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // A file without a pid (the process was not found) is kept for a day at most.
            if pid <= 0 && Date().timeIntervalSince(updated) > 24 * 3600 {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? updated
            sessions.append(Session(
                id: name, state: state, pid: pid, cwd: fields["cwd"] ?? "",
                title: fields["title"] ?? "", prompt: fields["prompt"] ?? "", updated: created
            ))
        }
        return sessions.sorted { $0.updated < $1.updated }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// One row per session: a lamp and the session's name.
@MainActor
final class LampListView: NSView {
    static let minWidth: CGFloat = 160
    static let maxWidth: CGFloat = 700
    static let rowHeight: CGFloat = 26
    static let padding: CGFloat = 6
    static let lampColumn: CGFloat = 30
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let prefixFont = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let detailFont = NSFont.systemFont(ofSize: 10, weight: .regular)
    static let emptyText = "no Claude session"
    /// The last message is cut to this many characters on the panel.
    static let promptLength = 60

    var sessions: [Session] = [] {
        didSet { needsDisplay = true }
    }
    var menuProvider: (() -> NSMenu)?

    override var mouseDownCanMoveWindow: Bool { true }

    static func height(forRows rows: Int) -> CGFloat {
        CGFloat(max(rows, 1)) * rowHeight + 2 * padding
    }

    /// Wide enough that every row's label and state fit without truncation.
    static func width(for sessions: [Session]) -> CGFloat {
        var widest: CGFloat = textWidth(emptyText, font: labelFont)
        for (session, label) in zip(sessions, labels(for: sessions)) {
            let row = textWidth(label.prefix, font: prefixFont) + textWidth(label.text, font: labelFont)
                + 10 + textWidth(session.state.label, font: detailFont)
            widest = max(widest, row)
        }
        return min(max(ceil(widest) + 2 * padding + lampColumn + 8, minWidth), maxWidth)
    }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor(white: 0.12, alpha: 0.94).setFill()
        card.fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        card.lineWidth = 1
        card.stroke()

        let labels = Self.labels(for: sessions)
        let font = Self.labelFont
        let detailFont = Self.detailFont
        var y = bounds.height - Self.padding - Self.rowHeight

        if sessions.isEmpty {
            drawLamp(at: NSPoint(x: Self.padding + 13, y: y + Self.rowHeight / 2), color: NSColor(white: 0.4, alpha: 1))
            Self.draw(Self.emptyText, font: font, color: NSColor(white: 0.55, alpha: 1),
                      in: NSRect(x: Self.padding + Self.lampColumn, y: y, width: bounds.width - Self.lampColumn - 2 * Self.padding, height: Self.rowHeight))
            return
        }

        for (session, label) in zip(sessions, labels) {
            let row = NSRect(x: Self.padding, y: y, width: bounds.width - 2 * Self.padding, height: Self.rowHeight)
            drawLamp(at: NSPoint(x: row.minX + 13, y: row.midY), color: session.state.color)
            let detail = session.state.label
            let detailWidth = ceil(Self.textWidth(detail, font: detailFont)) + 4
            let prefixWidth = ceil(Self.textWidth(label.prefix, font: Self.prefixFont))
            let textX = row.minX + Self.lampColumn
            Self.draw(label.prefix, font: Self.prefixFont, color: NSColor(white: 0.6, alpha: 1),
                      in: NSRect(x: textX, y: row.minY, width: prefixWidth, height: row.height))
            Self.draw(label.text, font: font, color: .white,
                      in: NSRect(x: textX + prefixWidth, y: row.minY, width: row.width - Self.lampColumn - prefixWidth - detailWidth, height: row.height))
            Self.draw(detail, font: detailFont, color: session.state.color, alignment: .right,
                      in: NSRect(x: row.maxX - detailWidth, y: row.minY, width: detailWidth, height: row.height))
            y -= Self.rowHeight
        }
    }

    private func drawLamp(at center: NSPoint, color: NSColor) {
        let diameter: CGFloat = 14
        let rect = NSRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    private static func draw(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let height = font.ascender - font.descender
        let textRect = NSRect(x: rect.minX, y: rect.midY - height / 2 - 1, width: rect.width, height: height + 2)
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    struct RowLabel {
        let prefix: String
        let text: String
    }

    /// The project folder (or the session title when one is set) and the last message
    /// sent to the session, cut to one line. Before a message is seen, two sessions
    /// with the same folder get the start of their id so they can be told apart.
    static func labels(for sessions: [Session]) -> [RowLabel] {
        let names = sessions.map { $0.title.isEmpty ? $0.folder : $0.title }
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return zip(sessions, names).map { session, name in
            if session.prompt.isEmpty {
                return RowLabel(prefix: "", text: counts[name, default: 0] > 1 ? "\(name) · \(session.id.prefix(4))" : name)
            }
            return RowLabel(prefix: name + "  ", text: shortened(session.prompt))
        }
    }

    static func shortened(_ prompt: String) -> String {
        if prompt.count <= promptLength { return prompt }
        return String(prompt.prefix(promptLength)).trimmingCharacters(in: .whitespaces) + "…"
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = SessionStore()
    private var panel: NSPanel!
    private var listView: LampListView!
    private var directorySource: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var sessions: [Session] = []
    private let positionKey = "trafficLightTopLeft"

    func applicationDidFinishLaunching(_ notification: Notification) {
        makePanel()
        watchDirectory()
        // The directory watcher misses nothing the hooks write, the timer catches a
        // claude process that died without a SessionEnd hook.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private func makePanel() {
        let size = NSSize(width: LampListView.width(for: []), height: LampListView.height(forRows: 1))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        listView = LampListView(frame: NSRect(origin: .zero, size: size))
        listView.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        panel.contentView = listView
        self.panel = panel

        panel.setFrameTopLeftPoint(restoredTopLeft(for: size))
        panel.delegate = self
        panel.orderFrontRegardless()
    }

    /// The saved top left corner when it is still on a screen, otherwise the top right
    /// corner of the main screen under the menu bar. The top left corner is what stays
    /// put when the list grows or shrinks.
    private func restoredTopLeft(for size: NSSize) -> NSPoint {
        if let saved = UserDefaults.standard.string(forKey: positionKey) {
            let topLeft = NSPointFromString(saved)
            let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                return topLeft
            }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - 16)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: positionKey)
    }

    private func watchDirectory() {
        let descriptor = open(store.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directorySource = source
    }

    private func refresh() {
        sessions = store.liveSessions()
        listView.sessions = sessions
        listView.toolTip = sessions.isEmpty ? nil : sessions.map { session in
            let name = session.title.isEmpty ? session.folder : session.title
            return session.prompt.isEmpty ? name : "\(name): \(session.prompt)"
        }.joined(separator: "\n\n")
        let size = NSSize(width: LampListView.width(for: sessions), height: LampListView.height(forRows: sessions.count))
        if panel.frame.size != size {
            // The top left corner stays put, unless the wider panel would leave the screen.
            var frame = NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height)
            if let screen = panel.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
                if frame.minX < visible.minX { frame.origin.x = visible.minX }
                if frame.minY < visible.minY { frame.origin.y = visible.minY }
            }
            panel.setFrame(frame, display: true)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let reset = NSMenuItem(title: "Move to Top Right Corner", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Claude Traffic Light", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: positionKey)
        panel.setFrameTopLeftPoint(restoredTopLeft(for: panel.frame.size))
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@main
struct ClaudeTrafficLightApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
