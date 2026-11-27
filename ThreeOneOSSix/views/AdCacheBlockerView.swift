import SwiftUI

/// Splash ad cache blocker, laid out to match the upstream Erosion-CN page:
/// a single inset-grouped List with an overview card, per-app sections and
/// inline target rows (locate / preview / ignore / lock / restore).
struct AdCacheBlockerView: View {
    @Environment(\.appLanguage) private var language
    @State private var isScanning = false
    @State private var isStopping = false
    @State private var isOperating = false
    @State private var allEntries: [AdLockAppEntry] = []
    @State private var searchText = ""
    @State private var showEmptyApps = false
    @State private var scanCompletedCount = 0
    @State private var scanTotalCount = 0
    @State private var activeScanToken: AdLockScanCancellationFlag?
    @State private var busyItemID: String?
    @State private var locateTarget: AdLockLocateTarget?
    @State private var previewTarget: AdLockItem?
    @State private var showAddCustomSheet = false
    @State private var showWhitelistSheet = false
    @State private var whitelistRulesCount = 0
    @State private var activeAlert: AdLockAlert?
    @State private var hasLoaded = false

    /// Routes the two alert sources through one binding. SwiftUI only
    /// guarantees one `.alert` per view hierarchy; stacking two modifiers
    /// can make the batch confirmation silently disappear.
    private var notice: AdLockNotice? {
        get {
            if case .notice(let value) = activeAlert { return value }
            return nil
        }
        nonmutating set { activeAlert = newValue.map { .notice($0) } }
    }

    private var batchAction: AdLockBatchAction? {
        get {
            if case .batch(let action) = activeAlert { return action }
            return nil
        }
        nonmutating set { activeAlert = newValue.map { .batch($0) } }
    }

    // MARK: - Derived state

    private var detectedEntries: [AdLockAppEntry] {
        allEntries.filter { !$0.items.isEmpty }
    }

    private var displayedEntries: [AdLockAppEntry] {
        let base = showEmptyApps ? allEntries : detectedEntries
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        return base.filter { entry in
            displayName(entry).localizedCaseInsensitiveContains(trimmed) ||
            entry.containerID.localizedCaseInsensitiveContains(trimmed) ||
            entry.items.contains {
                $0.relativePath.localizedCaseInsensitiveContains(trimmed) ||
                $0.marker.localizedCaseInsensitiveContains(trimmed)
            }
        }
    }

    private var totalAdFoldersCount: Int {
        detectedEntries.reduce(0) { $0 + $1.items.count }
    }

    private var whitelistedTargetCount: Int {
        detectedEntries.reduce(0) { total, entry in
            total + entry.items.filter { $0.isWhitelisted }.count
        }
    }

    private var activeTargetCount: Int {
        totalAdFoldersCount - whitelistedTargetCount
    }

    private var fullyLockedCount: Int {
        detectedEntries.reduce(0) { total, entry in
            total + entry.items.filter { !$0.isWhitelisted && !$0.needsActionToLock }.count
        }
    }

    private var pendingLockOrHardenCount: Int {
        detectedEntries.reduce(0) { total, entry in
            total + entry.items.filter { $0.needsActionToLock }.count
        }
    }

    private var totalReclaimableAdBytes: Int64 {
        detectedEntries.reduce(0) { total, entry in
            total + entry.items
                .filter { !$0.isWhitelisted && !$0.isLockedReadOnly }
                .reduce(0) { $0 + $1.cachedBytes }
        }
    }

    // MARK: - Body

    var body: some View {
        List {
            overviewSection
            boundarySection

            if isScanning {
                scanProgressSection
            }
            if isOperating {
                operatingSection
            }

            if displayedEntries.isEmpty && !isScanning {
                emptySection
            } else {
                ForEach(displayedEntries) { entry in
                    appSection(entry)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(language.text("adlock.title"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            prompt: language.text("adlock.search_placeholder")
        )
        .toolbar { toolbarContent }
        .sheet(item: $locateTarget) { target in
            NavigationStack {
                locateDestination(target)
            }
        }
        .sheet(item: $previewTarget) { item in
            NavigationStack {
                HexViewerView(path: item.fullPath, readOnly: true)
            }
        }
        .sheet(isPresented: $showAddCustomSheet) {
            AddAdCustomPathSheet { rescan() }
        }
        .sheet(isPresented: $showWhitelistSheet) {
            NavigationStack {
                AdWhitelistManagerSheet(entries: detectedEntries)
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .batch(let action):
                return batchAlert(for: action)
            case .notice(let notice):
                return Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text(language.text("common.ok")))
                )
            }
        }
        .onAppear {
            whitelistRulesCount = AdLockWhitelistStore.shared.rulesSnapshot().count
            guard !hasLoaded else { return }
            hasLoaded = true
            rescan()
        }
        .onReceive(NotificationCenter.default.publisher(for: .adLockWhitelistDidChange)) { _ in
            whitelistRulesCount = AdLockWhitelistStore.shared.rulesSnapshot().count
            if !isScanning && !isOperating { rescan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .adLockCustomPathsDidChange)) { _ in
            if !isScanning && !isOperating { rescan() }
        }
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("adlock.overview.title"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(totalAdFoldersCount)")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(
                                    totalAdFoldersCount > 0 ? AppTheme.accent : Color.secondary
                                )
                            Text(
                                language.text(
                                    "adlock.overview.counts",
                                    Int64(detectedEntries.count)
                                )
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(language.text("adlock.overview.sentinel"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text("\(fullyLockedCount) / \(activeTargetCount)")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(.green)
                        if activeTargetCount > 0 {
                            ProgressView(
                                value: Double(fullyLockedCount),
                                total: Double(activeTargetCount)
                            )
                            .tint(.green)
                            .frame(width: 84)
                        }
                    }
                }

                if whitelistedTargetCount > 0 {
                    Label(
                        language.text(
                            "adlock.overview.whitelist_skipped",
                            Int64(whitelistedTargetCount)
                        ),
                        systemImage: "checkmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.teal)
                }

                if totalReclaimableAdBytes > 0 {
                    Label(
                        language.text(
                            "adlock.overview.reclaimable",
                            byteText(totalReclaimableAdBytes)
                        ),
                        systemImage: "internaldrive"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Divider()

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            rescan()
                        } label: {
                            Label(language.text("adlock.rescan"), systemImage: "arrow.clockwise")
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isScanning || isOperating)

                        Spacer(minLength: 4)

                        Button {
                            showWhitelistSheet = true
                        } label: {
                            Label(
                                language.text("adlock.whitelist_count", Int64(whitelistRulesCount)),
                                systemImage: "checkmark.shield"
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isOperating)

                        Menu {
                            Button {
                                batchAction = .lockAll
                            } label: {
                                Label(language.text("adlock.batch.lock_harden"), systemImage: "lock.fill")
                            }
                            .disabled(pendingLockOrHardenCount == 0 || isScanning || isOperating)

                            Button {
                                batchAction = .unlockAll
                            } label: {
                                Label(language.text("adlock.batch.restore_all"), systemImage: "lock.open.fill")
                            }
                            .disabled(!hasAnyLockedItem || isScanning || isOperating)
                        } label: {
                            Label(language.text("adlock.batch.title"), systemImage: "ellipsis.circle")
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isScanning || isOperating)
                    }

                    if pendingLockOrHardenCount > 0 {
                        Button {
                            batchAction = .lockAll
                        } label: {
                            Label(
                                language.text(
                                    "adlock.lock_all_pending",
                                    Int64(pendingLockOrHardenCount)
                                ),
                                systemImage: "lock.fill"
                            )
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.orange)
                        .disabled(isScanning || isOperating)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            Toggle(isOn: $showEmptyApps) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("adlock.toggle.show_empty"))
                        .font(.subheadline)
                    Text(language.text("adlock.toggle.show_empty_subtitle"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.orange)
        } header: {
            AdLockHeaderLabel(
                title: language.text("adlock.overview.header"),
                symbol: "lock.shield"
            )
        } footer: {
            Text(language.text("adlock.overview.footer"))
        }
    }

    private var hasAnyLockedItem: Bool {
        detectedEntries.contains { entry in
            entry.items.contains { $0.isLockedReadOnly || $0.hasSentinel }
        }
    }

    // MARK: - Boundary

    @ViewBuilder
    private var boundarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(language.text("adlock.boundary.local"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                }
                Label {
                    Text(language.text("adlock.boundary.pairing"))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
        } header: {
            AdLockHeaderLabel(
                title: language.text("adlock.boundary_title"),
                symbol: "exclamationmark.shield"
            )
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var scanProgressSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        scanTotalCount > 0
                            ? language.text(
                                "adlock.scan_progress",
                                Int64(scanCompletedCount),
                                Int64(scanTotalCount)
                            )
                            : language.text("adlock.scanning")
                    )
                    .font(.subheadline)
                    if scanTotalCount > 0 {
                        ProgressView(
                            value: Double(scanCompletedCount),
                            total: Double(max(scanTotalCount, 1))
                        )
                    }
                }
                Spacer(minLength: 4)
                Button {
                    stopScan()
                } label: {
                    Text(isStopping ? language.text("adlock.stopping") : language.text("adlock.stop"))
                        .font(.subheadline.weight(.medium))
                        .fixedSize()
                }
                .buttonStyle(.borderless)
                .disabled(isStopping)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var operatingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                Text(language.text("adlock.operating"))
                    .font(.subheadline)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Empty

    @ViewBuilder
    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(language.text("adlock.empty_title"))
                    .font(.subheadline.weight(.medium))
                Text(language.text("adlock.empty_detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - App section

    @ViewBuilder
    private func appSection(_ entry: AdLockAppEntry) -> some View {
        Section {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(displayName(entry))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if entry.isWhitelisted {
                            adLockBadge(language.text("adlock.whitelisted"), color: .teal)
                        }
                    }
                    Text(appStatusSubtitle(entry))
                        .font(.caption2)
                        .foregroundStyle(appStatusColor(entry))
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 4)

                Menu {
                    Button {
                        locateTarget = AdLockLocateTarget(entry: entry, item: nil)
                    } label: {
                        Label(language.text("adlock.app.browse"), systemImage: "folder")
                    }
                    if entry.isWhitelisted {
                        Button {
                            toggleAppWhitelist(entry)
                        } label: {
                            Label(language.text("adlock.app.unwhitelist"), systemImage: "shield.slash")
                        }
                    } else {
                        Button {
                            toggleAppWhitelist(entry)
                        } label: {
                            Label(language.text("adlock.app.whitelist"), systemImage: "checkmark.shield")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.borderless)
                .disabled(isOperating)

                if entry.isWhitelisted {
                    Button {
                        toggleAppWhitelist(entry)
                    } label: {
                        Label(language.text("adlock.app.unwhitelist"), systemImage: "shield.slash")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.teal)
                    .disabled(isOperating)
                } else if entry.pendingCount > 0 {
                    Button {
                        toggleAllForApp(entry, lock: true)
                    } label: {
                        Label(language.text("adlock.app.lock_group"), systemImage: "lock.fill")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                    .disabled(isOperating)
                } else if entry.items.contains(where: { $0.isLockedReadOnly || $0.hasSentinel }) {
                    Button {
                        toggleAllForApp(entry, lock: false)
                    } label: {
                        Label(language.text("adlock.app.unlock_group"), systemImage: "lock.open.fill")
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.green)
                    .disabled(isOperating)
                }
            }
            .padding(.vertical, 2)

            ForEach(entry.items) { item in
                AdLockFolderRow(
                    item: item,
                    isBusy: isOperating || busyItemID != nil,
                    onLocate: {
                        locateTarget = AdLockLocateTarget(entry: entry, item: item)
                    },
                    onPreview: item.isDirectory ? nil : {
                        previewTarget = item
                    },
                    onToggleLock: {
                        toggleLock(item, in: entry)
                    },
                    onTogglePathWhitelist: item.isContainerWhitelisted ? nil : {
                        togglePathWhitelist(item, in: entry)
                    },
                    onRemoveCustom: item.isCustomRule ? {
                        removeCustom(item)
                    } : nil
                )
            }
        }
    }

    // MARK: - Status copy

    private func appStatusSubtitle(_ entry: AdLockAppEntry) -> String {
        if entry.isWhitelisted {
            let lockedCount = entry.items.filter { $0.isLockedReadOnly }.count
            if lockedCount > 0 {
                return language.text(
                    "adlock.app.status.whitelisted_locked",
                    Int64(lockedCount)
                )
            }
            return language.text("adlock.app.status.whitelisted_skip")
        }
        if entry.items.isEmpty {
            return language.text("adlock.app.status.no_hits")
        }
        let skippedCount = entry.items.filter { $0.isWhitelisted }.count
        let lockableItems = entry.items.filter { !$0.isWhitelisted }
        if lockableItems.isEmpty {
            return language.text("adlock.app.status.all_whitelisted", Int64(skippedCount))
        }
        let fullyProtected = lockableItems.filter { !$0.needsActionToLock }.count
        let total = lockableItems.count
        if fullyProtected == total {
            var text = language.text(
                "adlock.app.status.all_locked",
                Int64(fullyProtected),
                Int64(total)
            )
            if skippedCount > 0 {
                text += " · " + language.text(
                    "adlock.app.status.whitelist_suffix",
                    Int64(skippedCount)
                )
            }
            return text
        }
        var text = language.text(
            "adlock.app.status.partial",
            Int64(entry.items.count),
            Int64(total - fullyProtected),
            Int64(fullyProtected)
        )
        if skippedCount > 0 {
            text += " · " + language.text(
                "adlock.app.status.whitelist_suffix",
                Int64(skippedCount)
            )
        }
        return text
    }

    private func appStatusColor(_ entry: AdLockAppEntry) -> Color {
        if entry.isWhitelisted {
            return entry.items.contains(where: { $0.isLockedReadOnly }) ? .orange : .teal
        }
        if entry.items.isEmpty { return .secondary }
        let lockableItems = entry.items.filter { !$0.isWhitelisted }
        if lockableItems.isEmpty { return .teal }
        let fullyProtected = lockableItems.filter { !$0.needsActionToLock }.count
        return fullyProtected == lockableItems.count ? .green : .orange
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                showWhitelistSheet = true
            } label: {
                Label(language.text("adlock.toolbar.whitelist"), systemImage: "checkmark.shield")
            }
            .disabled(isOperating)

            Button {
                showAddCustomSheet = true
            } label: {
                Label(language.text("adlock.toolbar.add"), systemImage: "plus")
            }
            .disabled(isOperating)
        }
    }

    // MARK: - Scan

    private func rescan() {
        guard AdLockService.isAvailable else { return }
        let flag = AdLockScanCancellationFlag()
        activeScanToken = flag
        isScanning = true
        isStopping = false
        scanCompletedCount = 0
        scanTotalCount = 0

        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = AdLockService.scan(cancel: flag) { completed, total in
                DispatchQueue.main.async {
                    scanCompletedCount = completed
                    scanTotalCount = total
                }
            }
            DispatchQueue.main.async {
                guard activeScanToken === flag else { return }
                activeScanToken = nil
                isScanning = false
                isStopping = false
                allEntries = snapshot.entries
                scanCompletedCount = snapshot.scannedContainers
                scanTotalCount = snapshot.scannedContainers
                whitelistRulesCount = AdLockWhitelistStore.shared.rulesSnapshot().count
                if snapshot.cancelled {
                    notice = AdLockNotice(
                        title: language.text("adlock.scan_cancelled_title"),
                        message: language.text("adlock.scan_cancelled_message")
                    )
                }
            }
        }
    }

    private func stopScan() {
        isStopping = true
        activeScanToken?.cancel()
    }

    // MARK: - Actions

    private func toggleLock(_ item: AdLockItem, in entry: AdLockAppEntry) {
        guard !isOperating else { return }
        busyItemID = item.id
        let targets = [item]
        DispatchQueue.global(qos: .userInitiated).async {
            let results = AdLockService.setLocked(
                items: targets,
                containerPath: entry.containerPath,
                locked: item.needsActionToLock,
                cancel: AdLockScanCancellationFlag()
            )
            DispatchQueue.main.async {
                busyItemID = nil
                apply(results, to: entry)
                reportFailures(results)
            }
        }
    }

    private func toggleAllForApp(_ entry: AdLockAppEntry, lock: Bool) {
        let targets = lock
            ? entry.items.filter { !$0.isWhitelisted && $0.needsActionToLock }
            : entry.items.filter { $0.isLockedReadOnly || $0.hasSentinel }
        guard !targets.isEmpty, !isOperating else { return }
        executeBatch(pairs: [(entry, targets)], lock: lock)
    }

    private func executeBatch(
        pairs: [(AdLockAppEntry, [AdLockItem])],
        lock: Bool
    ) {
        guard !pairs.isEmpty else { return }
        isOperating = true
        DispatchQueue.global(qos: .userInitiated).async {
            var resultsByEntry: [String: [AdLockMutationResult]] = [:]
            var allResults: [AdLockMutationResult] = []
            for (entry, items) in pairs {
                if items.isEmpty { continue }
                let results = AdLockService.setLocked(
                    items: items,
                    containerPath: entry.containerPath,
                    locked: lock,
                    cancel: AdLockScanCancellationFlag()
                )
                resultsByEntry[entry.id, default: []].append(contentsOf: results)
                allResults.append(contentsOf: results)
            }
            DispatchQueue.main.async {
                isOperating = false
                for (entryID, results) in resultsByEntry {
                    guard let entry = allEntries.first(where: { $0.id == entryID }) else { continue }
                    apply(results, to: entry)
                }
                reportFailures(allResults)
                if !allResults.isEmpty && allResults.allSatisfy({ $0.ok }) {
                    notice = AdLockNotice(
                        title: lock
                            ? language.text("adlock.result.locked_title")
                            : language.text("adlock.result.unlocked_title"),
                        message: lock
                            ? language.text("adlock.result.locked_message", Int64(allResults.count))
                            : language.text("adlock.result.unlocked_message", Int64(allResults.count))
                    )
                }
            }
        }
    }

    private func apply(_ results: [AdLockMutationResult], to entry: AdLockAppEntry) {
        guard let index = allEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        allEntries[index] = allEntries[index].applying(results)
    }

    private func reportFailures(_ results: [AdLockMutationResult]) {
        let failures = results.filter { !$0.ok }
        guard !failures.isEmpty else { return }
        notice = AdLockNotice(
            title: language.text("adlock.results.title"),
            message: failures.first?.error ?? language.text("adlock.error.generic")
        )
    }

    private func toggleAppWhitelist(_ entry: AdLockAppEntry) {
        guard !isOperating else { return }
        let whitelisting = !entry.isWhitelisted
        if whitelisting {
            _ = AdLockWhitelistStore.shared.addBundleRule(bundleOrGroupID: entry.containerID)
        } else {
            AdLockWhitelistStore.shared.removeMatchingContainer(
                id: entry.containerID,
                isAppGroup: entry.isAppGroup
            )
        }
        whitelistRulesCount = AdLockWhitelistStore.shared.rulesSnapshot().count

        let items = entry.items.map { item -> AdLockItem in
            let pathWhitelisted = AdLockWhitelistStore.shared.isPathWhitelisted(item.fullPath)
            return item.updated(
                whitelisted: whitelisting || pathWhitelisted,
                pathWhitelisted: pathWhitelisted,
                containerWhitelisted: whitelisting
            )
        }
        let updated = AdLockAppEntry(
            id: entry.id,
            containerID: entry.containerID,
            displayName: entry.displayName,
            containerPath: entry.containerPath,
            isAppGroup: entry.isAppGroup,
            isWhitelisted: whitelisting,
            items: items
        )
        replace(updated)

        guard whitelisting else { return }
        let locked = items.filter { $0.isLockedReadOnly || $0.hasSentinel }
        guard !locked.isEmpty else { return }
        isOperating = true
        DispatchQueue.global(qos: .userInitiated).async {
            let results = AdLockService.restoreWhitelisted(
                items: locked,
                containerPath: entry.containerPath,
                cancel: AdLockScanCancellationFlag()
            )
            DispatchQueue.main.async {
                isOperating = false
                apply(results, to: updated)
            }
        }
    }

    private func togglePathWhitelist(_ item: AdLockItem, in entry: AdLockAppEntry) {
        guard !isOperating else { return }
        if item.isPathWhitelisted {
            AdLockWhitelistStore.shared.removeExactPath(item.fullPath)
            let updatedItem = item.updated(
                whitelisted: item.isContainerWhitelisted,
                pathWhitelisted: false
            )
            replace(entry.replacingItem(updatedItem))
            whitelistRulesCount = AdLockWhitelistStore.shared.rulesSnapshot().count
        } else {
            let result = AdLockWhitelistStore.shared.addPathRule(
                rawPath: item.fullPath,
                selfBundleID: Bundle.main.bundleIdentifier ?? "",
                selfAppGroupID: SandboxAccess.appGroup
            )
            switch result {
            case .success:
                let updatedItem = item.updated(whitelisted: true, pathWhitelisted: true)
                replace(entry.replacingItem(updatedItem))
                whitelistRulesCount = AdLockWhitelistStore.shared.rulesSnapshot().count
                if item.isLockedReadOnly || item.hasSentinel {
                    isOperating = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let results = AdLockService.setLocked(
                            items: [updatedItem],
                            containerPath: entry.containerPath,
                            locked: false,
                            cancel: AdLockScanCancellationFlag()
                        )
                        DispatchQueue.main.async {
                            isOperating = false
                            if let entry = allEntries.first(where: { $0.id == entry.id }) {
                                apply(results, to: entry)
                            }
                        }
                    }
                }
            case .failure(let failure):
                notice = AdLockNotice(
                    title: language.text("adlock.whitelist"),
                    message: language.text("adlock.error.\(failure.rawValue)")
                )
            }
        }
    }

    private func removeCustom(_ item: AdLockItem) {
        AdLockCustomWatchStore.shared.remove(fullPath: item.fullPath)
        rescan()
    }

    private func replace(_ entry: AdLockAppEntry) {
        guard let index = allEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        allEntries[index] = entry
    }

    private func displayName(_ entry: AdLockAppEntry) -> String {
        AdLockService.displayName(for: entry, languageCode: language.rawValue)
    }

    // MARK: - Batch confirmation

    private func batchAlert(for action: AdLockBatchAction) -> Alert {
        switch action {
        case .lockAll:
            let count = pendingLockOrHardenCount
            return Alert(
                title: Text(language.text("adlock.lock_all_confirm_title")),
                message: Text(language.text("adlock.lock_all_confirm_message", Int64(count))),
                primaryButton: .destructive(Text(language.text("adlock.lock_all"))) {
                    let pairs = detectedEntries.compactMap { entry -> (AdLockAppEntry, [AdLockItem])? in
                        let items = entry.items.filter { !$0.isWhitelisted && $0.needsActionToLock }
                        return items.isEmpty ? nil : (entry, items)
                    }
                    executeBatch(pairs: pairs, lock: true)
                },
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        case .unlockAll:
            let pairs = detectedEntries.compactMap { entry -> (AdLockAppEntry, [AdLockItem])? in
                let items = entry.items.filter { $0.isLockedReadOnly || $0.hasSentinel }
                return items.isEmpty ? nil : (entry, items)
            }
            let count = pairs.reduce(0) { $0 + $1.1.count }
            return Alert(
                title: Text(language.text("adlock.unlock_all_confirm_title")),
                message: Text(language.text("adlock.unlock_all_confirm_message", Int64(count))),
                primaryButton: .destructive(Text(language.text("adlock.unlock_all"))) {
                    executeBatch(pairs: pairs, lock: false)
                },
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        }
    }

    // MARK: - Locator

    @ViewBuilder
    private func locateDestination(_ target: AdLockLocateTarget) -> some View {
        if let item = target.item {
            FileBrowserView(
                containerPath: target.entry.containerPath,
                startPath: (item.fullPath as NSString).deletingLastPathComponent,
                title: item.relativePath,
                bundleID: target.entry.containerID,
                highlightPath: item.fullPath
            )
        } else {
            FileBrowserView(
                containerPath: target.entry.containerPath,
                title: displayName(target.entry),
                bundleID: target.entry.containerID
            )
        }
    }
}

// MARK: - Folder row

private struct AdLockFolderRow: View {
    @Environment(\.appLanguage) private var language
    let item: AdLockItem
    let isBusy: Bool
    let onLocate: () -> Void
    let onPreview: (() -> Void)?
    let onToggleLock: () -> Void
    let onTogglePathWhitelist: (() -> Void)?
    let onRemoveCustom: (() -> Void)?

    private var statusText: String {
        let octal = AdLockPolicy.octalString(item.mode)
        if item.isDirectory {
            if item.isLockedReadOnly {
                return "\(octal) " + language.text(
                    item.hasSentinel
                        ? "adlock.item.status.sentinel_locked"
                        : "adlock.item.status.weak_lock"
                )
            }
            return "\(octal) " + language.text("adlock.item.status.writable")
        }
        return "\(octal) " + language.text(
            item.isLockedReadOnly
                ? "adlock.item.status.file_locked"
                : "adlock.item.status.writable"
        )
    }

    private var statusColor: Color {
        if item.isWhitelisted && !item.isLockedReadOnly { return .teal }
        if !item.needsActionToLock { return .green }
        if item.isLockedReadOnly && item.isDirectory && !item.hasSentinel { return .yellow }
        return .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.text.fill")
                    .font(.caption2)
                    .foregroundStyle(item.isDirectory ? AppTheme.accent : .blue)

                Text(item.relativePath)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                Text(byteText(item.cachedBytes))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                if item.isCustomRule {
                    adLockBadge(language.text("adlock.custom_badge"), color: .blue)
                }
                if item.isWhitelisted {
                    adLockBadge(language.text("adlock.whitelisted"), color: .teal)
                }
                if !item.marker.isEmpty {
                    Text(item.marker)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(statusColor.opacity(0.16), in: Capsule())
                    .foregroundStyle(statusColor == .yellow ? .orange : statusColor)
                    .fixedSize()
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    leftActions
                    Spacer(minLength: 4)
                    lockAction
                }
                VStack(alignment: .leading, spacing: 6) {
                    leftActions
                    lockAction
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var leftActions: some View {
        Button(action: onLocate) {
            HStack(spacing: 3) {
                Image(systemName: "scope")
                Text(language.text("adlock.locate"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isBusy)

        if let onPreview {
            Button(action: onPreview) {
                HStack(spacing: 3) {
                    Image(systemName: "eye")
                    Text(language.text("adlock.preview"))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
        }

        if let onTogglePathWhitelist {
            Button(action: onTogglePathWhitelist) {
                HStack(spacing: 3) {
                    Image(systemName: item.isPathWhitelisted
                          ? "shield.slash" : "checkmark.shield")
                    Text(language.text(
                        item.isPathWhitelisted
                            ? "adlock.item.unignore"
                            : "adlock.item.ignore"
                    ))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(item.isPathWhitelisted ? .teal : .secondary)
            .disabled(isBusy)
        }

        if let onRemoveCustom {
            Button(role: .destructive, action: onRemoveCustom) {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
        }
    }

    @ViewBuilder
    private var lockAction: some View {
        if !item.needsActionToLock {
            if item.isLockedReadOnly {
                Button(action: onToggleLock) {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.open.fill")
                        Text(language.text("adlock.unlock"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.green)
                .disabled(isBusy)
            } else {
                Text(language.text("adlock.item.skipped"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.teal)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.teal.opacity(0.14), in: Capsule())
            }
        } else {
            Button(action: onToggleLock) {
                HStack(spacing: 3) {
                    Image(systemName: item.needsHarden ? "lock.fill" : "lock.fill")
                    Text(language.text(
                        item.needsHarden
                            ? "adlock.item.harden"
                            : "adlock.lock"
                    ))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
            .disabled(isBusy)
        }
    }
}

// MARK: - Shared bits

struct AdLockLocateTarget: Identifiable {
    let id = UUID()
    let entry: AdLockAppEntry
    let item: AdLockItem?
}

enum AdLockBatchAction: String, Identifiable {
    case lockAll
    case unlockAll
    var id: String { rawValue }
}

enum AdLockAlert: Identifiable {
    case batch(AdLockBatchAction)
    case notice(AdLockNotice)

    var id: String {
        switch self {
        case .batch(let action):
            return "batch:" + action.id
        case .notice(let notice):
            return "notice:" + notice.id.uuidString
        }
    }
}

struct AdLockNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct AdLockHeaderLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

@ViewBuilder
func adLockBadge(_ text: String, color: Color) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
        .fixedSize()
}

extension AdLockItem {
    func updated(
        mode: Int? = nil,
        hasSentinel: Bool? = nil,
        bytes: Int64? = nil,
        whitelisted: Bool? = nil,
        pathWhitelisted: Bool? = nil,
        containerWhitelisted: Bool? = nil
    ) -> AdLockItem {
        AdLockItem(
            id: id,
            fullPath: fullPath,
            relativePath: relativePath,
            isDirectory: isDirectory,
            marker: marker,
            isCustomRule: isCustomRule,
            mode: mode ?? self.mode,
            cachedBytes: bytes ?? cachedBytes,
            hasSentinel: hasSentinel ?? self.hasSentinel,
            isWhitelisted: whitelisted ?? isWhitelisted,
            isPathWhitelisted: pathWhitelisted ?? isPathWhitelisted,
            isContainerWhitelisted: containerWhitelisted ?? isContainerWhitelisted
        )
    }
}

extension AdLockAppEntry {
    func replacingItem(_ item: AdLockItem) -> AdLockAppEntry {
        replacingItems(items.map { $0.id == item.id ? item : $0 })
    }

    func replacingItems(_ newItems: [AdLockItem]) -> AdLockAppEntry {
        AdLockAppEntry(
            id: id,
            containerID: containerID,
            displayName: displayName,
            containerPath: containerPath,
            isAppGroup: isAppGroup,
            isWhitelisted: isWhitelisted,
            items: newItems
        )
    }

    func applying(_ results: [AdLockMutationResult]) -> AdLockAppEntry {
        var newItems = items
        for result in results where result.ok {
            guard let index = newItems.firstIndex(where: { $0.id == result.path }) else { continue }
            let old = newItems[index]
            newItems[index] = old.updated(
                mode: result.mode,
                hasSentinel: result.hasSentinel,
                bytes: result.mode == 0o555 ? 0 : old.cachedBytes
            )
        }
        return replacingItems(newItems)
    }
}