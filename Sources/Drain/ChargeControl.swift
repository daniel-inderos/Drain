import Foundation
import ObjectiveC

/// What macOS is doing about filling the battery, beyond "charging or not".
struct ChargePolicy: Equatable {
    /// macOS is keeping the charge below full on purpose: Optimized Battery
    /// Charging has paused it, or a charge limit is set.
    var limited = false
    /// The level it stops at, when macOS says. nil when it doesn't.
    var limit: Int?
    /// A pause or limit was lifted, here or in macOS's own menu: this charge goes to 100%.
    var chargingToFull = false

    /// From the raw answers of the system's charging service. Its state values,
    /// as seen on macOS 27.3: 0 off, 1 on, 3 lifted for this charge.
    static func from(optimizedPaused: Bool, pausedAt: Int, optimizedState: Int,
                     limitState: Int, limitPercent: Int) -> ChargePolicy {
        let lifted = 3
        let limitOn = limitState != 0 && limitState != lifted && (1..<100).contains(limitPercent)
        var policy = ChargePolicy()
        policy.limited = optimizedPaused || limitOn
        if limitOn { policy.limit = limitPercent }
        if optimizedPaused, (1..<100).contains(pausedAt) { policy.limit = min(policy.limit ?? 100, pausedAt) }
        policy.chargingToFull = !policy.limited && (optimizedState == lifted || limitState == lifted)
        return policy
    }
}

/// Talks to the service behind macOS's own "Charge to Full Now" (PowerUI's smart
/// charge client). It is a private interface, so everything is looked up at run
/// time: if any piece is missing on some macOS release, `read` reports nothing,
/// the menu item never appears, and the rest of Drain is unaffected.
enum ChargeControl {
    private typealias ErrorOut = AutoreleasingUnsafeMutablePointer<NSError?>
    private typealias InitFn = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
    private typealias StateFn = @convention(c) (AnyObject, Selector, ErrorOut) -> UInt
    private typealias ByteFn = @convention(c) (AnyObject, Selector, ErrorOut) -> UInt8
    private typealias BoolFn = @convention(c) (AnyObject, Selector, ErrorOut) -> ObjCBool
    private typealias EngagedFn = @convention(c) (
        AnyObject, Selector, UnsafeMutablePointer<ObjCBool>, UnsafeMutablePointer<UInt>,
        UnsafeMutablePointer<ObjCBool>, ErrorOut) -> ObjCBool

    private struct Client: @unchecked Sendable {   // only used on `queue`
        let object: AnyObject
        let cls: AnyClass

        func imp<T>(_ name: String, as type: T.Type) -> (T, Selector)? {
            let sel = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(cls, sel) else { return nil }
            return (unsafeBitCast(method_getImplementation(method), to: T.self), sel)
        }
    }

    private static let queue = DispatchQueue(label: "drain.charge-control")
    private static let client: Client? = {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient"),
              let alloc = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let method = class_getInstanceMethod(cls, NSSelectorFromString("initWithClientName:"))
        else { return nil }
        let create = unsafeBitCast(method_getImplementation(method), to: InitFn.self)
        guard let object = create(alloc, NSSelectorFromString("initWithClientName:"), "Drain") else { return nil }
        return Client(object: object, cls: cls)
    }()

    /// nil when the service can't be reached or doesn't look the way it did.
    static func read() -> ChargePolicy? {
        queue.sync {
            guard let client,
                  let (engaged, engagedSel) = client.imp(
                    "isOBCEngaged:chargeLimit:chargingOverrideAllowed:withError:", as: EngagedFn.self),
                  let (optimized, optimizedSel) = client.imp("isSmartChargingCurrentlyEnabled:", as: StateFn.self),
                  let (limitState, limitStateSel) = client.imp("isMCLCurrentlyEnabled:", as: StateFn.self),
                  let (limitValue, limitValueSel) = client.imp("getMCLLimitWithError:", as: ByteFn.self)
            else { return nil }

            var error: NSError?
            var paused = ObjCBool(false), allowed = ObjCBool(false)
            var pausedAt: UInt = 100
            guard engaged(client.object, engagedSel, &paused, &pausedAt, &allowed, &error).boolValue, error == nil
            else { return nil }
            let state = optimized(client.object, optimizedSel, &error)
            let mcl = limitState(client.object, limitStateSel, &error)
            let percent = limitValue(client.object, limitValueSel, &error)
            guard error == nil else { return nil }
            return ChargePolicy.from(optimizedPaused: paused.boolValue, pausedAt: Int(clamping: pausedAt),
                                     optimizedState: Int(clamping: state), limitState: Int(clamping: mcl),
                                     limitPercent: Int(percent))
        }
    }

    /// Lifts the pause and the limit for this charge only, as macOS's own
    /// "Charge to Full Now" does. Nothing in Battery settings is changed.
    @discardableResult
    static func chargeToFull() -> Bool {
        queue.sync {
            guard let client else { return false }
            var done = false
            for name in ["temporarilyDisableSmartCharging:", "temporarilyDisableMCL:"] {
                guard let (call, sel) = client.imp(name, as: BoolFn.self) else { continue }
                var error: NSError?
                if call(client.object, sel, &error).boolValue, error == nil {
                    done = true
                } else {
                    debugLog("\(name) failed: \(error?.localizedDescription ?? "no reason given")")
                }
            }
            return done
        }
    }
}
