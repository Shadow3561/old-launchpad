import AppKit
import UniformTypeIdentifiers
import QuartzCore
import Darwin

private struct InstalledApp {
    let name: String
    let url: URL
    var icon: NSImage
}

private struct AppFolder: Codable, Identifiable {
    var id: String
    var name: String
    var appPaths: [String]
}

private enum PageTransitionStyle: String, CaseIterable {
    case slide
    case fade
    case zoom
    case off

    var title: String {
        switch self {
        case .slide: "Schieben"
        case .fade: "Überblenden"
        case .zoom: "Zoomen"
        case .off: "Ohne Animation"
        }
    }
}

private enum LaunchpadItem {
    case app(InstalledApp)
    case folder(AppFolder)

    var name: String {
        switch self {
        case .app(let app): app.name
        case .folder(let folder): folder.name
        }
    }

    var id: String {
        switch self {
        case .app(let app): app.url.path
        case .folder(let folder): "folder:\(folder.id)"
        }
    }
}

private let appPasteboardType = NSPasteboard.PasteboardType("local.deepal.oldlaunchpad.app-path")
private let itemPasteboardType = NSPasteboard.PasteboardType("local.deepal.oldlaunchpad.item-id")
private func reopenNotificationName() -> Notification.Name {
    Notification.Name("local.deepal.oldlaunchpad.reopen.\(Bundle.main.bundleIdentifier ?? "default")")
}

@main
@MainActor
private struct OldLaunchpadApp {
    private static var delegate: AppDelegate?
    private static var instanceLockFileDescriptor: Int32 = -1

    static func main() {
        let application = NSApplication.shared
        guard acquireSingleInstanceLock() else { return }
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            application.applicationIconImage = icon
        }
        let delegate = AppDelegate()
        self.delegate = delegate
        application.mainMenu = makeMainMenu(target: delegate)
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        delegate.listenForReopenRequests()
        application.run()
    }

    private static func acquireSingleInstanceLock() -> Bool {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "local.deepal.oldlaunchpad"
        let lockPath = "\(NSTemporaryDirectory())\(bundleIdentifier).\(getuid()).lock"
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            showSingleInstanceError("Die Instanzsperre konnte nicht geöffnet werden.")
            return false
        }
        var lock = Darwin.flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        let lockResult = Darwin.fcntl(descriptor, F_SETLK, &lock)
        guard lockResult == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            if lockError == EACCES || lockError == EAGAIN {
                DistributedNotificationCenter.default().post(name: reopenNotificationName(), object: nil)
                if let bundleIdentifier = Bundle.main.bundleIdentifier,
                   let runningInstance = NSRunningApplication
                    .runningApplications(withBundleIdentifier: bundleIdentifier)
                    .first(where: { $0.processIdentifier != getpid() }) {
                    runningInstance.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                }
            } else {
                showSingleInstanceError("Die Instanzsperre konnte nicht aktiviert werden (Fehler \(lockError)).")
            }
            return false
        }

        instanceLockFileDescriptor = descriptor
        return true
    }

    private static func showSingleInstanceError(_ message: String) {
        NSLog("Old Launchpad: %@", message)
        let alert = NSAlert()
        alert.messageText = "Old Launchpad konnte nicht gestartet werden"
        alert.informativeText = message
        alert.runModal()
    }

    private static func makeMainMenu(target: AppDelegate) -> NSMenu {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Old Launchpad")
        appMenu.addItem(withTitle: "Old Launchpad ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let fullScreen = NSMenuItem(
            title: "Vollbild umschalten",
            action: #selector(AppDelegate.togglePresentationFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        fullScreen.target = target
        appMenu.addItem(fullScreen)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Old Launchpad beenden",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        return mainMenu
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: LaunchpadWindow?
    private var licenseWindow: LicenseActivationWindow?
    private var escapeMonitor: Any?

    func listenForReopenRequests() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleReopenRequest),
            name: reopenNotificationName(),
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if !DEVELOPER_BUILD && !PAID_BUILD
        do {
            try LemonSqueezyLicense.initializeTrialStartDateIfNeeded()
        } catch {
            NSLog("Old Launchpad: Testzeitraum konnte nicht initialisiert werden: %@", error.localizedDescription)
        }
        #endif
        showWindow()
    }

    @objc private func handleReopenRequest() {
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    @objc func togglePresentationFullScreen(_ sender: Any?) {
        window?.togglePresentationFullScreen(sender)
    }

    func showWindow() {
        #if !DEVELOPER_BUILD
        do {
            let hasLicense = try LemonSqueezyLicense.savedStatus()?.active == true
            if !hasLicense {
                #if PAID_BUILD
                showLicenseWindow()
                return
                #else
                let hasTrial = try LemonSqueezyLicense.savedTrialStatus()?.isActive == true
                guard hasTrial else {
                    showLicenseWindow()
                    return
                }
                #endif
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Lizenzstatus konnte nicht gelesen werden"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            showLicenseWindow()
            return
        }
        #endif

        showLaunchpadWindow()
    }

    private func showLaunchpadWindow() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.restoreFullScreenIfNeeded()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = LaunchpadViewController()
        let window = LaunchpadWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Old Launchpad"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.delegate = window
        window.contentViewController = controller
        window.collectionBehavior.insert(.fullScreenNone)
        if let zoomButton = window.standardWindowButton(.zoomButton) {
            zoomButton.target = window
            zoomButton.action = #selector(LaunchpadWindow.togglePresentationFullScreen(_:))
            zoomButton.toolTip = "Vollbild umschalten"
        }
        window.setContentSize(NSSize(width: 1100, height: 780))
        window.minSize = NSSize(width: 900, height: 680)
        window.center()
        self.window = window
        window.restoreFullScreenIfNeeded()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard event.keyCode == 53, window?.isKeyWindow == true else { return event }
            window?.dismissLaunchpad()
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showLicenseWindow() {
        if let licenseWindow {
            NSApp.activate(ignoringOtherApps: true)
            licenseWindow.makeKeyAndOrderFront(nil)
            return
        }

        let licenseWindow = LicenseActivationWindow(onAccessGranted: { [weak self] in
            guard let self else { return }
            self.licenseWindow?.orderOut(nil)
            self.licenseWindow = nil
            self.showWindow()
        })
        self.licenseWindow = licenseWindow
        NSApp.activate(ignoringOtherApps: true)
        licenseWindow.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class LaunchpadWindow: NSWindow, NSWindowDelegate {
    private var isDismissing = false
    private var isPresentationFullScreen = false
    private var windowedFrame: NSRect?

    func restoreFullScreenIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "launchpadFullScreen"),
              !isPresentationFullScreen else { return }
        enterPresentationFullScreen()
    }

    @objc func togglePresentationFullScreen(_ sender: Any?) {
        if isPresentationFullScreen {
            exitPresentationFullScreen()
        } else {
            enterPresentationFullScreen()
        }
    }

    private func enterPresentationFullScreen() {
        guard let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        windowedFrame = frame
        isPresentationFullScreen = true
        styleMask = [.borderless]
        setFrame(screen.frame, display: true, animate: false)
        UserDefaults.standard.set(true, forKey: "launchpadFullScreen")
        (contentViewController as? LaunchpadViewController)?.setFullScreenAppearance(true)
    }

    private func exitPresentationFullScreen() {
        isPresentationFullScreen = false
        styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        if let windowedFrame {
            setFrame(windowedFrame, display: true, animate: false)
        } else {
            setContentSize(NSSize(width: 1100, height: 780))
            center()
        }
        UserDefaults.standard.set(false, forKey: "launchpadFullScreen")
        (contentViewController as? LaunchpadViewController)?.setFullScreenAppearance(false)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            dismissLaunchpad()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        dismissLaunchpad()
    }

    func dismissLaunchpad() {
        guard !isDismissing, let contentView else { return }
        isDismissing = true
        contentView.wantsLayer = true
        guard let layer = contentView.layer else {
            finishDismissal()
            return
        }

        let dockEffect = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "mineffect") ?? "genie"
        let anchor = dockAnchorPoint(in: contentView)
        layer.position = CGPoint(
            x: layer.position.x + (anchor.x - layer.anchorPoint.x) * layer.bounds.width,
            y: layer.position.y + (anchor.y - layer.anchorPoint.y) * layer.bounds.height
        )
        layer.anchorPoint = anchor

        let dockPosition = dockOrientation()
        let isSideDock = dockPosition == "left" || dockPosition == "right"
        let targetScale: CATransform3D
        if dockEffect == "suck" {
            targetScale = CATransform3DConcat(
                CATransform3DMakeRotation(.pi * 2.2, 0, 0, 1),
                CATransform3DMakeScale(0.025, 0.025, 1)
            )
        } else if dockEffect == "scale" {
            targetScale = CATransform3DMakeScale(0.025, 0.025, 1)
        } else if isSideDock {
            targetScale = CATransform3DMakeScale(0.08, 0.025, 1)
        } else {
            targetScale = CATransform3DMakeScale(0.025, 0.08, 1)
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.52)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock { [weak self] in
            DispatchQueue.main.async {
                self?.finishDismissal()
            }
        }
        layer.transform = targetScale
        layer.opacity = 0
        CATransaction.commit()
    }

    private func dockAnchorPoint(in contentView: NSView) -> CGPoint {
        let dockDefaults = UserDefaults(suiteName: "com.apple.dock")
        let dockItems = dockDefaults?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        let appIndex = dockItems.firstIndex {
            let tileData = $0["tile-data"] as? [String: Any]
            return tileData?["bundle-identifier"] as? String == Bundle.main.bundleIdentifier
        }
        let itemCount = max(dockItems.count, 1)
        let iconSize = CGFloat(dockDefaults?.double(forKey: "tilesize") ?? 48)
        let spacing = iconSize * 1.22
        let offset = CGFloat(appIndex ?? itemCount / 2) - CGFloat(itemCount - 1) / 2
        guard let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return CGPoint(x: 0.5, y: 0)
        }
        let orientation = dockOrientation(on: screen)
        var target = screen.frame.origin

        switch orientation {
        case "left":
            target.x = screen.frame.minX
            target.y = screen.frame.midY + offset * spacing
        case "right":
            target.x = screen.frame.maxX
            target.y = screen.frame.midY + offset * spacing
        default:
            target.x = screen.frame.midX + offset * spacing
            target.y = screen.frame.minY
        }

        let windowPoint = convertPoint(fromScreen: target)
        let point = contentView.convert(windowPoint, from: nil)
        return CGPoint(
            x: min(max(point.x / max(1, contentView.bounds.width), 0), 1),
            y: min(max(point.y / max(1, contentView.bounds.height), 0), 1)
        )
    }

    private func dockOrientation() -> String {
        guard let screen = self.screen ?? NSScreen.main ?? NSScreen.screens.first else { return "bottom" }
        return dockOrientation(on: screen)
    }

    private func dockOrientation(on screen: NSScreen) -> String {
        if let configured = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation"),
           ["left", "right"].contains(configured) {
            return configured
        }

        let frame = screen.frame
        let visible = screen.visibleFrame
        let leftInset = visible.minX - frame.minX
        let rightInset = frame.maxX - visible.maxX
        let bottomInset = visible.minY - frame.minY
        if leftInset > rightInset && leftInset > bottomInset { return "left" }
        if rightInset > leftInset && rightInset > bottomInset { return "right" }
        return "bottom"
    }

    private func finishDismissal() {
        guard let contentView else { return }
        contentView.layer?.removeAllAnimations()
        contentView.layer?.transform = CATransform3DIdentity
        contentView.layer?.opacity = 1
        isDismissing = false
        orderOut(nil)
    }

}

@MainActor
private final class LaunchpadViewController: NSViewController {
    private let columns = 7
    private let backgrounds: [(id: String, name: String)] = [
        ("aurora", "Aurora"),
        ("ocean", "Ozean"),
        ("sunset", "Sonnenuntergang"),
        ("midnight", "Mitternacht")
    ]
    private var apps: [InstalledApp] = []
    private var folders: [AppFolder] = []
    private var itemOrder = UserDefaults.standard.stringArray(forKey: "launchpadItemOrder") ?? []
    private var page = 0
    private var iconSize = CGFloat(min(max(
        UserDefaults.standard.object(forKey: "launchpadIconSize") as? Double ?? 72,
        48
    ), 112))
    private var rowCount = min(max(UserDefaults.standard.object(forKey: "launchpadRows") as? Int ?? 5, 3), 6)
    private var backgroundStyle = UserDefaults.standard.string(forKey: "launchpadBackground") ?? "aurora"
    private var backgroundOpacity = CGFloat(min(max(
        UserDefaults.standard.object(forKey: "launchpadBackgroundOpacity") as? Double ?? 0.88,
        0.25
    ), 1))
    private var pageTransition = PageTransitionStyle(
        rawValue: UserDefaults.standard.string(forKey: "launchpadPageTransition") ?? ""
    ) ?? .slide
    private var isInFullScreen = false
    private var isTransitioningPage = false
    private var loadError: String?
    private var currentFolderID: String?
    private var accessibilityOptionsObserver: NSObjectProtocol?

    private let gridView = LaunchpadGridView()
    private let backButton = NSButton(title: "‹ Launchpad", target: nil, action: nil)
    private let settingsButton = NSButton(
        image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Einstellungen")!,
        target: nil,
        action: nil
    )
    private let searchField = NSSearchField()
    private let dotsView = LaunchpadClickView()
    private let messageLabel = LaunchpadMessageLabel(labelWithString: "")

    private var currentFolder: AppFolder? {
        folders.first { $0.id == currentFolderID }
    }

    func setFullScreenAppearance(_ isFullScreen: Bool) {
        isInFullScreen = isFullScreen
        (view as? LaunchpadBackgroundView)?.configure(
            style: backgroundStyle,
            opacity: backgroundOpacity
        )
    }

    override func loadView() {
        let backgroundView = LaunchpadBackgroundView()
        backgroundView.onAppearanceChange = { [weak self] in self?.refreshSystemIcons() }
        view = backgroundView
        view.wantsLayer = true
        view.setAccessibilityLabel("Old Launchpad")
        (view as? LaunchpadBackgroundView)?.onBackgroundClick = { [weak self] in self?.dismiss() }
        (view as? LaunchpadBackgroundView)?.configure(
            style: backgroundStyle,
            opacity: backgroundOpacity
        )

        backButton.target = self
        backButton.action = #selector(showRoot)
        backButton.isBordered = false
        backButton.font = .systemFont(ofSize: 14, weight: .medium)
        backButton.contentTintColor = .white
        backButton.isHidden = true
        view.addSubview(backButton)

        settingsButton.target = self
        settingsButton.action = #selector(showSettings)
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .white
        settingsButton.toolTip = "Launchpad-Einstellungen"
        view.addSubview(settingsButton)

        searchField.placeholderString = "Suchen"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.font = .systemFont(ofSize: 14)
        view.addSubview(searchField)

        gridView.onBackgroundClick = { [weak self] in self?.dismiss() }
        gridView.onScroll = { [weak self] horizontal, vertical in
            self?.scrollPage(horizontal: horizontal, vertical: vertical)
        }
        gridView.onReorder = { [weak self] itemID, index in
            self?.reorderItem(itemID, to: index)
        }
        gridView.onEdgePage = { [weak self] direction in
            self?.changePage(direction, duringDrag: true) ?? false
        }
        view.addSubview(gridView)

        messageLabel.font = .systemFont(ofSize: 16)
        messageLabel.textColor = .white
        messageLabel.alignment = .center
        messageLabel.isHidden = true
        messageLabel.onClick = { [weak self] in self?.dismiss() }
        view.addSubview(messageLabel)
        dotsView.onBackgroundClick = { [weak self] in self?.dismiss() }
        view.addSubview(dotsView)

        loadApps()
        loadFolders()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        accessibilityOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshSystemIcons()
            }
        }
    }

    private func refreshSystemIcons() {
        guard isViewLoaded else { return }
        for index in apps.indices {
            apps[index].icon = NSWorkspace.shared.icon(forFile: apps[index].url.path)
        }
        updateGrid()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        let inset: CGFloat = 56
        let headerY = bounds.height - 78
        backButton.frame = NSRect(x: inset, y: headerY + 2, width: 145, height: 36)
        settingsButton.frame = NSRect(x: bounds.width - inset - 34, y: headerY + 3, width: 32, height: 32)
        searchField.frame = NSRect(x: bounds.width - inset - 250 - 20 - 34, y: headerY + 3, width: 250, height: 34)

        let gridFrame = NSRect(
            x: inset,
            y: 78,
            width: bounds.width - inset * 2,
            height: max(0, bounds.height - 190)
        )
        gridView.frame = gridFrame
        messageLabel.frame = gridFrame
        dotsView.frame = NSRect(x: 0, y: 21, width: bounds.width, height: 30)
        updateGrid()
    }

    private var visibleItems: [LaunchpadItem] {
        if let folder = currentFolder {
            let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return folder.appPaths.compactMap(app(at:)).map(LaunchpadItem.app).filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            }
        }

        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return ordered(allRootItems).filter {
            query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query)
                || folderContainsMatch($0, query: query)
        }
    }

    private var allRootItems: [LaunchpadItem] {
        let groupedPaths = Set(folders.flatMap(\.appPaths))
        let rootApps = apps
            .filter { !groupedPaths.contains($0.url.path) }
            .map(LaunchpadItem.app)
        return rootApps + folders.map(LaunchpadItem.folder)
    }

    private func ordered(_ items: [LaunchpadItem]) -> [LaunchpadItem] {
        let positions = Dictionary(itemOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.sorted {
            let left = positions[$0.id] ?? Int.max
            let right = positions[$1.id] ?? Int.max
            if left != right { return left < right }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func folderContainsMatch(_ item: LaunchpadItem, query: String) -> Bool {
        guard case .folder(let folder) = item else { return false }
        return folder.appPaths.compactMap(app(at:)).contains {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    private var pageCount: Int {
        max(1, (visibleItems.count + itemsPerPage - 1) / itemsPerPage)
    }

    private var itemsPerPage: Int {
        columns * rowCount
    }

    private func app(at path: String) -> InstalledApp? {
        apps.first { $0.url.path == path }
    }

    private func loadApps() {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        var found: [InstalledApp] = []
        var inaccessibleRoots: [String] = []

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                inaccessibleRoots.append(root.path)
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()

                guard let bundle = Bundle(url: url) else { continue }
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                found.append(
                    InstalledApp(
                        name: name,
                        url: url,
                        icon: NSWorkspace.shared.icon(forFile: url.path)
                    )
                )
            }
        }

        var seenPaths = Set<String>()
        apps = found
            .filter { seenPaths.insert($0.url.path).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        if apps.isEmpty && !inaccessibleRoots.isEmpty {
            loadError = "Programme-Ordner nicht lesbar: " + inaccessibleRoots.joined(separator: ", ")
        }
    }

    private func loadFolders() {
        guard let data = UserDefaults.standard.data(forKey: "launchpadFolders") else {
            folders = []
            return
        }
        let savedFolders: [AppFolder]
        do {
            savedFolders = try JSONDecoder().decode([AppFolder].self, from: data)
        } catch {
            loadError = "Gespeicherte Ordner konnten nicht geladen werden: \(error.localizedDescription)"
            folders = []
            return
        }
        let installedPaths = Set(apps.map(\.url.path))
        var claimedPaths = Set<String>()
        folders = savedFolders.compactMap { folder in
            let members = folder.appPaths
                .filter(installedPaths.contains)
                .filter { claimedPaths.insert($0).inserted }
                .sorted {
                    (app(at: $0)?.name ?? $0).localizedStandardCompare(app(at: $1)?.name ?? $1)
                        == .orderedAscending
                }
            guard members.count > 1 else { return nil }
            return AppFolder(id: folder.id, name: folder.name, appPaths: members)
        }
        saveFolders()
    }

    private func saveFolders() {
        do {
            let data = try JSONEncoder().encode(folders)
            UserDefaults.standard.set(data, forKey: "launchpadFolders")
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Ordner konnten nicht gespeichert werden"
            alert.runModal()
        }
    }

    private func updateGrid() {
        guard isViewLoaded else { return }
        gridView.subviews.forEach { $0.removeFromSuperview() }
        let items = visibleItems
        let start = page * itemsPerPage
        let pageItems = Array(items.dropFirst(start).prefix(itemsPerPage))
        let rows = rowCount
        gridView.configure(page: page, columns: columns, rows: rows, itemIDs: pageItems.map(\.id))
        for (index, item) in pageItems.enumerated() {
            let tile: LaunchpadTileView
            switch item {
            case .app(let app):
                tile = LaunchpadTileView(
                    title: app.name,
                    image: app.icon,
                    draggableAppPath: app.url.path,
                    draggableItemID: item.id,
                    iconSize: iconSize,
                    onBeginDrag: { [weak self] itemID, appPath, image, event in
                        self?.gridView.beginDragging(
                            itemID: itemID,
                            appPath: appPath,
                            image: image,
                            event: event
                        )
                    },
                    onActivate: { [weak self] in self?.activate(app) },
                    onEmptyClick: { [weak self] in self?.dismiss() },
                    onDropApp: { [weak self] path, shouldGroup in
                        guard let self else { return }
                        if shouldGroup && NSApp.currentEvent?.modifierFlags.contains(.option) != true {
                            self.groupApp(path, with: app.url.path)
                        } else {
                            self.reorderItem(
                                path,
                                to: self.gridView.currentDropIndex(fallback: self.page * self.itemsPerPage + index)
                            )
                        }
                    },
                    onUnGroup: currentFolderID == nil ? nil : { [weak self] in
                        self?.removeAppFromFolder(app.url.path)
                    }
                )
            case .folder(let folder):
                let folderIcon = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Ordner")
                    ?? NSWorkspace.shared.icon(for: .folder)
                tile = LaunchpadTileView(
                    title: folder.name,
                    image: folderIcon,
                    draggableAppPath: nil,
                    draggableItemID: item.id,
                    iconSize: iconSize,
                    onBeginDrag: { [weak self] itemID, appPath, image, event in
                        self?.gridView.beginDragging(
                            itemID: itemID,
                            appPath: appPath,
                            image: image,
                            event: event
                        )
                    },
                    folderIcons: folder.appPaths.compactMap(app(at:)).prefix(4).map(\.icon),
                    onActivate: { [weak self] in self?.openFolder(folder) },
                    onEmptyClick: { [weak self] in self?.dismiss() },
                    onDropApp: { [weak self] path, _ in self?.addApp(path, to: folder.id) },
                    onTitleClick: { [weak self] in self?.renameFolder(folder) },
                    onRename: { [weak self] in self?.renameFolder(folder) },
                    onDissolve: { [weak self] in self?.dissolveFolder(folder.id) }
                )
            }
            tile.frame = gridView.frameForSlot(index)
            gridView.addSubview(tile)
            tile.layoutSubtreeIfNeeded()
        }

        let emptyMessage = loadError ?? (items.isEmpty ? "Keine Apps gefunden" : "")
        messageLabel.stringValue = emptyMessage
        messageLabel.isHidden = emptyMessage.isEmpty
        backButton.isHidden = currentFolder == nil
        settingsButton.isHidden = currentFolder != nil
        if let folder = currentFolder {
            backButton.title = "‹ \(folder.name)"
        } else {
            backButton.title = "‹ Launchpad"
        }
        searchField.isHidden = false
        updatePageDots()
    }

    private func updatePageDots() {
        dotsView.subviews.forEach { $0.removeFromSuperview() }
        let count = pageCount
        let spacing: CGFloat = 18
        let dotWidth: CGFloat = 16
        let totalWidth = CGFloat(count) * dotWidth + CGFloat(max(0, count - 1)) * spacing
        let startX = (dotsView.bounds.width - totalWidth) / 2
        for index in 0..<count {
            let dot = NSButton(title: "●", target: self, action: #selector(selectPage(_:)))
            dot.tag = index
            dot.isBordered = false
            dot.font = .systemFont(ofSize: index == page ? 11 : 9)
            dot.contentTintColor = index == page ? .white : NSColor.white.withAlphaComponent(0.48)
            dot.frame = NSRect(x: startX + CGFloat(index) * (dotWidth + spacing), y: 0, width: dotWidth, height: 24)
            dotsView.addSubview(dot)
        }
    }

    private func activate(_ app: InstalledApp) {
        guard NSWorkspace.shared.open(app.url) else {
            let alert = NSAlert()
            alert.messageText = "App konnte nicht geöffnet werden"
            alert.informativeText = "„\(app.name)“ wurde nicht gestartet. Prüfe, ob die App noch installiert ist."
            alert.alertStyle = .warning
            if let window = view.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return
        }
        dismiss()
    }

    private func openFolder(_ folder: AppFolder) {
        currentFolderID = folder.id
        page = 0
        updateGrid()
    }

    private func groupApp(_ draggedPath: String, with targetPath: String) {
        guard draggedPath != targetPath, app(at: draggedPath) != nil else { return }
        if let targetFolder = folders.first(where: { $0.appPaths.contains(targetPath) }) {
            addApp(draggedPath, to: targetFolder.id)
            return
        }

        removeAppFromFolders(draggedPath)
        let folder = AppFolder(
            id: UUID().uuidString,
            name: "Neuer Ordner",
            appPaths: [targetPath, draggedPath]
        )
        folders.append(folder)
        if let targetIndex = itemOrder.firstIndex(of: targetPath) {
            itemOrder[targetIndex] = "folder:\(folder.id)"
        } else {
            itemOrder.append("folder:\(folder.id)")
        }
        itemOrder.removeAll { $0 == draggedPath }
        currentFolderID = nil
        page = 0
        saveFolders()
        UserDefaults.standard.set(itemOrder, forKey: "launchpadItemOrder")
        updateGrid()
    }

    private func addApp(_ path: String, to folderID: String) {
        guard app(at: path) != nil,
              let index = folders.firstIndex(where: { $0.id == folderID }),
              !folders[index].appPaths.contains(path) else { return }
        removeAppFromFolders(path)
        guard let updatedIndex = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[updatedIndex].appPaths.append(path)
        itemOrder.removeAll { $0 == path }
        currentFolderID = nil
        page = 0
        saveFolders()
        UserDefaults.standard.set(itemOrder, forKey: "launchpadItemOrder")
        updateGrid()
    }

    private func removeAppFromFolders(_ path: String) {
        folders = folders.compactMap { folder in
            let remaining = folder.appPaths.filter { $0 != path }
            guard remaining.count > 1 else { return nil }
            return AppFolder(id: folder.id, name: folder.name, appPaths: remaining)
        }
    }

    private func removeAppFromFolder(_ path: String) {
        removeAppFromFolders(path)
        currentFolderID = nil
        page = 0
        saveFolders()
        updateGrid()
    }

    private func dissolveFolder(_ folderID: String) {
        folders.removeAll { $0.id == folderID }
        itemOrder.removeAll { $0 == "folder:\(folderID)" }
        currentFolderID = nil
        page = 0
        saveFolders()
        UserDefaults.standard.set(itemOrder, forKey: "launchpadItemOrder")
        updateGrid()
    }

    private func renameFolder(_ folder: AppFolder) {
        let alert = NSAlert()
        alert.messageText = "Ordner umbenennen"
        alert.addButton(withTitle: "Sichern")
        alert.addButton(withTitle: "Abbrechen")
        let input = NSTextField(string: folder.name)
        input.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn,
              let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        folders[index].name = name
        saveFolders()
        updateGrid()
    }

    private func dismiss() {
        (view.window as? LaunchpadWindow)?.dismissLaunchpad()
    }

    private func scrollPage(horizontal: CGFloat, vertical: CGFloat) {
        let isHorizontal = abs(horizontal) > abs(vertical)
        let delta = isHorizontal ? horizontal : vertical
        guard abs(delta) > 12 else { return }
        let pageChange = isHorizontal ? (delta < 0 ? 1 : -1) : (delta > 0 ? 1 : -1)
        changePage(pageChange)
    }

    @discardableResult
    private func changePage(_ direction: Int, duringDrag: Bool = false) -> Bool {
        let nextPage = min(max(0, page + direction), pageCount - 1)
        if duringDrag {
            guard nextPage != page else { return false }
            page = nextPage
            updateGrid()
            return true
        }
        guard nextPage != page else { return false }
        transitionToPage(nextPage)
        return true
    }

    private func transitionToPage(_ nextPage: Int) {
        guard !isTransitioningPage, nextPage != page else { return }
        guard pageTransition != .off else {
            page = nextPage
            updateGrid()
            return
        }
        isTransitioningPage = true
        let direction: CGFloat = nextPage > page ? 1 : -1
        let shift = gridView.bounds.width * direction
        if pageTransition == .slide, transitionPageBySliding(to: nextPage, shift: shift) {
            return
        }
        let outgoingTiles = gridView.subviews.compactMap { $0 as? LaunchpadTileView }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for tile in outgoingTiles {
                var frame = tile.frame
                if pageTransition == .slide {
                    frame.origin.x -= shift
                } else if pageTransition == .zoom {
                    frame = frame.insetBy(dx: frame.width * 0.3, dy: frame.height * 0.3)
                }
                tile.animator().frame = frame
                tile.animator().alphaValue = 0
            }
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.page = nextPage
                self.updateGrid()
                let incomingTiles = self.gridView.subviews.compactMap { $0 as? LaunchpadTileView }
                for (index, tile) in incomingTiles.enumerated() {
                    if self.pageTransition == .slide {
                        tile.frame.origin.x += shift
                    } else if self.pageTransition == .zoom {
                        let target = self.gridView.frameForSlot(index)
                        tile.frame = target.insetBy(dx: target.width * 0.3, dy: target.height * 0.3)
                    }
                    tile.alphaValue = 0
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.27
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    for (index, tile) in incomingTiles.enumerated() {
                        var frame = tile.frame
                        if self.pageTransition == .slide {
                            frame.origin.x -= shift
                        } else if self.pageTransition == .zoom {
                            frame = self.gridView.frameForSlot(index)
                        }
                        tile.animator().frame = frame
                        tile.animator().alphaValue = 1
                    }
                } completionHandler: { [weak self] in
                    DispatchQueue.main.async {
                        self?.isTransitioningPage = false
                    }
                }
            }
        }
    }

    private func transitionPageBySliding(to nextPage: Int, shift: CGFloat) -> Bool {
        guard let bitmap = gridView.bitmapImageRepForCachingDisplay(in: gridView.bounds) else {
            return false
        }
        gridView.cacheDisplay(in: gridView.bounds, to: bitmap)
        let snapshotImage = NSImage(size: gridView.bounds.size)
        snapshotImage.addRepresentation(bitmap)

        page = nextPage
        updateGrid()
        let incomingTiles = gridView.subviews.compactMap { $0 as? LaunchpadTileView }
        guard let firstTile = incomingTiles.first else {
            isTransitioningPage = false
            return true
        }

        let snapshot = LaunchpadTransitionSnapshotView(frame: gridView.bounds)
        snapshot.image = snapshotImage
        snapshot.imageScaling = .scaleAxesIndependently
        snapshot.wantsLayer = true
        gridView.addSubview(snapshot, positioned: .below, relativeTo: firstTile)

        for (index, tile) in incomingTiles.enumerated() {
            var frame = gridView.frameForSlot(index)
            frame.origin.x += shift
            tile.frame = frame
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.42
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22,
                1,
                0.36,
                1
            )
            var snapshotFrame = snapshot.frame
            snapshotFrame.origin.x -= shift
            snapshot.animator().frame = snapshotFrame
            snapshot.animator().alphaValue = 0

            for (index, tile) in incomingTiles.enumerated() {
                tile.animator().frame = gridView.frameForSlot(index)
            }
        } completionHandler: { [weak self, weak snapshot] in
            DispatchQueue.main.async {
                snapshot?.removeFromSuperview()
                self?.isTransitioningPage = false
            }
        }
        return true
    }

    private func reorderItem(_ itemID: String, to visibleIndex: Int) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayedItems = visibleItems
        guard let movingItem = displayedItems.first(where: { $0.id == itemID }) else { return }

        if let folderID = currentFolderID,
           let folderIndex = folders.firstIndex(where: { $0.id == folderID }) {
            var orderedPaths = folders[folderIndex].appPaths
            guard let fromIndex = orderedPaths.firstIndex(of: itemID) else { return }
            let path = orderedPaths.remove(at: fromIndex)
            var insertionIndex: Int
            if query.isEmpty {
                insertionIndex = min(max(visibleIndex, 0), orderedPaths.count)
                if fromIndex < visibleIndex { insertionIndex -= 1 }
            } else if visibleIndex < displayedItems.count,
                      case .app(let target) = displayedItems[visibleIndex],
                      let targetIndex = orderedPaths.firstIndex(of: target.url.path) {
                insertionIndex = targetIndex
            } else if let lastItem = displayedItems.last,
                      case .app(let lastApp) = lastItem,
                      let lastIndex = orderedPaths.firstIndex(of: lastApp.url.path) {
                insertionIndex = lastIndex + 1
            } else {
                insertionIndex = orderedPaths.count
            }
            guard insertionIndex != fromIndex else {
                gridView.cancelDragPreview()
                return
            }
            orderedPaths.insert(path, at: insertionIndex)
            folders[folderIndex].appPaths = orderedPaths
            currentFolderID = folderID
            page = insertionIndex / itemsPerPage
        } else {
            var allItems = ordered(allRootItems)
            guard let fromIndex = allItems.firstIndex(where: { $0.id == itemID }) else { return }
            allItems.remove(at: fromIndex)

            var destination: Int
            if query.isEmpty {
                destination = min(max(visibleIndex, 0), allItems.count)
                if fromIndex < visibleIndex { destination -= 1 }
            } else if visibleIndex < displayedItems.count,
                      let targetIndex = allItems.firstIndex(where: { $0.id == displayedItems[visibleIndex].id }) {
                destination = targetIndex
            } else {
                let lastVisible = displayedItems.last
                destination = lastVisible.flatMap { item in allItems.firstIndex(where: { $0.id == item.id }) }
                    .map { $0 + 1 } ?? allItems.count
            }
            let insertionIndex = min(max(destination, 0), allItems.count)
            guard insertionIndex != fromIndex else {
                gridView.cancelDragPreview()
                return
            }
            allItems.insert(movingItem, at: insertionIndex)
            itemOrder = allItems.map(\.id)
            page = insertionIndex / itemsPerPage
        }

        UserDefaults.standard.set(itemOrder, forKey: "launchpadItemOrder")
        saveFolders()
        updateGrid()
    }

    @objc private func showSettings() {
        let alert = NSAlert()
        alert.messageText = "Launchpad-Einstellungen"
        alert.informativeText = "Passe das Raster und die Darstellung an."
        alert.addButton(withTitle: "Sichern")
        alert.addButton(withTitle: "Abbrechen")

        let backgroundPopup = NSPopUpButton()
        backgrounds.forEach {
            backgroundPopup.addItem(withTitle: $0.name)
            backgroundPopup.lastItem?.representedObject = $0.id
        }
        let selectedBackground = backgrounds.first { $0.id == backgroundStyle }?.name ?? "Aurora"
        backgroundPopup.selectItem(withTitle: selectedBackground)
        if backgroundPopup.indexOfSelectedItem < 0 { backgroundPopup.selectItem(at: 0) }

        let sizeSlider = NSSlider(value: Double(iconSize), minValue: 48, maxValue: 112, target: nil, action: nil)
        sizeSlider.numberOfTickMarks = 9
        sizeSlider.allowsTickMarkValuesOnly = false

        let opacitySlider = NSSlider(
            value: Double(backgroundOpacity * 100),
            minValue: 25,
            maxValue: 100,
            target: nil,
            action: nil
        )
        opacitySlider.numberOfTickMarks = 4
        opacitySlider.allowsTickMarkValuesOnly = false

        let rowsPopup = NSPopUpButton()
        (3...6).forEach { rowsPopup.addItem(withTitle: "\($0) Reihen") }
        rowsPopup.selectItem(at: min(max(rowCount - 3, 0), 3))

        let transitionPopup = NSPopUpButton()
        for style in PageTransitionStyle.allCases {
            transitionPopup.addItem(withTitle: style.title)
            transitionPopup.lastItem?.representedObject = style.rawValue
        }
        transitionPopup.selectItem(
            withTitle: pageTransition.title
        )

        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 12
        accessory.setViews([
            settingsRow("Hintergrund", control: backgroundPopup),
            settingsRow("Transparenz", control: opacitySlider),
            settingsRow("Symbolgröße", control: sizeSlider),
            settingsRow("Raster", control: rowsPopup),
            settingsRow("Seitenwechsel", control: transitionPopup)
        ], in: .top)
        accessory.frame = NSRect(x: 0, y: 0, width: 360, height: 198)
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        iconSize = CGFloat(sizeSlider.doubleValue)
        backgroundStyle = backgroundPopup.selectedItem?.representedObject as? String ?? "aurora"
        backgroundOpacity = CGFloat(opacitySlider.doubleValue / 100)
        rowCount = rowsPopup.indexOfSelectedItem + 3
        pageTransition = PageTransitionStyle(
            rawValue: transitionPopup.selectedItem?.representedObject as? String ?? ""
        ) ?? .slide

        UserDefaults.standard.set(Double(iconSize), forKey: "launchpadIconSize")
        UserDefaults.standard.set(backgroundStyle, forKey: "launchpadBackground")
        UserDefaults.standard.set(Double(backgroundOpacity), forKey: "launchpadBackgroundOpacity")
        UserDefaults.standard.set(rowCount, forKey: "launchpadRows")
        UserDefaults.standard.set(pageTransition.rawValue, forKey: "launchpadPageTransition")
        (view as? LaunchpadBackgroundView)?.configure(
            style: backgroundStyle,
            opacity: backgroundOpacity
        )
        page = min(page, pageCount - 1)
        updateGrid()
    }

    private func settingsRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        label.widthAnchor.constraint(equalToConstant: 105).isActive = true
        return row
    }

    @objc private func searchChanged() {
        page = 0
        updateGrid()
    }

    @objc private func showRoot() {
        currentFolderID = nil
        page = 0
        updateGrid()
    }

    @objc private func selectPage(_ sender: NSButton) {
        transitionToPage(sender.tag)
    }
}

@MainActor
private final class LaunchpadGridView: NSView, NSDraggingSource {
    var onBackgroundClick: (() -> Void)?
    var onScroll: ((CGFloat, CGFloat) -> Void)?
    var onReorder: ((String, Int) -> Void)?
    var onEdgePage: ((Int) -> Bool)?
    private var gestureDeltaX: CGFloat = 0
    private var gestureDeltaY: CGFloat = 0
    private var scrollEndWorkItem: DispatchWorkItem?
    private var edgePageWorkItem: DispatchWorkItem?
    private var lastEdgeDirection = 0
    private var edgePageGeneration = 0
    private var currentPage = 0
    private var columnCount = 7
    private var rowCount = 5
    private var itemIDsOnPage: [String] = []
    private var dropInsertionIndex: Int?
    private var placeholderView: LaunchpadDropPlaceholderView?
    private var previewInsertionIndex: Int?
    private var previewDraggedItemID: String?
    private var dragOrigin: (itemID: String, page: Int, slot: Int)?

    func configure(page: Int, columns: Int, rows: Int, itemIDs: [String]) {
        currentPage = page
        columnCount = columns
        rowCount = rows
        itemIDsOnPage = itemIDs
        dropInsertionIndex = nil
        previewInsertionIndex = nil
        previewDraggedItemID = nil
        placeholderView?.removeFromSuperview()
        placeholderView = nil
    }

    func frameForSlot(_ index: Int) -> NSRect {
        slotFrame(index).insetBy(dx: 12, dy: 8)
    }

    private func slotFrame(_ index: Int) -> NSRect {
        let cellWidth = bounds.width / CGFloat(max(1, columnCount))
        let cellHeight = bounds.height / CGFloat(max(1, rowCount))
        let column = index % columnCount
        let row = index / columnCount
        return NSRect(
            x: CGFloat(column) * cellWidth,
            y: bounds.height - CGFloat(row + 1) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([itemPasteboardType])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([itemPasteboardType])
    }

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }

        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            gestureDeltaX = 0
            gestureDeltaY = 0
            scrollEndWorkItem?.cancel()
        }

        gestureDeltaX += event.scrollingDeltaX
        gestureDeltaY += event.scrollingDeltaY

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finishScrollGesture()
        } else if event.phase.isEmpty {
            scrollEndWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in self?.finishScrollGesture() }
            scrollEndWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: workItem)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: itemPasteboardType) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let itemID = sender.draggingPasteboard.string(forType: itemPasteboardType) else { return [] }
        let windowPoint = window?.convertPoint(fromScreen: sender.draggingLocation) ?? .zero
        handleDragLocation(windowPoint, draggedItemID: itemID)
        return .move
    }

    func handleDragLocation(_ windowPoint: NSPoint, draggedItemID: String? = nil) {
        let point = convert(windowPoint, from: nil)
        updateDropPlaceholder(at: point, draggedItemID: draggedItemID)
        let edgeWidth: CGFloat = 54
        let direction = point.x < edgeWidth ? -1 : (point.x > bounds.width - edgeWidth ? 1 : 0)
        if direction == 0 {
            cancelEdgePage()
        } else if direction != lastEdgeDirection {
            cancelEdgePage()
            lastEdgeDirection = direction
            scheduleEdgePage(direction)
        }
    }

    private func scheduleEdgePage(_ direction: Int) {
        guard edgePageWorkItem == nil else { return }
        let generation = edgePageGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.edgePageGeneration == generation,
                  self.lastEdgeDirection == direction else { return }
            self.edgePageWorkItem = nil
            guard self.onEdgePage?(direction) == true else {
                self.cancelEdgePage()
                return
            }
            guard self.edgePageGeneration == generation,
                  self.lastEdgeDirection == direction else { return }
            self.scheduleEdgePage(direction)
        }
        edgePageWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
    }

    func cancelEdgePage() {
        edgePageGeneration += 1
        edgePageWorkItem?.cancel()
        edgePageWorkItem = nil
        lastEdgeDirection = 0
    }

    func cancelDragPreview() {
        dropInsertionIndex = nil
        previewInsertionIndex = nil
        previewDraggedItemID = nil
        placeholderView?.removeFromSuperview()
        placeholderView = nil
        for (index, itemID) in itemIDsOnPage.enumerated() {
            guard let tile = subviews.compactMap({ $0 as? LaunchpadTileView })
                .first(where: { $0.itemID == itemID }) else { continue }
            tile.alphaValue = 1
            tile.frame = frameForSlot(index)
        }
    }

    func currentDropIndex(fallback: Int) -> Int {
        dropInsertionIndex ?? fallback
    }

    func beginDragging(itemID: String, appPath: String?, image: NSImage, event: NSEvent) {
        dragOrigin = itemIDsOnPage.firstIndex(of: itemID).map {
            (itemID: itemID, page: currentPage, slot: $0)
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(itemID, forType: itemPasteboardType)
        if let appPath {
            pasteboardItem.setString(appPath, forType: appPasteboardType)
        }

        let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let location = convert(event.locationInWindow, from: nil)
        let previewSize = min(88, max(56, image.size.width))
        dragItem.setDraggingFrame(
            NSRect(
                x: location.x - previewSize / 2,
                y: location.y - previewSize / 2,
                width: previewSize,
                height: previewSize
            ),
            contents: image
        )
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    private func updateDropPlaceholder(at point: NSPoint, draggedItemID: String?) {
        let cellWidth = bounds.width / CGFloat(max(1, columnCount))
        let cellHeight = bounds.height / CGFloat(max(1, rowCount))
        let column = min(max(Int(point.x / max(1, cellWidth)), 0), columnCount - 1)
        let row = min(max(Int((bounds.height - point.y) / max(1, cellHeight)), 0), rowCount - 1)
        let cellIndex = row * columnCount + column
        let fractionX = (point.x - CGFloat(column) * cellWidth) / cellWidth
        let fractionY = (bounds.height - point.y - CGFloat(row) * cellHeight) / cellHeight
        let horizontalSide = abs(fractionX - 0.5) >= abs(fractionY - 0.5)
        let isAfterCell = horizontalSide ? fractionX >= 0.5 : fractionY >= 0.5
        let localInsertionIndex = min(cellIndex + (isAfterCell ? 1 : 0), columnCount * rowCount)
        dropInsertionIndex = currentPage * columnCount * rowCount + localInsertionIndex

        let movingFromPage = draggedItemID.flatMap(itemIDsOnPage.firstIndex(of:)) != nil
        let adjustedInsertionIndex: Int
        if movingFromPage,
           let sourceIndex = draggedItemID.flatMap(itemIDsOnPage.firstIndex(of:)),
           sourceIndex < localInsertionIndex {
            adjustedInsertionIndex = localInsertionIndex - 1
        } else {
            adjustedInsertionIndex = localInsertionIndex
        }
        let placeholderIndex = min(adjustedInsertionIndex, columnCount * rowCount - 1)
        let frame = frameForSlot(placeholderIndex).insetBy(dx: -4, dy: -4)
        let previewChanged = previewInsertionIndex != adjustedInsertionIndex
            || previewDraggedItemID != draggedItemID
        previewInsertionIndex = adjustedInsertionIndex
        previewDraggedItemID = draggedItemID
        if placeholderView == nil {
            let placeholder = LaunchpadDropPlaceholderView(frame: frame)
            placeholderView = placeholder
            addSubview(placeholder, positioned: .above, relativeTo: nil)
        } else {
            placeholderView?.frame = frame
        }
        if previewChanged {
            animateItemsAroundPlaceholder(
                draggedItemID: draggedItemID,
                insertionIndex: adjustedInsertionIndex
            )
        }
    }

    private func animateItemsAroundPlaceholder(draggedItemID: String?, insertionIndex: Int) {
        var items = itemIDsOnPage
        if let draggedItemID, let sourceIndex = items.firstIndex(of: draggedItemID) {
            items.remove(at: sourceIndex)
        }
        let insertion = min(max(insertionIndex, 0), items.count)
        let tileByID = Dictionary(
            subviews.compactMap { $0 as? LaunchpadTileView }.compactMap { tile in
                tile.itemID.map { ($0, tile) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        if let draggedItemID {
            tileByID[draggedItemID]?.alphaValue = 0.12
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            var itemIndex = 0
            for slot in 0..<columnCount * rowCount where slot != insertion {
                guard itemIndex < items.count, let tile = tileByID[items[itemIndex]] else { continue }
                tile.animator().frame = frameForSlot(slot)
                tile.alphaValue = 1
                itemIndex += 1
            }
        }
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender {
            let windowPoint = window?.convertPoint(fromScreen: sender.draggingLocation) ?? .zero
            if bounds.contains(convert(windowPoint, from: nil)) {
                cancelDragPreview()
                return
            }
        }
        cancelEdgePage()
        cancelDragPreview()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.string(forType: itemPasteboardType) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        cancelEdgePage()
        guard let itemID = sender.draggingPasteboard.string(forType: itemPasteboardType) else { return false }
        let windowPoint = window?.convertPoint(fromScreen: sender.draggingLocation) ?? .zero
        handleDragLocation(windowPoint, draggedItemID: itemID)
        let dropPoint = convert(windowPoint, from: nil)
        let appPath = sender.draggingPasteboard.string(forType: appPasteboardType)
        let isDropAtOrigin = dragOrigin.map {
            $0.itemID == itemID && $0.page == currentPage && slotFrame($0.slot).contains(dropPoint)
        } ?? false
        if !isDropAtOrigin,
           let tile = subviews.compactMap({ $0 as? LaunchpadTileView })
            .first(where: { $0.frame.contains(dropPoint) }),
           tile.handleDrop(appPath: appPath, at: dropPoint) {
            placeholderView?.removeFromSuperview()
            placeholderView = nil
            dropInsertionIndex = nil
            return true
        }
        onReorder?(itemID, currentDropIndex(fallback: currentPage * columnCount * rowCount))
        placeholderView?.removeFromSuperview()
        placeholderView = nil
        dropInsertionIndex = nil
        return true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let window else { return }
        handleDragLocation(
            window.convertPoint(fromScreen: screenPoint),
            draggedItemID: dragOrigin?.itemID
        )
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        cancelEdgePage()
        dragOrigin = nil
        if operation == [] {
            cancelDragPreview()
        }
    }

    private func finishScrollGesture() {
        scrollEndWorkItem?.cancel()
        scrollEndWorkItem = nil
        let horizontal = gestureDeltaX
        let vertical = gestureDeltaY
        gestureDeltaX = 0
        gestureDeltaY = 0
        onScroll?(horizontal, vertical)
    }
}

@MainActor
private final class LaunchpadTransitionSnapshotView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class LaunchpadDropPlaceholderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 16, yRadius: 16)
        let dash: [CGFloat] = [6, 4]
        shape.setLineDash(dash, count: dash.count, phase: 0)
        shape.lineWidth = 2
        NSColor.white.withAlphaComponent(0.20).setFill()
        shape.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        shape.stroke()
    }
}

@MainActor
private final class LaunchpadClickView: NSView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}

@MainActor
private final class LaunchpadMessageLabel: NSTextField {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

@MainActor
private final class LaunchpadTileTitleLabel: NSTextField {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

@MainActor
private final class LaunchpadTileView: NSView {
    private let title: String
    private let image: NSImage
    private let draggableAppPath: String?
    let itemID: String?
    private let iconSize: CGFloat
    private let onBeginDrag: ((String, String?, NSImage, NSEvent) -> Void)?
    private let onActivate: () -> Void
    private let onEmptyClick: (() -> Void)?
    private let onDropApp: (String, Bool) -> Void
    private let onTitleClick: (() -> Void)?
    private let onRename: (() -> Void)?
    private let onDissolve: (() -> Void)?
    private let onUnGroup: (() -> Void)?
    private let folderIcons: [NSImage]
    private let iconView = LaunchpadTileIconView()
    private let titleLabel = LaunchpadTileTitleLabel(labelWithString: "")

    init(
        title: String,
        image: NSImage,
        draggableAppPath: String?,
        draggableItemID: String?,
        iconSize: CGFloat,
        onBeginDrag: ((String, String?, NSImage, NSEvent) -> Void)? = nil,
        folderIcons: [NSImage] = [],
        onActivate: @escaping () -> Void,
        onEmptyClick: (() -> Void)? = nil,
        onDropApp: @escaping (String, Bool) -> Void,
        onTitleClick: (() -> Void)? = nil,
        onRename: (() -> Void)? = nil,
        onDissolve: (() -> Void)? = nil,
        onUnGroup: (() -> Void)? = nil
    ) {
        self.title = title
        self.image = image
        self.draggableAppPath = draggableAppPath
        self.itemID = draggableItemID
        self.iconSize = iconSize
        self.onBeginDrag = onBeginDrag
        self.folderIcons = folderIcons
        self.onActivate = onActivate
        self.onEmptyClick = onEmptyClick
        self.onDropApp = onDropApp
        self.onTitleClick = onTitleClick
        self.onRename = onRename
        self.onDissolve = onDissolve
        self.onUnGroup = onUnGroup
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 12
        iconView.configure(image: image, folderIcons: folderIcons)
        iconView.onMouseDown = { [weak self] event in self?.mouseDown(with: event) }
        addSubview(iconView)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 2
        titleLabel.onClick = onTitleClick ?? onEmptyClick
        addSubview(titleLabel)
        toolTip = draggableAppPath == nil
            ? "\(title) — Namen anklicken zum Umbenennen; Apps zum Gruppieren hierher ziehen"
            : "\(title) öffnen — Zum Gruppieren auf eine andere App ziehen"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let displayedSize = min(iconSize, max(36, bounds.height - 46))
        iconView.frame = NSRect(
            x: (bounds.width - displayedSize) / 2,
            y: 40,
            width: displayedSize,
            height: displayedSize
        )
        titleLabel.frame = NSRect(x: 2, y: 3, width: bounds.width - 4, height: 34)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { onEmptyClick?(); return }
        let start = convert(event.locationInWindow, from: nil)
        while let next = window.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if next.type == .leftMouseDragged, let itemID {
                let point = convert(next.locationInWindow, from: nil)
                if hypot(point.x - start.x, point.y - start.y) > 5 {
                    onBeginDrag?(itemID, draggableAppPath, image, next)
                    return
                }
            } else if next.type == .leftMouseUp {
                let point = convert(next.locationInWindow, from: nil)
                if iconView.frame.contains(point) {
                    onActivate()
                } else {
                    onEmptyClick?()
                }
                return
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard onRename != nil || onDissolve != nil || onUnGroup != nil else { return }
        let menu = NSMenu()
        self.pendingRename = onRename
        self.pendingDissolve = onDissolve
        self.pendingUnGroup = onUnGroup
        if onRename != nil {
            let rename = NSMenuItem(title: "Ordner umbenennen…", action: #selector(renameFolder), keyEquivalent: "")
            rename.target = self
            menu.addItem(rename)
        }
        if onDissolve != nil {
            let dissolve = NSMenuItem(title: "Ordner auflösen", action: #selector(dissolveFolder), keyEquivalent: "")
            dissolve.target = self
            menu.addItem(dissolve)
        }
        if onUnGroup != nil {
            let ungroup = NSMenuItem(title: "Aus Ordner entfernen", action: #selector(removeFromFolder), keyEquivalent: "")
            ungroup.target = self
            menu.addItem(ungroup)
        }
        menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
    }

    private var pendingRename: (() -> Void)?
    private var pendingDissolve: (() -> Void)?
    private var pendingUnGroup: (() -> Void)?

    @objc private func renameFolder() {
        pendingRename?()
    }

    @objc private func dissolveFolder() {
        pendingDissolve?()
    }

    @objc private func removeFromFolder() {
        pendingUnGroup?()
    }

    func handleDrop(appPath: String?, at pointInGrid: NSPoint) -> Bool {
        let point = convert(pointInGrid, from: superview)
        if let appPath, draggableAppPath == nil {
            onDropApp(appPath, false)
            return true
        }
        if let appPath,
           let targetPath = draggableAppPath,
           appPath != targetPath,
           iconView.frame.contains(point) {
            onDropApp(appPath, true)
            return true
        }
        return false
    }

}

@MainActor
private final class LaunchpadTileIconView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    private var image: NSImage?
    private var folderIcons: [NSImage] = []

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }

    func configure(image: NSImage, folderIcons: [NSImage]) {
        self.image = image
        self.folderIcons = folderIcons
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !folderIcons.isEmpty else {
            image?.draw(in: bounds)
            return
        }

        let glassShape = NSBezierPath(roundedRect: bounds, xRadius: bounds.width * 0.22, yRadius: bounds.width * 0.22)
        let glass = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.38),
            NSColor.white.withAlphaComponent(0.15)
        ])
        glass?.draw(in: glassShape, angle: 90)

        NSGraphicsContext.saveGraphicsState()
        glassShape.addClip()
        let inset = bounds.width * 0.12
        let gap = bounds.width * 0.06
        let cell = (bounds.width - inset * 2 - gap) / 2
        for (index, appIcon) in folderIcons.prefix(4).enumerated() {
            let column = index % 2
            let row = index / 2
            let rect = NSRect(
                x: inset + CGFloat(column) * (cell + gap),
                y: bounds.height - inset - cell - CGFloat(row) * (cell + gap),
                width: cell,
                height: cell
            )
            appIcon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.9)
        }
        NSGraphicsContext.restoreGraphicsState()

        glassShape.lineWidth = max(1, bounds.width * 0.018)
        NSColor.white.withAlphaComponent(0.58).setStroke()
        glassShape.stroke()
    }
}

@MainActor
private final class LaunchpadBackgroundView: NSView {
    var onBackgroundClick: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    private var style = "aurora"
    private var opacity: CGFloat = 0.88

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    func configure(style: String, opacity: CGFloat) {
        self.style = style
        self.opacity = min(max(opacity, 0), 1)
        needsDisplay = true
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let colors: [NSColor]
        switch style {
        case "ocean":
            colors = [
                NSColor(calibratedRed: 0.04, green: 0.22, blue: 0.48, alpha: opacity),
                NSColor(calibratedRed: 0.05, green: 0.46, blue: 0.58, alpha: opacity),
                NSColor(calibratedRed: 0.10, green: 0.30, blue: 0.55, alpha: opacity)
            ]
        case "sunset":
            colors = [
                NSColor(calibratedRed: 0.48, green: 0.16, blue: 0.35, alpha: opacity),
                NSColor(calibratedRed: 0.72, green: 0.30, blue: 0.28, alpha: opacity),
                NSColor(calibratedRed: 0.30, green: 0.18, blue: 0.46, alpha: opacity)
            ]
        case "midnight":
            colors = [
                NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.13, alpha: opacity),
                NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.24, alpha: opacity),
                NSColor(calibratedRed: 0.03, green: 0.10, blue: 0.19, alpha: opacity)
            ]
        default:
            colors = [
                NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.48, alpha: opacity),
                NSColor(calibratedRed: 0.32, green: 0.18, blue: 0.49, alpha: opacity),
                NSColor(calibratedRed: 0.12, green: 0.35, blue: 0.52, alpha: opacity)
            ]
        }
        guard let gradient = NSGradient(colors: colors) else { return }
        gradient.draw(in: bounds, angle: -35)
    }

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
