import SwiftUI
import Dev2KitCore

/// Kenar çubuğunun en üstündeki "Kurum" bölümü (2026-11-11): oturum durumu,
/// kullanıcı/grup, yenile, yeni, çıkış. Kurum collection'larının kendisi
/// altta normal collection bölümleri olarak durur (kilit/kalem simgesiyle).
struct TeamSidebarSection: View {
    @Environment(AppState.self) private var appState
    @State private var creating = false
    @State private var newName = ""
    @State private var createError: String?
    @State private var confirmingSignOut = false

    var body: some View {
        Section {
            status
            if let notice = appState.teamNotice {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(notice)
                        .font(.secondaryText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        appState.teamNotice = nil
                    } label: {
                        Image(systemName: "xmark").iconHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(L10n.t("team.notice.dismiss"))
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text(L10n.t("team.section").uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if appState.teamIdentity != nil {
                    if appState.teamCanCreate {
                        Button {
                            newName = ""
                            createError = nil
                            creating = true
                        } label: {
                            Image(systemName: "plus").iconHitTarget()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L10n.t("team.new.help"))
                        .accessibilityLabel(L10n.t("team.new"))
                    }
                    Button {
                        Task { await appState.teamRefresh(reloadLoaded: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise").iconHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(appState.teamIsRefreshing)
                    .help(L10n.t("team.refresh"))
                    .accessibilityLabel(L10n.t("team.refresh"))
                }
            }
        }
        .task { await appState.teamStart() }
        .alert(L10n.t("team.new.title"), isPresented: $creating) {
            TextField(L10n.t("team.new.placeholder"), text: $newName)
                .inputLimit(.name)
            Button(L10n.t("team.new.confirm")) {
                let name = newName
                Task {
                    if let error = await appState.teamCreate(name: name) { appState.teamNotice = error }
                }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("team.new.message"))
        }
        .alert(L10n.t("team.signOut.unsaved.title"), isPresented: $confirmingSignOut) {
            Button(L10n.t("team.signOut"), role: .destructive) {
                Task { await appState.teamLogout() }
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("team.signOut.unsaved.message"))
        }
    }

    @ViewBuilder
    private var status: some View {
        switch appState.teamStatus {
        case .restoring:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("team.connecting")).font(.secondaryText).foregroundStyle(.secondary)
            }
        case .unknown:
            Button {
                Task { await appState.teamStart() }
            } label: {
                Label(L10n.t("team.retry"), systemImage: "arrow.clockwise")
                    .font(.secondaryText)
                    .rowHitTarget(minHeight: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        case .loggedOut:
            Button {
                appState.showingTeamLogin = true
            } label: {
                Label(L10n.t("team.signIn"), systemImage: "person.badge.key")
                    .font(.secondaryText)
                    .rowHitTarget(minHeight: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .help(L10n.t("team.signIn.help"))
        case .loggedIn(let identity):
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                Text(identity.displayName ?? identity.username)
                    .font(.secondaryText)
                    .lineLimit(1)
                Text(identity.group)
                    .font(.tinyMono)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if appState.teamIsRefreshing { ProgressView().controlSize(.mini) }
                Menu {
                    Button(L10n.t("team.signOut"), role: .destructive) {
                        // Kaydedilmemiş değişiklik varsa önce sorulur (tıklamada
                        // bir kez bakılır, gövdede taranmaz).
                        if appState.teamCatalog.dirtyIDs.isEmpty {
                            Task { await appState.teamLogout() }
                        } else {
                            confirmingSignOut = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.t("team.account"))
            }
            .help(L10n.t("team.user.help", identity.username, identity.group))
        }
    }
}

/// Kurum girişi. Parola yalnızca login isteğinde gider; saklanmaz, istek
/// bitince alandan silinir. Başarısız giriş otomatik tekrarlanmaz; 429'da
/// düğme süre dolana dek kapalı (rehber: her hatalı deneme AD hesabını
/// kilitlenmeye yaklaştırır).
struct TeamLoginSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var working = false
    @State private var now = Date()
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    private var waitSeconds: Int {
        guard let until = appState.teamLoginRetryAt else { return 0 }
        return max(0, Int(until.timeIntervalSince(now).rounded(.up)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("team.login.title")).font(.headline)
            Text(L10n.t("team.login.detail"))
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(L10n.t("team.login.username"), text: $username)
                .textFieldStyle(.input)
                .inputLimit(.short)
                .textContentType(.username)
                .focused($focus, equals: .username)
                .onSubmit { focus = .password }
            SecureField(L10n.t("team.login.password"), text: $password)
                .textFieldStyle(.input)
                .inputLimit(.credential)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .onSubmit(submit)
            if let error {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(TeamConfig.default.authBaseURL.host ?? "")
                    .font(.tinyMono)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(L10n.t("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(waitSeconds > 0 ? L10n.t("team.login.retryIn", L10n.number(waitSeconds)) : L10n.t("team.login.submit"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || waitSeconds > 0 || username.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focus = .username }
        .task {
            // 429 geri sayımı (yalnızca bekleme varken saniyede bir).
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func submit() {
        guard !working, waitSeconds == 0, !username.isEmpty, !password.isEmpty else { return }
        working = true
        let secret = password
        Task {
            let failure = await appState.teamLogin(username: username, password: secret)
            password = ""
            working = false
            if let failure {
                error = failure
                focus = .password
            } else {
                dismiss()
            }
        }
    }
}

/// İstek ekranının üstündeki bant: kurum collection'ının isteği.
struct TeamRequestBanner: View {
    @Environment(AppState.self) private var appState
    let collectionID: UUID

    var body: some View {
        let info = appState.teamCatalog.entries[collectionID]
        let editable = appState.teamCatalog.canEdit(collectionID)
        HStack(spacing: 8) {
            Image(systemName: editable ? "pencil" : "lock")
            if info?.isDirty == true {
                Text(L10n.t("team.banner.dirty"))
                Spacer(minLength: 0)
                Button(L10n.t("team.save")) { Task { await appState.teamSave(collectionID) } }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help(L10n.t("team.save.help"))
            } else {
                Text(editable ? L10n.t("team.banner.editable", info?.summary.ownerGroup ?? "")
                              : L10n.t("team.banner.readOnly", info?.summary.ownerGroup ?? ""))
                Spacer(minLength: 0)
                if !editable {
                    Button(L10n.t("team.copyToMine")) { appState.teamCopyToMine(collectionID) }
                        .controlSize(.small)
                        .help(L10n.t("team.copyToMine.help"))
                }
            }
        }
        .font(.secondaryText)
        .foregroundStyle(info?.isDirty == true ? Theme.warning : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
    }
}
