import Foundation
import Darwin

/// Filesystem helpers for the `.erosion_adlock` sentinel.
///
/// Kept separate from `AdLockPolicy` so the policy remains pure and testable;
/// the cleaner and the ad module both use this single sentinel source of truth.
enum AdLockSentinel {
    static let fileName = AdLockCatalog.sentinelFileName

    /// True when `path` is a directory containing the 0-byte sentinel.
    static func isLockedDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return hasSentinelDirectly(under: path)
    }

    /// True when `path` itself or any descendant directory contains a
    /// sentinel. Stops at the first hit; budgeted so a pathological cache
    /// tree cannot stall a scan.
    static func containsLockedDirectory(
        inSubtree path: String,
        maximumEntries: Int = 4000
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        if hasSentinelDirectly(under: path) { return true }

        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return false
        }

        var visited = 0
        for case let item as URL in enumerator {
            visited += 1
            if visited > maximumEntries { break }
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            if hasSentinelDirectly(under: item.path) {
                enumerator.skipDescendants()
                return true
            }
        }
        return false
    }

    static func hasSentinelDirectly(under directory: String) -> Bool {
        let sentinelPath = (directory as NSString).appendingPathComponent(fileName)
        var status = stat()
        return lstat(sentinelPath, &status) == 0 &&
            (status.st_mode & S_IFMT) == S_IFREG
    }

    static func hasSentinel(inDirectoryDescriptor descriptor: Int32) -> Bool {
        var status = stat()
        let result = fileName.withCString {
            fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        return result == 0 && (status.st_mode & S_IFMT) == S_IFREG
    }
}