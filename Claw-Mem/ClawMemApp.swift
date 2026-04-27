import SwiftUI
import SwiftData
import Sparkle

// MARK: - Menu bar bridge (stable observable so the hosting controller never swaps view types)

@Observable
final class MenuBarBridge {
    var coordinator: IngestCoordinator?
}

// Thin wrapper with a stable type identity — avoids AnyView diffing issues.
private struct MenuBarRoot: View {
    let bridge: MenuBarBridge
    var body: some View {
        if let coordinator = bridge.coordinator {
            MenuBarView().environment(coordinator)
        } else {
            Color.clear.frame(width: 300, height: 1)
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let bridge = MenuBarBridge()
    private var hostingController: NSHostingController<MenuBarRoot>?
    private var labelHostingView: NSHostingView<AnyView>?
    private weak var observedCoordinator: IngestCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "brain.head.profile",
                                   accessibilityDescription: "Claw-Mem")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let hc = NSHostingController(rootView: MenuBarRoot(bridge: bridge))
        hostingController = hc

        let p = NSPopover()
        p.contentViewController = hc
        p.behavior = .transient
        p.animates = false
        popover = p
    }

    /// Called from MainView.onAppear once the SwiftUI environment is ready.
    func attachMenuBar(coordinator: IngestCoordinator) {
        observedCoordinator = coordinator
        bridge.coordinator = coordinator  // triggers MenuBarRoot to swap from clear → MenuBarView
        setupLabel(coordinator: coordinator)
        observeLabelChanges()
    }

    private func setupLabel(coordinator: IngestCoordinator) {
        guard let button = statusItem?.button else { return }
        button.image = nil
        labelHostingView?.removeFromSuperview()

        let view = NSHostingView(rootView: AnyView(MenuBarLabel(coordinator: coordinator)))
        view.sizingOptions = .intrinsicContentSize
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        labelHostingView = view
        updateStatusItemLength()
    }

    private func observeLabelChanges() {
        guard let coordinator = observedCoordinator else { return }
        withObservationTracking {
            _ = coordinator.messageCountByDateProject.count
        } onChange: { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.updateStatusItemLength()
                self?.observeLabelChanges()
            }
        }
    }

    private func updateStatusItemLength() {
        guard let view = labelHostingView else { return }
        let width = view.intrinsicContentSize.width
        statusItem?.length = max(width + 4, 26)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // NSPopover.show() does NOT activate the app, so macOS will NOT
            // switch Spaces to wherever the main window is.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let win = popover.contentViewController?.view.window {
                // canJoinAllSpaces ensures the popover appears on whichever
                // Space the user is on, not the Space that hosts the main window.
                win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                win.makeKey()
            }
        }
    }
}

// MARK: - App

@main
struct ClawMemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    let modelContainer: ModelContainer
    @State private var ingestCoordinator: IngestCoordinator
    @State private var settings: AppSettings
    @State private var syncService: SyncService

    init() {
        setenv("MTL_DEBUG_LAYER_WARNING_MODE", "ignore", 1)
        do {
            let container = try makeModelContainer()
            self.modelContainer = container
            let appSettings = AppSettings()
            self._settings = State(initialValue: appSettings)
            let coord = IngestCoordinator(modelContainer: container)
            self._ingestCoordinator = State(initialValue: coord)
            let sync = SyncService(
                modelContainer: container,
                coordinator: coord,
                deviceID: appSettings.deviceID
            )
            sync.setFolder(appSettings.syncFolderPath)
            self._syncService = State(initialValue: sync)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(ingestCoordinator)
                .environment(settings)
                .environment(syncService)
                .onAppear {
                    // Show previously-ingested data immediately. Ingest
                    // and sync are now both fully manual — user triggers
                    // them via the toolbar buttons.
                    ingestCoordinator.loadInitialIndex()
                    appDelegate.attachMenuBar(coordinator: ingestCoordinator)
                }
                .onDisappear {
                    ingestCoordinator.stopIngest()
                }
                .onChange(of: settings.syncFolderPath) { _, newPath in
                    syncService.setFolder(newPath)
                }
        }
        .defaultSize(width: NSScreen.main?.visibleFrame.width ?? 1200,
                     height: NSScreen.main?.visibleFrame.height ?? 800)

        Settings {
            SettingsView(updater: updaterController.updater)
                .environment(settings)
                .environment(syncService)
        }
    }
}
