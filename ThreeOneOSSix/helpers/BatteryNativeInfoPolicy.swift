import Foundation

/// Pure hardware check for devices that natively expose Battery Cycle Count
/// and Manufacture Date in Settings (iOS/iPadOS 17.4+).
///
/// Enabling the legacy battery keys on these devices would shadow the native
/// information, so the Gestalt card locks that preset off.
enum BatteryNativeInfoPolicy {
    static func isNative(machineModel: String) -> Bool {
        let machine = machineModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !machine.isEmpty else { return false }

        if machine == "iPhone15,4" || machine == "iPhone15,5" {
            return true
        }
        if machine.hasPrefix("iPhone"),
           let major = majorVersion(in: machine, prefix: "iPhone"),
           major >= 16 {
            return true
        }

        let modernIPads: Set<String> = [
            "iPad14,8", "iPad14,9", "iPad14,10", "iPad14,11",
            "iPad15,3", "iPad15,4", "iPad15,5", "iPad15,6",
            "iPad15,7", "iPad15,8",
        ]
        if modernIPads.contains(machine) {
            return true
        }
        if machine.hasPrefix("iPad"),
           let major = majorVersion(in: machine, prefix: "iPad"),
           major >= 16 {
            return true
        }
        return false
    }

    /// The factory machine identifier, reusing the same saved-original-first
    /// rule as the MobileGestalt layout coordinator. Lives at the call site
    /// (`currentOriginalMachineName()`) so this policy stays pure for tests.
    private static func majorVersion(in machine: String, prefix: String) -> Int? {
        let rest = machine.dropFirst(prefix.count)
        guard let majorPart = rest.split(separator: ",").first else { return nil }
        return Int(majorPart)
    }
}