import Foundation

extension Notification.Name {
    static let adLockWhitelistDidChange = Notification.Name("adlock.whitelistDidChange")
    static let adLockCustomPathsDidChange = Notification.Name("adlock.customPathsDidChange")
}

/// Persistent whitelist for the ad-cache blocker.
///
/// Rules are scoped to this app's own defaults (`adlock.*`), not the upstream
/// `erosion.*` keys: two apps installed side by side must not share state.
final class AdLockWhitelistStore: @unchecked Sendable {
    static let shared = AdLockWhitelistStore()

    static let storageKey = "adlock.whitelist.v1"
    static let seededKey = "adlock.whitelistSeeded.v1"
    static let crashGuardTarget = "com.smzdm.client.ios"

    private let defaults: UserDefaults
    private let storageKeyName: String
    private let seededKeyName: String
    private let lock = NSLock()
    private var cachedRules: [AdLockRule]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = AdLockWhitelistStore.storageKey,
        seededKey: String = AdLockWhitelistStore.seededKey
    ) {
        self.defaults = defaults
        self.storageKeyName = storageKey
        self.seededKeyName = seededKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([AdLockRule].self, from: data) {
            self.cachedRules = decoded
        } else {
            self.cachedRules = []
        }
        seedCrashGuardIfNeeded()
    }

    // MARK: - Reads

    func rulesSnapshot() -> [AdLockRule] {
        lock.lock()
        defer { lock.unlock() }
        return cachedRules
    }

    func isContainerWhitelisted(id: String, isAppGroup: Bool) -> Bool {
        AdLockPolicy.isWhitelistedContainer(
            id: id,
            isAppGroup: isAppGroup,
            rules: rulesSnapshot()
        )
    }

    func isPathWhitelisted(_ rawPath: String) -> Bool {
        AdLockPolicy.isPathWhitelisted(rawPath, rules: rulesSnapshot())
    }

    func containsExactBundleRule(_ rawID: String) -> Bool {
        let target = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return false }
        return rulesSnapshot().contains {
            $0.kind == .bundleID && $0.target.lowercased() == target
        }
    }

    // MARK: - Writes

    @discardableResult
    func addBundleRule(bundleOrGroupID rawID: String, note: String = "") -> AdLockRule? {
        guard let target = AdLockPolicy.normalisedRuleTarget(rawID) else { return nil }
        let rule = AdLockRule(kind: .bundleID, target: target, note: note)

        lock.lock()
        if let index = cachedRules.firstIndex(where: { $0.id == rule.id }) {
            cachedRules[index].note = note
            let updated = cachedRules[index]
            persistLocked()
            lock.unlock()
            notifyChanged()
            return updated
        }
        cachedRules.insert(rule, at: 0)
        persistLocked()
        lock.unlock()
        notifyChanged()
        return rule
    }

    @discardableResult
    func addPathRule(
        rawPath: String,
        note: String = "",
        selfBundleID: String = Bundle.main.bundleIdentifier ?? "",
        selfAppGroupID: String? = nil
    ) -> Result<AdLockRule, AdLockFailure> {
        let path = AdLockPolicy.canonicalVarPath(rawPath)
        let validation = AdLockPolicy.validateTarget(
            path: path,
            isDirectory: true,
            ownerAccountName: nil,
            isSymbolicLink: false,
            selfBundleID: selfBundleID,
            selfAppGroupID: selfAppGroupID
        )
        guard validation.allowed else {
            return .failure(validation.failure ?? .emptyPath)
        }
        let rule = AdLockRule(kind: .path, target: path, note: note)

        lock.lock()
        if let index = cachedRules.firstIndex(where: { $0.id == rule.id }) {
            cachedRules[index].note = note
            let updated = cachedRules[index]
            persistLocked()
            lock.unlock()
            notifyChanged()
            return .success(updated)
        }
        cachedRules.insert(rule, at: 0)
        persistLocked()
        lock.unlock()
        notifyChanged()
        return .success(rule)
    }

    func remove(ruleID: String) {
        lock.lock()
        let before = cachedRules.count
        cachedRules.removeAll { $0.id == ruleID }
        let changed = cachedRules.count != before
        if changed { persistLocked() }
        lock.unlock()
        if changed { notifyChanged() }
    }

    /// Removes every bundle rule that would whitelist this app or AppGroup.
    func removeMatchingContainer(id rawID: String, isAppGroup: Bool) {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return }
        lock.lock()
        let before = cachedRules.count
        cachedRules.removeAll { rule in
            guard rule.kind == .bundleID else { return false }
            let target = rule.target.lowercased()
            if target == id { return true }
            guard isAppGroup else { return false }
            let groupID = id.hasPrefix("group.") ? id : "group." + id
            return target == groupID ||
                groupID.hasPrefix(target + ".") ||
                (target.hasPrefix("group.") && id.hasPrefix(target + "."))
        }
        let changed = cachedRules.count != before
        if changed { persistLocked() }
        lock.unlock()
        if changed { notifyChanged() }
    }

    func removeExactPath(_ rawPath: String) {
        let path = AdLockPolicy.canonicalVarPath(rawPath)
        lock.lock()
        let before = cachedRules.count
        cachedRules.removeAll { $0.kind == .path && $0.target == path }
        let changed = cachedRules.count != before
        if changed { persistLocked() }
        lock.unlock()
        if changed { notifyChanged() }
    }

    // MARK: - Seeding

    private func seedCrashGuardIfNeeded() {
        guard !defaults.bool(forKey: seededKeyName) else { return }
        defaults.set(true, forKey: seededKeyName)
        guard !cachedRules.contains(where: {
            $0.kind == .bundleID &&
                $0.target.caseInsensitiveCompare(Self.crashGuardTarget) == .orderedSame
        }) else { return }
        cachedRules.append(
            AdLockRule(
                kind: .bundleID,
                target: Self.crashGuardTarget,
                note: "",
                isSeed: true
            )
        )
        if let data = try? JSONEncoder().encode(cachedRules) {
            defaults.set(data, forKey: storageKeyName)
        }
    }

    // MARK: - Persistence

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(cachedRules) {
            defaults.set(data, forKey: storageKeyName)
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .adLockWhitelistDidChange, object: self)
    }
}

/// User-curated ad-cache paths.
final class AdLockCustomWatchStore: @unchecked Sendable {
    static let shared = AdLockCustomWatchStore()
    static let storageKey = "adlock.customPaths.v1"

    private let defaults: UserDefaults
    private let storageKeyName: String
    private let lock = NSLock()
    private var cachedRules: [AdLockCustomRule]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = AdLockCustomWatchStore.storageKey
    ) {
        self.defaults = defaults
        self.storageKeyName = storageKey
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([AdLockCustomRule].self, from: data) {
            self.cachedRules = decoded
        } else {
            self.cachedRules = []
        }
    }

    func rulesSnapshot() -> [AdLockCustomRule] {
        lock.lock()
        defer { lock.unlock() }
        return cachedRules
    }

    func contains(url: URL) -> Bool {
        contains(canonicalPath: AdLockPolicy.canonicalVarPath(url.path))
    }

    func contains(canonicalPath: String) -> Bool {
        let path = AdLockPolicy.canonicalVarPath(canonicalPath)
        return rulesSnapshot().contains { $0.fullPath == path }
    }

    @discardableResult
    func addValidatedRule(
        rawPath: String,
        note: String = "",
        isDirectory: Bool = true,
        ownerAccountName: String? = nil,
        isSymbolicLink: Bool = false,
        selfBundleID: String = Bundle.main.bundleIdentifier ?? "",
        selfAppGroupID: String? = nil
    ) -> Result<AdLockCustomRule, AdLockFailure> {
        let path = AdLockPolicy.canonicalVarPath(rawPath)
        let validation = AdLockPolicy.validateTarget(
            path: path,
            isDirectory: isDirectory,
            ownerAccountName: ownerAccountName,
            isSymbolicLink: isSymbolicLink,
            selfBundleID: selfBundleID,
            selfAppGroupID: selfAppGroupID
        )
        guard validation.allowed else {
            return .failure(validation.failure ?? .emptyPath)
        }

        let rule = AdLockCustomRule(fullPath: path, note: note)
        lock.lock()
        if let existing = cachedRules.first(where: { $0.fullPath == path }) {
            lock.unlock()
            return .success(existing)
        }
        cachedRules.insert(rule, at: 0)
        persistLocked()
        lock.unlock()
        NotificationCenter.default.post(name: .adLockCustomPathsDidChange, object: self)
        return .success(rule)
    }

    func remove(fullPath: String) {
        let path = AdLockPolicy.canonicalVarPath(fullPath)
        lock.lock()
        let before = cachedRules.count
        cachedRules.removeAll { $0.fullPath == path }
        let changed = cachedRules.count != before
        if changed { persistLocked() }
        lock.unlock()
        if changed {
            NotificationCenter.default.post(name: .adLockCustomPathsDidChange, object: self)
        }
    }

    private func persistLocked() {
        if let data = try? JSONEncoder().encode(cachedRules) {
            defaults.set(data, forKey: storageKeyName)
        }
    }
}