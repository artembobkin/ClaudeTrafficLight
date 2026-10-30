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
// Under the lamps are the usage limits of the Claude subscription (the 5-hour window
// and the weekly one): how much is used and when it resets. Claude Code hands them to
// the status line command, statusline.sh writes them into ~/.claude/traffic-light/limits/.
// Nothing goes over the network.
//
// The panel is borderless, stays above every window and on every Space, never takes the
// focus away from the app you work in, and can be dragged anywhere. Its position is
// remembered. A right click opens the menu with Quit.

import AppKit
import Darwin

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
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            // The folder was removed under the app, for example by uninstall.sh. Bring it
            // back so the hooks and the watcher have something to write to and watch.
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return []
        }
        var sessions: [Session] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            if name.contains(".tmp.") {
                // A hook killed in the middle of its write leaves its temporary file behind.
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if Date().timeIntervalSince(modified) > 60 {
                    try? FileManager.default.removeItem(at: url)
                }
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var fields: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
            guard let state = fields["state"].flatMap(SessionState.init(rawValue:)) else { continue }
            let pid = fields["pid"].flatMap { Int32($0) } ?? 0
            let updated = fields["updated"].flatMap { Double($0) }.map(Date.init(timeIntervalSince1970:)) ?? Date()
            // The session is over when its claude process is gone. After a reboot the
            // system may hand the same pid to another program, so the process behind the
            // pid must still be claude for the session to count.
            if pid > 0 && !Self.isClaudeProcess(pid) {
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

    /// True when the pid belongs to a running claude binary, or to a node process
    /// (claude installed through npm runs as node). The path is the resolved one:
    /// ~/.local/bin/claude is a link to ~/.local/share/claude/versions/<version>, so
    /// "claude" is looked for anywhere in the path, not only in the file name.
    static func isClaudeProcess(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let bytes = buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        let name = (path as NSString).lastPathComponent
        return path.lowercased().contains("claude") || name.hasPrefix("node")
    }
}

/// One usage limit of the Claude subscription: the 5-hour window, the weekly window,
/// or a spend limit behind a gateway. statusline.sh stores each one in
/// ~/.claude/traffic-light/limits/<name> as "<used percent> <reset unix time>".
struct UsageLimit {
    let name: String
    let usedPercent: Double
    let resetsAt: Date

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/traffic-light/limits", isDirectory: true)
    /// Known limits come first, in this order, any other one after them by name.
    static let order = ["five_hour", "seven_day", "spend_limit"]

    var shortLabel: String {
        switch name {
        case "five_hour": return "5h"
        case "seven_day": return "7d"
        case "spend_limit": return "$"
        default: return String(name.prefix(3))
        }
    }

    var longLabel: String {
        switch name {
        case "five_hour": return "5-hour limit"
        case "seven_day": return "Weekly limit"
        case "spend_limit": return "Spend limit"
        default: return name.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// A window is back at zero once its reset time has passed, even before a status
    /// line update says so. A spend limit can go above 100.
    func used(at now: Date) -> Double {
        now >= resetsAt ? 0 : max(usedPercent, 0)
    }

    /// The time left until the reset, "42m", "2h 14m" or "3d 4h", empty once it passed.
    func remaining(at now: Date) -> String {
        let seconds = Int(resetsAt.timeIntervalSince(now))
        guard seconds > 0 else { return "" }
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    func detail(at now: Date) -> String {
        let percent = "\(Int(used(at: now).rounded()))%"
        let left = remaining(at: now)
        return left.isEmpty ? percent : "\(percent) · \(left)"
    }

    /// Green while there is plenty left, yellow from 70%, red from 90%.
    static func color(forUsed used: Double) -> NSColor {
        if used >= 90 { return SessionState.working.color }
        if used >= 70 { return SessionState.attention.color }
        return SessionState.idle.color
    }

    static func readAll() -> [UsageLimit] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var limits: [UsageLimit] = []
        for name in names where !name.contains(".tmp.") {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { continue }
            let parts = text.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let used = Double(parts[0]), let resets = Double(parts[1]) else { continue }
            limits.append(UsageLimit(name: name, usedPercent: used, resetsAt: Date(timeIntervalSince1970: resets)))
        }
        func rank(_ limit: UsageLimit) -> Int { order.firstIndex(of: limit.name) ?? order.count }
        return limits.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.name < $1.name }
    }
}

/// One row per session: a lamp and the session's name. Below them one row per usage
/// limit: a bar, the percentage used and the time left until the reset.
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
    static let limitRowHeight: CGFloat = 18
    /// The space between the last lamp and the first limit, with a hairline in it.
    static let limitsGap: CGFloat = 6
    static let minBarWidth: CGFloat = 60
    static let limitFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    /// Fixed, so the bars do not jump while the countdown ticks.
    static let limitDetailWidth = ceil(textWidth("100% · 23h 59m", font: limitFont)) + 4

    var sessions: [Session] = [] {
        didSet { needsDisplay = true }
    }
    var limits: [UsageLimit] = [] {
        didSet { needsDisplay = true }
    }
    var menuProvider: (() -> NSMenu)?

    override var mouseDownCanMoveWindow: Bool { true }

    static func height(forRows rows: Int, limits: Int) -> CGFloat {
        let limitsHeight = limits > 0 ? limitsGap + CGFloat(limits) * limitRowHeight : 0
        return CGFloat(max(rows, 1)) * rowHeight + 2 * padding + limitsHeight
    }

    /// Wide enough that every row's label and state fit without truncation.
    static func width(for sessions: [Session], limits: [UsageLimit]) -> CGFloat {
        var widest: CGFloat = textWidth(emptyText, font: labelFont)
        for (session, label) in zip(sessions, labels(for: sessions)) {
            let row = textWidth(label.prefix, font: prefixFont) + textWidth(label.text, font: labelFont)
                + 10 + textWidth(session.state.label, font: detailFont)
            widest = max(widest, row)
        }
        if !limits.isEmpty {
            widest = max(widest, minBarWidth + 8 + limitDetailWidth)
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
            y -= Self.rowHeight
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

        guard !limits.isEmpty else { return }
        let lampsBottom = y + Self.rowHeight
        NSColor(white: 1, alpha: 0.12).setFill()
        NSRect(x: Self.padding + 4, y: lampsBottom - Self.limitsGap / 2, width: bounds.width - 2 * Self.padding - 8, height: 1).fill()
        let now = Date()
        var limitY = lampsBottom - Self.limitsGap - Self.limitRowHeight
        for limit in limits {
            drawLimit(limit, in: NSRect(x: Self.padding, y: limitY, width: bounds.width - 2 * Self.padding, height: Self.limitRowHeight), now: now)
            limitY -= Self.limitRowHeight
        }
    }

    /// The short name under the lamp column, the bar, then the percentage and the time left.
    private func drawLimit(_ limit: UsageLimit, in row: NSRect, now: Date) {
        let used = limit.used(at: now)
        let color = UsageLimit.color(forUsed: used)
        Self.draw(limit.shortLabel, font: Self.limitFont, color: NSColor(white: 0.6, alpha: 1), alignment: .center,
                  in: NSRect(x: row.minX, y: row.minY, width: 26, height: row.height))
        let detailX = row.maxX - Self.limitDetailWidth
        let barX = row.minX + Self.lampColumn
        let bar = NSRect(x: barX, y: row.midY - 2.5, width: detailX - 8 - barX, height: 5)
        NSColor(white: 1, alpha: 0.15).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()
        if used > 0 {
            var fill = bar
            fill.size.width = max(bar.height, bar.width * min(used, 100) / 100)
            color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
        }
        Self.draw(limit.detail(at: now), font: Self.limitFont, color: color, alignment: .right,
                  in: NSRect(x: detailX, y: row.minY, width: Self.limitDetailWidth, height: row.height))
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
        let size = NSSize(width: LampListView.width(for: [], limits: []), height: LampListView.height(forRows: 1, limits: 0))
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
        directorySource?.cancel()
        directorySource = nil
        let descriptor = open(store.directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let gone = source.data.contains(.delete) || source.data.contains(.rename)
            Task { @MainActor in
                self.refresh()
                if gone { self.watchDirectory() }
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directorySource = source
    }

    private func refresh() {
        let exists = FileManager.default.fileExists(atPath: store.directory.path)
        sessions = store.liveSessions()
        if !exists || directorySource == nil {
            // liveSessions recreated a missing folder, the watcher must follow it.
            watchDirectory()
        }
        // The status line writes the limits, the 3 second timer is quick enough for them
        // and keeps the countdown going.
        let limits = UsageLimit.readAll()
        listView.sessions = sessions
        listView.limits = limits
        listView.toolTip = tooltip(sessions: sessions, limits: limits)
        let size = NSSize(width: LampListView.width(for: sessions, limits: limits),
                          height: LampListView.height(forRows: sessions.count, limits: limits.count))
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

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    /// Each session with its full last message, then each limit with its reset time.
    private func tooltip(sessions: [Session], limits: [UsageLimit]) -> String? {
        var parts = sessions.map { session in
            let name = session.title.isEmpty ? session.folder : session.title
            return session.prompt.isEmpty ? name : "\(name): \(session.prompt)"
        }
        let now = Date()
        let limitLines = limits.map { limit in
            let at = Self.resetFormatter.string(from: limit.resetsAt)
            return limit.remaining(at: now).isEmpty
                ? "\(limit.longLabel): reset \(at)"
                : "\(limit.longLabel): \(Int(limit.used(at: now).rounded()))% used, resets \(at)"
        }
        if !limitLines.isEmpty { parts.append(limitLines.joined(separator: "\n")) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
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
