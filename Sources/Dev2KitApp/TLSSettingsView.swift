import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Dev2KitCore

/// TLS ayarları: kurum güven deposu (tüm host'lar) ve host profilleri tek
/// ekranda. Solda liste, sağda seçilenin ayrıntısı.
///
/// Eskiden iki sekmeydi (Güven Deposu / Host Profilleri); ikisi de "hangi
/// CA'ya güvenilsin" sorusunun cevabı olduğu için sekme geçişi gereksiz bir
/// adımdı ve "Profili Aç" profili değil boş bir sekmeyi açıyordu
/// (kullanıcı isteği, 2026-10-20).
struct TLSSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Selection? = .trustStore
    @State private var confirmingDisable = false

    enum Selection: Hashable {
        /// Tüm host'lara uygulanan güven deposu.
        case trustStore
        case profile(UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TLS").font(.title2).bold()
                Text(L10n.t("tls.subtitle"))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 0) {
                sidebar
                    .frame(width: 210)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

            HStack(alignment: .bottom) {
                validationSection
                Spacer()
                Button(L10n.t("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 580)
        .onAppear {
            appState.reloadTrustStore()
            if let id = appState.takeTLSSettingsProfileID() {
                selection = .profile(id)
            }
        }
    }

    // MARK: Liste

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section(L10n.t("tls.allHosts")) {
                    HStack {
                        Label(L10n.t("tls.trustStore"), systemImage: "shield")
                        Spacer()
                        Text("\(appState.trustStore.entries.count)")
                            .font(.tinyText.monospacedDigit())
                            .foregroundStyle(appState.trustStore.problems.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.down))
                            .help(appState.trustStore.problems.isEmpty ? L10n.t("tls.certCount") : L10n.t("tls.unreadableFile"))
                    }
                    .tag(Selection.trustStore)
                }
                Section(L10n.t("tls.hostProfiles")) {
                    ForEach(appState.workspace.tlsProfiles) { profile in
                        TLSProfileRow(profile: profile)
                            .tag(Selection.profile(profile.id))
                    }
                    if appState.workspace.tlsProfiles.isEmpty {
                        Text(L10n.t("tls.noProfiles"))
                            .font(.secondaryText)
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 2) {
                Button {
                    selection = .profile(appState.addTLSProfile())
                } label: {
                    Image(systemName: "plus").iconHitTarget()
                }
                .help(L10n.t("tls.newProfile"))
                .accessibilityLabel(L10n.t("tls.newProfile"))
                Button {
                    deleteSelectedProfile()
                } label: {
                    Image(systemName: "minus").iconHitTarget()
                }
                .disabled(selectedProfileID == nil)
                .help(L10n.t("tls.deleteProfile"))
                .accessibilityLabel(L10n.t("tls.deleteProfile"))
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
    }

    private var selectedProfileID: UUID? {
        if case .profile(let id) = selection { return id }
        return nil
    }

    private func deleteSelectedProfile() {
        guard let id = selectedProfileID else { return }
        appState.deleteTLSProfile(id)
        selection = appState.workspace.tlsProfiles.first.map { .profile($0.id) } ?? .trustStore
    }

    // MARK: Ayrıntı

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .profile(let id):
            if let binding = appState.tlsProfileBinding(id) {
                TLSProfileDetail(profile: binding)
                    // Profil değişince "Gelişmiş"in açık/kapalı hali o profile göre baştan kurulsun.
                    .id(id)
            } else {
                TrustStoreDetail()
            }
        case .trustStore, nil:
            TrustStoreDetail()
        }
    }

    // TODO(showcase): geçici kaçış kapısı. İleride host bazlı hale getirilecek
    // ya da tamamen kaldırılacak — bkz. TODO.md "Sertifika doğrulama anahtarı".
    private var validationSection: some View {
        let disabled = appState.certificateValidationDisabled
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(L10n.t("tls.disableValidation"), isOn: Binding(
                get: { disabled },
                set: { newValue in
                    // Kapatmak onay ister; geri açmak (güvenli yön) istemez.
                    if newValue { confirmingDisable = true } else { appState.certificateValidationDisabled = false }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            Label(
                disabled
                    ? L10n.t("tls.validation.off")
                    : L10n.t("tls.validation.on"),
                systemImage: disabled ? "exclamationmark.shield.fill" : "lock.shield"
            )
            .font(.secondaryText)
            .foregroundStyle(disabled ? Theme.down : .secondary)
        }
        .confirmationDialog(
            L10n.t("tls.disable.title"),
            isPresented: $confirmingDisable
        ) {
            Button(L10n.t("tls.disable.confirm"), role: .destructive) {
                appState.certificateValidationDisabled = true
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("tls.disable.message"))
        }
    }
}

// MARK: - Ortak parçalar

/// Dosya seçme paneli (CA ve istemci sertifikası seçimi ortak).
private func chooseFile(types: [String]) -> URL? {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
    return panel.runModal() == .OK ? panel.url : nil
}

private let caFileTypes = ["pem", "crt", "cer", "der"]

/// Ayrıntı bölümü başlığı.
private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).bold()
            content
        }
    }
}

/// Yardım metni: ikincil, satır kırılabilen.
private struct Hint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.secondaryText)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Uyarı satırı (sarı) ya da hata satırı (kırmızı).
private struct StatusLine: View {
    let text: String
    var isError = false
    var body: some View {
        Label(text, systemImage: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .font(.secondaryText)
            .foregroundStyle(isError ? Theme.down : Theme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Katlanır "Gelişmiş" bölümü. Kapalıyken içindeki ayar açıksa başlıkta
/// özeti görünür: gizli kalan bir gevşetme fark edilmeden kalmasın.
private struct AdvancedSection<Content: View>: View {
    @Binding var isExpanded: Bool
    let summary: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Başlık Button: gesture'a güvenilmiyor (docs/UI-KURALLARI.md §2).
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.tinyText.bold())
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(L10n.t("tls.advanced")).font(.subheadline).bold()
                    if let summary, !isExpanded {
                        Text(summary)
                            .font(.tinyText)
                            .foregroundStyle(Theme.warning)
                    }
                    Spacer()
                }
                .rowHitTarget(minHeight: 22)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) { content }
                    .padding(.leading, 16)
            }
        }
    }
}

// MARK: - Profil

private struct TLSProfileRow: View {
    let profile: TLSProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(profile.name).lineLimit(1)
            HStack(spacing: 4) {
                if profile.hasCA {
                    Label("CA", systemImage: "checkmark.seal")
                        .font(.tinyText).foregroundStyle(Theme.purple)
                }
                if profile.hasClientCertificate {
                    Label("mTLS", systemImage: "person.badge.key")
                        .font(.tinyText).foregroundStyle(Theme.up)
                }
                if !profile.invalidPatterns.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.tinyText).foregroundStyle(Theme.down)
                        .help(L10n.t("tls.invalidPattern"))
                }
                // Eski dosyalarda CA'sız sabitleme kalmış olabilir; listede de görünsün.
                if profile.appliesToNothing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.tinyText).foregroundStyle(Theme.warning)
                        .help(L10n.t("tls.noPattern"))
                }
                if profile.pinsWithoutCA {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.tinyText).foregroundStyle(Theme.warning)
                        .help(L10n.t("tls.pinWithoutCA"))
                }
            }
        }
    }
}

private struct TLSProfileDetail: View {
    @Binding var profile: TLSProfile
    @State private var showsAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField(L10n.t("tls.profileName"), text: $profile.name)
                    .inputLimit(.name)
                    .textFieldStyle(.input)
                    .font(.headline)

                DetailSection(title: L10n.t("tls.hosts")) {
                    Hint(text: L10n.t("tls.hosts.help"))
                    KeyValueFreeList(items: $profile.hostPatterns, placeholder: L10n.t("tls.host.placeholder"))
                    if !profile.invalidPatterns.isEmpty {
                        StatusLine(text: L10n.t("tls.invalidPatterns", profile.invalidPatterns.joined(separator: ", ")), isError: true)
                    }
                    if profile.appliesToNothing {
                        StatusLine(text: L10n.t("tls.noValidPattern"))
                    }
                }

                DetailSection(title: L10n.t("tls.companyCA")) {
                    FilePathField(path: $profile.caCertificatePath, prompt: L10n.t("tls.caFile"), types: caFileTypes)
                    Hint(text: L10n.t("tls.companyCA.help"))
                }

                DetailSection(title: L10n.t("tls.clientCertificate")) {
                    FilePathField(path: $profile.clientCertificatePath, prompt: L10n.t("tls.clientIdentity"), types: ["p12", "pfx"])
                    HStack {
                        Text(L10n.t("auth.password")).font(.secondaryText).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        TemplateTextField(placeholder: L10n.t("tls.password.placeholder"), text: $profile.clientCertificatePassword, limit: .credential)
                    }
                    Hint(text: L10n.t("tls.clientCertificate.help"))
                }

                AdvancedSection(isExpanded: $showsAdvanced, summary: advancedSummary) {
                    // CA yokken kapalı: sabitlenecek çıpa olmadan kutu bir
                    // güvenlik özelliği vaat edip veremiyordu.
                    Toggle(L10n.t("tls.pin"), isOn: $profile.pinToCA)
                        .toggleStyle(.checkbox)
                        .disabled(!profile.hasCA)
                        .help(profile.hasCA ? "" : L10n.t("tls.pin.needsCA"))
                    if profile.pinsWithoutCA {
                        StatusLine(text: L10n.t("tls.pin.notApplied"))
                    }
                    Hint(text: !profile.hasCA
                         ? L10n.t("tls.pin.needsCA.sentence")
                         : (profile.pinToCA
                            ? L10n.t("tls.pin.on")
                            : L10n.t("tls.pin.off")))

                    Divider().padding(.vertical, 2)

                    Toggle(L10n.t("tls.longValidity"), isOn: $profile.allowLongValidity)
                        .toggleStyle(.checkbox)
                    Hint(text: profile.allowLongValidity
                         ? L10n.t("tls.longValidity.on")
                         : L10n.t("tls.longValidity.off"))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Açık bir gevşetme ya da sorun varsa bölüm açık gelsin.
        .onAppear { showsAdvanced = profile.pinToCA || profile.allowLongValidity }
    }

    private var advancedSummary: String? {
        if profile.pinsWithoutCA { return L10n.t("tls.summary.pinNotApplied") }
        var parts: [String] = []
        if profile.pinToCA { parts.append(L10n.t("tls.summary.pinOn")) }
        if profile.allowLongValidity { parts.append(L10n.t("tls.summary.longValidity")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Dosya yolu alanı: elle yazılabilir, "Seç…" ile seçilir, ⓧ ile temizlenir.
private struct FilePathField: View {
    @Binding var path: String
    let prompt: String
    let types: [String]

    var body: some View {
        HStack {
            TextField(prompt, text: $path)
                .inputLimit(.path)
                .textFieldStyle(.input)
                .font(.secondaryMono)
            Button(L10n.t("common.choose")) {
                if let url = chooseFile(types: types) { path = url.path }
            }
            if !path.isEmpty {
                Button {
                    path = ""
                } label: {
                    Image(systemName: "xmark.circle")
                        .iconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(L10n.t("common.clear"))
                .accessibilityLabel(L10n.t("common.clear"))
            }
        }
    }
}

/// Basit metin listesi düzenleyici (host kalıpları için).
private struct KeyValueFreeList: View {
    @Binding var items: [String]
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items.indices, id: \.self) { index in
                HStack {
                    TextField(placeholder, text: Binding(
                        get: { index < items.count ? items[index] : "" },
                        set: { if index < items.count { items[index] = $0 } }
                    ))
                    .textFieldStyle(.input)
                    .font(.system(.body, design: .monospaced))
                    .inputLimit(.short)
                    Button {
                        if index < items.count { items.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                            .iconHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L10n.t("tls.deletePattern"))
                    .accessibilityLabel(L10n.t("tls.deletePattern"))
                }
            }
            Button {
                items.append("")
            } label: {
                Label(L10n.t("tls.addHost"), systemImage: "plus").font(.secondaryText)
                    .rowHitTarget(minHeight: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Güven deposu

/// Kurum güven deposu: cacerts dizinine bırakılan CA'lar.
/// Buraya dosya bırakmak güven genişletmektir, bu yüzden her sertifika
/// burada listelenir — kullanıcı neye güvendiğini görebilmeli.
private struct TrustStoreDetail: View {
    @Environment(AppState.self) private var appState
    @State private var notice: TrustStoreNotice?
    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("tls.trustStore")).font(.headline)
                    Hint(text: L10n.t("tls.trustStore.help"))
                }
                Spacer()
                Button {
                    appState.reloadTrustStore()
                    notice = TrustStoreNotice(text: L10n.plural("tls.loaded", count: appState.trustStore.entries.count), isError: false)
                } label: {
                    Image(systemName: "arrow.clockwise").iconHitTarget()
                }
                .buttonStyle(.borderless)
                .help(L10n.t("tls.reload.help"))
                .accessibilityLabel(L10n.t("common.refresh"))
                Button {
                    if let url = chooseFile(types: caFileTypes) {
                        notice = appState.installCertificate(from: url)
                    }
                } label: {
                    Label(L10n.t("tls.addCertificate"), systemImage: "plus")
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }

            if let notice {
                Label(notice.text, systemImage: notice.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.secondaryText)
                    .foregroundStyle(notice.isError ? Theme.down : Theme.up)
            }
            ForEach(appState.trustStore.problems, id: \.self) { problem in
                StatusLine(text: problem, isError: true)
            }

            certificateList

            AdvancedSection(isExpanded: $showsAdvanced, summary: appState.trustStoreAllowsLongValidity ? L10n.t("tls.summary.longValidity") : nil) {
                @Bindable var state = appState
                Toggle(L10n.t("tls.store.longValidity"), isOn: $state.trustStoreAllowsLongValidity)
                    .toggleStyle(.checkbox)
                Hint(text: appState.trustStoreAllowsLongValidity
                     ? L10n.t("tls.store.longValidity.on")
                     : L10n.t("tls.store.longValidity.off"))

                Divider().padding(.vertical, 2)

                Text(L10n.t("tls.directories")).font(.secondaryText).bold()
                pathRow(L10n.t("tls.dir.machine"), TrustStore.machineDirectory.path,
                        hint: L10n.t("tls.dir.machine.hint"))
                HStack(alignment: .top) {
                    pathRow(L10n.t("tls.dir.user"), TrustStore.userDirectory.path,
                            hint: L10n.t("tls.dir.user.hint"))
                    Spacer()
                    Button {
                        try? TrustStore.prepareUserDirectory()
                        NSWorkspace.shared.open(TrustStore.userDirectory)
                    } label: {
                        Label(L10n.t("tls.openFolder"), systemImage: "folder")
                    }
                    .controlSize(.small)
                }
                if !TrustStore.environmentDirectories().isEmpty {
                    pathRow(TrustStore.environmentVariable,
                            TrustStore.environmentDirectories().map(\.path).joined(separator: ", "),
                            hint: L10n.t("tls.dir.env.hint"))
                }
            }
        }
        .padding(14)
        // Açık bir gevşetme varsa bölüm açık gelsin.
        .onAppear { showsAdvanced = appState.trustStoreAllowsLongValidity }
    }

    @ViewBuilder
    private var certificateList: some View {
        if appState.trustStore.entries.isEmpty {
            ContentUnavailableView(
                L10n.t("tls.store.empty.title"),
                systemImage: "shield",
                description: Text(L10n.t("tls.store.empty.message"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(appState.trustStore.entries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: entry.isExpired ? "xmark.seal.fill" : "checkmark.seal.fill")
                        .foregroundStyle(entry.isExpired ? Theme.down : Theme.up)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.subject)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(entry.source.title)
                                .font(.tinyText)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.purple.opacity(0.18))
                                .clipShape(Capsule())
                            Text(entry.fileName).font(.tinyText).foregroundStyle(.secondary)
                            if let expiry = entry.expiresAt {
                                Text(entry.isExpired
                                     ? L10n.t("tls.cert.expired", L10n.date(expiry, time: false))
                                     : "→ \(L10n.date(expiry, time: false))")
                                    .font(.tinyText)
                                    .foregroundStyle(entry.isExpired ? AnyShapeStyle(Theme.down) : AnyShapeStyle(.tertiary))
                            }
                            if entry.isCertificateAuthority == false {
                                Label(L10n.t("tls.cert.notCA"), systemImage: "exclamationmark.triangle.fill")
                                    .font(.tinyText).foregroundStyle(Theme.warning)
                                    .help(L10n.t("tls.cert.notCA.help"))
                            }
                        }
                    }
                    Spacer()
                    if entry.source == .user {
                        Button {
                            notice = appState.removeCertificate(path: entry.path)
                        } label: {
                            Image(systemName: "trash")
                                .iconHitTarget()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L10n.t("tls.cert.remove"))
                        .accessibilityLabel(L10n.t("tls.cert.remove"))
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
        }
    }

    private func pathRow(_ title: String, _ path: String, hint: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.secondaryText).bold()
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(path)
                    .font(.secondaryMono)
                    .textSelection(.enabled)
                Text(hint).font(.tinyText).foregroundStyle(.tertiary)
            }
        }
    }
}
