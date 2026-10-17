import AppKit
import SwiftUI
import Dev2KitCore

/// Token Factory isteğinin "Token" sekmesi: yanıttaki hangi alan, hangi
/// değişkene, hangi environment'ta yazılsın; token'ın şu anki durumu ve
/// yapılandırmadaki sorunlar.
struct TokenOutputEditor: View {
    @Environment(AppState.self) private var appState
    @Binding var request: RequestModel

    private var output: Binding<TokenOutput> {
        Binding(
            get: { request.tokenOutput ?? TokenOutput() },
            set: { request.tokenOutput = $0 }
        )
    }

    var body: some View {
        let environment = appState.activeEnvironment
        let current = output.wrappedValue
        let source = appState.tokenSources(for: environment).first { $0.request.id == request.id }
        let problems = TokenFactory.problems(in: appState.workspace.tokenFactoryRequests, environment: environment)
            .filter { $0.involves(request: request.name) }
        let shadowed = source.map { TokenFactory.shadowedVariables(in: environment, sources: [$0]) } ?? []

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Yanıttaki alan").gridColumnAlignment(.trailing)
                        TextField(TokenOutput.defaultResponseField, text: output.responseField)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("")
                        Text("Yanıt gövdesindeki yol: access_token, data.token, items[0].jwt")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text("Değişken")
                        HStack(spacing: 2) {
                            Text("{{").foregroundStyle(.secondary)
                            TextField(TokenOutput.defaultVariableName, text: output.variableName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            Text("}}").foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Environment")
                        Picker("", selection: output.environmentID) {
                            Text("Tüm environment'lar").tag(UUID?.none)
                            ForEach(appState.workspace.environments) { env in
                                Text(env.name).tag(UUID?.some(env.id))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                Divider()
                status(source: source, environment: environment, output: current)

                ForEach(problems, id: \.self) { problem in
                    Label(problem.description, systemImage: "exclamationmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.down)
                }
                ForEach(shadowed, id: \.self) { name in
                    Label(
                        "Aktif environment'ta \"\(name)\" adlı bir değişken zaten var. İsteklerde onun yerine bu token kullanılır.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                }

                Text("Kullanım: isteklerde {{\(current.trimmedVariableName)}} yaz, ör. Authorization: Bearer {{\(current.trimmedVariableName)}}. Token yalnızca bellekte tutulur; JWT ise süresinin bitmesine 10 sn kala kendiliğinden yenilenir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    @ViewBuilder
    private func status(source: TokenFactory.Source?, environment: EnvironmentModel?, output: TokenOutput) -> some View {
        if let source {
            switch appState.tokenState(source, environment: environment) {
            case .fetching:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Token alınıyor…").font(.caption)
                }
            case .valid(let expiresAt):
                Label(
                    expiresAt.map { "Token geçerli, \($0.formatted(date: .omitted, time: .standard))'e kadar." }
                        ?? "Token alındı (süresi bilinmiyor; hata alınırsa yenilenir).",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(Theme.up)
            case .failed(let message):
                Label("Token alınamadı: \(message)", systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.down)
                    .textSelection(.enabled)
            case nil:
                Label("Henüz token alınmadı. Bu isteği gönder ya da {{\(source.variable)}} kullanan bir istek gönder.",
                      systemImage: "circle.dashed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if !output.applies(to: environment) {
            Label("Bu token isteği aktif environment'ta etkin değil.", systemImage: "moon.zzz")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Token Factory isteğinin üstündeki şerit: kullanıcı normal bir REST
/// isteğinde değil, token üreten bir istekte olduğunu bilmeli.
struct TokenFactoryBanner: View {
    let variable: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.viewfinder")
            Text("TOKEN FACTORY").font(.caption.weight(.bold))
            Text("Bu istek {{\(variable)}} değişkenini üretir. Gönderdiğinde token güncellenir.")
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Theme.purple)
        .accessibilityElement(children: .combine)
    }
}

/// Alttan çıkan, kendiliğinden kaybolan kırmızı uyarı.
///
/// Kendiliğinden kaybolduğu için içerik ayrıca yanıt panelinde de kalır
/// (istek gönderilmedi hatası); burası dikkat çekmek için. VoiceOver'a da
/// duyurulur — görsel bir uyarı sessizce kaybolup ekran okuyucuda hiç
/// duyulmamalı.
struct TokenAlertToast: View {
    @Environment(AppState.self) private var appState
    let alert: AppState.TokenAlert

    static let visibleSeconds: Double = 6

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
            Text(alert.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                appState.dismissTokenAlert(alert.id)
            } label: {
                Image(systemName: "xmark").iconHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Uyarıyı kapat")
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(maxWidth: 560)
        .background(Theme.down, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 6, y: 2)
        .padding(14)
        .task(id: alert.id) {
            NSAccessibility.post(
                element: NSApp.mainWindow as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: alert.message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
            try? await Task.sleep(for: .seconds(Self.visibleSeconds))
            withAnimation(.easeOut(duration: 0.2)) { appState.dismissTokenAlert(alert.id) }
        }
    }
}
