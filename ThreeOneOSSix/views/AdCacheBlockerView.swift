import SwiftUI

// MARK: - Main page

struct AdCacheBlockerView: View {
    @Environment(\.appLanguage) private var language
    @State private var entries: [AdLockAppEntry] = []
    @State private var isScanning = false
    @State private var isStopping = false
    @State private var scanCompleted = 0
    @State private var scanTotal = 0
    @State private var deniedContainers = 0
    @State private var searchText = ""
    @State private var showWhitelisted = true
    @State private var showWhitelistSheet = false
    @State private var showAddCustomSheet = false
    @State private var activeCancellation: AdLockScanCancellationFlag?
    @State private var batchAction: AdLockBatchAction?
    @State private var hasLoaded = false
    @State private var notice: AdLockNotice?

    private var filteredEntries: [AdLockAppEntry] {
        let base = showWhitelisted ? entries : entries.filter { !$0.isWhitelisted }
        guard !searchText.isEmpty else { return base }
        let query = searchText.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: language.locale
        )
        return base.filter { entry in
            let name = displayName(entry).folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: language.locale
            )
            return name.contains(query) ||
                entry.containerID.lowercased().contains(query.lowercased()) ||
                entry.items.contains {
                    $0.relativePath.lowercased().contains(query.lowercased()) ||
                        $0.marker.lowercased().contains(query.lowercased())
                }
        }
    }

    private var detectedCount: Int {
        entries.reduce(0) { $0 + $1.items.count }
    }

    private var lockedCount: Int {
        entries.reduce(0) { $0 + $1.lockedCount }
    }

    private var pendingCount: Int {
        entries.reduce(0) { $0 + $1.pendingCount }
    }

    private var reclaimableBytes: Int64 {
        entries.reduce(0) { $0 + $1.reclaimableBytes }
    }

    private var lockableCount: Int {
        entries.reduce(0) { total, entry in
            total + entry.items.filter { !$0.isWhitelisted && $0.needsActionToLock }.count
        }
    }

    private var unlockableCount: Int {
        entries.reduce(0) { total, entry in
            total + entry.items.filter { $0.isLockedReadOnly || $0.hasSentinel }.count
        }
    }

    var body: some View {
        List {
            statusSection
            if AdLockService.isAvailable {
                resultsSection
            }
            boundarySection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(language.text("adlock.title"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: language.text("adlock.search_placeholder"))
        .toolbar { toolbarContent }
        .sheet(isPresented: $showWhitelistSheet) {
            NavigationStack {
                AdWhitelistManagerSheet(entries: entries)
            }
        }
        .sheet(isPresented: $showAddCustomSheet) {
            NavigationStack {
                AddAdCustomPathSheet { rescan() }
            }
        }
        .alert(item: $batchAction) { action in
            batchAlert(for: action)
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
        .onAppear {
            guard !hasLoaded else { return }
            hasLoaded = true
            rescan()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if !AdLockService.isAvailable {
                Label(language.text("adlock.unsupported"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if isScanning {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ProgressView()
                        Text(
                            scanTotal > 0
                                ? language.text("adlock.scan_progress", Int64(scanCompleted), Int64(scanTotal))
                                : language.text("adlock.scanning")
                        )
                        .font(.subheadline)
                        Spacer()
                        Button(isStopping ? language.text("adlock.stopping") : language.text("adlock.stop")) {
                            stopScan()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isStopping)
                    }
                    if scanTotal > 0 {
                        ProgressView(
                            value: Double(scanCompleted),
                            total: Double(max(scanTotal, 1))
                        )
                    }
                }
                .padding(.vertical, 4)
            } else {
                LabeledContent(language.text("adlock.summary.detected"), value: "\(detectedCount)")
                LabeledContent(language.text("adlock.summary.locked"), value: "\(lockedCount)")
                LabeledContent(language.text("adlock.summary.pending"), value: "\(pendingCount)")
                LabeledContent(
                    language.text("adlock.summary.reclaimable"),
                    value: byteText(reclaimableBytes)
                )
                if deniedContainers > 0 {
                    Text(language.text("adlock.denied", Int64(deniedContainers)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(language.text("adlock.show_whitelisted"), isOn: $showWhitelisted)
        } header: {
            Text(language.text("adlock.section.overview"))
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        Section {
            if filteredEntries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isScanning ? language.text("adlock.scanning") : language.text("adlock.empty"))
                        .font(.subheadline)
                    Text(language.text("adlock.empty_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else {
                ForEach(filteredEntries) { entry in
                    NavigationLink {
                        AdLockEntryDetailView(entry: entry) { updated in
                            replace(updated)
                        }
                    } label: {
                        appRow(entry)
                    }
                }
            }
        } header: {
            Text(language.text("adlock.section.apps"))
        }
    }

    @ViewBuilder
    private var boundarySection: some View {
        Section {
            Text(language.text("adlock.boundary_body"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(language.text("adlock.boundary_title"))
        }
    }

    private func appRow(_ entry: AdLockAppEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isAppGroup ? "person.2.square.stack.fill" : "app.dashed")
                .font(.title3)
                .foregroundStyle(entry.isWhitelisted ? Color.secondary : AppTheme.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName(entry))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if entry.isWhitelisted {
                        adLockBadge(language.text("adlock.whitelisted"), color: .secondary)
                    }
                }
                Text(entry.isAppGroup ? entry.containerID : entry.containerID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Label("\(entry.items.count)", systemImage: "scope")
                    Label("\(entry.lockedCount)", systemImage: "lock.fill")
                    Text(byteText(entry.reclaimableBytes))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                rescan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isScanning || !AdLockService.isAvailable)
            .accessibilityLabel(language.text("adlock.rescan"))
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    showWhitelistSheet = true
                } label: {
                    Label(language.text("adlock.whitelist_manage"), systemImage: "checkmark.shield")
                }
                Button {
                    showAddCustomSheet = true
                } label: {
                    Label(language.text("adlock.add_custom"), systemImage: "plus")
                }
                Divider()
                Button {
                    batchAction = .lockAll
                } label: {
                    Label(language.text("adlock.lock_all"), systemImage: "lock.fill")
                }
                .disabled(lockableCount == 0 || isScanning)
                Button {
                    batchAction = .unlockAll
                } label: {
                    Label(language.text("adlock.unlock_all"), systemImage: "lock.open.fill")
                }
                .disabled(unlockableCount == 0 || isScanning)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func batchAlert(for action: AdLockBatchAction) -> Alert {
        switch action {
        case .lockAll:
            return Alert(
                title: Text(language.text("adlock.lock_all_confirm_title")),
                message: Text(language.text("adlock.lock_all_confirm_message", Int64(lockableCount))),
                primaryButton: .destructive(Text(language.text("adlock.lock_all"))) {
                    performBatch(lock: true)
                },
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        case .unlockAll:
            return Alert(
                title: Text(language.text("adlock.unlock_all_confirm_title")),
                message: Text(language.text("adlock.unlock_all_confirm_message", Int64(unlockableCount))),
                primaryButton: .destructive(Text(language.text("adlock.unlock_all"))) {
                    performBatch(lock: false)
                },
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        }
    }

    // MARK: - Actions

    private func rescan() {
        guard AdLockService.isAvailable else { return }
        let flag = AdLockScanCancellationFlag()
        activeCancellation = flag
        isScanning = true
        isStopping = false
        scanCompleted = 0
        scanTotal = 0
        deniedContainers = 0

        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = AdLockService.scan(cancel: flag) { completed, total in
                DispatchQueue.main.async {
                    scanCompleted = completed
                    scanTotal = total
                }
            }
            DispatchQueue.main.async {
                guard activeCancellation === flag else { return }
                activeCancellation = nil
                isScanning = false
                isStopping = false
                entries = snapshot.entries
                scanCompleted = snapshot.scannedContainers
                scanTotal = snapshot.scannedContainers
                deniedContainers = snapshot.deniedContainers
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
        activeCancellation?.cancel()
    }

    private func performBatch(lock: Bool) {
        let flag = AdLockScanCancellationFlag()
        let snapshotEntries = entries
        isScanning = true
        isStopping = false
        scanCompleted = 0
        scanTotal = snapshotEntries.count

        DispatchQueue.global(qos: .userInitiated).async {
            var results: [AdLockMutationResult] = []
            for (index, entry) in snapshotEntries.enumerated() {
                if flag.isCancelled { break }
                let targets = lock
                    ? entry.items.filter { !$0.isWhitelisted && $0.needsActionToLock }
                    : entry.items.filter { $0.isLockedReadOnly || $0.hasSentinel }
                guard !targets.isEmpty else {
                    DispatchQueue.main.async {
                        scanCompleted = index + 1
                    }
                    continue
                }
                results.append(
                    contentsOf: AdLockService.setLocked(
                        items: targets,
                        containerPath: entry.containerPath,
                        locked: lock,
                        cancel: flag
                    )
                )
                DispatchQueue.main.async {
                    scanCompleted = index + 1
                }
            }

            DispatchQueue.main.async {
                isScanning = false
                isStopping = false
                let failures = results.filter { !$0.ok }
                if !failures.isEmpty {
                    notice = AdLockNotice(
                        title: language.text("adlock.results.title"),
                        message: language.text(
                            "adlock.results.summary",
                            Int64(results.count - failures.count),
                            Int64(failures.count)
                        )
                    )
                }
                rescan()
            }
        }
    }

    private func replace(_ entry: AdLockAppEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        }
    }

    private func displayName(_ entry: AdLockAppEntry) -> String {
        AdLockService.displayName(for: entry, languageCode: language.rawValue)
    }
}

// MARK: - Detail page

struct AdLockEntryDetailView: View {
    @Environment(\.appLanguage) private var language
    @State private var entry: AdLockAppEntry
    @State private var isBusy = false
    @State private var notice: AdLockNotice?
    @State private var locateItem: AdLockItem?
    @State private var previewItem: AdLockItem?
    private let onChanged: (AdLockAppEntry) -> Void

    init(entry: AdLockAppEntry, onChanged: @escaping (AdLockAppEntry) -> Void) {
        _entry = State(initialValue: entry)
        self.onChanged = onChanged
    }

    var body: some View {
        List {
            Section {
                LabeledContent(language.text("adlock.summary.detected"), value: "\(entry.items.count)")
                LabeledContent(language.text("adlock.summary.locked"), value: "\(entry.lockedCount)")
                LabeledContent(language.text("adlock.summary.reclaimable"), value: byteText(entry.reclaimableBytes))
                if entry.isWhitelisted {
                    Label(language.text("adlock.app_whitelisted"), systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                }
            } header: {
                Text(displayName)
            }

            Section {
                ForEach(entry.items) { item in
                    itemRow(item)
                }
            } header: {
                Text(language.text("adlock.section.targets"))
            }

            Section {
                Button {
                    toggleEntryWhitelist()
                } label: {
                    Label(
                        entry.isWhitelisted
                            ? language.text("adlock.app_unwhitelist")
                            : language.text("adlock.app_whitelist"),
                        systemImage: entry.isWhitelisted ? "shield.slash" : "checkmark.shield"
                    )
                }
                .disabled(isBusy)

                Button {
                    lockAll()
                } label: {
                    Label(language.text("adlock.lock_all"), systemImage: "lock.fill")
                }
                .disabled(isBusy || entry.items.filter { $0.needsActionToLock }.isEmpty)

                Button {
                    unlockAll()
                } label: {
                    Label(language.text("adlock.unlock_all"), systemImage: "lock.open.fill")
                }
                .disabled(isBusy || entry.items.filter { $0.isLockedReadOnly || $0.hasSentinel }.isEmpty)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isBusy {
                ProgressView()
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
        .sheet(item: $locateItem) { item in
            NavigationStack {
                FileBrowserView(
                    containerPath: entry.containerPath,
                    startPath: (item.fullPath as NSString).deletingLastPathComponent,
                    title: item.relativePath,
                    bundleID: entry.containerID,
                    highlightPath: item.fullPath
                )
            }
        }
        .sheet(item: $previewItem) { item in
            NavigationStack {
                HexViewerView(path: item.fullPath, readOnly: true)
            }
        }
    }

    private var displayName: String {
        AdLockService.displayName(for: entry, languageCode: language.rawValue)
    }

    private func itemRow(_ item: AdLockItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.text.fill")
                .foregroundStyle(item.isLockedReadOnly ? Color.green : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.relativePath)
                    .font(.footnote.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if item.isLockedReadOnly {
                        adLockBadge(language.text("adlock.locked"), color: .green)
                    } else if item.needsHarden {
                        adLockBadge(language.text("adlock.needs_harden"), color: .orange)
                    } else {
                        adLockBadge(language.text("adlock.unlocked"), color: .secondary)
                    }
                    if item.isWhitelisted {
                        adLockBadge(language.text("adlock.whitelisted"), color: .secondary)
                    }
                    if item.isCustomRule {
                        adLockBadge(language.text("adlock.custom_badge"), color: .blue)
                    }
                    Text("\(AdLockPolicy.octalString(item.mode)) · \(byteText(item.cachedBytes))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            Button {
                toggleLock(item)
            } label: {
                Image(systemName: item.isLockedReadOnly ? "lock.open.fill" : "lock.fill")
                    .font(.body)
            }
            .buttonStyle(.borderless)
            .disabled(isBusy || item.isWhitelisted)
            .accessibilityLabel(
                item.isLockedReadOnly
                    ? language.text("adlock.unlock")
                    : language.text("adlock.lock")
            )
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button {
                locateItem = item
            } label: {
                Label(language.text("adlock.locate"), systemImage: "scope")
            }
            if !item.isDirectory {
                Button {
                    previewItem = item
                } label: {
                    Label(language.text("adlock.preview"), systemImage: "eye")
                }
            }
            Button {
                togglePathWhitelist(item)
            } label: {
                Label(
                    item.isWhitelisted
                        ? language.text("adlock.path_unwhitelist")
                        : language.text("adlock.path_whitelist"),
                    systemImage: item.isWhitelisted ? "shield.slash" : "checkmark.shield"
                )
            }
        }
    }

    // MARK: - Actions

    private func toggleLock(_ item: AdLockItem) {
        guard !isBusy else { return }
        isBusy = true
        let target = item
        let containerPath = entry.containerPath
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AdLockService.setLocked(
                item: target,
                containerPath: containerPath,
                locked: !target.isLockedReadOnly
            )
            DispatchQueue.main.async {
                isBusy = false
                if result.ok {
                    apply([result])
                } else {
                    notice = AdLockNotice(
                        title: language.text("adlock.results.title"),
                        message: result.error ?? language.text("adlock.error.generic")
                    )
                }
            }
        }
    }

    private func lockAll() {
        let targets = entry.items.filter { $0.needsActionToLock }
        runBatch(targets: targets, locked: true)
    }

    private func unlockAll() {
        let targets = entry.items.filter { $0.isLockedReadOnly || $0.hasSentinel }
        runBatch(targets: targets, locked: false)
    }

    private func runBatch(targets: [AdLockItem], locked: Bool) {
        guard !targets.isEmpty, !isBusy else { return }
        isBusy = true
        let containerPath = entry.containerPath
        let flag = AdLockScanCancellationFlag()
        DispatchQueue.global(qos: .userInitiated).async {
            let results = AdLockService.setLocked(
                items: targets,
                containerPath: containerPath,
                locked: locked,
                cancel: flag
            )
            DispatchQueue.main.async {
                isBusy = false
                apply(results)
                let failures = results.filter { !$0.ok }
                if !failures.isEmpty {
                    notice = AdLockNotice(
                        title: language.text("adlock.results.title"),
                        message: language.text(
                            "adlock.results.summary",
                            Int64(results.count - failures.count),
                            Int64(failures.count)
                        )
                    )
                }
            }
        }
    }

    private func toggleEntryWhitelist() {
        guard !isBusy else { return }
        isBusy = true
        let containerID = entry.containerID
        let isAppGroup = entry.isAppGroup
        let containerPath = entry.containerPath
        let whitelisting = !entry.isWhitelisted

        if whitelisting {
            _ = AdLockWhitelistStore.shared.addBundleRule(bundleOrGroupID: containerID)
        } else {
            AdLockWhitelistStore.shared.removeMatchingContainer(id: containerID, isAppGroup: isAppGroup)
        }

        let items = entry.items.map {
            $0.updated(whitelisted: whitelisting)
        }
        var updated = entry.replacingItems(items).withWhitelisted(whitelisting)
        DispatchQueue.global(qos: .userInitiated).async {
            let results = whitelisting
                ? AdLockService.restoreWhitelisted(
                    items: items,
                    containerPath: containerPath,
                    cancel: AdLockScanCancellationFlag()
                )
                : []
            DispatchQueue.main.async {
                isBusy = false
                if !results.isEmpty {
                    updated = updated.applying(results)
                }
                entry = updated
                onChanged(updated)
            }
        }
    }

    private func togglePathWhitelist(_ item: AdLockItem) {
        guard !isBusy else { return }
        if item.isWhitelisted {
            if item.isContainerWhitelisted {
                notice = AdLockNotice(
                    title: language.text("adlock.whitelist"),
                    message: language.text("adlock.error.container_whitelisted")
                )
                return
            }
            AdLockWhitelistStore.shared.removeExactPath(item.fullPath)
            let updatedItem = item.updated(whitelisted: false)
            var updated = entry.replacingItem(updatedItem)
            entry = updated
            onChanged(updated)
        } else {
            let result = AdLockWhitelistStore.shared.addPathRule(
                rawPath: item.fullPath,
                selfBundleID: Bundle.main.bundleIdentifier ?? "",
                selfAppGroupID: SandboxAccess.appGroup
            )
            switch result {
            case .success:
                let updatedItem = item.updated(whitelisted: true)
                var updated = entry.replacingItem(updatedItem)
                entry = updated
                onChanged(updated)
                if item.isLockedReadOnly || item.hasSentinel {
                    isBusy = true
                    let containerPath = entry.containerPath
                    DispatchQueue.global(qos: .userInitiated).async {
                        let results = AdLockService.setLocked(
                            items: [updatedItem],
                            containerPath: containerPath,
                            locked: false,
                            cancel: AdLockScanCancellationFlag()
                        )
                        DispatchQueue.main.async {
                            isBusy = false
                            updated = updated.applying(results)
                            entry = updated
                            onChanged(updated)
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

    private func apply(_ results: [AdLockMutationResult]) {
        let updated = entry.applying(results)
        entry = updated
        onChanged(updated)
    }
}

// MARK: - Shared helpers

enum AdLockBatchAction: String, Identifiable {
    case lockAll
    case unlockAll
    var id: String { rawValue }
}

struct AdLockNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

@ViewBuilder
func adLockBadge(_ text: String, color: Color) -> some View {
    Text(text)
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
}

extension AdLockItem {
    func updated(
        mode: Int? = nil,
        hasSentinel: Bool? = nil,
        bytes: Int64? = nil,
        whitelisted: Bool? = nil
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
            isContainerWhitelisted: isContainerWhitelisted
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

    func withWhitelisted(_ flag: Bool) -> AdLockAppEntry {
        AdLockAppEntry(
            id: id,
            containerID: containerID,
            displayName: displayName,
            containerPath: containerPath,
            isAppGroup: isAppGroup,
            isWhitelisted: flag,
            items: items.map { $0.updated(whitelisted: flag) }
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