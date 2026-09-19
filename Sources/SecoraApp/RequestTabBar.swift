import SwiftUI
import SecoraCore

/// Açık isteklerin sekmeleri (Postman benzeri).
///
/// Önizleme sekmesi italik görünür ve bir sonraki açılan istekle yer
/// değiştirir; istek kullanılınca (düzenleme, gönderme, çift tıklama)
/// kalıcı olur. Kalıcı sekmeler sürüklenerek sıralanır ve kapatılır.
struct RequestTabBar: View {
    @Environment(AppState.self) private var appState
    @State private var dragging: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(appState.openTabs, id: \.self) { id in
                        if let request = appState.request(withID: id) {
                            RequestTab(
                                request: request,
                                isSelected: appState.selectedRequestID == id,
                                isPreview: appState.previewTabID == id,
                                isDirty: appState.isDirty(id)
                            )
                            .id(id)
                            .opacity(dragging == id ? 0.4 : 1)
                            .onDrag {
                                dragging = id
                                return NSItemProvider(object: id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: TabReorderDelegate(target: id, dragging: $dragging, appState: appState))
                        }
                    }
                }
            }
            .onChange(of: appState.selectedRequestID) {
                // Yeni seçilen sekme görünür alana kaydırılır.
                if let id = appState.selectedRequestID {
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
        .frame(height: 32)
        .background(.bar)
        // Sekmelerin dışına bırakılırsa sürükleme durumu temizlenir.
        .onDrop(of: [.text], isTargeted: nil) { _ in
            dragging = nil
            return true
        }
    }
}

private struct RequestTab: View {
    @Environment(AppState.self) private var appState
    let request: RequestModel
    let isSelected: Bool
    let isPreview: Bool
    let isDirty: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(request.method.rawValue)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.color(for: request.method))
            Text(request.name)
                .italic(isPreview)
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            ZStack {
                // Kirli işaret ile kapat düğmesi aynı yeri paylaşır (Xcode/Safari gibi):
                // üzerine gelince kapat düğmesine döner.
                if isDirty && !hovering {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Theme.warning)
                } else if hovering || isSelected {
                    Button {
                        appState.closeTab(request.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Sekmeyi kapat (⌘W)")
                }
            }
            .frame(width: 14)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(isSelected ? Theme.editorBackground : (hovering ? Color.primary.opacity(0.05) : .clear))
        .overlay(alignment: .top) {
            if isSelected {
                Rectangle().fill(Theme.accent).frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { appState.pinTab(request.id) }
        .onTapGesture { appState.selectedRequestID = request.id }
        .help(isPreview ? "\(request.name) — önizleme; çift tıklayınca kalıcı olur" : request.name)
        .contextMenu {
            if isPreview {
                Button("Kalıcı Yap") { appState.pinTab(request.id) }
                Divider()
            }
            Button("Kapat") { appState.closeTab(request.id) }
            Button("Diğerlerini Kapat") { appState.closeOtherTabs(request.id) }
            Button("Sağdakileri Kapat") { appState.closeTabsToRight(of: request.id) }
        }
    }
}

/// Sekmeler arasında canlı sıralama: sürüklenen sekme başka bir sekmenin
/// üzerine gelince yer değiştirir.
private struct TabReorderDelegate: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let appState: AppState

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            appState.moveTab(dragging, before: target)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Sürüklenen önizleme sekmesi artık bilinçli yerleştirilmiş bir sekmedir.
        if let dragging { appState.pinTab(dragging) }
        dragging = nil
        return true
    }
}
