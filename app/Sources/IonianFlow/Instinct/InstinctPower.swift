import Foundation
import IOKit.ps

/// Power state for the battery rule (F1.10).
struct InstinctPower: Equatable, Sendable {
    var onBattery: Bool
    var percent: Int

    /// Reads the internal battery; a Mac without one counts as plugged in.
    static func current() -> InstinctPower {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return InstinctPower(onBattery: false, percent: 100)
        }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let state = d[kIOPSPowerSourceStateKey] as? String
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 100
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            return InstinctPower(onBattery: state == kIOPSBatteryPowerValue, percent: max > 0 ? cur * 100 / max : 100)
        }
        return InstinctPower(onBattery: false, percent: 100)
    }
}
