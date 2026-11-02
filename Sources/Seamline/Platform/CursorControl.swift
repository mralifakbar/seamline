import CoreGraphics
import Foundation

/// Freezes and hides the local pointer while input is going to another Mac.
enum CursorControl {
    private static let lock = NSLock()
    private static var hidden = false

    /// Background apps can only hide the cursor after opting in through this private CoreGraphics property.
    /// If the symbol ever disappears, the pointer still freezes at the edge; it just stays visible.
    static func prepare() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW),
              let connSym = dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty")
        else { return }
        let connection = unsafeBitCast(connSym, to: DefaultConnection.self)()
        _ = unsafeBitCast(setSym, to: SetProperty.self)(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    static func detach() {
        lock.lock(); defer { lock.unlock() }
        CGAssociateMouseAndMouseCursorPosition(0)
        if !hidden {
            CGDisplayHideCursor(CGMainDisplayID())
            hidden = true
        }
    }

    static func attach(at point: CGPoint) {
        lock.lock(); defer { lock.unlock() }
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        if hidden {
            CGDisplayShowCursor(CGMainDisplayID())
            hidden = false
        }
    }
}
