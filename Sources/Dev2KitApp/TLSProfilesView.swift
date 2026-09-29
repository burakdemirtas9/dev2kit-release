import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Dev2KitCore

/// Host bazlı TLS ayarları: kurum CA'sı ve istemci sertifikası (mTLS).
struct TLSProfilesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var tab: Tab = .trustStore

    enum Tab: String, CaseIterable {
        case trustStore = "Güven Deposu"
        case profiles = "Host Profilleri"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TLS")
                .font(.title2).bold()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tab == .trustStore {
                TrustStoreSection()
            } else {
                profilesSection
            }

            HStack {
                Label(
                    "Sertifika doğrulaması hiçbir durumda atlanmaz. CA yalnızca EK güven çıpası olarak eklenir; \"doğrulamayı kapat\" seçeneği bilinçli olarak yoktur.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Kapat") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 580)
        .onAppear {
            selectedID = appState.workspace.tlsProfiles.first?.id
            appState.reloadTrustStore()
        }
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Belirli host'lar için ek CA veya istemci sertifikası (mTLS). Ayarlar yalnızca eşleşen host'lara uygulanır.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selectedID) {
                        ForEach(appState.workspace.tlsProfiles) { profile in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.name).lineLimit(1)
                                HStack(spacing: 4) {
                                    if profile.hasCA {
                                        Label("CA", systemImage: "checkmark.seal")
                                            .font(.caption2).foregroundStyle(Theme.purple)
                                    }
                                    if profile.hasClientCertificate {
                                        Label("mTLS", systemImage: "person.badge.key")
                                            .font(.caption2).foregroundStyle(Theme.up)
                                    }
                                    if !profile.invalidPatterns.isEmpty {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption2).foregroundStyle(Theme.down)
                                            .help("Geçersiz host kalıbı var")
                                    }
                                    // Eski dosyalarda CA'sız sabitleme kalmış
                                    // olabilir; listede de görünsün.
                                    if profile.pinsWithoutCA {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption2).foregroundStyle(Theme.warning)
                                            .help("Sabitleme işaretli ama CA seçilmemiş; uygulanmıyor")
                                    }
                                }
                            }
                            .tag(profile.id)
                        }
                    }
                    HStack {
                        Button {
                            selectedID = appState.addTLSProfile()
                        } label: { Image(systemName: "plus") }
                        Button {
                            if let selectedID {
                                appState.deleteTLSProfile(selectedID)
                                self.selectedID = appState.workspace.tlsProfiles.first?.id
                            }
                        } label: { Image(systemName: "minus") }
                        .disabled(selectedID == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(6)
                }
                .frame(width: 200)

                Divider()

                if let selectedID, let binding = appState.tlsProfileBinding(selectedID) {
                    TLSProfileDetail(profile: binding)
                } else {
                    ContentUnavailableView(
                        "Profil seç",
                        systemImage: "lock.shield",
                        description: Text("Soldan seç veya + ile yeni oluştur.")
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(minHeight: 360)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
    }
}

private struct TLSProfileDetail: View {
    @Binding var profile: TLSProfile

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Profil adı", text: $profile.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)

                section("Host'lar") {
                    Text("Her satıra bir kalıp. Tam ad (api.firma.com) veya tek seviye joker (*.firma.com). Tek başına * kabul edilmez.")
                        .font(.caption).foregroundStyle(.secondary)
                    KeyValueFreeList(items: $profile.hostPatterns, placeholder: "api.firma.com")
                    if !profile.invalidPatterns.isEmpty {
                        Label("Geçersiz kalıp: \(profile.invalidPatterns.joined(separator: ", "))",
                              systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(Theme.down)
                    }
                }

                section("Kurum CA'sı") {
                    filePicker(
                        path: $profile.caCertificatePath,
                        prompt: "CA sertifikası seç (.pem / .crt / .der)",
                        types: ["pem", "crt", "cer", "der"]
                    )
                    // CA yokken kapalı: sabitlenecek çıpa olmadan kutu bir
                    // güvenlik özelliği vaat edip veremiyordu.
                    Toggle("Yalnızca bu CA kabul edilsin (sabitleme)", isOn: $profile.pinToCA)
                        .toggleStyle(.checkbox)
                        .disabled(!profile.hasCA)
                        .help(profile.hasCA ? "" : "Önce bir CA sertifikası seç")
                    if profile.pinsWithoutCA {
                        Label("Sabitleme uygulanmıyor: sabitlenecek bir CA seçilmemiş.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                    Text(!profile.hasCA
                         ? "Sabitleme için önce bir CA sertifikası seç."
                         : (profile.pinToCA
                            ? "Bu host için sistem kök sertifikaları geçersiz sayılır — kurum güven deposu da dahil. Daha sıkı ama CA değişirse istekler durur."
                            : "Sistem kökleri geçerli kalır; kurum CA'sı bunlara EK olarak kabul edilir."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("İstemci Sertifikası (mTLS)") {
                    filePicker(
                        path: $profile.clientCertificatePath,
                        prompt: "İstemci kimliği seç (.p12 / .pfx)",
                        types: ["p12", "pfx"]
                    )
                    HStack {
                        Text("Parola").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        TemplateTextField(placeholder: "{{secret:isim}} önerilir", text: $profile.clientCertificatePassword)
                    }
                    Text("Sertifika dosyası kopyalanmaz, yalnızca yolu tutulur; özel anahtar istek anında belleğe alınır. Parolayı Secrets'a ekleyip referans vermen önerilir.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).bold()
            content()
        }
    }

    private func filePicker(path: Binding<String>, prompt: String, types: [String]) -> some View {
        HStack {
            TextField(prompt, text: path)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            Button("Seç…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
                if panel.runModal() == .OK, let url = panel.url {
                    path.wrappedValue = url.path
                }
            }
            if !path.wrappedValue.isEmpty {
                Button {
                    path.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle")
                        .iconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    Button {
                        if index < items.count { items.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                            .iconHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            Button {
                items.append("")
            } label: {
                Label("Host Ekle", systemImage: "plus").font(.caption)
                    .rowHitTarget(minHeight: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

/// Kurum güven deposu: cacerts dizinine bırakılan CA'lar.
/// Buraya dosya bırakmak güven genişletmektir, bu yüzden her sertifika
/// burada listelenir — kullanıcı neye güvendiğini görebilmeli.
struct TrustStoreSection: View {
    @Environment(AppState.self) private var appState
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Buradaki CA'lar tüm host'lara ek güven çıpası olarak uygulanır — Java'daki cacerts gibi. Güvenlik ekibi dosyaları doğrudan dizine bırakabilir.")
                .font(.caption)
                .foregroundStyle(.secondary)

            pathRow("Makine geneli", TrustStore.machineDirectory.path,
                    hint: "yönetici hakkı gerekir · MDM ile dağıtıma uygun")
            pathRow("Kullanıcı", TrustStore.userDirectory.path,
                    hint: "aşağıdaki düğmeyle eklenen sertifikalar buraya kopyalanır")
            if !TrustStore.environmentDirectories().isEmpty {
                pathRow(TrustStore.environmentVariable,
                        TrustStore.environmentDirectories().map(\.path).joined(separator: ", "),
                        hint: "ortam değişkeniyle tanımlı")
            }

            if appState.trustStore.entries.isEmpty {
                ContentUnavailableView(
                    "Güven deposu boş",
                    systemImage: "shield",
                    description: Text("Kurum CA'sı ekleyince buraya listelenir.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
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
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Theme.purple.opacity(0.18))
                                    .clipShape(Capsule())
                                Text(entry.fileName).font(.caption2).foregroundStyle(.secondary)
                                if let expiry = entry.expiresAt {
                                    Text(entry.isExpired
                                         ? "SÜRESİ DOLDU \(expiry.formatted(date: .abbreviated, time: .omitted))"
                                         : "→ \(expiry.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(entry.isExpired ? AnyShapeStyle(Theme.down) : AnyShapeStyle(.tertiary))
                                }
                                if entry.isCertificateAuthority == false {
                                    Label("CA değil", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2).foregroundStyle(Theme.warning)
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
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                .frame(minHeight: 180)
            }

            ForEach(appState.trustStore.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.down)
            }
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.allowedContentTypes = ["pem", "crt", "cer", "der"]
                        .compactMap { UTType(filenameExtension: $0) }
                    if panel.runModal() == .OK, let url = panel.url {
                        notice = appState.installCertificate(from: url)
                    }
                } label: {
                    Label("Sertifika Ekle…", systemImage: "plus")
                }
                Button {
                    try? TrustStore.prepareUserDirectory()
                    NSWorkspace.shared.open(TrustStore.userDirectory)
                } label: {
                    Label("Dizini Aç", systemImage: "folder")
                }
                Button {
                    appState.reloadTrustStore()
                    notice = "\(appState.trustStore.entries.count) sertifika yüklendi."
                } label: {
                    Label("Yenile", systemImage: "arrow.clockwise")
                }
                Spacer()
            }
        }
    }

    private func pathRow(_ title: String, _ path: String, hint: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.caption).bold()
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(hint).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
