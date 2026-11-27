import SwiftUI
import Darwin

// MARK: - Whitelist manager

struct AdWhitelistManagerSheet: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    let entries: [AdLockAppEntry]

    @State private var rules: [AdLockRule] = []
    @State private var bundleInput = ""
    @State private var pathInput = ""
    @State private var selectedEntryID = ""
    @State private var notice: AdLockNotice?

    var body: some View {
        List {
            Section {
                if !entries.isEmpty {
                    Picker(language.text("adlock.whitelist_pick_app"), selection: $selectedEntryID) {
                        Text(language.text("adlock.whitelist_pick_none")).tag("")
                        ForEach(entries) { entry in
                            Text(displayName(entry)).tag(entry.id)
                        }
                    }
                    Button(language.text("adlock.whitelist_add_selected")) {
                        addSelectedEntry()
                    }
                    .disabled(selectedEntryID.isEmpty)
                }

                TextField(language.text("adlock.whitelist_bundle_placeholder"), text: $bundleInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(language.text("adlock.whitelist_add_bundle")) {
                    addBundleInput()
                }
                .disabled(bundleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                TextField(language.text("adlock.whitelist_path_placeholder"), text: $pathInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                Button(language.text("adlock.whitelist_add_path")) {
                    addPathInput()
                }
                .disabled(pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text(language.text("adlock.whitelist_add"))
            } footer: {
                Text(language.text("adlock.whitelist_footer"))
            }

            Section {
                if rules.isEmpty {
                    Text(language.text("adlock.whitelist_empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules) { rule in
                        ruleRow(rule)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    remove(rule)
                                } label: {
                                    Label(language.text("common.delete"), systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text(language.text("adlock.whitelist_rules"))
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(language.text("adlock.whitelist_manage"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(language.text("common.done")) { dismiss() }
            }
        }
        .onAppear { reload() }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private func ruleRow(_ rule: AdLockRule) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(
                    rule.kind == .bundleID
                        ? language.text("adlock.whitelist_kind_app")
                        : language.text("adlock.whitelist_kind_path")
                )
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(.secondary)
                if rule.isSeed {
                    Text(language.text("adlock.whitelist_seed_badge"))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            Text(rule.target)
                .font(.footnote.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        rules = AdLockWhitelistStore.shared.rulesSnapshot()
    }

    private func addSelectedEntry() {
        guard let entry = entries.first(where: { $0.id == selectedEntryID }) else { return }
        _ = AdLockWhitelistStore.shared.addBundleRule(bundleOrGroupID: entry.containerID)
        selectedEntryID = ""
        reload()
    }

    private func addBundleInput() {
        guard AdLockWhitelistStore.shared.addBundleRule(
            bundleOrGroupID: bundleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        ) != nil else {
            notice = AdLockNotice(
                title: language.text("adlock.whitelist"),
                message: language.text("adlock.whitelist_invalid")
            )
            return
        }
        bundleInput = ""
        reload()
    }

    private func addPathInput() {
        let result = AdLockWhitelistStore.shared.addPathRule(
            rawPath: pathInput,
            selfBundleID: Bundle.main.bundleIdentifier ?? "",
            selfAppGroupID: SandboxAccess.appGroup
        )
        switch result {
        case .success:
            pathInput = ""
            reload()
        case .failure(let failure):
            notice = AdLockNotice(
                title: language.text("adlock.whitelist"),
                message: language.text("adlock.error.\(failure.rawValue)")
            )
        }
    }

    private func remove(_ rule: AdLockRule) {
        AdLockWhitelistStore.shared.remove(ruleID: rule.id)
        reload()
    }

    private func displayName(_ entry: AdLockAppEntry) -> String {
        AdLockService.displayName(for: entry, languageCode: language.rawValue)
    }
}

// MARK: - Add custom watch path

struct AddAdCustomPathSheet: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dismiss) private var dismiss
    let onAdded: () -> Void

    @State private var path = ""
    @State private var note = ""
    @State private var notice: AdLockNotice?
    @State private var pendingConfirmation = false
    @State private var pendingPath = ""
    @State private var pendingDirectory = true

    var body: some View {
        Form {
            Section {
                TextField(language.text("adlock.custom_path_placeholder"), text: $path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                TextField(language.text("adlock.custom_note_placeholder"), text: $note)
            } header: {
                Text(language.text("adlock.custom_title"))
            } footer: {
                Text(language.text("adlock.custom_footer"))
            }

            Section {
                Button(language.text("adlock.custom_confirm")) {
                    validate()
                }
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(language.text("adlock.add_custom"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(language.text("common.cancel")) { dismiss() }
            }
        }
        .alert(item: $notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
        .alert(language.text("adlock.custom_risk_title"), isPresented: $pendingConfirmation) {
            Button(language.text("common.cancel"), role: .cancel) {}
            Button(language.text("adlock.custom_risk_confirm"), role: .destructive) {
                add(path: pendingPath, isDirectory: pendingDirectory)
            }
        } message: {
            Text(
                language.text(
                    "adlock.custom_risk_message",
                    pendingPath,
                    Int64(pendingDirectory ? 1 : 0)
                )
            )
        }
    }

    private func validate() {
        let canonical = AdLockPolicy.canonicalVarPath(
            path.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var status = stat()
        guard lstat(canonical, &status) == 0 else {
            fail("adlock.error.not_found")
            return
        }
        let format = status.st_mode & S_IFMT
        guard format == S_IFDIR || format == S_IFREG else {
            fail("adlock.error.symbolic_link")
            return
        }
        let isDirectory = format == S_IFDIR
        if !isDirectory && !AdLockPolicy.isAdConfigFile(name: (canonical as NSString).lastPathComponent) {
            fail("adlock.error.unsupported_type")
            return
        }

        let owner = (try? FileManager.default.attributesOfItem(atPath: canonical)[.ownerAccountName] as? String) ?? nil
        let validation = AdLockPolicy.validateTarget(
            path: canonical,
            isDirectory: isDirectory,
            ownerAccountName: owner,
            isSymbolicLink: format == S_IFLNK,
            selfBundleID: Bundle.main.bundleIdentifier ?? "",
            selfAppGroupID: SandboxAccess.appGroup
        )
        guard validation.allowed else {
            fail("adlock.error.\(validation.failure?.rawValue ?? AdLockFailure.emptyPath.rawValue)")
            return
        }

        pendingPath = canonical
        pendingDirectory = isDirectory
        pendingConfirmation = true
    }

    private func add(path canonical: String, isDirectory: Bool) {
        let owner = (try? FileManager.default.attributesOfItem(atPath: canonical)[.ownerAccountName] as? String) ?? nil
        let result = AdLockCustomWatchStore.shared.addValidatedRule(
            rawPath: canonical,
            note: note,
            isDirectory: isDirectory,
            ownerAccountName: owner,
            isSymbolicLink: false,
            selfBundleID: Bundle.main.bundleIdentifier ?? "",
            selfAppGroupID: SandboxAccess.appGroup
        )
        switch result {
        case .success:
            onAdded()
            dismiss()
        case .failure(let failure):
            fail("adlock.error.\(failure.rawValue)")
        }
    }

    private func fail(_ key: String) {
        notice = AdLockNotice(
            title: language.text("adlock.add_custom"),
            message: language.text(key)
        )
    }
}