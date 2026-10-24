import SwiftUI
import Dev2KitCore

/// Kayıtlı bir response örneği. İstek editörünün yerinde durur ama isteği
/// değiştirmez: adres salt okunur, gönder yerine "Dene" (istek editörüne
/// döner, hiçbir şey göndermez). Yanıt kısmı canlı yanıtla aynı görünüm
/// (`ResponseView`), örnek olduğu üstteki şeritte açıkça yazar.
struct ExampleDetailView: View {
    @Environment(AppState.self) private var appState
    let request: RequestModel
    let example: ResponseExample

    /// Biçimlendirilmiş hali; canlı yanıttaki gibi arka planda bir kez.
    @State private var display: AppState.ResponseDisplay?
    @State private var displayedExampleID: UUID?

    private var ref: AppState.ExampleRef {
        AppState.ExampleRef(requestID: request.id, exampleID: example.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            controlsRow
            banner
            Divider()
            if let display, displayedExampleID == example.id {
                ResponseView(exampleDisplay: display)
                    // Başka örneğe geçince sekme/arama durumu sıfırlansın.
                    .id(example.id)
            } else {
                ProgressView(L10n.t("example.preparing"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Yeniden adlandırma body'yi değiştirmez; gösterim yalnızca içerik
        // değişince yeniden hazırlanır.
        .task(id: DisplayKey(example)) {
            let data = example.responseData
            let prepared = await BackgroundWork.run { AppState.makeDisplay(data) }
            guard !Task.isCancelled else { return }
            display = prepared
            displayedExampleID = example.id
        }
    }

    private struct DisplayKey: Equatable {
        let id: UUID
        let statusCode: Int
        let headers: [ResponseExample.Header]
        let body: String

        init(_ example: ResponseExample) {
            id = example.id
            statusCode = example.statusCode
            headers = example.headers
            body = example.body
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            // Ad ve bağlı istek yan yana, sola yaslı; uzun ad kısalır (genişlik
            // içerikten istenmez, pencere asgari ölçüsü büyümesin).
            HStack(spacing: 8) {
                Text(ResponseExamples.badge)
                    .font(.secondaryMono)
                    .foregroundStyle(.secondary)
                Text(example.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(example.name)
                    .layoutPriority(1)
                Text(L10n.t("example.parent", request.name))
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                appState.exampleRenameTarget = ref
            } label: {
                Image(systemName: "pencil")
                    .iconHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.t("example.rename.title"))
            .accessibilityLabel(L10n.t("example.rename.title"))
            Button {
                appState.exampleDeleteTarget = ref
            } label: {
                Image(systemName: "trash")
                    .iconHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.t("example.delete.help"))
            .accessibilityLabel(L10n.t("example.delete"))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// İsteğin metodu ve adresi salt okunur; düzenleme isteğin kendi
    /// editöründe ("Dene").
    private var controlsRow: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(request.method.rawValue)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.color(for: request.method))
                    .frame(width: 56, alignment: .leading)
                    .padding(.leading, 10)
                Text(request.url.isEmpty ? " " : request.url)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 28)
            .inputChrome(isFocused: false)

            Button {
                appState.returnFromExample()
            } label: {
                Label(L10n.t("example.try"), systemImage: "arrow.uturn.backward")
                    .padding(.horizontal, 6)
                    .frame(height: 28)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            // Gönder'in kısayolu burada isteğe döner; gönderim yapmaz.
            .keyboardShortcut(KeyboardShortcut(.return, modifiers: .command), onlyIn: .apiClient)
            .help(L10n.t("example.try.help"))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var banner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            MessageIcon(kind: .info)
            Text(L10n.t("example.banner.title")).fontWeight(.semibold)
            Text(L10n.t("example.banner.detail", L10n.date(example.savedAt)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.secondaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MessageKind.info.background)
        .accessibilityElement(children: .combine)
    }
}
