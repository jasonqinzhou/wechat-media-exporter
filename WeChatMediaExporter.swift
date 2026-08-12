import AppKit
import ApplicationServices
import CryptoKit
import Foundation

private let weChatBundleID = "com.tencent.xinWeChat"
private let exporterVersion = "0.3.1"
private let scheduleLabel = "com.local.wechat-media-exporter.daily"

private let saveControlNames = [
    "save", "save as", "保存", "另存为", "另存為", "儲存", "存储", "下载", "下載"
]

private let cancelControlNames = ["cancel", "取消"]

private let destinationConfirmNames = [
    "choose", "choose folder", "select", "select folder", "open", "store", "storage",
    "选取", "選取", "选择", "選擇", "打开", "打開"
]

private func isSaveControlName(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return saveControlNames.contains(normalized)
}

private func isCancelControlName(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return cancelControlNames.contains(normalized)
}

private func isDestinationConfirmName(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return isSaveControlName(normalized) || destinationConfirmNames.contains(normalized)
}

private func selectionDragPoints(for frames: [CGRect], within container: CGRect) -> (start: CGPoint, end: CGPoint)? {
    guard var selection = frames.first else { return nil }
    for item in frames.dropFirst() { selection = selection.union(item) }

    let inset: CGFloat = 5
    let margin: CGFloat = 9
    let usable = container.insetBy(dx: inset, dy: inset)
    let start = CGPoint(
        x: max(usable.minX, selection.minX - margin),
        y: max(usable.minY, selection.minY - margin)
    )
    let end = CGPoint(
        x: min(usable.maxX, selection.maxX + margin),
        y: min(usable.maxY, selection.maxY + margin)
    )
    guard start.x < selection.minX, start.y < selection.minY,
          end.x > selection.maxX, end.y > selection.maxY else { return nil }
    return (start, end)
}

private func mergeStagedFiles(
    fileManager: FileManager,
    from staging: URL,
    into destination: URL
) throws -> (saved: Int, existing: Int) {
    let files = try fileManager.contentsOfDirectory(
        at: staging,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    var saved = 0
    var existing = 0
    for source in files {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let target = destination.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: source)
            existing += 1
        } else {
            try fileManager.moveItem(at: source, to: target)
            saved += 1
        }
    }
    return (saved, existing)
}

enum ExporterError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

struct Config: Codable {
    var destination: String
    var mode: String = "allRecentChats"
    var chats: [String] = []
    var maxItemsPerChat: Int = 500
    var maxScrollPages: Int = 200
    var stopOnExisting: Bool = true
    var waitForDownloadsSeconds: Int = 600
}

struct ExportStats {
    var saved = 0
    var existing = 0
    var skipped = 0
    var failed = 0
}

struct BatchExportResult {
    var selected = 0
    var saved = 0
    var existing = 0
    var skipped = 0
}

struct ChatRow {
    let name: String
    let element: AXUIElement
    let frame: CGRect
}

struct MediaTile {
    let type: String
    let element: AXUIElement
    let frame: CGRect
}

struct SaveDialog {
    let root: AXUIElement
    let hostWindow: AXUIElement
}

final class WeChatAutomation {
    private let fileManager = FileManager.default
    private(set) var application: NSRunningApplication
    private(set) var root: AXUIElement
    private let config: Config

    init(config: Config) throws {
        self.config = config
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: weChatBundleID).first else {
            throw ExporterError.message("WeChat is not running. Open WeChat, unlock it, and try again.")
        }
        application = app
        root = AXUIElementCreateApplication(app.processIdentifier)
    }

    // MARK: - Accessibility helpers

    private func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ name: CFString) -> String {
        attribute(element, name) as? String ?? ""
    }

    private func bool(_ element: AXUIElement, _ name: CFString, default defaultValue: Bool = true) -> Bool {
        attribute(element, name) as? Bool ?? defaultValue
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionObject = attribute(element, kAXPositionAttribute as CFString),
              let sizeObject = attribute(element, kAXSizeAttribute as CFString) else { return nil }
        let positionValue = positionObject as! AXValue
        let sizeValue = sizeObject as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func descendants(_ element: AXUIElement, maxDepth: Int = 28) -> [AXUIElement] {
        var result: [AXUIElement] = [element]
        func visit(_ node: AXUIElement, _ depth: Int) {
            guard depth < maxDepth else { return }
            for child in children(node) {
                result.append(child)
                visit(child, depth + 1)
            }
        }
        visit(element, 0)
        return result
    }

    private func elements(
        in rootElement: AXUIElement,
        role: String? = nil,
        title: String? = nil,
        description: String? = nil,
        subrole: String? = nil
    ) -> [AXUIElement] {
        descendants(rootElement).filter { element in
            if let role, string(element, kAXRoleAttribute as CFString) != role { return false }
            if let title, string(element, kAXTitleAttribute as CFString) != title { return false }
            if let description, string(element, kAXDescriptionAttribute as CFString) != description { return false }
            if let subrole, string(element, kAXSubroleAttribute as CFString) != subrole { return false }
            return true
        }
    }

    private func windows() -> [AXUIElement] {
        attribute(root, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
    }

    private func sameElement(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }

    private func window(exactTitle: String) -> AXUIElement? {
        windows().first { string($0, kAXTitleAttribute as CFString) == exactTitle }
    }

    private func window(titlePrefix: String) -> AXUIElement? {
        windows().first { string($0, kAXTitleAttribute as CFString).hasPrefix(titlePrefix) }
    }

    private func isChatHistoryWindow(_ element: AXUIElement) -> Bool {
        let title = string(element, kAXTitleAttribute as CFString)
        return title.hasPrefix("Chat history of") || title.hasPrefix("Chat history with")
    }

    private func chatHistoryWindow() -> AXUIElement? {
        windows().first(where: isChatHistoryWindow)
    }

    private func wait<T>(seconds: TimeInterval, every: TimeInterval = 0.1, _ body: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let value = body() { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(every))
        } while Date() < deadline
        return nil
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func bringForward(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(root, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        application.activate(options: [.activateAllWindows])
        AXUIElementSetAttributeValue(root, kAXFocusedWindowAttribute as CFString, window)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = wait(seconds: 1.5, every: 0.05) {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == weChatBundleID ? true : nil
        }
        pause(0.15)
    }

    @discardableResult
    private func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private func mouseClick(_ element: AXUIElement, count: Int = 1) throws {
        guard let bounds = frame(element), bounds.width > 0, bounds.height > 0 else {
            throw ExporterError.message("WeChat exposed a control without usable screen coordinates.")
        }
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        for clickState in 1...count {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
            down?.post(tap: .cghidEventTap)
            usleep(45_000)
            up?.post(tap: .cghidEventTap)
            usleep(75_000)
        }
    }

    private func mouseDrag(from start: CGPoint, to end: CGPoint) {
        CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: start,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        usleep(100_000)

        let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: start,
            mouseButton: .left
        )
        down?.setIntegerValueField(.mouseEventClickState, value: 1)
        down?.post(tap: .cghidEventTap)

        let steps = 30
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
            let drag = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: point,
                mouseButton: .left
            )
            drag?.setIntegerValueField(.mouseEventClickState, value: 1)
            drag?.post(tap: .cghidEventTap)
            usleep(15_000)
        }

        let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: end,
            mouseButton: .left
        )
        up?.setIntegerValueField(.mouseEventClickState, value: 1)
        up?.post(tap: .cghidEventTap)
        pause(0.5)
    }

    private func sendKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func closeWindow(_ target: AXUIElement) {
        if let close = elements(in: target, role: kAXButtonRole as String, subrole: kAXCloseButtonSubrole as String).first {
            _ = press(close)
            pause(0.25)
        }
    }

    private func closeAuxiliaryWindows() {
        for target in windows() {
            let title = string(target, kAXTitleAttribute as CFString)
            if title == "Save" {
                if let cancel = elements(in: target, role: kAXButtonRole as String, title: "Cancel").last {
                    _ = press(cancel)
                    pause(0.25)
                }
                continue
            }
            if title == "Photos and Videos",
               let saveSheet = elements(in: target, role: kAXSheetRole as String).first(where: {
                   string($0, kAXDescriptionAttribute as CFString) == "save"
               }),
               let cancel = elements(in: saveSheet, role: kAXButtonRole as String, title: "Cancel").last {
                _ = press(cancel)
                pause(0.25)
            }
            if title == "Photos and Videos" || isChatHistoryWindow(target) || title == "Save" {
                closeWindow(target)
            }
        }
    }

    // MARK: - Chat discovery

    private func mainWindow() throws -> AXUIElement {
        let candidates = windows().filter { candidate in
            let title = string(candidate, kAXTitleAttribute as CFString)
            return title == "Weixin" || title == "WeChat"
        }
        if let main = candidates.max(by: { lhs, rhs in
            let left = frame(lhs).map { $0.width * $0.height } ?? 0
            let right = frame(rhs).map { $0.width * $0.height } ?? 0
            return left < right
        }) {
            return main
        }
        throw ExporterError.message("The WeChat chats window is not visible. Open its main window and try again.")
    }

    func currentChatName() throws -> String {
        let main = try mainWindow()
        guard let mainFrame = frame(main) else { return "Current Chat" }
        let candidates = elements(in: main, role: kAXStaticTextRole as String).compactMap { element -> (String, CGRect)? in
            let value = string(element, kAXValueAttribute as CFString)
            guard !value.isEmpty, let bounds = frame(element) else { return nil }
            let isHeader = bounds.minX > mainFrame.minX + 260
                && bounds.minY >= mainFrame.minY
                && bounds.minY <= mainFrame.minY + 65
                && bounds.width > 40
            return isHeader ? (value, bounds) : nil
        }.sorted { lhs, rhs in
            if abs(lhs.1.minY - rhs.1.minY) > 2 { return lhs.1.minY < rhs.1.minY }
            return lhs.1.minX < rhs.1.minX
        }
        guard var name = candidates.first?.0, !name.isEmpty else { return "Current Chat" }
        name = name.replacingOccurrences(of: #"\(\d+\)$"#, with: "", options: .regularExpression)
        return name
    }

    private func chatList(in main: AXUIElement) -> AXUIElement? {
        elements(in: main, role: kAXListRole as String, title: "Chats").first
    }

    func visibleChatRows() throws -> [ChatRow] {
        let main = try mainWindow()
        guard let list = chatList(in: main), let listFrame = frame(list) else {
            throw ExporterError.message("Could not find WeChat's Recent Chats list.")
        }
        var seen = Set<String>()
        var rows: [ChatRow] = []
        for element in elements(in: list, role: kAXStaticTextRole as String) {
            let title = string(element, kAXTitleAttribute as CFString)
            guard !title.isEmpty, let bounds = frame(element), bounds.width > 0, bounds.height > 0,
                  bounds.minY >= listFrame.minY,
                  bounds.maxY <= listFrame.maxY else { continue }
            let name = title.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            rows.append(ChatRow(name: name, element: element, frame: bounds))
        }
        return rows.sorted { lhs, rhs in lhs.frame.minY < rhs.frame.minY }
    }

    private func scrollChatListDown() throws {
        let main = try mainWindow()
        guard let list = chatList(in: main), let bounds = frame(list) else {
            throw ExporterError.message("Could not scroll WeChat's Recent Chats list.")
        }
        bringForward(main)
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        for _ in 0..<3 {
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -7, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            usleep(80_000)
        }
        pause(0.6)
    }

    private func selectChat(_ row: ChatRow) throws {
        for _ in 0..<3 {
            let main = try mainWindow()
            bringForward(main)
            let freshRow = try visibleChatRows().first(where: { $0.name == row.name }) ?? row
            try mouseClick(freshRow.element)
            if wait(seconds: 2.5, { () -> Bool? in
                guard self.elements(in: main, role: kAXButtonRole as String, title: "Chat History").first != nil,
                      (try? self.currentChatName()) == row.name else { return nil }
                return true
            }) != nil {
                return
            }
        }
        throw ExporterError.message("WeChat did not select the chat named \(row.name).")
    }

    // MARK: - Media viewer and save dialogs

    private func controlStrings(_ element: AXUIElement) -> [String] {
        [
            string(element, kAXTitleAttribute as CFString),
            string(element, kAXDescriptionAttribute as CFString),
            string(element, kAXHelpAttribute as CFString),
            string(element, kAXValueAttribute as CFString)
        ].filter { !$0.isEmpty }
    }

    private func isSaveButton(_ element: AXUIElement) -> Bool {
        controlStrings(element).contains(where: isSaveControlName)
    }

    private func buttonDiagnostics(in element: AXUIElement) -> String {
        let names = elements(in: element, role: kAXButtonRole as String).flatMap(controlStrings)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = Array(NSOrderedSet(array: names)).compactMap { $0 as? String }
        return unique.prefix(20).joined(separator: ", ")
    }

    private func newDestinationDialog(
        for history: AXUIElement,
        excluding existingWindows: [AXUIElement],
        existingSheets: [AXUIElement]
    ) -> SaveDialog? {
        if let sheet = elements(in: history, role: kAXSheetRole as String).first(where: { candidate in
            !existingSheets.contains(where: { sameElement(candidate, $0) })
        }) {
            return SaveDialog(root: sheet, hostWindow: history)
        }
        if let panel = windows().first(where: { candidate in
            !sameElement(candidate, history)
                && !existingWindows.contains(where: { sameElement(candidate, $0) })
        }) {
            return SaveDialog(root: panel, hostWindow: panel)
        }
        return nil
    }

    private func dialogIsPresent(_ dialog: SaveDialog) -> Bool {
        if sameElement(dialog.root, dialog.hostWindow) {
            return windows().contains(where: { sameElement($0, dialog.root) })
        }
        return elements(in: dialog.hostWindow, role: kAXSheetRole as String).contains(where: {
            sameElement($0, dialog.root)
        })
    }

    private func cancel(_ dialog: SaveDialog) {
        if let rawButton = attribute(dialog.root, kAXCancelButtonAttribute as CFString) {
            let button = rawButton as! AXUIElement
            _ = press(button)
            pause(0.3)
            return
        }
        if let button = elements(in: dialog.root, role: kAXButtonRole as String).last(where: { candidate in
            controlStrings(candidate).contains(where: isCancelControlName)
        }) {
            _ = press(button)
            pause(0.3)
        }
    }

    private func cancelAnySaveDialog(for viewer: AXUIElement) {
        // Escape a possible nested Go to Folder sheet first.
        bringForward(viewer)
        sendKey(53)
        pause(0.25)
    }

    private func setDestination(_ destination: URL, for dialog: SaveDialog) throws {
        bringForward(dialog.hostWindow)
        let previousSheetCount = elements(in: dialog.hostWindow, role: kAXSheetRole as String).count
        sendKey(5, flags: [.maskCommand, .maskShift]) // Command-Shift-G

        guard let goSheet = wait(seconds: 4, { () -> AXUIElement? in
            let sheets = self.elements(in: dialog.hostWindow, role: kAXSheetRole as String)
            guard sheets.count > previousSheetCount else { return nil }
            return sheets.last
        }) else {
            throw ExporterError.message("The macOS Go to Folder sheet did not open.")
        }
        guard let pathField = elements(in: goSheet, role: kAXTextFieldRole as String).first else {
            throw ExporterError.message("The macOS Go to Folder field was unavailable.")
        }
        let result = AXUIElementSetAttributeValue(pathField, kAXValueAttribute as CFString, destination.path as CFString)
        guard result == .success else {
            throw ExporterError.message("Could not enter the destination folder in the Save dialog.")
        }
        AXUIElementSetAttributeValue(pathField, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        sendKey(36) // Return
        guard wait(seconds: 5, {
            self.elements(in: dialog.hostWindow, role: kAXSheetRole as String).count <= previousSheetCount ? true : nil
        }) != nil else {
            throw ExporterError.message("The Save dialog did not accept the destination folder.")
        }
    }

    private func commitDestination(_ dialog: SaveDialog) throws {
        for container in [dialog.root, dialog.hostWindow] {
            if let rawButton = attribute(container, kAXDefaultButtonAttribute as CFString) {
                let button = rawButton as! AXUIElement
                if bool(button, kAXEnabledAttribute as CFString), press(button) { return }
            }
        }
        let buttons = elements(in: dialog.root, role: kAXButtonRole as String)
            + elements(in: dialog.hostWindow, role: kAXButtonRole as String)
        if let button = buttons.last(where: { candidate in
            bool(candidate, kAXEnabledAttribute as CFString)
                && controlStrings(candidate).contains(where: isDestinationConfirmName)
        }) {
            guard press(button) else {
                throw ExporterError.message("The folder chooser's confirmation button could not be pressed.")
            }
            return
        }

        // Some macOS folder panels temporarily expose no button descendants
        // after their Go to Folder sheet closes. Return still activates the
        // panel's default Store/Choose action; the caller verifies closure.
        bringForward(dialog.hostWindow)
        sendKey(36) // Return
    }

    private func cleanFolderName(_ raw: String) -> String {
        var clean = raw.replacingOccurrences(of: #"[/\\:\x00-\x1F]"#, with: "_", options: .regularExpression)
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { clean = "Unnamed Chat" }
        if clean.count > 90 { clean = String(clean.prefix(90)) }
        let digest = SHA256.hash(data: Data(raw.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(clean) [\(digest)]"
    }

    private func openHistoryMedia() throws -> AXUIElement {
        closeAuxiliaryWindows()
        let main = try mainWindow()
        bringForward(main)
        guard let historyButton = elements(in: main, role: kAXButtonRole as String, title: "Chat History").first else {
            throw ExporterError.message("No current chat is selected, or its Chat History button is unavailable.")
        }
        try mouseClick(historyButton)
        guard let history = wait(seconds: 8, { self.chatHistoryWindow() }) else {
            throw ExporterError.message("WeChat did not open Chat History.")
        }
        bringForward(history)
        if let mediaTab = elements(in: history, role: kAXRadioButtonRole as String, title: "Media").first {
            try mouseClick(mediaTab)
        }
        pause(0.9)
        return history
    }

    private func visibleMediaTiles(in history: AXUIElement) -> [MediaTile] {
        guard let historyFrame = frame(history) else { return [] }
        let safeFrame = historyFrame.insetBy(dx: 12, dy: 12)
        return elements(in: history, role: kAXStaticTextRole as String).compactMap { element -> MediaTile? in
            let type = string(element, kAXTitleAttribute as CFString)
            guard type == "Image" || type == "Video", let bounds = frame(element),
                  bounds.width > 0, bounds.height > 0,
                  safeFrame.contains(bounds), bounds.minY > historyFrame.minY + 100 else { return nil }
            return MediaTile(type: type, element: element, frame: bounds)
        }.sorted { lhs, rhs in
            if abs(lhs.frame.minY - rhs.frame.minY) > 3 { return lhs.frame.minY < rhs.frame.minY }
            return lhs.frame.minX < rhs.frame.minX
        }
    }

    private func batchSaveButton(in history: AXUIElement) -> AXUIElement? {
        guard let historyFrame = frame(history) else { return nil }
        return elements(in: history, role: kAXButtonRole as String).filter { button in
            guard isSaveButton(button), bool(button, kAXEnabledAttribute as CFString),
                  let bounds = frame(button), bounds.intersects(historyFrame) else { return false }
            return bounds.midY > historyFrame.midY
        }.max { lhs, rhs in
            (frame(lhs)?.midY ?? 0) < (frame(rhs)?.midY ?? 0)
        }
    }

    private func clearBatchSelection(in history: AXUIElement) {
        guard batchSaveButton(in: history) != nil else { return }
        bringForward(history)
        sendKey(53) // Escape clears the rubber-band selection.
        _ = wait(seconds: 2, { self.batchSaveButton(in: history) == nil ? true : nil })
        pause(0.2)
    }

    private func rectangularTilePrefix(_ tiles: [MediaTile], maximumCount: Int) -> [MediaTile] {
        var rows: [[MediaTile]] = []
        for tile in tiles {
            if let lastY = rows.last?.first?.frame.minY, abs(lastY - tile.frame.minY) <= 3 {
                rows[rows.count - 1].append(tile)
            } else {
                rows.append([tile])
            }
        }

        var selected: [MediaTile] = []
        for row in rows {
            let remaining = maximumCount - selected.count
            if remaining <= 0 { break }
            if row.count <= remaining {
                selected.append(contentsOf: row)
            } else if selected.isEmpty {
                selected.append(contentsOf: row.prefix(remaining))
            } else {
                break
            }
        }
        return selected
    }

    private func selectVisibleBatch(
        in history: AXUIElement,
        tiles: [MediaTile],
        maximumCount: Int
    ) throws -> (button: AXUIElement, selectedCount: Int) {
        clearBatchSelection(in: history)
        let selectedTiles = rectangularTilePrefix(tiles, maximumCount: max(1, maximumCount))
        guard let historyFrame = frame(history),
              let points = selectionDragPoints(for: selectedTiles.map(\.frame), within: historyFrame) else {
            throw ExporterError.message("The visible media grid did not leave enough room for drag selection.")
        }

        bringForward(history)
        mouseDrag(from: points.start, to: points.end)
        if let button = wait(seconds: 4, { self.batchSaveButton(in: history) }) {
            return (button, selectedTiles.count)
        }

        // A few WeChat builds begin rubber-band selection more reliably from
        // the lower-right gutter, so retry once in the opposite direction.
        bringForward(history)
        sendKey(53)
        pause(0.2)
        mouseDrag(from: points.end, to: points.start)
        guard let button = wait(seconds: 4, { self.batchSaveButton(in: history) }) else {
            let visible = buttonDiagnostics(in: history)
            throw ExporterError.message(
                "Drag selection completed, but WeChat did not show its batch Save button. "
                + "Visible buttons: \(visible)"
            )
        }
        return (button, selectedTiles.count)
    }

    private func visibleProgressIndicators(in history: AXUIElement) -> [AXUIElement] {
        guard let historyFrame = frame(history) else { return [] }
        return elements(in: history, role: kAXProgressIndicatorRole as String).filter { indicator in
            if (attribute(indicator, kAXHiddenAttribute as CFString) as? Bool) == true { return false }
            guard let bounds = frame(indicator) else { return true }
            return bounds.width > 0 && bounds.height > 0 && bounds.intersects(historyFrame)
        }
    }

    private func progressIsComplete(_ indicator: AXUIElement) -> Bool {
        guard let value = (attribute(indicator, kAXValueAttribute as CFString) as? NSNumber)?.doubleValue else {
            return false
        }
        let maximum = (attribute(indicator, kAXMaxValueAttribute as CFString) as? NSNumber)?.doubleValue ?? 1
        return maximum > 0 && value >= maximum - 0.000_001
    }

    private func stagingSnapshot(_ directory: URL) -> [String: UInt64] {
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var result: [String: UInt64] = [:]
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            result[file.lastPathComponent] = UInt64(values.fileSize ?? 0)
        }
        return result
    }

    private func directoryIsEmpty(_ directory: URL) -> Bool {
        ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty
    }

    private func waitForBatchCompletion(in history: AXUIElement, staging: URL) throws {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(TimeInterval(max(300, config.waitForDownloadsSeconds)))
        var lastSnapshot = stagingSnapshot(staging)
        var lastChange = Date()
        var sawProgress = false
        var sawFileActivity = !lastSnapshot.isEmpty

        while Date() < deadline {
            let indicators = visibleProgressIndicators(in: history)
            if !indicators.isEmpty { sawProgress = true }
            let progressActive = indicators.contains(where: { !progressIsComplete($0) })

            let snapshot = stagingSnapshot(staging)
            if snapshot != lastSnapshot {
                lastSnapshot = snapshot
                lastChange = Date()
                sawFileActivity = true
            }

            let stableFor = Date().timeIntervalSince(lastChange)
            if sawProgress, !progressActive, stableFor >= 1.5 { return }
            if sawFileActivity, !progressActive, stableFor >= 3.0 { return }

            // When every selected item is unavailable, WeChat can finish
            // without creating a file or leaving a progress indicator visible.
            if !sawProgress, !sawFileActivity, Date().timeIntervalSince(startedAt) >= 12 { return }
            pause(0.25)
        }
        throw ExporterError.message("Timed out waiting for WeChat's batch-save progress to finish.")
    }

    private func saveSelectedBatch(
        in history: AXUIElement,
        saveButton: AXUIElement,
        selectedCount: Int,
        staging: URL,
        destination: URL
    ) throws -> BatchExportResult {
        let initialSnapshot = stagingSnapshot(staging)
        let existingWindows = windows()
        let existingSheets = elements(in: history, role: kAXSheetRole as String)
        try mouseClick(saveButton)
        guard let dialog = wait(seconds: 8, {
            self.newDestinationDialog(
                for: history,
                excluding: existingWindows,
                existingSheets: existingSheets
            )
        }) else {
            throw ExporterError.message("WeChat's batch Save button did not open a destination chooser.")
        }

        do {
            try setDestination(staging, for: dialog)
            try commitDestination(dialog)
            guard wait(seconds: 5, { !self.dialogIsPresent(dialog) ? true : nil }) != nil else {
                throw ExporterError.message("The destination chooser did not close after confirmation.")
            }
            try waitForBatchCompletion(in: history, staging: staging)
        } catch {
            bringForward(dialog.hostWindow)
            sendKey(53) // Close a possible nested Go to Folder sheet.
            pause(0.2)
            if dialogIsPresent(dialog) { cancel(dialog) }
            throw error
        }

        let completedSnapshot = stagingSnapshot(staging)
        guard completedSnapshot != initialSnapshot || completedSnapshot.isEmpty else {
            throw ExporterError.message("WeChat reported completion, but the staging folder did not change.")
        }
        let merged = try mergeStagedFiles(fileManager: fileManager, from: staging, into: destination)
        let skipped = max(0, selectedCount - merged.saved - merged.existing)
        clearBatchSelection(in: history)
        return BatchExportResult(
            selected: selectedCount,
            saved: merged.saved,
            existing: merged.existing,
            skipped: skipped
        )
    }

    private func scrollGalleryDown(_ history: AXUIElement) {
        guard let bounds = frame(history) else { return }
        bringForward(history)
        let point = CGPoint(x: bounds.midX, y: bounds.maxY - 100)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        for _ in 0..<3 {
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -7, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            usleep(80_000)
        }
        pause(0.7)
    }

    private func exportGallery(destination: URL) throws -> ExportStats {
        var stats = ExportStats()
        var selectedTotal = 0
        var emptyBatchStreak = 0
        let history = try openHistoryMedia()
        let staging = destination.appendingPathComponent(
            ".wechat-media-exporter-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        defer {
            clearBatchSelection(in: history)
            sendKey(53)
            pause(0.2)
            if chatHistoryWindow() != nil { closeWindow(history) }

            if directoryIsEmpty(staging) {
                try? fileManager.removeItem(at: staging)
            } else {
                print("  Warning: unfinished staged files were retained at \(staging.path)")
            }
        }

        for _ in 0..<max(1, config.maxScrollPages) {
            let remaining = max(1, config.maxItemsPerChat) - selectedTotal
            if remaining <= 0 { break }

            let tiles = visibleMediaTiles(in: history)
            if tiles.isEmpty {
                if selectedTotal == 0 { print("  No locally available media found.") }
                break
            }

            do {
                let selection = try selectVisibleBatch(
                    in: history,
                    tiles: tiles,
                    maximumCount: remaining
                )
                let result = try saveSelectedBatch(
                    in: history,
                    saveButton: selection.button,
                    selectedCount: selection.selectedCount,
                    staging: staging,
                    destination: destination
                )
                let produced = result.saved + result.existing
                if produced == 0 {
                    emptyBatchStreak += 1
                    if emptyBatchStreak == 1 {
                        selectedTotal += result.selected
                        stats.skipped += result.selected
                        print(
                            "  Batch: \(result.selected) selected, 0 files produced; "
                            + "\(result.selected) unavailable skipped."
                        )
                    } else {
                        print(
                            "  Batch: no files produced again; stopping to avoid "
                            + "repeating the gallery endpoint."
                        )
                    }
                } else {
                    emptyBatchStreak = 0
                    selectedTotal += result.selected
                    stats.saved += result.saved
                    stats.existing += result.existing
                    stats.skipped += result.skipped
                    print(
                        "  Batch: \(result.selected) selected, \(result.saved) saved, "
                        + "\(result.existing) already present, \(result.skipped) unavailable skipped."
                    )
                }

                if config.stopOnExisting, result.saved == 0, result.existing > 0 { break }
                if emptyBatchStreak >= 2 { break }
            } catch {
                stats.failed += 1
                print("  Batch warning: \(error.localizedDescription)")
                cancelAnySaveDialog(for: history)
                clearBatchSelection(in: history)
                break
            }

            if selectedTotal >= max(1, config.maxItemsPerChat) { break }
            scrollGalleryDown(history)
        }
        return stats
    }

    func exportCurrentChat(destinationRoot: URL, folderName: String? = nil) throws -> ExportStats {
        let rawName = try folderName ?? currentChatName()
        let destination = destinationRoot.appendingPathComponent(cleanFolderName(rawName), isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        print("Chat: \(rawName)")
        return try exportGallery(destination: destination)
    }

    func exportRecentChats(destinationRoot: URL) throws -> ExportStats {
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let allowList = Set(config.chats)
        var processed = Set<String>()
        var total = ExportStats()
        var stagnantPages = 0

        for _ in 0..<max(1, config.maxScrollPages) {
            closeAuxiliaryWindows()
            let rows = try visibleChatRows()
            let candidates = rows.filter { row in
                !processed.contains(row.name) && (allowList.isEmpty || allowList.contains(row.name))
            }
            if candidates.isEmpty {
                stagnantPages += 1
            } else {
                stagnantPages = 0
            }

            for candidate in candidates {
                processed.insert(candidate.name)
                do {
                    try selectChat(candidate)
                    let stats = try exportCurrentChat(destinationRoot: destinationRoot, folderName: candidate.name)
                    total.saved += stats.saved
                    total.existing += stats.existing
                    total.skipped += stats.skipped
                    total.failed += stats.failed
                } catch {
                    total.failed += 1
                    print("Chat \(candidate.name): warning: \(error.localizedDescription)")
                    closeAuxiliaryWindows()
                }
            }

            if !allowList.isEmpty && allowList.isSubset(of: processed) { break }
            if stagnantPages >= 3 { break }
            try scrollChatListDown()
        }

        let missing = allowList.subtracting(processed)
        if !missing.isEmpty {
            print("Not found in Recent Chats: \(missing.sorted().joined(separator: ", "))")
        }
        return total
    }
}

private func expandedURL(_ path: String) -> URL {
    URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
}

private func loadConfig(_ path: String) throws -> Config {
    let url = expandedURL(path)
    do {
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    } catch {
        throw ExporterError.message("Could not read config at \(url.path): \(error.localizedDescription)")
    }
}

private func argument(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private func appInfo() -> (path: String, version: String, build: String)? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: weChatBundleID),
          let bundle = Bundle(url: url) else { return nil }
    return (
        url.path,
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    )
}

private func doctor(prompt: Bool) -> Int32 {
    print("WeChat Media Exporter \(exporterVersion)")
    if let info = appInfo() {
        print("OK  WeChat installed: \(info.version) (\(info.build))")
        print("    \(info.path)")
    } else {
        print("ERR WeChat is not installed.")
    }

    let trusted: Bool
    if prompt {
        trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    } else {
        trusted = AXIsProcessTrusted()
    }
    print(trusted ? "OK  Accessibility permission granted." : "ERR Accessibility permission is required.")

    let running = !NSRunningApplication.runningApplications(withBundleIdentifier: weChatBundleID).isEmpty
    print(running ? "OK  WeChat is running." : "ERR WeChat is not running.")

    print("OK  Uses only WeChat's visible controls; no direct access to its data folder.")
    return (appInfo() != nil && trusted && running) ? 0 : 1
}

private func schedulePlist(configPath: String, executablePath: String, hour: Int, minute: Int) -> String {
    let escapedExecutable = executablePath.replacingOccurrences(of: "&", with: "&amp;")
    let escapedConfig = configPath.replacingOccurrences(of: "&", with: "&amp;")
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(scheduleLabel)</string>
      <key>ProgramArguments</key>
      <array>
        <string>\(escapedExecutable)</string>
        <string>run</string>
        <string>--config</string>
        <string>\(escapedConfig)</string>
      </array>
      <key>StartCalendarInterval</key>
      <dict><key>Hour</key><integer>\(hour)</integer><key>Minute</key><integer>\(minute)</integer></dict>
      <key>ProcessType</key><string>Interactive</string>
    </dict>
    </plist>
    """
}

private func runLaunchctl(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    } catch {
        print("launchctl error: \(error.localizedDescription)")
        return 1
    }
}

private func installSchedule(configPath: String, hour: Int, minute: Int) throws {
    guard (0...23).contains(hour), (0...59).contains(minute) else {
        throw ExporterError.message("Schedule time must use hour 0-23 and minute 0-59.")
    }
    let configURL = expandedURL(configPath)
    _ = try loadConfig(configURL.path)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let agents = expandedURL("~/Library/LaunchAgents")
    try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    let plistURL = agents.appendingPathComponent("\(scheduleLabel).plist")
    let plist = schedulePlist(configPath: configURL.path, executablePath: executable, hour: hour, minute: minute)
    try plist.data(using: .utf8)!.write(to: plistURL, options: .atomic)

    let domain = "gui/\(getuid())"
    _ = runLaunchctl(["bootout", domain + "/" + scheduleLabel])
    guard runLaunchctl(["bootstrap", domain, plistURL.path]) == 0 else {
        throw ExporterError.message("launchd could not install the schedule. The plist is at \(plistURL.path).")
    }
    print("Installed daily schedule for \(String(format: "%02d:%02d", hour, minute)).")
    print("WeChat must be running, logged in, and the Mac must be unlocked at run time.")
}

private func removeSchedule() {
    let domain = "gui/\(getuid())"
    _ = runLaunchctl(["bootout", domain + "/" + scheduleLabel])
    let plistURL = expandedURL("~/Library/LaunchAgents/\(scheduleLabel).plist")
    do {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        print("Removed the daily schedule.")
    } catch {
        print("Could not remove \(plistURL.path): \(error.localizedDescription)")
    }
}

private func printHelp() {
    print("""
    WeChat Media Exporter \(exporterVersion)

    Uses WeChat's own Chat History and Save controls. It does not read keys,
    decrypt databases, inject code, or upload anything.

    Commands:
      doctor [--prompt]
      self-test
      list-visible-chats
      run --config /absolute/path/config.json
      export-current --destination /path/to/folder [--max-items 500]
      schedule-install --config /absolute/path/config.json --hour 3 [--minute 0]
      schedule-remove
    """)
}

private func runSelfTests() -> Int32 {
    for value in ["Save", "Save As", "保存", "儲存", "下载"] where !isSaveControlName(value) {
        fputs("Self-test failed: Save control was not recognized: \(value)\n", stderr)
        return 1
    }
    let frames = [CGRect(x: 100, y: 100, width: 50, height: 50), CGRect(x: 160, y: 100, width: 50, height: 50)]
    guard let drag = selectionDragPoints(for: frames, within: CGRect(x: 0, y: 0, width: 300, height: 300)),
          drag.start.x < 100, drag.start.y < 100, drag.end.x > 210, drag.end.y > 150 else {
        fputs("Self-test failed: batch drag geometry did not enclose the media tiles.\n", stderr)
        return 1
    }
    for value in ["Save", "Choose Folder", "Open", "选择"] where !isDestinationConfirmName(value) {
        fputs("Self-test failed: destination confirmation was not recognized: \(value)\n", stderr)
        return 1
    }
    let fileManager = FileManager.default
    let testRoot = fileManager.temporaryDirectory.appendingPathComponent(
        "wechat-media-exporter-self-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: testRoot) }
    do {
        let staging = testRoot.appendingPathComponent("staging", isDirectory: true)
        let destination = testRoot.appendingPathComponent("destination", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("existing.jpg"))
        try Data("old".utf8).write(to: staging.appendingPathComponent("existing.jpg"))
        try Data("new".utf8).write(to: staging.appendingPathComponent("new.mp4"))
        let merged = try mergeStagedFiles(fileManager: fileManager, from: staging, into: destination)
        guard merged.saved == 1, merged.existing == 1,
              fileManager.fileExists(atPath: destination.appendingPathComponent("new.mp4").path),
              (try fileManager.contentsOfDirectory(atPath: staging.path)).isEmpty else {
            fputs("Self-test failed: staging merge did not deduplicate the batch.\n", stderr)
            return 1
        }
    } catch {
        fputs("Self-test failed: staging merge error: \(error.localizedDescription)\n", stderr)
        return 1
    }
    print("Self-test passed.")
    return 0
}

private func main() -> Int32 {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        printHelp()
        return 0
    }
    do {
        switch command {
        case "doctor":
            return doctor(prompt: arguments.contains("--prompt"))

        case "self-test":
            return runSelfTests()

        case "list-visible-chats":
            let automation = try WeChatAutomation(config: Config(destination: "."))
            for row in try automation.visibleChatRows() { print(row.name) }
            return 0

        case "run":
            guard let path = argument(after: "--config", in: arguments) else {
                throw ExporterError.message("run requires --config /path/config.json")
            }
            let config = try loadConfig(path)
            let destination = expandedURL(config.destination)
            let automation = try WeChatAutomation(config: config)
            let stats: ExportStats
            if config.mode == "currentChat" {
                stats = try automation.exportCurrentChat(destinationRoot: destination)
            } else if config.mode == "allRecentChats" {
                stats = try automation.exportRecentChats(destinationRoot: destination)
            } else {
                throw ExporterError.message("Unknown config mode: \(config.mode)")
            }
            print("Done: \(stats.saved) saved, \(stats.existing) already present, \(stats.skipped) unavailable skipped, \(stats.failed) warnings.")
            return stats.failed == 0 ? 0 : 2

        case "export-current":
            guard let destinationPath = argument(after: "--destination", in: arguments) else {
                throw ExporterError.message("export-current requires --destination /path/to/folder")
            }
            var config = Config(destination: destinationPath, mode: "currentChat")
            if let value = argument(after: "--max-items", in: arguments), let count = Int(value) {
                config.maxItemsPerChat = count
            }
            let destination = expandedURL(destinationPath)
            let automation = try WeChatAutomation(config: config)
            let stats = try automation.exportCurrentChat(destinationRoot: destination)
            print("Done: \(stats.saved) saved, \(stats.existing) already present, \(stats.skipped) unavailable skipped, \(stats.failed) warnings.")
            return stats.failed == 0 ? 0 : 2

        case "schedule-install":
            guard let configPath = argument(after: "--config", in: arguments),
                  let hourText = argument(after: "--hour", in: arguments),
                  let hour = Int(hourText) else {
                throw ExporterError.message("schedule-install requires --config PATH --hour 0-23 [--minute 0-59]")
            }
            let minute = argument(after: "--minute", in: arguments).flatMap(Int.init) ?? 0
            try installSchedule(configPath: configPath, hour: hour, minute: minute)
            return 0

        case "schedule-remove":
            removeSchedule()
            return 0

        case "help", "--help", "-h":
            printHelp()
            return 0

        default:
            throw ExporterError.message("Unknown command: \(command)")
        }
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

exit(main())
