import AppKit
import SwiftUI
import Dev2KitCore

/// Sol panelin altındaki Token Factory bölümü.
///
/// Koleksiyon listesinin İÇİNDE değil, altında sabit duruyor: kaydırınca
/// kaybolmasın, kullanıcı token isteklerinin normal isteklerden ayrı bir yer
/// olduğunu görsün. Satırlar `List` değil Button: liste seçimi ana listeye
/// ait, iki ayrı `List` seçimi birbirini eziyordu. Çoklu seçim (⌘ tek tek,
/// ⇧ aralık) bu yüzden elle: kural `MultiSelection.click` (Core, testli),
/// küme ana listeyle ortak (`selectedRequestIDs`).
struct TokenFactoryPanel: View {
    @Environment(AppState.self) private var appState
    @AppStorage("tokenFactoryCollapsed") private var collapsed = false
    /// Silme onayı bekleyen token request'leri (tek ya da çoklu seçim).
    @State private var pendingDelete: Set<UUID> = []
    /// ⇧ aralığının sabit ucu: son düz ya da ⌘ tıklanan satır.
    @State private var anchor: UUID?
    /// Yukarıdan bir istek panelin üstüne sürükleniyor (bırakma ContentView'da).
    var isDropTargeted = false

    private static let maxListHeight: CGFloat = 150

    var body: some View {
        let requests = appState.workspace.tokenFactoryRequests
        let environment = appState.activeEnvironment
        let problems = TokenFactory.problems(in: requests, environment: environment)

        VStack(spacing: 0) {
            Divider()
            header(count: requests.count, hasProblems: !problems.isEmpty)
            if !collapsed {
                if requests.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(requests) { request in
                                row(request, order: requests.map(\.id), environment: environment, problems: problems)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: Self.maxListHeight)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .background(Theme.purple.opacity(0.06))
        // Vurgu yalnızca üst katman: yerleşim değişirse panelin boyu oynar,
        // imleç hedeften çıkar, panel geri büyür — sürükleme boyunca titrer.
        .overlay {
            if isDropTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.purple.opacity(0.12))
                        .strokeBorder(Theme.purple, lineWidth: 2)
                    Label(L10n.t("tokenFactory.dropHint"), systemImage: "plus.square.on.square")
                        .font(.secondaryText.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.purple, in: Capsule())
                }
                .padding(2)
                .allowsHitTesting(false)
            }
        }
        .confirmationDialog(
            deleteTitle(requests),
            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
            titleVisibility: .visible
        ) {
            Button(pendingDelete.count > 1 ? L10n.plural("request.deleteMany", count: pendingDelete.count) : L10n.t("request.delete"),
                   role: .destructive) {
                appState.deleteRequests(pendingDelete)
                pendingDelete = []
            }
            Button(L10n.t("common.cancel"), role: .cancel) { pendingDelete = [] }
        } message: {
            // Hangi token değişkenlerinin artık dolmayacağı adıyla söylenir.
            let variables = requests.filter { pendingDelete.contains($0.id) }
                .map { "{{\(($0.tokenOutput ?? TokenOutput()).trimmedVariableName)}}" }
            Text(variables.count > 1
                 ? L10n.t("token.deleteMany.message", variables.joined(separator: ", "))
                 : L10n.t("token.delete.message", String(variables.first?.dropFirst(2).dropLast(2) ?? "")))
        }
    }

    /// Silme onayının başlığı: tek request'te adı, çoklu seçimde sayısı.
    private func deleteTitle(_ requests: [RequestModel]) -> String {
        if pendingDelete.count == 1, let request = requests.first(where: { pendingDelete.contains($0.id) }) {
            return L10n.t("common.deleteNamed.title", request.name)
        }
        return L10n.plural("request.deleteMany.title", count: pendingDelete.count)
    }

    /// Tıklama: düz seçer, ⌘ ekler/çıkarır, ⇧ çapadan aralık seçer.
    private func select(_ id: UUID, order: [UUID]) {
        let flags = NSEvent.modifierFlags
        let click: MultiSelection.Click = flags.contains(.command) ? .toggle : flags.contains(.shift) ? .range : .plain
        let result = MultiSelection.click(id, click, selection: appState.selectedRequestIDs, anchor: anchor, order: order)
        anchor = result.anchor
        appState.applySelection(result.selection, order: order)
    }

    private func header(count: Int, hasProblems: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.tinyText.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Image(systemName: "key.viewfinder")
                        .foregroundStyle(Theme.purple)
                    Text(CollectionModel.tokenFactoryName)
                        .font(.callout.weight(.semibold))
                    Text("\(count)")
                        .font(.tinyText)
                        .foregroundStyle(.tertiary)
                    if hasProblems {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.tinyText)
                            .foregroundStyle(Theme.down)
                            .help(L10n.t("token.panel.problem"))
                    }
                    Spacer(minLength: 0)
                }
                .rowHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? L10n.t("token.panel.expand") : L10n.t("token.panel.collapse"))

            Button {
                collapsed = false
                appState.addTokenFactoryRequest()
            } label: {
                Image(systemName: "plus").iconHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.t("token.panel.add"))
            .accessibilityLabel(L10n.t("token.panel.add"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("token.panel.empty"))
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                appState.addTokenFactoryRequest()
            } label: {
                Label(L10n.t("tokenFactory.add"), systemImage: "plus")
                    .font(.secondaryText)
                    .rowHitTarget(minHeight: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.purple)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func row(_ request: RequestModel, order: [UUID], environment: EnvironmentModel?, problems: [TokenFactory.Problem]) -> some View {
        let output = request.tokenOutput ?? TokenOutput()
        let isSelected = appState.selectedRequestIDs.contains(request.id)
        let source = appState.tokenSources(for: environment).first { $0.request.id == request.id }
        let state = source.flatMap { appState.tokenState($0, environment: environment) }
        let hasProblem = problems.contains { $0.involves(request: request.name) }
        let isActive = output.applies(to: environment)

        return Button {
            select(request.id, order: order)
        } label: {
            HStack(spacing: 6) {
                Text(request.method.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.color(for: request.method))
                    .frame(width: 40, alignment: .leading)
                Text(request.name).lineLimit(1)
                Spacer(minLength: 4)
                Text("{{\(output.trimmedVariableName)}}")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                indicator(state: state, hasProblem: hasProblem)
            }
            .opacity(isActive ? 1 : 0.45)
            .padding(.horizontal, 6)
            .rowHitTarget()
            .background(
                isSelected ? Color.accentColor.opacity(0.25) : .clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
        }
        .buttonStyle(.plain)
        .help(isActive ? request.name : L10n.t("token.panel.inactive", request.name))
        .contextMenu {
            // Sağ tıklanan satır seçimdeyse işlem seçimdeki TOKEN request'lerine,
            // değilse yalnızca o satıra (ana listede seçili olanlara dokunulmaz).
            let picked = MultiSelection.targets(forContextMenuOn: request.id, selection: appState.selectedRequestIDs)
                .intersection(order)
            if picked.count <= 1 {
                Button {
                    appState.duplicateRequest(request.id)
                } label: {
                    Label(L10n.t("request.duplicate"), systemImage: "plus.square.on.square")
                }
                Divider()
            }
            Button(role: .destructive) {
                pendingDelete = picked
            } label: {
                Label(picked.count > 1 ? L10n.plural("request.deleteManyEllipsis", count: picked.count) : L10n.t("common.deleteEllipsis"),
                      systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func indicator(state: AppState.TokenState?, hasProblem: Bool) -> some View {
        if hasProblem {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.tinyText).foregroundStyle(Theme.down)
                .accessibilityLabel(L10n.t("token.state.problem"))
        } else {
            switch state {
            case .valid:
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Theme.up)
                    .accessibilityLabel(L10n.t("token.state.valid"))
            case .failed:
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Theme.down)
                    .accessibilityLabel(L10n.t("token.state.failed"))
            case .fetching:
                ProgressView().controlSize(.mini)
            case nil:
                EmptyView()
            }
        }
    }
}
