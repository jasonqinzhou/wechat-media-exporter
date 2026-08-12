import AppKit
import ApplicationServices
import CryptoKit
import Foundation

private let weChatBundleID = "com.tencent.xinWeChat"
private let exporterVersion = "0.1.0"
private let scheduleLabel = "com.local.wechat-media-exporter.daily"

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
    var waitForDownloadsSeconds: Int = 120
}

struct ExportStats {
    var saved = 0
    var existing = 0
    var failed = 0
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
    private var lastConfirmedSaveDestination: URL?

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

    private func window(exactTitle: String) -> AXUIElement? {
        windows().first { string($0, kAXTitleAttribute as CFString) == exactTitle }
    }

    private func window(titlePrefix: String) -> AXUIElement? {
        windows().first { string($0, kAXTitleAttribute as CFString).hasPrefix(titlePrefix) }
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
            if title == "Photos and Videos" || title.hasPrefix("Chat history of") || title == "Save" {
                closeWindow(target)
            }
        }
    }

    // MARK: - Chat discovery

    private func mainWindow() throws -> AXUIElement {
        if let main = window(exactTitle: "Weixin") { return main }
        if let main = window(exactTitle: "WeChat") { return main }
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
                  bounds.intersects(listFrame) else { continue }
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
            if wait(seconds: 2.5, {
                self.elements(in: main, role: kAXButtonRole as String, title: "Chat History").first
            }) != nil {
                return
            }
        }
        throw ExporterError.message("WeChat did not select the chat named \(row.name).")
    }

    // MARK: - Media viewer and save dialogs

    private func saveButton(in viewer: AXUIElement) -> AXUIElement? {
        let candidates = elements(in: viewer, role: kAXButtonRole as String, title: "Save")
        if string(viewer, kAXTitleAttribute as CFString).hasPrefix("Chat history of") {
            return candidates.first
        }
        return candidates.first {
            guard let bounds = frame($0), let viewerFrame = frame(viewer) else { return false }
            return bounds.minY < viewerFrame.minY + 80
        }
    }

    private func activeSaveDialog(for viewer: AXUIElement) -> SaveDialog? {
        if let sheet = elements(in: viewer, role: kAXSheetRole as String).first(where: {
            string($0, kAXDescriptionAttribute as CFString) == "save"
        }) {
            return SaveDialog(root: sheet, hostWindow: viewer)
        }
        if let saveWindow = window(exactTitle: "Save") {
            return SaveDialog(root: saveWindow, hostWindow: saveWindow)
        }
        return nil
    }

    private func suggestedFilename(in dialog: SaveDialog) -> String? {
        elements(in: dialog.root, role: kAXTextFieldRole as String).compactMap { field -> String? in
            guard string(field, kAXDescriptionAttribute as CFString) != "tag editor" else { return nil }
            let value = string(field, kAXValueAttribute as CFString)
            return value.contains(".") ? value : nil
        }.first
    }

    private func cancel(_ dialog: SaveDialog) {
        if let button = elements(in: dialog.root, role: kAXButtonRole as String, title: "Cancel").last {
            _ = press(button)
            pause(0.3)
        }
    }

    private func cancelAnySaveDialog(for viewer: AXUIElement) {
        // Escape a possible nested Go to Folder sheet first.
        sendKey(53)
        pause(0.15)
        if let current = activeSaveDialog(for: viewer) {
            cancel(current)
        }
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

    private func commitSave(_ dialog: SaveDialog) throws {
        guard let button = elements(in: dialog.root, role: kAXButtonRole as String, title: "Save").last else {
            throw ExporterError.message("The macOS Save button was unavailable.")
        }
        guard press(button) else {
            throw ExporterError.message("The macOS Save button could not be pressed.")
        }
    }

    private func saveCurrentItem(from viewer: AXUIElement, to destination: URL) throws -> (filename: String, existed: Bool) {
        bringForward(viewer)
        if string(viewer, kAXTitleAttribute as CFString).hasPrefix("Chat history of") {
            sendKey(1, flags: .maskCommand) // Command-S
        } else {
            guard let button = wait(seconds: TimeInterval(config.waitForDownloadsSeconds), { () -> AXUIElement? in
                guard let candidate = self.saveButton(in: viewer), self.bool(candidate, kAXEnabledAttribute as CFString) else { return nil }
                return candidate
            }) else {
                throw ExporterError.message("The current media item did not finish loading in WeChat.")
            }
            try mouseClick(button)
        }

        guard let dialog = wait(seconds: 8, { self.activeSaveDialog(for: viewer) }),
              let filename = wait(seconds: 3, { self.suggestedFilename(in: dialog) }) else {
            throw ExporterError.message("WeChat did not present a usable Save dialog.")
        }
        let target = destination.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: target.path) {
            cancel(dialog)
            return (filename, true)
        }

        do {
            if lastConfirmedSaveDestination != destination {
                try setDestination(destination, for: dialog)
            }
            guard let refreshedDialog = wait(seconds: 3, { self.activeSaveDialog(for: viewer) }) else {
                throw ExporterError.message("The macOS Save dialog closed before the file was committed.")
            }
            try commitSave(refreshedDialog)
            guard wait(seconds: TimeInterval(config.waitForDownloadsSeconds), {
                self.fileManager.fileExists(atPath: target.path) ? true : nil
            }) != nil else {
                throw ExporterError.message("Timed out waiting for \(filename) to be written.")
            }
        } catch {
            cancelAnySaveDialog(for: viewer)
            throw error
        }
        lastConfirmedSaveDestination = destination
        return (filename, false)
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
        guard let history = wait(seconds: 8, { self.window(titlePrefix: "Chat history of") }) else {
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
        return elements(in: history, role: kAXStaticTextRole as String).compactMap { element -> MediaTile? in
            let type = string(element, kAXTitleAttribute as CFString)
            guard type == "Image" || type == "Video", let bounds = frame(element),
                  bounds.width > 0, bounds.height > 0,
                  bounds.intersects(historyFrame), bounds.minY > historyFrame.minY + 100 else { return nil }
            return MediaTile(type: type, element: element, frame: bounds)
        }.sorted { lhs, rhs in
            if abs(lhs.frame.minY - rhs.frame.minY) > 3 { return lhs.frame.minY < rhs.frame.minY }
            return lhs.frame.minX < rhs.frame.minX
        }
    }

    private func openTile(_ tile: MediaTile, in history: AXUIElement) throws -> AXUIElement {
        bringForward(history)
        try mouseClick(tile.element, count: tile.type == "Image" ? 2 : 1)
        if tile.type == "Image" {
            pause(0.55)
            return history
        }
        if let viewer = wait(seconds: 2.5, { self.window(exactTitle: "Photos and Videos") }) {
            return viewer
        }
        bringForward(history)
        try mouseClick(tile.element)
        guard let viewer = wait(seconds: 8, { self.window(exactTitle: "Photos and Videos") }) else {
            throw ExporterError.message("WeChat did not open the selected video.")
        }
        return viewer
    }

    private func closeTileViewer(_ viewer: AXUIElement, history: AXUIElement) {
        if string(viewer, kAXTitleAttribute as CFString).hasPrefix("Chat history of") {
            bringForward(history)
            sendKey(53)
            pause(0.3)
        } else {
            closeWindow(viewer)
            pause(0.35)
        }
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

    private func destinationFilenames(_ destination: URL) -> Set<String> {
        let names = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
        return Set(names)
    }

    private func exportGallery(destination: URL) throws -> ExportStats {
        let initialFiles = destinationFilenames(destination)
        var encountered = Set<String>()
        var stats = ExportStats()
        var openedCount = 0
        var stagnantPages = 0
        let history = try openHistoryMedia()
        defer {
            if window(exactTitle: "Save") != nil { cancelAnySaveDialog(for: history) }
            if let video = window(exactTitle: "Photos and Videos") { closeWindow(video) }
            sendKey(53)
            pause(0.2)
            if window(titlePrefix: "Chat history of") != nil { closeWindow(history) }
        }

        for _ in 0..<max(1, config.maxScrollPages) {
            let tiles = visibleMediaTiles(in: history)
            if tiles.isEmpty {
                if encountered.isEmpty { print("  No locally available media found.") }
                break
            }
            var newOnPage = 0
            for snapshot in tiles {
                if openedCount >= max(1, config.maxItemsPerChat) { return stats }

                // Reacquire by type and position after closing each viewer.
                let currentTiles = visibleMediaTiles(in: history)
                guard let tile = currentTiles.min(by: {
                    let left = abs($0.frame.midX - snapshot.frame.midX) + abs($0.frame.midY - snapshot.frame.midY)
                    let right = abs($1.frame.midX - snapshot.frame.midX) + abs($1.frame.midY - snapshot.frame.midY)
                    return left < right
                }), tile.type == snapshot.type else { continue }

                var viewer: AXUIElement?
                do {
                    viewer = try openTile(tile, in: history)
                    let result = try saveCurrentItem(from: viewer!, to: destination)
                    openedCount += 1
                    if encountered.insert(result.filename).inserted { newOnPage += 1 }
                    if result.existed {
                        stats.existing += 1
                        print("  Existing: \(result.filename)")
                        closeTileViewer(viewer!, history: history)
                        viewer = nil
                        if config.stopOnExisting && initialFiles.contains(result.filename) { return stats }
                    } else {
                        stats.saved += 1
                        print("  Saved: \(result.filename)")
                    }
                } catch {
                    stats.failed += 1
                    openedCount += 1
                    print("  Warning (\(tile.type.lowercased())): \(error.localizedDescription)")
                    cancelAnySaveDialog(for: viewer ?? history)
                }
                if let viewer { closeTileViewer(viewer, history: history) }
                if stats.failed >= 10 { return stats }
            }

            stagnantPages = newOnPage == 0 ? stagnantPages + 1 : 0
            if stagnantPages >= 2 { break }
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
      list-visible-chats
      run --config /absolute/path/config.json
      export-current --destination /path/to/folder [--max-items 500]
      schedule-install --config /absolute/path/config.json --hour 3 [--minute 0]
      schedule-remove
    """)
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
            print("Done: \(stats.saved) saved, \(stats.existing) already present, \(stats.failed) warnings.")
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
            print("Done: \(stats.saved) saved, \(stats.existing) already present, \(stats.failed) warnings.")
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
