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
                Text("Hangi CA'lara güvenileceği ve hangi host'a hangi sertifikanın sunulacağı.")
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
                Button("Kapat") { dismiss() }
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
                Section("Tüm host'lar") {
                    HStack {
                        Label("Güven Deposu", systemImage: "shield")
                        Spacer()
                        Text("\(appState.trustStore.entries.count)")
                            .font(.tinyText.monospacedDigit())
                            .foregroundStyle(appState.trustStore.problems.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.down))
                            .help(appState.trustStore.problems.isEmpty ? "Sertifika sayısı" : "Okunamayan dosya var")
                    }
                    .tag(Selection.trustStore)
                }
                Section("Host Profilleri") {
                    ForEach(appState.workspace.tlsProfiles) { profile in
                        TLSProfileRow(profile: profile)
                            .tag(Selection.profile(profile.id))
                    }
                    if appState.workspace.tlsProfiles.isEmpty {
                        Text("Henüz yok. + ile ekle.")
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
                .help("Yeni host profili")
                .accessibilityLabel("Yeni host profili")
                Button {
                    deleteSelectedProfile()
                } label: {
                    Image(systemName: "minus").iconHitTarget()
                }
                .disabled(selectedProfileID == nil)
                .help("Seçili profili sil")
                .accessibilityLabel("Seçili profili sil")
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
            Toggle("Sertifika doğrulamasını kapat (tüm istekler)", isOn: Binding(
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
                    ? "Doğrulama KAPALI: sunucu sertifikası hiç kontrol edilmiyor. Uygulama yeniden açılınca kendiliğinden açılır."
                    : "Doğrulama açık. Eklenen CA'lar sistem köklerine EK olarak güvenilir.",
                systemImage: disabled ? "exclamationmark.shield.fill" : "lock.shield"
            )
            .font(.secondaryText)
            .foregroundStyle(disabled ? Theme.down : .secondary)
        }
        .confirmationDialog(
            "Sertifika doğrulaması kapatılsın mı?",
            isPresented: $confirmingDisable
        ) {
            Button("Doğrulamayı Kapat", role: .destructive) {
                appState.certificateValidationDisabled = true
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Tüm isteklerde sunucu sertifikası kontrol edilmez; araya giren biri bağlantıyı devralabilir. Yalnızca sertifikası yanlış yapılandırılmış iç ortamlar için kullan. Uygulama yeniden açılınca doğrulama kendiliğinden açılır.")
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
                    Text("Gelişmiş").font(.subheadline).bold()
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
                        .help("Geçersiz host kalıbı var")
                }
                // Eski dosyalarda CA'sız sabitleme kalmış olabilir; listede de görünsün.
                if profile.appliesToNothing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.tinyText).foregroundStyle(Theme.warning)
                        .help("Host kalıbı yok; profil hiçbir isteğe uygulanmıyor")
                }
                if profile.pinsWithoutCA {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.tinyText).foregroundStyle(Theme.warning)
                        .help("Sabitleme işaretli ama CA seçilmemiş; uygulanmıyor")
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
                TextField("Profil adı", text: $profile.name)
                    .inputLimit(.name)
                    .textFieldStyle(.input)
                    .font(.headline)

                DetailSection(title: "Host'lar") {
                    Hint(text: "Satır başına bir kalıp: api.firma.com ya da *.firma.com. Tek başına * olmaz.")
                    KeyValueFreeList(items: $profile.hostPatterns, placeholder: "api.firma.com")
                    if !profile.invalidPatterns.isEmpty {
                        StatusLine(text: "Geçersiz kalıp: \(profile.invalidPatterns.joined(separator: ", "))", isError: true)
                    }
                    if profile.appliesToNothing {
                        StatusLine(text: "Geçerli kalıp yok; profil hiçbir isteğe uygulanmıyor.")
                    }
                }

                DetailSection(title: "Kurum CA'sı") {
                    FilePathField(path: $profile.caCertificatePath, prompt: "CA sertifikası (.pem / .crt / .der)", types: caFileTypes)
                    Hint(text: "Sistem kökleri geçerli kalır; bu CA onlara EK olarak güvenilir.")
                }

                DetailSection(title: "İstemci sertifikası (mTLS)") {
                    FilePathField(path: $profile.clientCertificatePath, prompt: "İstemci kimliği (.p12 / .pfx)", types: ["p12", "pfx"])
                    HStack {
                        Text("Parola").font(.secondaryText).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        TemplateTextField(placeholder: "{{secret:isim}} önerilir", text: $profile.clientCertificatePassword, limit: .credential)
                    }
                    Hint(text: "Dosya kopyalanmaz, yalnızca yolu tutulur; özel anahtar istek anında belleğe alınır. Parolayı Secrets'a ekleyip referans ver.")
                }

                AdvancedSection(isExpanded: $showsAdvanced, summary: advancedSummary) {
                    // CA yokken kapalı: sabitlenecek çıpa olmadan kutu bir
                    // güvenlik özelliği vaat edip veremiyordu.
                    Toggle("Yalnızca bu CA kabul edilsin (sabitleme)", isOn: $profile.pinToCA)
                        .toggleStyle(.checkbox)
                        .disabled(!profile.hasCA)
                        .help(profile.hasCA ? "" : "Önce bir CA sertifikası seç")
                    if profile.pinsWithoutCA {
                        StatusLine(text: "Sabitleme uygulanmıyor: CA seçilmemiş.")
                    }
                    Hint(text: !profile.hasCA
                         ? "Sabitleme için önce bir CA sertifikası seç."
                         : (profile.pinToCA
                            ? "Bu host için sistem kökleri ve güven deposu geçersiz sayılır. Daha sıkı ama CA değişirse istekler durur."
                            : "Kapalıyken sistem kökleri de geçerli."))

                    Divider().padding(.vertical, 2)

                    Toggle("Uzun geçerlilik süresini kabul et (ömür üst sınırı aranmasın)", isOn: $profile.allowLongValidity)
                        .toggleStyle(.checkbox)
                    Hint(text: profile.allowLongValidity
                         ? "Yalnızca ömür üst sınırı gevşer. Zincir, imza, tarih ve host adı kontrolleri AYNEN zorunlu."
                         : "Apple sunucu sertifikalarına ömür sınırı koyuyor: kurum CA'larında 825, public CA'larda 398 gün. CA güven deposundaysa bunu Güven Deposu'nda host yazmadan açmak daha kolay.")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Açık bir gevşetme ya da sorun varsa bölüm açık gelsin.
        .onAppear { showsAdvanced = profile.pinToCA || profile.allowLongValidity }
    }

    private var advancedSummary: String? {
        if profile.pinsWithoutCA { return "sabitleme uygulanmıyor" }
        var parts: [String] = []
        if profile.pinToCA { parts.append("sabitleme açık") }
        if profile.allowLongValidity { parts.append("ömür sınırı muaf") }
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
            Button("Seç…") {
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
                .help("Temizle")
                .accessibilityLabel("Temizle")
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
                    .help("Kalıbı sil")
                    .accessibilityLabel("Kalıbı sil")
                }
            }
            Button {
                items.append("")
            } label: {
                Label("Host Ekle", systemImage: "plus").font(.secondaryText)
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
                    Text("Güven Deposu").font(.headline)
                    Hint(text: "Buradaki CA'lar tüm host'larda EK güven çıpasıdır (Java'daki cacerts gibi).")
                }
                Spacer()
                Button {
                    appState.reloadTrustStore()
                    notice = TrustStoreNotice(text: "\(appState.trustStore.entries.count) sertifika yüklendi.", isError: false)
                } label: {
                    Image(systemName: "arrow.clockwise").iconHitTarget()
                }
                .buttonStyle(.borderless)
                .help("Dizinleri yeniden oku (dışarıdan dosya bırakıldıysa)")
                .accessibilityLabel("Yenile")
                Button {
                    if let url = chooseFile(types: caFileTypes) {
                        notice = appState.installCertificate(from: url)
                    }
                } label: {
                    Label("Sertifika Ekle…", systemImage: "plus")
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

            AdvancedSection(isExpanded: $showsAdvanced, summary: appState.trustStoreAllowsLongValidity ? "ömür sınırı muaf" : nil) {
                @Bindable var state = appState
                Toggle("Bu CA'larla imzalı sertifikalarda ömür üst sınırını uygulama (825 gün)", isOn: $state.trustStoreAllowsLongValidity)
                    .toggleStyle(.checkbox)
                Hint(text: appState.trustStoreAllowsLongValidity
                     ? "Yalnızca zinciri buradaki bir CA'ya çıkan sertifikalarda ömür sınırı aranmaz. Host adı, imza ve tarih kontrolleri AYNEN zorunlu; public sitelerde kural değişmez."
                     : "Apple, kurum CA'larıyla imzalı sertifikalarda 825 günden uzun ömrü reddeder. PKI'n 3-5 yıllık sertifika basıyorsa aç; kalıcı çözüm daha kısa ömürlü sertifika.")

                Divider().padding(.vertical, 2)

                Text("Dizinler").font(.secondaryText).bold()
                pathRow("Makine geneli", TrustStore.machineDirectory.path,
                        hint: "yönetici hakkı gerekir · MDM ile dağıtıma uygun")
                HStack(alignment: .top) {
                    pathRow("Kullanıcı", TrustStore.userDirectory.path,
                            hint: "\"Sertifika Ekle\" buraya kopyalar")
                    Spacer()
                    Button {
                        try? TrustStore.prepareUserDirectory()
                        NSWorkspace.shared.open(TrustStore.userDirectory)
                    } label: {
                        Label("Dizini Aç", systemImage: "folder")
                    }
                    .controlSize(.small)
                }
                if !TrustStore.environmentDirectories().isEmpty {
                    pathRow(TrustStore.environmentVariable,
                            TrustStore.environmentDirectories().map(\.path).joined(separator: ", "),
                            hint: "ortam değişkeniyle tanımlı")
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
                "Güven deposu boş",
                systemImage: "shield",
                description: Text("\"Sertifika Ekle\" ile ya da dizine dosya bırakarak kurum CA'sı ekle.")
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
                            Text(entry.source.rawValue)
                                .font(.tinyText)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.purple.opacity(0.18))
                                .clipShape(Capsule())
                            Text(entry.fileName).font(.tinyText).foregroundStyle(.secondary)
                            if let expiry = entry.expiresAt {
                                Text(entry.isExpired
                                     ? "SÜRESİ DOLDU \(expiry.formatted(date: .abbreviated, time: .omitted))"
                                     : "→ \(expiry.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.tinyText)
                                    .foregroundStyle(entry.isExpired ? AnyShapeStyle(Theme.down) : AnyShapeStyle(.tertiary))
                            }
                            if entry.isCertificateAuthority == false {
                                Label("CA değil", systemImage: "exclamationmark.triangle.fill")
                                    .font(.tinyText).foregroundStyle(Theme.warning)
                                    .help("Bu sertifika CA olmadığı için güven çıpası olarak kullanılamaz.")
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
                        .help("Güven deposundan kaldır")
                        .accessibilityLabel("Güven deposundan kaldır")
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
