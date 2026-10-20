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
                        Text(L10n.t("token.field")).gridColumnAlignment(.trailing)
                        TextField(TokenOutput.defaultResponseField, text: output.responseField)
                            .inputLimit(.short)
                            .textFieldStyle(.input)
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("")
                        Text(L10n.t("token.field.help"))
                            .font(.secondaryText).foregroundStyle(.secondary)
                    }
                    GridRow {
                        Text(L10n.t("token.variable"))
                        HStack(spacing: 2) {
                            Text("{{").foregroundStyle(.secondary)
                            TextField(TokenOutput.defaultVariableName, text: output.variableName)
                                .inputLimit(.short)
                                .textFieldStyle(.input)
                                .font(.system(.body, design: .monospaced))
                            Text("}}").foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Environment")
                        Picker("", selection: output.environmentID) {
                            Text(L10n.t("token.allEnvironments")).tag(UUID?.none)
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
                        .font(.secondaryText)
                        .foregroundStyle(Theme.down)
                }
                ForEach(shadowed, id: \.self) { name in
                    Label(
                        L10n.t("token.shadowed", name),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.secondaryText)
                    .foregroundStyle(Theme.warning)
                }

                Text(L10n.t("token.usage", current.trimmedVariableName))
                    .font(.secondaryText)
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
                    Text(L10n.t("token.fetching")).font(.secondaryText)
                }
            case .valid(let expiresAt):
                Label(
                    expiresAt.map { L10n.t("token.validUntil", $0.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(L10n.language.locale))) }
                        ?? L10n.t("token.fetchedNoExpiry"),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.secondaryText)
                .foregroundStyle(Theme.up)
            case .failed(let message):
                Label(L10n.t("token.failed", message), systemImage: "xmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .textSelection(.enabled)
            case nil:
                Label(L10n.t("token.notFetched", source.variable),
                      systemImage: "circle.dashed")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }
        } else if !output.applies(to: environment) {
            Label(L10n.t("token.inactive"), systemImage: "moon.zzz")
                .font(.secondaryText)
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
            Text("TOKEN FACTORY").font(.secondaryText.weight(.bold))
            Text(L10n.t("token.banner", variable))
                .font(.secondaryText)
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

/// Alttan çıkan, kendiliğinden kaybolan hata bildirimi (token alınamadı).
/// Panel zemininde kırmızı kenar + hata ikonu: hata belli, metin okunur
/// (eskiden tam kırmızı blok ve başlıksız ham hata metniydi).
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
            MessageIcon(kind: .error)
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.title)
                    .fontWeight(.semibold)
                Text(alert.message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let variables = appState.tokenBlockedSends[alert.requestID] {
                    SendWithoutTokenButton(requestID: alert.requestID, variables: variables)
                        .padding(.top, 2)
                }
            }
            .font(.callout)
            Spacer(minLength: 0)
            Button {
                appState.dismissTokenAlert(alert.id)
            } label: {
                Image(systemName: "xmark").iconHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.t("token.alert.dismiss"))
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                .fill(Theme.down)
                .frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(radius: 6, y: 2)
        .padding(14)
        .task(id: alert.id) {
            NSAccessibility.post(
                element: NSApp.mainWindow as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: "\(alert.title). \(alert.message)", .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
            try? await Task.sleep(for: .seconds(Self.visibleSeconds))
            withAnimation(.easeOut(duration: 0.2)) { appState.dismissTokenAlert(alert.id) }
        }
    }
}

/// Token kullanan istek hata aldığında durum kodunun hemen altında çıkan öneri.
///
/// İlk hatada "token'ı yenile ve tekrar gönder"; yenilenmiş token'la yine hata
/// gelirse sorun büyük ihtimalle token'ın içeriğinde (yanlış müşteri, scope,
/// environment) — o zaman ilgili Token Factory isteğine yönlendirir.
struct TokenRetryBanner: View {
    @Environment(AppState.self) private var appState
    let requestID: UUID
    let advice: TokenRetryAdvice

    var body: some View {
        let names = advice.variables.map { "{{\($0)}}" }.joined(separator: ", ")
        // İkisi de uyarı: hata durum kodunda zaten görünüyor, bu şerit
        // yönlendirme (eskiden ikinci hal kırmızıydı, arıza gibi okunuyordu).
        switch advice {
        case .offerRefresh(let status, _):
            MessageBanner(
                kind: .warning,
                title: L10n.t("token.retry.title", String(status)),
                message: L10n.t("token.retry.message", names)
            ) {
                Button(L10n.t("token.retry.action")) {
                    appState.refreshTokensAndResend(requestID)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                .controlSize(.small)
            }
        case .checkTokenContent(let status, let variables):
            MessageBanner(
                kind: .warning,
                title: L10n.t("token.content.title", String(status)),
                message: L10n.t("token.content.message")
            ) {
                if let first = variables.first {
                    Button(L10n.t("token.content.action")) {
                        appState.openTokenRequest(producing: first)
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .controlSize(.small)
                }
            }
        }
    }
}

/// Token alınamadığında isteği bilerek token'sız göndermek.
///
/// Varsayılan "gönderme" — bu düğme kullanıcının açık kararı. Değişken
/// environment'taki aynı adlı değere, yoksa boşa bağlanır; ne olacağı
/// düğmenin ipucunda yazar.
struct SendWithoutTokenButton: View {
    @Environment(AppState.self) private var appState
    let requestID: UUID
    let variables: [String]

    var body: some View {
        let names = variables.map { "{{\($0)}}" }.joined(separator: ", ")
        Button(L10n.t("token.sendWithout")) {
            appState.sendWithoutTokens(requestID)
        }
        .controlSize(.small)
        .help(L10n.t("token.sendWithout.help", names))
    }
}
