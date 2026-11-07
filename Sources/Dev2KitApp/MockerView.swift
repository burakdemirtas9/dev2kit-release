import AppKit
import SwiftUI
import Dev2KitCore

/// Mocker modu (2026-11-07): solda endpoint listesi, sağda tanım ya da gelen
/// istekler. Kurallar Core'da (`MockRouter`, `MockValidator`, `MockServer`);
/// burası yalnızca gösterir ve düzenler.
struct MockerView: View {
    @Environment(MockerState.self) private var mocker
    var sidebarWidth: CGFloat = SidebarSizing.baseMinimum

    var body: some View {
        @Bindable var state = mocker
        HStack(spacing: 0) {
            MockerSidebar()
                .frame(width: sidebarWidth)
            Divider()
            VStack(spacing: 0) {
                MockerHeaderBar()
                Divider()
                if case .failed(let message) = mocker.status {
                    MockerBanner(message: message, isError: true)
                    Divider()
                }
                if let notice = mocker.autoStopNotice {
                    HStack {
                        Label(notice, systemImage: "moon.zzz")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            mocker.dismissAutoStopNotice()
                        } label: {
                            Image(systemName: "xmark").iconHitTarget()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(L10n.t("mocker.autoStop.dismiss"))
                        .accessibilityLabel(L10n.t("mocker.autoStop.dismiss"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    Divider()
                }
                if let error = mocker.saveError {
                    MockerBanner(message: L10n.t("mocker.saveFailed", error), isError: true)
                    Divider()
                }
                switch mocker.pane {
                case .definitions:
                    if let id = mocker.selectedEndpointID, mocker.selectedEndpoint != nil {
                        MockEndpointEditor(id: id)
                            .id(id)
                    } else {
                        MockerEmptyState()
                    }
                case .requests:
                    MockRequestLogView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.editorBackground)
        }
        .alert(L10n.t("mocker.loadCorrupt.title"), isPresented: Binding(
            get: { mocker.loadNotice != nil },
            set: { if !$0 { state.loadNotice = nil } }
        )) {
            Button(L10n.t("common.ok")) { state.loadNotice = nil }
        } message: {
            Text(mocker.loadNotice ?? "")
        }
    }
}

// MARK: - Üst çubuk

private struct MockerHeaderBar: View {
    @Environment(MockerState.self) private var mocker

    var body: some View {
        @Bindable var state = mocker
        HStack(spacing: 12) {
            Picker(L10n.t("mocker.pane"), selection: $state.pane) {
                Text(L10n.t("mocker.pane.definitions")).tag(MockerState.Pane.definitions)
                Text(mocker.log.isEmpty
                     ? L10n.t("mocker.pane.requests")
                     : L10n.t("mocker.pane.requestsCount", L10n.number(mocker.log.count)))
                    .tag(MockerState.Pane.requests)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
            status
            if mocker.hasUnappliedChanges {
                Button(L10n.t("mocker.apply")) { mocker.applyChanges() }
                    .buttonStyle(.borderedProminent)
                    .help(L10n.t("mocker.apply.help"))
            }
            if mocker.isRunning {
                Button {
                    Task { await mocker.stop() }
                } label: {
                    Label(L10n.t("mocker.stop"), systemImage: "stop.fill")
                }
                .help(L10n.t("mocker.stop.help"))
            } else {
                Button {
                    Task { await mocker.start() }
                } label: {
                    Label(L10n.t("mocker.start"), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(mocker.status == .starting)
                .help(L10n.t("mocker.start.help"))
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    @ViewBuilder
    private var status: some View {
        switch mocker.status {
        case .running:
            HStack(spacing: 6) {
                Circle().fill(Theme.up).frame(width: 7, height: 7)
                Text(mocker.address ?? "")
                    .font(.secondaryMono)
                    .textSelection(.enabled)
                CopyButton(text: mocker.address ?? "", help: L10n.t("mocker.copyAddress"))
            }
            .help(L10n.t("mocker.local.help"))
        case .starting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("mocker.status.starting")).foregroundStyle(.secondary)
            }
        case .stopped, .failed:
            Text(L10n.t("mocker.status.stopped"))
                .font(.secondaryText)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MockerBanner: View {
    let message: String
    let isError: Bool

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(isError ? Theme.down : Theme.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .textSelection(.enabled)
    }
}

private struct MockerEmptyState: View {
    @Environment(MockerState.self) private var mocker

    var body: some View {
        ContentUnavailableView {
            Label(L10n.t("mocker.empty.title"), systemImage: "server.rack")
        } description: {
            Text(L10n.t("mocker.empty.detail"))
        } actions: {
            Button(L10n.t("mocker.addEndpoint")) { mocker.addEndpoint() }
                .disabled(!mocker.canAddEndpoint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Kenar çubuğu

private struct MockerSidebar: View {
    @Environment(MockerState.self) private var mocker

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(L10n.t("mocker.endpoints").uppercased())
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    mocker.addEndpoint()
                } label: {
                    Image(systemName: "plus").iconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!mocker.canAddEndpoint)
                .help(mocker.canAddEndpoint
                      ? L10n.t("mocker.addEndpoint.help")
                      : L10n.t("mocker.addEndpoint.limit", L10n.number(MockerLimits.maxEndpoints)))
                .accessibilityLabel(L10n.t("mocker.addEndpoint"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 36)
            Divider()
            List(selection: Binding(
                get: { mocker.pane == .definitions ? mocker.selectedEndpointID : nil },
                set: { mocker.select(endpointID: $0) }
            )) {
                ForEach(mocker.endpoints) { endpoint in
                    MockEndpointRow(endpoint: endpoint, issues: mocker.issues(for: endpoint.id))
                        .tag(endpoint.id)
                        .contextMenu {
                            Button(L10n.t("mocker.duplicate")) { mocker.duplicateEndpoint(endpoint.id) }
                                .disabled(!mocker.canAddEndpoint)
                            Button(L10n.t("mocker.moveUp")) { mocker.moveEndpoint(endpoint.id, by: -1) }
                            Button(L10n.t("mocker.moveDown")) { mocker.moveEndpoint(endpoint.id, by: 1) }
                            Divider()
                            Button(L10n.t("mocker.delete"), role: .destructive) { mocker.deleteEndpoint(endpoint.id) }
                        }
                }
            }
            .listStyle(.sidebar)
            .environment(\.sidebarRowSize, .small)
            Divider()
            statusBadge
        }
    }

    /// Sunucu durumu her zaman görünür (TASARIM §1.3): adres ya da "durdu".
    private var statusBadge: some View {
        HStack(spacing: 6) {
            Text(mocker.port.map { "localhost:\($0)" } ?? L10n.t("mocker.badge.stopped"))
                .font(.secondaryMono)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Circle().fill(mocker.isRunning ? Theme.up : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .help(L10n.t("mocker.local.help"))
        .accessibilityElement(children: .combine)
    }
}

private struct MockEndpointRow: View {
    let endpoint: MockEndpoint
    let issues: [MockIssue]

    var body: some View {
        HStack(spacing: 6) {
            Text(endpoint.method.title)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(MockerColors.method(endpoint.method))
                .frame(width: 48, alignment: .leading)
            Text(endpoint.path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if !endpoint.scenarios.isEmpty {
                Text(L10n.number(endpoint.scenarios.count))
                    .font(.tinyMono)
                    .foregroundStyle(.secondary)
                    .help(L10n.t("mocker.scenarioCount.help", L10n.number(endpoint.scenarios.count)))
            }
            if let worst = MockerColors.worst(issues) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(worst == .error ? Theme.down : Theme.warning)
                    .help(issues.map(\.message).joined(separator: "\n"))
            }
        }
    }
}

/// Seçici metinleri. Anahtarlar açıkça yazılır: yerelleştirme testi koddaki
/// her anahtarın tabloda olduğunu böyle doğrulayabiliyor.
enum MockerText {
    static func source(_ source: MockCondition.Source) -> String {
        switch source {
        case .header: return L10n.t("mocker.source.header")
        case .query: return L10n.t("mocker.source.query")
        case .jsonBody: return L10n.t("mocker.source.jsonBody")
        case .bodyText: return L10n.t("mocker.source.bodyText")
        case .pathParameter: return L10n.t("mocker.source.pathParameter")
        }
    }

    static func placeholder(_ source: MockCondition.Source) -> String {
        switch source {
        case .header: return L10n.t("mocker.source.header.placeholder")
        case .query: return L10n.t("mocker.source.query.placeholder")
        case .jsonBody: return L10n.t("mocker.source.jsonBody.placeholder")
        case .pathParameter: return L10n.t("mocker.source.pathParameter.placeholder")
        case .bodyText: return ""
        }
    }

    static func help(_ source: MockCondition.Source) -> String {
        switch source {
        case .header: return L10n.t("mocker.source.header.help")
        case .query: return L10n.t("mocker.source.query.help")
        case .jsonBody: return L10n.t("mocker.source.jsonBody.help")
        case .pathParameter: return L10n.t("mocker.source.pathParameter.help")
        case .bodyText: return ""
        }
    }

    static func comparison(_ comparison: MockCondition.Comparison) -> String {
        switch comparison {
        case .equals: return L10n.t("mocker.comparison.equals")
        case .notEquals: return L10n.t("mocker.comparison.notEquals")
        case .contains: return L10n.t("mocker.comparison.contains")
        case .exists: return L10n.t("mocker.comparison.exists")
        }
    }
}

enum MockerColors {
    static func method(_ method: MockMethod) -> Color {
        HTTPMethod(rawValue: method.rawValue).map(Theme.color(for:)) ?? Theme.muted
    }

    static func worst(_ issues: [MockIssue]) -> MockIssue.Severity? {
        if issues.contains(where: { $0.severity == .error }) { return .error }
        return issues.isEmpty ? nil : .warning
    }
}

// MARK: - Endpoint düzenleyici

private struct MockEndpointEditor: View {
    @Environment(MockerState.self) private var mocker
    let id: UUID
    /// Açık senaryo kartları (çok senaryoda editörler kapalı başlar).
    @State private var expanded: Set<UUID> = []
    @State private var didInitExpansion = false

    private var binding: Binding<MockEndpoint> {
        Binding(
            get: { mocker.endpoints.first { $0.id == id } ?? MockEndpoint(id: id) },
            set: { newValue in
                if let index = mocker.endpoints.firstIndex(where: { $0.id == id }), mocker.endpoints[index] != newValue {
                    mocker.endpoints[index] = newValue
                }
            }
        )
    }

    var body: some View {
        let endpoint = binding
        let issues = mocker.issues(for: id)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    Picker(L10n.t("mocker.method"), selection: endpoint.method) {
                        ForEach(MockMethod.allCases, id: \.self) { method in
                            Text(method.title).tag(method)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help(L10n.t("mocker.method.help"))
                    TextField(L10n.t("mocker.path.placeholder"), text: endpoint.path)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.input)
                        .inputLimit(.path)
                        .help(L10n.t("mocker.path.help"))
                    Menu {
                        Button(L10n.t("mocker.duplicate")) { mocker.duplicateEndpoint(id) }
                            .disabled(!mocker.canAddEndpoint)
                        Button(L10n.t("mocker.moveUp")) { mocker.moveEndpoint(id, by: -1) }
                        Button(L10n.t("mocker.moveDown")) { mocker.moveEndpoint(id, by: 1) }
                        Divider()
                        Button(L10n.t("mocker.delete"), role: .destructive) { mocker.deleteEndpoint(id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L10n.t("mocker.more"))
                }
                if let address = mocker.address, MockValidator.pathError(endpoint.wrappedValue.path) == nil {
                    Text(address + endpoint.wrappedValue.path)
                        .font(.secondaryMono)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                IssueList(issues: issues.filter { $0.scenarioID == nil })

                MockRequestExampleEditor(endpoint: endpoint, address: mocker.address)

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeading(title: L10n.t("mocker.defaultResponse"), detail: L10n.t("mocker.defaultResponse.detail"))
                    MockResponseEditor(response: endpoint.response)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionHeading(title: L10n.t("mocker.scenarios"), detail: L10n.t("mocker.scenarios.detail"))
                        Spacer(minLength: 0)
                        Button {
                            // Endpoint'in örnek gövdesiyle başlar: yalnızca farklı olan değer değiştirilir.
                            let scenario = MockScenario(requestBody: endpoint.wrappedValue.requestBody)
                            endpoint.wrappedValue.scenarios.append(scenario)
                            expanded.insert(scenario.id)
                        } label: {
                            Label(L10n.t("mocker.addScenario"), systemImage: "plus")
                        }
                        .disabled(endpoint.wrappedValue.scenarios.count >= MockerLimits.maxScenarios)
                    }
                    ForEach(Array(endpoint.wrappedValue.scenarios.enumerated()), id: \.element.id) { index, scenario in
                        MockScenarioCard(
                            endpointID: id,
                            endpointExample: endpoint.wrappedValue.requestBody,
                            scenario: scenarioBinding(scenario.id, in: endpoint),
                            index: index,
                            count: endpoint.wrappedValue.scenarios.count,
                            isExpanded: Binding(
                                get: { expanded.contains(scenario.id) },
                                set: { if $0 { expanded.insert(scenario.id) } else { expanded.remove(scenario.id) } }
                            ),
                            issues: issues.filter { $0.scenarioID == scenario.id },
                            move: { offset in
                                let target = index + offset
                                guard endpoint.wrappedValue.scenarios.indices.contains(target) else { return }
                                endpoint.wrappedValue.scenarios.swapAt(index, target)
                            },
                            delete: { endpoint.wrappedValue.scenarios.removeAll { $0.id == scenario.id } }
                        )
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            // Az senaryoda hepsi açık; çoksa kapalı başlar (her biri bir kod editörü).
            guard !didInitExpansion else { return }
            didInitExpansion = true
            let scenarios = binding.wrappedValue.scenarios
            if scenarios.count <= 3 { expanded = Set(scenarios.map(\.id)) }
        }
    }

    private func scenarioBinding(_ scenarioID: UUID, in endpoint: Binding<MockEndpoint>) -> Binding<MockScenario> {
        Binding(
            get: { endpoint.wrappedValue.scenarios.first { $0.id == scenarioID } ?? MockScenario(id: scenarioID) },
            set: { newValue in
                if let index = endpoint.wrappedValue.scenarios.firstIndex(where: { $0.id == scenarioID }) {
                    endpoint.wrappedValue.scenarios[index] = newValue
                }
            }
        )
    }
}

/// Örnek request gövdesi: eşleşmeyi etkilemez, ne gönderileceğini gösterir
/// ve cURL olarak kopyalanır (kullanıcı isteği, 2026-11-07).
private struct MockRequestExampleEditor: View {
    @Binding var endpoint: MockEndpoint
    /// Çalışıyorsa gerçek adres; durmuşsa ilk port varsayılır.
    let address: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                SectionHeading(title: L10n.t("mocker.requestExample"), detail: L10n.t("mocker.requestExample.detail"))
                Spacer(minLength: 0)
                Button {
                    let command = MockRequestExample.curl(
                        method: endpoint.method,
                        baseURL: address ?? "http://localhost:\(MockerLimits.ports[0])",
                        path: endpoint.path,
                        body: endpoint.requestBody)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? L10n.t("mocker.copied") : L10n.t("mocker.copyCurl"),
                          systemImage: copied ? "checkmark" : "terminal")
                }
                .help(L10n.t("mocker.copyCurl.help"))
            }
            MockBodyEditor(text: $endpoint.requestBody, height: 140,
                           placeholder: L10n.t("mocker.requestExample.placeholder"))
        }
    }
}

/// Mocker'ın gövde alanı: kod editörü + Beautify. Kural ve metinler API
/// Client'taki gövdeyle ortak: tür `Beautifier.kind(contentType:body:)` (önce
/// Content-Type, yoksa gövdenin başı), biçimlendirme `Beautifier.beautify`,
/// ipucu ve hata metni `BodyEditor.label` / `BodyEditor.message`.
private struct MockBodyEditor<Accessory: View>: View {
    var title: String?
    @Binding var text: String
    /// Response'ta tanımdaki Content-Type; request'te boş (gövdeden tahmin).
    var contentType: String = ""
    var height: CGFloat
    var placeholder: String?
    @ViewBuilder var accessory: () -> Accessory
    @State private var formatError: String?

    private var kind: Beautifier.Kind { Beautifier.kind(contentType: contentType, body: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let title {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                accessory()
                Spacer(minLength: 0)
                beautifyButton
            }
            CodeEditor(
                text: $text,
                language: CodeLanguage(kind),
                limits: EditorLimits(maxBytes: MockerLimits.maxResponseBodyBytes,
                                     maxDisplayBytes: MockerLimits.maxResponseBodyBytes,
                                     onRejected: { _ in NSSound.beep() },
                                     onLongLine: { _ in NSSound.beep() })
            )
            .frame(height: height)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.tableLine))
            .overlay(alignment: .topLeading) {
                if text.isEmpty, let placeholder {
                    Text(placeholder)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            if let formatError {
                Label(formatError, systemImage: "xmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Yazınca eski hata kalkar.
        .onChange(of: text) { if formatError != nil { formatError = nil } }
    }

    private var beautifyButton: some View {
        let kind = kind
        let isPlain = kind == .plain
        return Button {
            do {
                text = try Beautifier.beautify(text, as: kind)
                formatError = nil
            } catch {
                formatError = BodyEditor.message(for: error, source: text)
            }
        } label: {
            Label(L10n.t("body.beautify"), systemImage: "wand.and.stars")
        }
        .controlSize(.small)
        .help(isPlain ? L10n.t("body.beautify.plain") : L10n.t("body.beautify.help", BodyEditor.label(kind)))
        .disabled(text.isEmpty || isPlain)
    }
}

extension MockBodyEditor where Accessory == EmptyView {
    init(title: String? = nil, text: Binding<String>, contentType: String = "", height: CGFloat, placeholder: String? = nil) {
        self.init(title: title, text: text, contentType: contentType, height: height, placeholder: placeholder) { EmptyView() }
    }
}

private struct SectionHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.secondaryText).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct IssueList: View {
    let issues: [MockIssue]

    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues) { issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.secondaryText)
                        .foregroundStyle(issue.severity == .error ? Theme.down : Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Senaryo

private struct MockScenarioCard: View {
    let endpointID: UUID
    /// Endpoint'in örnek request body'si ("örnekten kopyala").
    let endpointExample: String
    @Binding var scenario: MockScenario
    let index: Int
    let count: Int
    @Binding var isExpanded: Bool
    let issues: [MockIssue]
    let move: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right").iconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isExpanded ? L10n.t("mocker.collapse") : L10n.t("mocker.expand"))
                TextField(MockValidator.displayName(of: scenario, index: index), text: $scenario.name)
                    .textFieldStyle(.input)
                    .inputLimit(.name)
                    .frame(maxWidth: 260)
                Text(summary)
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                Text("→ \(scenario.response.status)")
                    .font(.secondaryMono)
                    .foregroundStyle(Theme.statusColor(scenario.response.status))
                if let worst = MockerColors.worst(issues) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(worst == .error ? Theme.down : Theme.warning)
                        .help(issues.map(\.message).joined(separator: "\n"))
                }
                Spacer(minLength: 0)
                Button { move(-1) } label: { Image(systemName: "arrow.up").iconHitTarget() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(index == 0)
                    .help(L10n.t("mocker.moveUp"))
                Button { move(1) } label: { Image(systemName: "arrow.down").iconHitTarget() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(index == count - 1)
                    .help(L10n.t("mocker.moveDown"))
                Button(role: .destructive) { delete() } label: { Image(systemName: "trash").iconHitTarget() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L10n.t("mocker.scenario.delete"))
                    .accessibilityLabel(L10n.t("mocker.scenario.delete"))
            }
            if isExpanded {
                IssueList(issues: issues.filter { $0.conditionID == nil })
                MockScenarioBodyEditor(scenario: $scenario, endpointExample: endpointExample)
                VStack(alignment: .leading, spacing: 6) {
                    Text(scenario.hasRequestBody ? L10n.t("mocker.conditions.extra") : L10n.t("mocker.conditions"))
                        .font(.subheadline.weight(.semibold))
                    ForEach($scenario.conditions) { $condition in
                        MockConditionRow(condition: $condition,
                                         issue: issues.first { $0.conditionID == condition.id },
                                         delete: { scenario.conditions.removeAll { $0.id == condition.id } })
                    }
                    Button {
                        scenario.conditions.append(MockCondition())
                    } label: {
                        Label(L10n.t("mocker.addCondition"), systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .disabled(scenario.conditions.count >= MockerLimits.maxConditions)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.t("mocker.response")).font(.subheadline.weight(.semibold))
                    MockResponseEditor(response: $scenario.response)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.tableLine))
    }
}

extension MockScenarioCard {
    /// Kapalı kartta: "gövde + 2 koşul", "1 koşul"…
    fileprivate var summary: String {
        let conditions = L10n.t("mocker.condition.count", L10n.number(scenario.conditions.count))
        guard scenario.hasRequestBody else { return conditions }
        return scenario.conditions.isEmpty ? L10n.t("mocker.summary.body") : L10n.t("mocker.summary.bodyAnd", conditions)
    }
}

/// Senaryonun request body'si: gelen gövde buna göre karşılaştırılır.
private struct MockScenarioBodyEditor: View {
    @Binding var scenario: MockScenario
    let endpointExample: String

    var body: some View {
        MockBodyEditor(title: L10n.t("mocker.scenario.body"), text: $scenario.requestBody, height: 120,
                       placeholder: L10n.t("mocker.scenario.body.placeholder")) {
                Picker(L10n.t("mocker.scenario.bodyMatch"), selection: $scenario.bodyMatch) {
                    Text(L10n.t("mocker.bodyMatch.contains")).tag(MockBodyMatch.contains)
                    Text(L10n.t("mocker.bodyMatch.exact")).tag(MockBodyMatch.exact)
                }
                .labelsHidden()
                .fixedSize()
                .help(L10n.t("mocker.bodyMatch.help"))
                if !endpointExample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   scenario.requestBody != endpointExample {
                    Button(L10n.t("mocker.scenario.copyExample")) { scenario.requestBody = endpointExample }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .help(L10n.t("mocker.scenario.copyExample.help"))
                }
        }
    }
}

private struct MockConditionRow: View {
    @Binding var condition: MockCondition
    let issue: MockIssue?
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Picker(L10n.t("mocker.condition.source"), selection: $condition.source) {
                    ForEach(MockCondition.Source.allCases, id: \.self) { source in
                        Text(MockerText.source(source)).tag(source)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                if condition.usesName {
                    TextField(MockerText.placeholder(condition.source), text: $condition.name)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.input)
                        .inputLimit(.key)
                        .frame(minWidth: 120, maxWidth: 220)
                        .help(MockerText.help(condition.source))
                }
                Picker(L10n.t("mocker.condition.comparison"), selection: $condition.comparison) {
                    ForEach(MockCondition.Comparison.allCases, id: \.self) { comparison in
                        Text(MockerText.comparison(comparison)).tag(comparison)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                if condition.usesValue {
                    TextField(L10n.t("mocker.condition.value"), text: $condition.value)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.input)
                        .inputLimit(.headerValue)
                }
                Spacer(minLength: 0)
                Button(role: .destructive) { delete() } label: { Image(systemName: "minus.circle").iconHitTarget() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L10n.t("mocker.condition.delete"))
                    .accessibilityLabel(L10n.t("mocker.condition.delete"))
            }
            if let issue {
                Text(issue.message)
                    .font(.secondaryText)
                    .foregroundStyle(issue.severity == .error ? Theme.down : Theme.warning)
            }
        }
    }
}

// MARK: - Response

private struct MockResponseEditor: View {
    @Binding var response: MockResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.t("mocker.status")).foregroundStyle(.secondary)
                TextField("200", value: Binding(
                    get: { response.status },
                    set: { response.status = min(max($0, MockerLimits.statusRange.lowerBound), MockerLimits.statusRange.upperBound) }
                ), format: .number.grouping(.never))
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.input)
                .frame(width: 64)
                Text(MockHTTPWriter.reason(response.status))
                    .font(.secondaryText)
                    .foregroundStyle(Theme.statusColor(response.status))
                Divider().frame(height: 16)
                Text(L10n.t("mocker.delay")).foregroundStyle(.secondary)
                TextField("0", value: Binding(
                    get: { response.delayMilliseconds },
                    set: { response.delayMilliseconds = min(max($0, 0), MockerLimits.maxDelayMilliseconds) }
                ), format: .number.grouping(.never))
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.input)
                .frame(width: 80)
                .help(L10n.t("mocker.delay.help", L10n.number(MockerLimits.maxDelayMilliseconds)))
                Text("ms").foregroundStyle(.secondary)
            }
            Text(L10n.t("mocker.headers")).font(.secondaryText).foregroundStyle(.secondary)
            KeyValueEditor(entries: $response.headers,
                           keyPlaceholder: L10n.t("mocker.header.key"),
                           valuePlaceholder: L10n.t("mocker.header.value"))
                .frame(height: 130)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.tableLine))
            MockBodyEditor(text: $response.body, contentType: Self.contentType(of: response), height: 180) {
                Text(L10n.t("mocker.body")).font(.secondaryText).foregroundStyle(.secondary)
            }
        }
    }

    /// Tanımdaki etkin Content-Type (tür tahmini önce buna bakar).
    static func contentType(of response: MockResponse) -> String {
        response.headers.first { $0.enabled && $0.key.lowercased() == "content-type" }?.value ?? ""
    }
}

// MARK: - Gelen istekler

private struct MockRequestLogView: View {
    @Environment(MockerState.self) private var mocker

    var body: some View {
        @Bindable var state = mocker
        if mocker.log.isEmpty {
            ContentUnavailableView {
                Label(L10n.t("mocker.log.empty"), systemImage: "tray")
            } description: {
                Text(mocker.address.map { L10n.t("mocker.log.empty.running", $0) } ?? L10n.t("mocker.log.empty.stopped"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SplitPanes(minFirst: 260, minSecond: 280, dividerBackground: Theme.editorBackground) {
                VStack(spacing: 0) {
                    HStack {
                        Text(L10n.t("mocker.log.title", L10n.number(mocker.log.count)))
                            .font(.secondaryText).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.t("mocker.log.clear")) { mocker.clearLog() }
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    Divider()
                    List(selection: $state.selectedLogID) {
                        ForEach(mocker.log) { event in
                            MockLogRow(event: event, title: outcomeTitle(event))
                                .tag(event.id)
                        }
                    }
                    .listStyle(.inset)
                }
            } second: {
                if let event = mocker.log.first(where: { $0.id == mocker.selectedLogID }) {
                    MockLogDetail(event: event, outcome: outcomeTitle(event))
                } else {
                    Text(L10n.t("mocker.log.select"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func outcomeTitle(_ event: MockLogEvent) -> String {
        switch event.outcome {
        case .scenario(let id, let name)?:
            if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
            let endpoint = mocker.endpoints.first { $0.id == event.endpointID }
            let index = endpoint?.scenarios.firstIndex { $0.id == id } ?? 0
            return L10n.t("mocker.scenario.untitled", L10n.number(index + 1))
        case .defaultResponse?: return L10n.t("mocker.outcome.default")
        case .noEndpoint?: return L10n.t("mocker.outcome.none")
        case nil: return L10n.t("mocker.outcome.invalid")
        }
    }
}

private struct MockLogRow: View {
    let event: MockLogEvent
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(event.date, format: .dateTime.hour().minute().second())
                .font(.tinyMono).foregroundStyle(.tertiary)
            Text(event.method)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(HTTPMethod(rawValue: event.method).map(Theme.color(for:)) ?? Theme.muted)
                .frame(width: 52, alignment: .leading)
            Text(event.target)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text(title).font(.secondaryText).foregroundStyle(.secondary).lineLimit(1)
            Text("\(event.status)")
                .font(.secondaryMono)
                .foregroundStyle(Theme.statusColor(event.status))
        }
    }
}

private struct MockLogDetail: View {
    @Environment(MockerState.self) private var mocker
    let event: MockLogEvent
    let outcome: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(event.method) \(event.target)")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Text("\(event.status) \(MockHTTPWriter.reason(event.status))")
                        .foregroundStyle(Theme.statusColor(event.status))
                    Text(outcome).foregroundStyle(.secondary)
                    Text(L10n.t("mocker.log.duration", L10n.number(event.milliseconds))).foregroundStyle(.secondary)
                    if let endpointID = event.endpointID, mocker.endpoints.contains(where: { $0.id == endpointID }) {
                        Button(L10n.t("mocker.log.openEndpoint")) { mocker.select(endpointID: endpointID) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .font(.secondaryText)
                Text(L10n.t("mocker.headers")).font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(event.headers.enumerated()), id: \.offset) { _, header in
                        Text("\(header.name): \(header.value)")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Text(L10n.t("mocker.body")).font(.subheadline.weight(.semibold))
                if event.bodyBytes == 0 {
                    Text(L10n.t("mocker.log.noBody")).foregroundStyle(.secondary)
                } else {
                    Text(event.bodyPreview)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if event.bodyBytes > MockerLimits.logBodyPreviewBytes {
                        Text(L10n.t("mocker.log.truncated",
                                    TextStats.size(MockerLimits.logBodyPreviewBytes), TextStats.size(event.bodyBytes)))
                            .font(.secondaryText).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
