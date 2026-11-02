import AppKit
import Combine
import SwiftUI
import SeamlineCore

enum Role: String {
    /// This Mac's keyboard and mouse drive the others.
    case host
    /// Another Mac drives this one.
    case guest
}

enum EdgeResistanceSetting: String, CaseIterable, Identifiable {
    case none, light, firm
    var id: String { rawValue }
    var distance: Double {
        switch self {
        case .none: return 0
        case .light: return 30
        case .firm: return 110
        }
    }
    var title: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .firm: return "Firm"
        }
    }
}

struct Machine: Identifiable, Equatable {
    enum Status: Equatable {
        /// Seen on the network, never paired.
        case nearby
        case connecting
        case pairing
        case connected
        /// Paired before, not reachable now.
        case offline
    }

    let id: UUID
    var name: String
    var kind: MachineKind
    var displays: [Rect]
    var status: Status
    var isPaired: Bool
    /// Measured round trip in milliseconds, only while connected.
    var latency: Double? = nil
    var link: LinkKind? = nil

}

struct PairingPrompt: Identifiable, Equatable {
    let id: UUID
    let name: String
    let code: String
    var waiting: Bool
}

@MainActor
final class AppModel: ObservableObject {
    let vault = Vault()
    var identity: Identity { vault.identity }

    @Published var role: Role? {
        didSet {
            UserDefaults.standard.set(role?.rawValue, forKey: "role")
            if oldValue != role { restartSession() }
        }
    }
    @Published private(set) var accessibilityGranted = Permissions.accessibility
    @Published private(set) var inputMonitoringGranted = Permissions.inputMonitoring
    @Published var setupComplete: Bool {
        didSet { UserDefaults.standard.set(setupComplete, forKey: "setupComplete"); restartSession() }
    }

    @Published var machines: [Machine] = []
    @Published var layout = Layout()
    @Published var focus: Focus = .local
    @Published var pairing: PairingPrompt?
    @Published var notice: String?
    @Published var discoveryProblem: DiscoveryProblem?
    @Published var secureInputApp: String?
    @Published var tapFailed = false
    /// Guest only: the Mac currently driving this one.
    @Published var controller: String?
    /// Guest only: where another Mac can reach this one when Bonjour cannot (VPN, Tailscale).
    @Published var listenAddresses: [String] = []

    @Published var paused = false {
        didSet { host?.setPaused(paused) }
    }
    @Published var resistance: EdgeResistanceSetting {
        didSet { UserDefaults.standard.set(resistance.rawValue, forKey: "resistance"); host?.engine.setResistance(resistance.distance) }
    }
    @Published var clipboardSync: Bool {
        didSet { UserDefaults.standard.set(clipboardSync, forKey: "clipboardSync") }
    }
    @Published var showInDock: Bool {
        didSet { UserDefaults.standard.set(showInDock, forKey: "showInDock"); applyDockPolicy() }
    }
    @Published var launchAtLogin = LoginItem.isEnabled

    #if DEBUG
    /// Snapshot scenarios fill the model with sample state and skip real sessions.
    var previewing = false
    #endif

    private(set) var host: HostSession?
    private(set) var guest: GuestSession?
    private var permissionTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let defaults = UserDefaults.standard
        role = defaults.string(forKey: "role").flatMap(Role.init(rawValue:))
        setupComplete = defaults.bool(forKey: "setupComplete")
        resistance = defaults.string(forKey: "resistance").flatMap(EdgeResistanceSetting.init(rawValue:)) ?? .light
        clipboardSync = defaults.object(forKey: "clipboardSync") as? Bool ?? true
        showInDock = defaults.object(forKey: "showInDock") as? Bool ?? true
        if let data = defaults.data(forKey: "layout"), let saved = try? JSONDecoder().decode(Layout.self, from: data) {
            layout = saved
        }
        #if DEBUG
        // A snapshot run shows sample state only: no real discovery, event tap or network traffic.
        previewing = ProcessInfo.processInfo.environment["SEAMLINE_SCENARIO"] != nil
        #endif
        CursorControl.prepare()
        applyDockPolicy()
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.displaysChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.host?.reconnectAll() }
        })
        watchPermissions()
        restartSession()
    }

    var permissionsReady: Bool {
        #if DEBUG
        if previewing || Snapshot.autopair { return true }
        #endif
        switch role {
        case .host: return accessibilityGranted && inputMonitoringGranted
        case .guest: return accessibilityGranted
        case nil: return false
        }
    }

    var isRunning: Bool { setupComplete && permissionsReady && role != nil }

    // MARK: Permissions

    func refreshPermissions() {
        let a = Permissions.accessibility, i = Permissions.inputMonitoring
        let changed = a != accessibilityGranted || i != inputMonitoringGranted
        accessibilityGranted = a
        inputMonitoringGranted = i
        if changed { restartSession() }
    }

    /// TCC has no change notification, so poll gently. The check is a cheap in-process call.
    private func watchPermissions() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    // MARK: Sessions

    private func restartSession() {
        #if DEBUG
        if previewing { return }
        #endif
        host?.stop(); host = nil
        guest?.stop(); guest = nil
        machines = []
        pairing = nil
        focus = .local
        controller = nil
        guard isRunning, let role else { return }
        switch role {
        case .host:
            if layout.cell(of: identity.id.uuidString) == nil { layout.place(identity.id.uuidString, at: Cell(x: 0, y: 0)) }
            let session = HostSession(model: self)
            host = session
            session.start()
        case .guest:
            let session = GuestSession(model: self)
            guest = session
            session.start()
        }
    }

    private func displaysChanged() {
        host?.engine.localDisplaysChanged()
        guest?.broadcastDisplays()
    }

    func saveLayout() {
        layout.normalize()
        if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: "layout") }
        host?.engine.setLayout(layout)
    }

    func move(_ id: UUID, to cell: Cell) {
        layout.place(id.uuidString, at: cell)
        saveLayout()
    }

    func pair(_ id: UUID) { host?.pair(id) }
    func connect(address: String) -> String? { host?.connect(address: address) }
    func acceptPairing() { host?.acceptPairing(); guest?.acceptPairing() }
    func declinePairing() { host?.declinePairing(); guest?.declinePairing() }

    func forget(_ id: UUID) {
        vault.forget(id)
        layout.remove(id.uuidString)
        saveLayout()
        host?.forget(id)
        guest?.forget(id)
    }

    func changeRole() {
        setupComplete = false
        role = nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
        } catch {
            notice = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = LoginItem.isEnabled
    }

    private func applyDockPolicy() {
        NSApp?.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    // MARK: Helpers for views

    var thisMac: Machine {
        Machine(id: identity.id, name: identity.name, kind: SystemInfo.kind, displays: SystemInfo.displays(), status: .connected, isPaired: true)
    }

    func machine(_ id: UUID) -> Machine? {
        id == identity.id ? thisMac : machines.first { $0.id == id }
    }

    var focusName: String? {
        if case .remote(let id) = focus { return machine(id)?.name }
        return nil
    }
}
