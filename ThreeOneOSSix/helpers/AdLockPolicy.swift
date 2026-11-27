import Foundation

// MARK: - Rules

enum AdLockRuleKind: String, Codable, Sendable {
    case bundleID
    case path
}

struct AdLockRule: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(kind.rawValue):\(target.lowercased())" }
    var kind: AdLockRuleKind
    var target: String
    var note: String
    var addedAt: Date
    var isSeed: Bool

    init(
        kind: AdLockRuleKind,
        target: String,
        note: String = "",
        addedAt: Date = Date(),
        isSeed: Bool = false
    ) {
        self.kind = kind
        self.target = target
        self.note = note
        self.addedAt = addedAt
        self.isSeed = isSeed
    }
}

struct AdLockCustomRule: Codable, Identifiable, Hashable, Sendable {
    var id: String { fullPath }
    var fullPath: String
    var note: String
    var addedAt: Date

    init(fullPath: String, note: String = "", addedAt: Date = Date()) {
        self.fullPath = fullPath
        self.note = note
        self.addedAt = addedAt
    }
}

// MARK: - Validation

struct AdLockContainerInfo: Equatable, Sendable {
    let rootPath: String
    let containerID: String
    let isAppGroup: Bool
}

enum AdLockFailure: String, Error, Equatable, Sendable {
    case emptyPath = "empty_path"
    case outsideAllowedRoot = "outside_allowed_root"
    case containerRoot = "container_root"
    case forbiddenName = "forbidden_name"
    case downloads = "downloads"
    case mainPreferences = "main_preferences"
    case symbolicLink = "symbolic_link"
    case ownerMismatch = "owner_mismatch"
    case ignoredContainer = "ignored_container"
    case unsupportedType = "unsupported_type"
}

struct AdLockValidation: Equatable, Sendable {
    let allowed: Bool
    let failure: AdLockFailure?

    static let ok = AdLockValidation(allowed: true, failure: nil)

    static func rejected(_ failure: AdLockFailure) -> AdLockValidation {
        AdLockValidation(allowed: false, failure: failure)
    }
}

/// Pure path, whitelist and payload rules for the ad-cache blocker.
///
/// Everything here is filesystem-free so the policy can be compiled into the
/// macOS test binary; IO (lstat/chmod/open) belongs to `AdLockService`.
enum AdLockPolicy {
    static let allowedOwnerAccounts: Set<String> = ["mobile"]

    // MARK: - Paths

    static func canonicalVarPath(_ rawPath: String) -> String {
        var path = (rawPath as NSString).standardizingPath
        if path.hasPrefix("/private/var/") {
            path = String(path.dropFirst("/private".count))
        } else if path == "/private/var" {
            path = "/var"
        }
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    static func containerInfo(for rawPath: String) -> AdLockContainerInfo? {
        let path = canonicalVarPath(rawPath)
        let roots: [(String, Bool)] = [
            (AdLockCatalog.appDataRoot, false),
            (AdLockCatalog.appGroupRoot, true),
        ]
        for (root, isAppGroup) in roots {
            let prefix = root + "/"
            guard path.hasPrefix(prefix) else { continue }
            let rest = String(path.dropFirst(prefix.count))
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = parts.first, !first.isEmpty else { continue }
            return AdLockContainerInfo(
                rootPath: root + "/" + String(first),
                containerID: String(first),
                isAppGroup: isAppGroup
            )
        }
        return nil
    }

    static func relativePath(for rawPath: String) -> String? {
        guard let info = containerInfo(for: rawPath) else { return nil }
        let path = canonicalVarPath(rawPath)
        if path == info.rootPath { return "" }
        let prefix = info.rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    static func isInsideContainer(_ rawPath: String) -> Bool {
        guard let relative = relativePath(for: rawPath) else { return false }
        return !relative.isEmpty
    }

    // MARK: - Target validation

    static func validateTarget(
        path rawPath: String,
        isDirectory: Bool,
        ownerAccountName: String?,
        isSymbolicLink: Bool,
        selfBundleID: String,
        selfAppGroupID: String? = nil,
        resolvedContainerID: String? = nil
    ) -> AdLockValidation {
        let path = canonicalVarPath(rawPath)
        guard !path.isEmpty else { return .rejected(.emptyPath) }
        guard let info = containerInfo(for: path) else {
            return .rejected(.outsideAllowedRoot)
        }
        let relative = relativePath(for: path) ?? ""
        guard !relative.isEmpty else { return .rejected(.containerRoot) }

        if isSymbolicLink { return .rejected(.symbolicLink) }

        if let owner = ownerAccountName,
           !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !allowedOwnerAccounts.contains(owner.lowercased()) {
            return .rejected(.ownerMismatch)
        }

        let resolvedID = (resolvedContainerID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? info.containerID
        if isIgnoredContainer(
            id: resolvedID,
            isAppGroup: info.isAppGroup,
            selfBundleID: selfBundleID,
            selfAppGroupID: selfAppGroupID
        ) {
            return .rejected(.ignoredContainer)
        }

        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let leaf = components.last, !leaf.isEmpty else {
            return .rejected(.containerRoot)
        }

        if components.first?.lowercased() == "downloads" {
            return .rejected(.downloads)
        }
        if components.count >= 2,
           components[0].caseInsensitiveCompare("Library") == .orderedSame,
           components[1].caseInsensitiveCompare("Preferences") == .orderedSame,
           leaf.lowercased().hasSuffix(".plist") {
            return .rejected(.mainPreferences)
        }
        if AdLockCatalog.forbiddenCustomNames.contains(leaf.lowercased()) {
            return .rejected(.forbiddenName)
        }
        if !isDirectory && leaf.lowercased().hasSuffix(".app") {
            return .rejected(.unsupportedType)
        }
        return .ok
    }

    static func isIgnoredContainer(
        id rawID: String,
        isAppGroup: Bool,
        selfBundleID: String,
        selfAppGroupID: String?
    ) -> Bool {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return true }
        let lower = id.lowercased()

        if lower == selfBundleID.lowercased() { return true }
        if let selfGroup = selfAppGroupID?.lowercased(), !selfGroup.isEmpty, lower == selfGroup {
            return true
        }
        if lower.hasPrefix("com.apple.") || lower.hasPrefix("systemgroup.") {
            return true
        }
        if AdLockCatalog.protectedBundleIDs.contains(where: { $0.lowercased() == lower }) {
            return true
        }
        if isAppGroup {
            let groupID = lower.hasPrefix("group.") ? lower : "group." + lower
            for prefix in AdLockCatalog.ignoredAppGroupPrefixes where groupID.hasPrefix(prefix.lowercased()) {
                return true
            }
        }
        return false
    }

    // MARK: - Whitelist matching

    static func isWhitelistedContainer(
        id rawID: String,
        isAppGroup: Bool,
        rules: [AdLockRule]
    ) -> Bool {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !id.isEmpty else { return false }
        let groupID = id.hasPrefix("group.") ? id : "group." + id

        for rule in rules where rule.kind == .bundleID {
            let target = rule.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !target.isEmpty else { continue }
            if target == id { return true }
            if isAppGroup {
                if target == groupID { return true }
                if groupID == "group." + target { return true }
                if groupID.hasPrefix(target + ".") { return true }
                if groupID.hasPrefix("group." + target + ".") { return true }
                if target.hasPrefix("group."), id == target || id.hasPrefix(target + ".") {
                    return true
                }
            }
        }
        return false
    }

    static func isPathWhitelisted(_ rawPath: String, rules: [AdLockRule]) -> Bool {
        let path = canonicalVarPath(rawPath)
        return rules.contains {
            $0.kind == .path && canonicalVarPath($0.target) == path
        }
    }

    static func normalisedRuleTarget(_ rawTarget: String) -> String? {
        let trimmed = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 512,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return trimmed
    }

    // MARK: - Folder classification

    /// Returns the matched SDK marker (the folder name itself) when the child
    /// folder looks like a splash/ad SDK cache. `neverTouchOrDescend` wins.
    static func classifyAdFolder(name: String) -> String? {
        let lower = name.lowercased()
        if AdLockCatalog.neverTouchOrDescend.contains(lower) {
            return nil
        }
        if AdLockCatalog.adSDKTokens.contains(lower) {
            return name
        }
        let tokens = splitBoundaryTokens(name)
        guard tokens.contains("ad") || tokens.contains("ads") else {
            return nil
        }
        let modifiers: Set<String> = [
            "sdk", "splash", "launch", "cache", "banner", "interstitial", "mob",
        ]
        if tokens.contains(where: { modifiers.contains($0) }) {
            return name
        }
        return nil
    }

    static func isAdConfigFile(name: String) -> Bool {
        AdLockCatalog.payload(forConfigFileName: name) != nil
    }

    /// Splits on `_`, `-`, `.`, spaces and ASCII camelCase boundaries without
    /// substring ambiguity. `SplashAdCache` → ["splash", "ad", "cache"].
    static func splitBoundaryTokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        let scalars = Array(raw.unicodeScalars)

        for i in scalars.indices {
            let scalar = scalars[i]
            if scalar == "_" || scalar == "-" || scalar == "." || scalar == " " {
                if !current.isEmpty {
                    tokens.append(current.lowercased())
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            let isUpper = scalar.value >= 65 && scalar.value <= 90
            if isUpper && !current.isEmpty {
                let previous = scalars[i - 1]
                let previousIsLower = previous.value >= 97 && previous.value <= 122
                let nextIsLower = (i + 1 < scalars.count) &&
                    (scalars[i + 1].value >= 97 && scalars[i + 1].value <= 122)
                if previousIsLower || nextIsLower {
                    tokens.append(current.lowercased())
                    current.removeAll(keepingCapacity: true)
                }
            }
            current.unicodeScalars.append(scalar)
        }

        if !current.isEmpty {
            tokens.append(current.lowercased())
        }
        return tokens
    }

    // MARK: - Modes and payloads

    static func isReadOnlyMode(_ mode: Int) -> Bool {
        (mode & 0o222) == 0
    }

    static func isSentinelLocked(mode: Int, hasSentinel: Bool) -> Bool {
        hasSentinel && isReadOnlyMode(mode)
    }

    static func octalString(_ mode: Int) -> String {
        String(format: "%04o", mode & 0o777)
    }

    /// Minimal valid payload written into an ad configuration file before it
    /// is locked read-only. JSON becomes `{}`, plist becomes an empty dict.
    static func emptyPayload(forConfigFileName name: String) -> Data? {
        switch AdLockCatalog.payload(forConfigFileName: name) {
        case .json:
            return Data("{}".utf8)
        case .plist:
            return try? PropertyListSerialization.data(
                fromPropertyList: [String: Any](),
                format: .xml,
                options: 0
            )
        case .text:
            return Data()
        case nil:
            return nil
        }
    }
}