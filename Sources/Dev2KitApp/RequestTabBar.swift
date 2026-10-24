import SwiftUI
import Dev2KitCore

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
            // Kirli istekler sekme başına değil, render başına tek kez.
            let dirty = appState.dirtyRequestIDs
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(appState.openTabs, id: \.self) { id in
                        if let request = appState.request(withID: id) {
                            RequestTab(
                                request: request,
                                isSelected: appState.selectedRequestID == id,
                                isPreview: appState.previewTabID == id,
                                isDirty: dirty.contains(id)
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
    /// Çift tıklamayı kendimiz ölçüyoruz; bkz. `onTapGesture`.
    @State private var lastTapAt: Date?

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
                    .help(L10n.t("tabs.close.help"))
                }
            }
            .frame(width: 14)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 28)
        // Ortak sekme görünümü (yuvarlak üst köşeler; arka plan güvenli alana
        // taşmaz, seçili sekme pencerenin tepesine kadar uzanmaz).
        .modifier(TabChrome(isSelected: isSelected, hovering: hovering))
        .onHover { hovering = $0 }
        // TEK gesture: tek tık ANINDA seçer, çift tık sekmeyi kalıcı yapar.
        //
        // Neden iki ayrı `onTapGesture` değil: `count: 2` ile birlikte
        // tanımlanınca SwiftUI tek tıklamayı "ikinci tık gelecek mi" diye
        // çift tıklama süresi kadar bekletiyor. Sekmeye basınca hissedilen
        // gecikme buydu — iş yükü değil, bekleme.
        .onTapGesture {
            let now = Date()
            let isDouble = lastTapAt.map { now.timeIntervalSince($0) <= NSEvent.doubleClickInterval } ?? false
            lastTapAt = now
            if isDouble {
                appState.pinTab(request.id)
            } else {
                // Açık örneğin sekmesine basmak istek editörüne döner.
                appState.openExample = nil
                appState.selectedRequestID = request.id
            }
        }
        .help(isPreview ? L10n.t("tabs.preview.help", request.name) : request.name)
        .contextMenu {
            if isPreview {
                Button(L10n.t("tabs.pin")) { appState.pinTab(request.id) }
                Divider()
            }
            Button(L10n.t("common.close")) { appState.closeTab(request.id) }
            Button(L10n.t("tabs.closeOthers")) { appState.closeOtherTabs(request.id) }
            Button(L10n.t("tabs.closeRight")) { appState.closeTabsToRight(of: request.id) }
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
