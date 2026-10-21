import AppKit
import SwiftUI
import Dev2KitCore

/// API Client modu: kenar çubuğu, sekmeler, istek editörü.
///
/// Ayrı görünüm (eskiden `ContentView`'da hesaplanan özellikti): mod
/// değişince `ContentView` yeniden değerlendirilir; bu görünümün girdisi
/// olmadığı için gövdesi tekrar hesaplanmaz, yalnızca görünürlüğü değişir.
/// Ölçüldü: içerideyken her geçişte istek editörü ve yanıt baştan
/// güncelleniyordu (yoğun içerikte ~40 ms).
struct APIClientLayout: View {
    @Environment(AppState.self) private var appState

    private static let sidebarWidthKey = "sidebarWidth"
    private static let minSidebarWidth: CGFloat = 220
    private static let splitSpace = "splitContainer"

    /// İlk açılışta minimum; sonraki açılışlarda kullanıcının bıraktığı genişlik.
    @State private var sidebarWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: APIClientLayout.sidebarWidthKey)
        return stored >= APIClientLayout.minSidebarWidth ? CGFloat(stored) : APIClientLayout.minSidebarWidth
    }()

    @State private var dragStartWidth: CGFloat?

    /// Genişlik sınırları: alt 220, üst içerik genişliği — ve detay paneline
    /// en az 480px kalacak şekilde pencereye göre kırpılır.
    private func sidebarUpperBound(totalWidth: CGFloat) -> CGFloat {
        min(appState.sidebarMaxWidth, totalWidth - 480 - SplitDivider.thickness)
    }

    private func effectiveSidebarWidth(totalWidth: CGFloat) -> CGFloat {
        SplitSizing.clamp(sidebarWidth, lower: Self.minSidebarWidth, upper: sidebarUpperBound(totalWidth: totalWidth))
    }


    var body: some View {
        // Genişlik tamamen bizde: HSplitView/NavigationSplitView ayraç konumunu
        // dışarıdan vermeye izin vermiyor (ilk açılış + kalıcılık için gerekli).
        GeometryReader { geometry in
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: effectiveSidebarWidth(totalWidth: geometry.size.width))
                sidebarDivider(totalWidth: geometry.size.width)
                VStack(spacing: 0) {
                    if !appState.openTabs.isEmpty {
                        RequestTabBar()
                        Divider()
                    }
                    if let requestBinding = appState.selectedRequest {
                        RequestDetailView(request: requestBinding)
                    } else {
                        NoRequestSelectedView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: Self.splitSpace)
            // Sürüklerken örtük animasyon genişliği "kovalayınca" titreme oluyor.
            .animation(nil, value: sidebarWidth)
        }
    }

    /// Kenar çubuğu ayracı. Bırakınca genişlik UserDefaults'a yazılır,
    /// sonraki açılışta geri gelir.
    private func sidebarDivider(totalWidth: CGFloat) -> some View {
        // Görünür çizgi yalnızca hover/sürüklemede: kenar çubuğu camlı
        // zeminiyle ayrışıyor (Workbench'teki gibi, 2026-10-20).
        SplitDivider(axis: .horizontal, showsLineAtRest: false) {
            dragStartWidth = effectiveSidebarWidth(totalWidth: totalWidth)
        } onChange: { delta in
            sidebarWidth = SplitSizing.resized(start: dragStartWidth ?? sidebarWidth, delta: delta,
                                               lower: Self.minSidebarWidth, upper: sidebarUpperBound(totalWidth: totalWidth))
        } onEnd: {
            dragStartWidth = nil
            UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
        }
    }
}
