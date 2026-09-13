import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BoltDockCore

/// Host bazlı TLS ayarları: kurum CA'sı ve istemci sertifikası (mTLS).
struct TLSProfilesView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TLS Profilleri")
                .font(.title2).bold()
            Text("Kurum içi CA ile imzalı API'ler ve istemci sertifikası (mTLS) isteyen sunucular için. Ayarlar yalnızca eşleşen host'lara uygulanır.")
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
        .frame(width: 720, height: 540)
        .onAppear {
            selectedID = appState.workspace.tlsProfiles.first?.id
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
                    Toggle("Yalnızca bu CA kabul edilsin (sabitleme)", isOn: $profile.pinToCA)
                        .toggleStyle(.checkbox)
                    Text(profile.pinToCA
                         ? "Bu host için sistem kök sertifikaları geçersiz sayılır. Daha sıkı ama CA değişirse istekler durur."
                         : "Sistem kökleri geçerli kalır; kurum CA'sı bunlara EK olarak kabul edilir.")
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
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            Button {
                items.append("")
            } label: {
                Label("Host Ekle", systemImage: "plus").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}
