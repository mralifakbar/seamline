import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import IOKit
import IOKit.ps
import ServiceManagement
import SeamlineCore

enum SystemInfo {
    static var computerName: String {
        Host.current().localizedName ?? "Mac"
    }

    /// Active displays in global points. Mirrored displays share bounds, so duplicates collapse.
    static func displays() -> [Rect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        var rects: [Rect] = []
        for id in ids.prefix(Int(count)) {
            let b = CGDisplayBounds(id)
            let rect = Rect(x: b.origin.x, y: b.origin.y, width: b.width, height: b.height)
            if !rects.contains(rect) { rects.append(rect) }
        }
        return rects
    }

    /// IPv4 addresses another Mac can reach this one at. 100.64.0.0/10 is the carrier-grade NAT range VPNs such as Tailscale use.
    static func addresses() -> [(address: String, vpn: Bool)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [(String, Bool)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard !text.hasPrefix("169.254."), !result.contains(where: { $0.0 == text }) else { continue }
            let octets = text.split(separator: ".").compactMap { Int($0) }
            let vpn = octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
            result.append((text, vpn))
        }
        return result.sorted { !$0.1 && $1.1 }
    }

    static var kind: MachineKind {
        if hasInternalBattery { return .laptop }
        let hasBuiltIn = (try? activeDisplayIDs())?.contains { CGDisplayIsBuiltin($0) != 0 } ?? false
        return hasBuiltIn ? .allInOne : .desktop
    }

    private static func activeDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    private static var hasInternalBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { source in
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}

enum Permissions {
    /// Needed by both roles: an active event tap on the host, posting events on the guest.
    static var accessibility: Bool { AXIsProcessTrusted() }
    /// Needed by the host so keystrokes reach the tap while the pointer is on another Mac.
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) { open("Privacy_Accessibility") }
    }

    static func requestInputMonitoring() {
        if !CGRequestListenEventAccess() { open("Privacy_ListenEvent") }
    }

    static func openLocalNetworkSettings() { open("Privacy_LocalNetwork") }

    private static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum SecureInput {
    /// Name of the app holding Secure Input, which hides keystrokes from every event tap (password fields, some terminals).
    static func owner() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]]
        else { return "Another app" }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int,
               let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                return app.localizedName ?? "Another app"
            }
        }
        return "Another app"
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

enum Pasteboard {
    /// Standard formats only. Apps also publish private types, and copying those across Macs wastes bandwidth.
    static let types = [
        "public.utf8-plain-text", "public.rtf", "public.html", "com.apple.flat-rtfd",
        "public.png", "public.tiff", "com.adobe.pdf", "public.url",
    ]
    static let maxBytes = 48 << 20

    static var changeCount: Int { NSPasteboard.general.changeCount }

    static func read() -> ClipboardPayload? {
        guard let item = NSPasteboard.general.pasteboardItems?.first else { return nil }
        var items: [ClipboardPayload.Item] = []
        var total = 0
        for type in types {
            guard let data = item.data(forType: NSPasteboard.PasteboardType(type)) else { continue }
            guard total + data.count <= maxBytes else { continue }
            items.append(.init(type: type, data: data))
            total += data.count
        }
        return items.isEmpty ? nil : ClipboardPayload(items: items)
    }

    /// Writes and returns the new change count, so the write is not mistaken for a local copy later.
    @discardableResult
    static func write(_ payload: ClipboardPayload) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        for entry in payload.items where types.contains(entry.type) {
            item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
        }
        pb.writeObjects([item])
        return pb.changeCount
    }
}
