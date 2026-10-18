import SwiftUI
import Dev2KitCore

/// Sol panelin altındaki Token Factory bölümü.
///
/// Koleksiyon listesinin İÇİNDE değil, altında sabit duruyor: kaydırınca
/// kaybolmasın, kullanıcı token isteklerinin normal isteklerden ayrı bir yer
/// olduğunu görsün. Satırlar `List` değil Button: liste seçimi ana listeye
/// ait, iki ayrı `List` seçimi birbirini eziyordu.
struct TokenFactoryPanel: View {
    @Environment(AppState.self) private var appState
    @AppStorage("tokenFactoryCollapsed") private var collapsed = false
    @State private var pendingDelete: RequestModel?
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
                                row(request, environment: environment, problems: problems)
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
                    Label("Bırak: Token Factory'ye kopyalanır", systemImage: "plus.square.on.square")
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
            "\"\(pendingDelete?.name ?? "")\" silinsin mi?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Sil", role: .destructive) {
                if let request = pendingDelete { appState.deleteRequest(request.id) }
                pendingDelete = nil
            }
            Button("Vazgeç", role: .cancel) { pendingDelete = nil }
        } message: {
            let variable = (pendingDelete?.tokenOutput ?? TokenOutput()).trimmedVariableName
            Text("{{\(variable)}} kullanan istekler artık token alamaz.")
        }
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
                            .help("Token Factory yapılandırmasında sorun var")
                    }
                    Spacer(minLength: 0)
                }
                .rowHitTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Token Factory'yi aç" : "Token Factory'yi daralt")

            Button {
                collapsed = false
                appState.addTokenFactoryRequest()
            } label: {
                Image(systemName: "plus").iconHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Token isteği ekle")
            .accessibilityLabel("Token isteği ekle")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Token üreten istekleri buraya ekle. Diğer istekler token'ı {{token}} ile kullanır.")
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                appState.addTokenFactoryRequest()
            } label: {
                Label("Token İsteği Ekle", systemImage: "plus")
                    .font(.secondaryText)
                    .rowHitTarget(minHeight: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.purple)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func row(_ request: RequestModel, environment: EnvironmentModel?, problems: [TokenFactory.Problem]) -> some View {
        let output = request.tokenOutput ?? TokenOutput()
        let isSelected = appState.selectedRequestID == request.id
        let source = appState.tokenSources(for: environment).first { $0.request.id == request.id }
        let state = source.flatMap { appState.tokenState($0, environment: environment) }
        let hasProblem = problems.contains { $0.involves(request: request.name) }
        let isActive = output.applies(to: environment)

        return Button {
            appState.applySelection([request.id], order: [request.id])
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
        .help(isActive ? request.name : "\(request.name) — aktif environment'ta etkin değil")
        .contextMenu {
            Button {
                appState.duplicateRequest(request.id)
            } label: {
                Label("Çoğalt", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive) {
                pendingDelete = request
            } label: {
                Label("Sil…", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func indicator(state: AppState.TokenState?, hasProblem: Bool) -> some View {
        if hasProblem {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.tinyText).foregroundStyle(Theme.down)
                .accessibilityLabel("yapılandırma sorunu")
        } else {
            switch state {
            case .valid:
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Theme.up)
                    .accessibilityLabel("token geçerli")
            case .failed:
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Theme.down)
                    .accessibilityLabel("token alınamadı")
            case .fetching:
                ProgressView().controlSize(.mini)
            case nil:
                EmptyView()
            }
        }
    }
}
