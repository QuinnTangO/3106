import Foundation
import Darwin

// MARK: - Models

struct AdLockItem: Identifiable, Hashable, Sendable {
    let id: String
    let fullPath: String
    let relativePath: String
    let isDirectory: Bool
    let marker: String
    let isCustomRule: Bool
    let mode: Int
    let cachedBytes: Int64
    let hasSentinel: Bool
    let isWhitelisted: Bool
    let isPathWhitelisted: Bool
    let isContainerWhitelisted: Bool

    var isLockedReadOnly: Bool {
        if isDirectory {
            return hasSentinel && AdLockPolicy.isReadOnlyMode(mode)
        }
        return AdLockPolicy.isReadOnlyMode(mode)
    }

    /// A directory left at 0555 by an older build has no sentinel; locking it
    /// again both recreates the sentinel and makes the lock durable.
    var needsHarden: Bool {
        isDirectory && AdLockPolicy.isReadOnlyMode(mode) && !hasSentinel
    }

    var needsActionToLock: Bool {
        if isWhitelisted { return false }
        if isDirectory { return !isLockedReadOnly || needsHarden }
        return !isLockedReadOnly
    }
}

struct AdLockAppEntry: Identifiable, Hashable, Sendable {
    let id: String
    let containerID: String
    let displayName: String
    let containerPath: String
    let isAppGroup: Bool
    let isWhitelisted: Bool
    let items: [AdLockItem]

    var lockedCount: Int {
        items.filter { !$0.isWhitelisted && $0.isLockedReadOnly }.count
    }

    var pendingCount: Int {
        items.filter { $0.needsActionToLock }.count
    }

    var reclaimableBytes: Int64 {
        items.filter { !$0.isWhitelisted && !$0.isLockedReadOnly }
            .reduce(0) { $0 + $1.cachedBytes }
    }
}

struct AdLockScanSnapshot: Sendable {
    let entries: [AdLockAppEntry]
    let scannedContainers: Int
    let deniedContainers: Int
    let cancelled: Bool
}

struct AdLockMutationResult: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let ok: Bool
    let mode: Int
    let hasSentinel: Bool
    let error: String?
}

final class AdLockScanCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private struct AdLockContainer {
    let containerID: String
    let displayName: String
    let containerPath: String
    let isAppGroup: Bool
}

// MARK: - Service

enum AdLockService {
    static var isAvailable: Bool {
        SandboxAccess.backend != .unsupported
    }

    static func displayName(for entry: AdLockAppEntry, languageCode: String) -> String {
        if entry.isAppGroup {
            let candidate = entry.containerID.hasPrefix("group.")
                ? String(entry.containerID.dropFirst("group.".count))
                : entry.containerID
            return AdLockCatalog.displayName(
                bundleID: candidate,
                languageCode: languageCode,
                fallback: entry.displayName
            )
        }
        return AdLockCatalog.displayName(
            bundleID: entry.containerID,
            languageCode: languageCode,
            fallback: entry.displayName
        )
    }

    // MARK: - Scan

    static func scan(
        cancel: AdLockScanCancellationFlag,
        progress: ((Int, Int) -> Void)? = nil
    ) -> AdLockScanSnapshot {
        guard isAvailable else {
            return AdLockScanSnapshot(
                entries: [],
                scannedContainers: 0,
                deniedContainers: 0,
                cancelled: false
            )
        }

        let selfBundleID = Bundle.main.bundleIdentifier ?? ""
        let selfAppGroupID = SandboxAccess.appGroup
        let containers = enumerateContainers()
        progress?(0, containers.count)

        var entries: [AdLockAppEntry] = []
        var denied = 0
        var completed = 0

        for container in containers {
            if cancel.isCancelled {
                return AdLockScanSnapshot(
                    entries: sorted(entries),
                    scannedContainers: completed,
                    deniedContainers: denied,
                    cancelled: true
                )
            }

            if AdLockPolicy.isIgnoredContainer(
                id: container.containerID,
                isAppGroup: container.isAppGroup,
                selfBundleID: selfBundleID,
                selfAppGroupID: selfAppGroupID
            ) {
                completed += 1
                progress?(completed, containers.count)
                continue
            }

            if let entry = scanContainer(
                container,
                cancel: cancel,
                selfBundleID: selfBundleID,
                selfAppGroupID: selfAppGroupID
            ) {
                entries.append(entry)
            } else {
                denied += 1
            }

            completed += 1
            progress?(completed, containers.count)
        }

        return AdLockScanSnapshot(
            entries: sorted(entries),
            scannedContainers: completed,
            deniedContainers: denied,
            cancelled: cancel.isCancelled
        )
    }

    static func sorted(_ entries: [AdLockAppEntry]) -> [AdLockAppEntry] {
        entries.sorted { lhs, rhs in
            if lhs.items.isEmpty != rhs.items.isEmpty {
                return !lhs.items.isEmpty
            }
            if lhs.isWhitelisted != rhs.isWhitelisted {
                return !lhs.isWhitelisted
            }
            if lhs.items.count != rhs.items.count {
                return lhs.items.count > rhs.items.count
            }
            if lhs.isAppGroup != rhs.isAppGroup {
                return !lhs.isAppGroup
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private static func scanContainer(
        _ container: AdLockContainer,
        cancel: AdLockScanCancellationFlag,
        selfBundleID: String,
        selfAppGroupID: String?
    ) -> AdLockAppEntry? {
        let containerRoot = AdLockPolicy.canonicalVarPath(container.containerPath)
        let isWhitelisted = AdLockWhitelistStore.shared.isContainerWhitelisted(
            id: container.containerID,
            isAppGroup: container.isAppGroup
        )
        let customRules = AdLockCustomWatchStore.shared.rulesSnapshot()
        let knownPaths = container.isAppGroup
            ? []
            : AdLockCatalog.knownPaths(for: container.containerID)

        var items: [AdLockItem] = []
        var seen = Set<String>()
        var accessDenied = false

        do {
            try SandboxAccess.withGrant(directory: container.containerPath, writable: false) {
                // Pass A: curated paths.
                for known in knownPaths {
                    if cancel.isCancelled { return }
                    let fullPath = (containerRoot as NSString)
                        .appendingPathComponent(known.relativePath)
                    if let item = inspectTarget(
                        path: fullPath,
                        relativePath: known.relativePath,
                        containerRoot: containerRoot,
                        containerID: container.containerID,
                        isAppGroup: container.isAppGroup,
                        isContainerWhitelisted: isWhitelisted,
                        isCustomRule: false,
                        marker: (known.relativePath as NSString).lastPathComponent,
                        selfBundleID: selfBundleID,
                        selfAppGroupID: selfAppGroupID,
                        cancel: cancel
                    ), seen.insert(item.id).inserted {
                        items.append(item)
                    }
                }

                // Pass B: user-curated rules inside this container.
                for rule in customRules {
                    if cancel.isCancelled { return }
                    let canonical = AdLockPolicy.canonicalVarPath(rule.fullPath)
                    guard canonical.hasPrefix(containerRoot + "/") else { continue }
                    let relative = String(canonical.dropFirst(containerRoot.count + 1))
                    if let item = inspectTarget(
                        path: canonical,
                        relativePath: relative,
                        containerRoot: containerRoot,
                        containerID: container.containerID,
                        isAppGroup: container.isAppGroup,
                        isContainerWhitelisted: isWhitelisted,
                        isCustomRule: true,
                        marker: (canonical as NSString).lastPathComponent,
                        selfBundleID: selfBundleID,
                        selfAppGroupID: selfAppGroupID,
                        cancel: cancel
                    ), seen.insert(item.id).inserted {
                        items.append(item)
                    }
                }

                // Pass C: shallow SDK scan of the disposable roots.
                let scanRoots = [
                    "Documents",
                    "Library/Caches",
                    "Library/Application Support",
                    "tmp",
                ]
                for root in scanRoots {
                    if cancel.isCancelled { return }
                    let rootPath = (containerRoot as NSString).appendingPathComponent(root)
                    shallowScan(
                        directory: rootPath,
                        containerRoot: containerRoot,
                        depth: 0,
                        maxDepth: AdLockCatalog.maximumScanDepth,
                        containerID: container.containerID,
                        isAppGroup: container.isAppGroup,
                        isContainerWhitelisted: isWhitelisted,
                        selfBundleID: selfBundleID,
                        selfAppGroupID: selfAppGroupID,
                        seen: &seen,
                        results: &items,
                        cancel: cancel
                    )
                }
            }
        } catch {
            accessDenied = true
        }

        guard !accessDenied else { return nil }
        guard !cancel.isCancelled else { return nil }

        return AdLockAppEntry(
            id: (container.isAppGroup ? "g:" : "a:") + container.containerID.lowercased(),
            containerID: container.containerID,
            displayName: container.displayName,
            containerPath: containerRoot,
            isAppGroup: container.isAppGroup,
            isWhitelisted: isWhitelisted,
            items: items.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
        )
    }

    private static func shallowScan(
        directory: String,
        containerRoot: String,
        depth: Int,
        maxDepth: Int,
        containerID: String,
        isAppGroup: Bool,
        isContainerWhitelisted: Bool,
        selfBundleID: String,
        selfAppGroupID: String?,
        seen: inout Set<String>,
        results: inout [AdLockItem],
        cancel: AdLockScanCancellationFlag
    ) {
        guard depth <= maxDepth, !cancel.isCancelled else { return }
        guard let dir = opendir(directory) else { return }
        defer { closedir(dir) }

        while let entryPointer = readdir(dir) {
            if cancel.isCancelled { return }
            let entry = entryPointer.pointee
            let nameLength = Int(entry.d_namlen)
            guard nameLength > 0,
                  let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name) else {
                continue
            }
            let namePointer = UnsafeRawPointer(entryPointer)
                .advanced(by: nameOffset)
                .assumingMemoryBound(to: CChar.self)
            if namePointer[0] == 0x2E { continue }
            let name = String(cString: namePointer)
            let lower = name.lowercased()
            if AdLockCatalog.neverTouchOrDescend.contains(lower) { continue }

            let childPath = (directory as NSString).appendingPathComponent(name)
            var status = stat()
            guard lstat(childPath, &status) == 0 else { continue }
            let format = status.st_mode & S_IFMT
            guard format == S_IFDIR || format == S_IFREG else { continue }

            let canonical = AdLockPolicy.canonicalVarPath(childPath)
            if seen.contains(canonical) { continue }

            if format == S_IFDIR {
                if let marker = AdLockPolicy.classifyAdFolder(name: name) {
                    let relative = canonical.hasPrefix(containerRoot + "/")
                        ? String(canonical.dropFirst(containerRoot.count + 1))
                        : name
                    if let item = inspectTarget(
                        path: canonical,
                        relativePath: relative,
                        containerRoot: containerRoot,
                        containerID: containerID,
                        isAppGroup: isAppGroup,
                        isContainerWhitelisted: isContainerWhitelisted,
                        isCustomRule: false,
                        marker: marker,
                        selfBundleID: selfBundleID,
                        selfAppGroupID: selfAppGroupID,
                        cancel: cancel
                    ), seen.insert(item.id).inserted {
                        results.append(item)
                    }
                    continue
                }
                if depth < maxDepth {
                    shallowScan(
                        directory: childPath,
                        containerRoot: containerRoot,
                        depth: depth + 1,
                        maxDepth: maxDepth,
                        containerID: containerID,
                        isAppGroup: isAppGroup,
                        isContainerWhitelisted: isContainerWhitelisted,
                        selfBundleID: selfBundleID,
                        selfAppGroupID: selfAppGroupID,
                        seen: &seen,
                        results: &results,
                        cancel: cancel
                    )
                }
            } else if AdLockPolicy.isAdConfigFile(name: name) {
                let relative = canonical.hasPrefix(containerRoot + "/")
                    ? String(canonical.dropFirst(containerRoot.count + 1))
                    : name
                if let item = inspectTarget(
                    path: canonical,
                    relativePath: relative,
                    containerRoot: containerRoot,
                    containerID: containerID,
                    isAppGroup: isAppGroup,
                    isContainerWhitelisted: isContainerWhitelisted,
                    isCustomRule: false,
                    marker: name,
                    selfBundleID: selfBundleID,
                    selfAppGroupID: selfAppGroupID,
                    cancel: cancel
                ), seen.insert(item.id).inserted {
                    results.append(item)
                }
            }
        }
    }

    private static func inspectTarget(
        path: String,
        relativePath: String,
        containerRoot: String,
        containerID: String,
        isAppGroup: Bool,
        isContainerWhitelisted: Bool,
        isCustomRule: Bool,
        marker: String,
        selfBundleID: String,
        selfAppGroupID: String?,
        cancel: AdLockScanCancellationFlag
    ) -> AdLockItem? {
        let canonical = AdLockPolicy.canonicalVarPath(path)
        guard canonical.hasPrefix(containerRoot + "/") else { return nil }
        var status = stat()
        guard lstat(canonical, &status) == 0 else { return nil }
        let format = status.st_mode & S_IFMT
        guard format == S_IFDIR || format == S_IFREG else { return nil }

        let owner = (try? FileManager.default.attributesOfItem(atPath: canonical)[.ownerAccountName] as? String) ?? nil
        let isDirectory = format == S_IFDIR
        let validation = AdLockPolicy.validateTarget(
            path: canonical,
            isDirectory: isDirectory,
            ownerAccountName: owner,
            isSymbolicLink: format == S_IFLNK,
            selfBundleID: selfBundleID,
            selfAppGroupID: selfAppGroupID,
            resolvedContainerID: containerID
        )
        guard validation.allowed else { return nil }

        let mode = Int(status.st_mode) & 0o777
        let sentinelPath = (canonical as NSString).appendingPathComponent(AdLockCatalog.sentinelFileName)
        var sentinelStatus = stat()
        let hasSentinel = lstat(sentinelPath, &sentinelStatus) == 0 &&
            ((sentinelStatus.st_mode & S_IFMT) == S_IFREG)

        let bytes: Int64
        if isDirectory {
            bytes = fastFolderSize(atPath: canonical, maxDepth: 6, cancel: cancel)
        } else {
            bytes = max(0, Int64(status.st_size))
        }

        let pathWhitelisted = AdLockWhitelistStore.shared.isPathWhitelisted(canonical)
        return AdLockItem(
            id: canonical,
            fullPath: canonical,
            relativePath: relativePath,
            isDirectory: isDirectory,
            marker: marker,
            isCustomRule: isCustomRule,
            mode: mode,
            cachedBytes: bytes,
            hasSentinel: hasSentinel,
            isWhitelisted: isContainerWhitelisted || pathWhitelisted,
            isPathWhitelisted: pathWhitelisted,
            isContainerWhitelisted: isContainerWhitelisted
        )
    }

    // MARK: - Containers

    private static func enumerateContainers() -> [AdLockContainer] {
        var containers: [AdLockContainer] = []
        var seenApps = Set<String>()

        var installed = ContainerStore.installedAppsFromCatalog(includeExtensions: false)
        if installed.isEmpty {
            installed = ContainerStore.containersFromFilesystem()
        }
        if installed.isEmpty {
            installed = ContainerStore.installedAppsFromMCM()
        }

        for app in installed {
            let canonicalPath = AdLockPolicy.canonicalVarPath(app.containerPath)
            guard ContainerStore.isApplicationContainerPath(canonicalPath) else { continue }
            let key = app.bundleID.lowercased()
            guard seenApps.insert(key).inserted else { continue }
            containers.append(
                AdLockContainer(
                    containerID: app.bundleID,
                    displayName: app.name,
                    containerPath: canonicalPath,
                    isAppGroup: false
                )
            )
        }

        containers.append(contentsOf: enumerateAppGroups())
        return containers
    }

    private static func enumerateAppGroups() -> [AdLockContainer] {
        let root = AdLockCatalog.appGroupRoot
        var results: [AdLockContainer] = []
        var seen = Set<String>()

        var names: [String] = []
        do {
            try SandboxAccess.withGrant(directory: root, writable: false) {
                names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            }
        } catch {
            return []
        }

        for name in names.sorted() {
            let lower = name.lowercased()
            guard lower.hasPrefix("group.") else { continue }
            let path = (root as NSString).appendingPathComponent(name)
            var status = stat()
            guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
                continue
            }
            let metadata = ContainerStore.readContainerMetadata(containerPath: path)
            let groupID = (metadata?.bundleID ?? name).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !groupID.isEmpty else { continue }
            let key = groupID.lowercased()
            guard seen.insert(key).inserted else { continue }
            results.append(
                AdLockContainer(
                    containerID: groupID,
                    displayName: metadata?.displayName ?? groupID,
                    containerPath: path,
                    isAppGroup: true
                )
            )
        }
        return results
    }

    // MARK: - Lock / unlock

    @discardableResult
    static func setLocked(
        item: AdLockItem,
        containerPath: String,
        locked: Bool
    ) -> AdLockMutationResult {
        do {
            return try SandboxAccess.withGrant(directory: containerPath, writable: true) {
                performSetLocked(item: item, locked: locked)
            }
        } catch {
            return AdLockMutationResult(
                path: item.fullPath,
                ok: false,
                mode: item.mode,
                hasSentinel: item.hasSentinel,
                error: String(describing: error)
            )
        }
    }

    static func setLocked(
        items: [AdLockItem],
        containerPath: String,
        locked: Bool,
        cancel: AdLockScanCancellationFlag
    ) -> [AdLockMutationResult] {
        guard !items.isEmpty else { return [] }
        var results: [AdLockMutationResult] = []
        do {
            try SandboxAccess.withGrant(directory: containerPath, writable: true) {
                for item in items {
                    if cancel.isCancelled { break }
                    results.append(performSetLocked(item: item, locked: locked))
                }
            }
        } catch {
            for item in items where results.contains(where: { $0.path == item.fullPath }) == false {
                results.append(
                    AdLockMutationResult(
                        path: item.fullPath,
                        ok: false,
                        mode: item.mode,
                        hasSentinel: item.hasSentinel,
                        error: String(describing: error)
                    )
                )
            }
        }
        return results
    }

    static func restoreWhitelisted(
        items: [AdLockItem],
        containerPath: String,
        cancel: AdLockScanCancellationFlag
    ) -> [AdLockMutationResult] {
        let targets = items.filter { $0.isWhitelisted && ($0.isLockedReadOnly || $0.hasSentinel) }
        return setLocked(items: targets, containerPath: containerPath, locked: false, cancel: cancel)
    }

    private static func performSetLocked(
        item: AdLockItem,
        locked: Bool
    ) -> AdLockMutationResult {
        let path = AdLockPolicy.canonicalVarPath(item.fullPath)
        var status = stat()
        guard lstat(path, &status) == 0 else {
            return failure(item, error: "目标已不存在")
        }
        let format = status.st_mode & S_IFMT
        guard format == S_IFDIR || format == S_IFREG else {
            return failure(item, error: "不支持的条目类型（符号链接已拦截）")
        }

        let owner = (try? FileManager.default.attributesOfItem(atPath: path)[.ownerAccountName] as? String) ?? nil
        if let owner, !owner.isEmpty, owner.lowercased() != "mobile" {
            return failure(item, error: "目标属主不是 mobile")
        }

        if format == S_IFDIR {
            return locked
                ? lockDirectory(path: path, fallback: item)
                : unlockDirectory(path: path, fallback: item)
        }
        return locked
            ? lockFile(path: path, fallback: item)
            : unlockFile(path: path, fallback: item)
    }

    private static func lockDirectory(
        path: String,
        fallback: AdLockItem
    ) -> AdLockMutationResult {
        guard chmod(path, 0o755) == 0 else {
            return failure(fallback, error: "准备写权限失败：\(lastError())")
        }
        purgeDirectoryContents(atPath: path)

        let sentinelPath = (path as NSString).appendingPathComponent(AdLockCatalog.sentinelFileName)
        let descriptor = Darwin.open(
            sentinelPath,
            O_CREAT | O_TRUNC | O_WRONLY | O_NOFOLLOW,
            mode_t(0o644)
        )
        guard descriptor >= 0 else {
            return failure(fallback, error: "创建占位文件失败：\(lastError())")
        }
        Darwin.close(descriptor)
        guard chmod(sentinelPath, 0o444) == 0 else {
            return failure(fallback, error: "设置占位文件只读失败：\(lastError())")
        }

        guard chmod(path, 0o555) == 0 else {
            return failure(fallback, error: "锁定目录 0555 失败：\(lastError())")
        }
        guard let mode = verifiedMode(atPath: path) else {
            return failure(fallback, error: "lstat 回读目录权限失败")
        }
        let sentinelPresent = fileExists(sentinelPath)
        return AdLockMutationResult(
            path: path,
            ok: (mode & 0o777) == 0o555 && sentinelPresent,
            mode: mode,
            hasSentinel: sentinelPresent,
            error: (mode & 0o777) == 0o555 && sentinelPresent ? nil : "锁定后回读不一致"
        )
    }

    private static func unlockDirectory(
        path: String,
        fallback: AdLockItem
    ) -> AdLockMutationResult {
        guard chmod(path, 0o755) == 0 else {
            return failure(fallback, error: "恢复目录 0755 失败：\(lastError())")
        }
        let sentinelPath = (path as NSString).appendingPathComponent(AdLockCatalog.sentinelFileName)
        if unlink(sentinelPath) != 0 && errno != ENOENT {
            return failure(fallback, error: "删除占位文件失败：\(lastError())")
        }
        guard let mode = verifiedMode(atPath: path) else {
            return failure(fallback, error: "lstat 回读目录权限失败")
        }
        let sentinelPresent = fileExists(sentinelPath)
        return AdLockMutationResult(
            path: path,
            ok: (mode & 0o777) == 0o755 && !sentinelPresent,
            mode: mode,
            hasSentinel: sentinelPresent,
            error: (mode & 0o777) == 0o755 && !sentinelPresent ? nil : "恢复后回读不一致"
        )
    }

    private static func lockFile(
        path: String,
        fallback: AdLockItem
    ) -> AdLockMutationResult {
        let fileName = (path as NSString).lastPathComponent
        guard let payload = AdLockPolicy.emptyPayload(forConfigFileName: fileName) else {
            return failure(fallback, error: "不支持的广告配置文件类型")
        }
        let descriptor = Darwin.open(path, O_WRONLY | O_TRUNC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return failure(fallback, error: "打开配置文件失败：\(lastError())")
        }
        var writeFailed = false
        payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written <= 0 {
                    writeFailed = true
                    break
                }
                offset += written
            }
        }
        Darwin.close(descriptor)
        if writeFailed {
            return failure(fallback, error: "写入空载荷失败：\(lastError())")
        }
        guard chmod(path, 0o444) == 0 else {
            return failure(fallback, error: "设置文件 0444 失败：\(lastError())")
        }
        guard let mode = verifiedMode(atPath: path) else {
            return failure(fallback, error: "lstat 回读文件权限失败")
        }
        return AdLockMutationResult(
            path: path,
            ok: (mode & 0o777) == 0o444,
            mode: mode,
            hasSentinel: false,
            error: (mode & 0o777) == 0o444 ? nil : "文件锁定后回读不一致"
        )
    }

    private static func unlockFile(
        path: String,
        fallback: AdLockItem
    ) -> AdLockMutationResult {
        guard chmod(path, 0o644) == 0 else {
            return failure(fallback, error: "恢复文件 0644 失败：\(lastError())")
        }
        guard let mode = verifiedMode(atPath: path) else {
            return failure(fallback, error: "lstat 回读文件权限失败")
        }
        return AdLockMutationResult(
            path: path,
            ok: (mode & 0o777) == 0o644,
            mode: mode,
            hasSentinel: false,
            error: (mode & 0o777) == 0o644 ? nil : "文件恢复后回读不一致"
        )
    }

    // MARK: - POSIX helpers

    private static func failure(_ item: AdLockItem, error: String) -> AdLockMutationResult {
        AdLockMutationResult(
            path: item.fullPath,
            ok: false,
            mode: item.mode,
            hasSentinel: item.hasSentinel,
            error: error
        )
    }

    private static func verifiedMode(atPath path: String) -> Int? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        return Int(status.st_mode) & 0o777
    }

    private static func fileExists(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }

    private static func purgeDirectoryContents(atPath directory: String) {
        guard let dir = opendir(directory) else { return }
        var names: [String] = []
        while let entryPointer = readdir(dir) {
            let entry = entryPointer.pointee
            let nameLength = Int(entry.d_namlen)
            guard nameLength > 0,
                  let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name) else {
                continue
            }
            let namePointer = UnsafeRawPointer(entryPointer)
                .advanced(by: nameOffset)
                .assumingMemoryBound(to: CChar.self)
            if namePointer[0] == 0x2E {
                if nameLength == 1 { continue }
                if nameLength == 2 && namePointer[1] == 0x2E { continue }
            }
            names.append(String(cString: namePointer))
        }
        closedir(dir)

        for name in names {
            let child = (directory as NSString).appendingPathComponent(name)
            var status = stat()
            guard lstat(child, &status) == 0 else { continue }
            let format = status.st_mode & S_IFMT
            if format == S_IFDIR {
                _ = chmod(child, 0o755)
                purgeDirectoryContents(atPath: child)
                _ = rmdir(child)
            } else {
                if name == AdLockCatalog.sentinelFileName {
                    _ = chmod(child, 0o644)
                }
                _ = unlink(child)
            }
        }
    }

    private static func fastFolderSize(
        atPath path: String,
        maxDepth: Int,
        cancel: AdLockScanCancellationFlag
    ) -> Int64 {
        var total: Int64 = 0
        var visited = 0
        let budget = 4000

        func walk(_ directory: String, depth: Int) {
            guard depth <= maxDepth, !cancel.isCancelled, visited < budget else { return }
            guard let dir = opendir(directory) else { return }
            while let entryPointer = readdir(dir) {
                if cancel.isCancelled || visited >= budget { break }
                let entry = entryPointer.pointee
                let nameLength = Int(entry.d_namlen)
                guard nameLength > 0,
                      let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name) else {
                    continue
                }
                let namePointer = UnsafeRawPointer(entryPointer)
                    .advanced(by: nameOffset)
                    .assumingMemoryBound(to: CChar.self)
                if namePointer[0] == 0x2E { continue }
                let name = String(cString: namePointer)
                if AdLockCatalog.neverTouchOrDescend.contains(name.lowercased()) { continue }
                let child = (directory as NSString).appendingPathComponent(name)
                var status = stat()
                guard lstat(child, &status) == 0 else { continue }
                let format = status.st_mode & S_IFMT
                if format == S_IFDIR {
                    if depth < maxDepth { walk(child, depth: depth + 1) }
                } else if format == S_IFREG {
                    visited += 1
                    total += max(0, Int64(status.st_size))
                }
            }
            closedir(dir)
        }

        walk(path, depth: 0)
        return total
    }
}