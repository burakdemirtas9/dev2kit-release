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
    @State private var isHoveringDivider = false

    /// Genişlik sınırları: alt 220, üst içerik genişliği — ve detay paneline
    /// en az 480px kalacak şekilde pencereye göre kırpılır.
    private func effectiveSidebarWidth(totalWidth: CGFloat) -> CGFloat {
        let upper = max(Self.minSidebarWidth, min(appState.sidebarMaxWidth, totalWidth - 489))
        return min(max(sidebarWidth, Self.minSidebarWidth), upper)
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

    /// Sürüklenebilir dikey ayraç: 1px çizgi + 9px görünmez tutma alanı.
    /// Bırakınca genişlik UserDefaults'a yazılır, sonraki açılışta geri gelir.
    private func sidebarDivider(totalWidth: CGFloat) -> some View {
        ZStack {
            Color.clear
                .frame(width: 9)
                .contentShape(Rectangle())
            // Görünür çizgi yok: kenar çubuğu camlı zeminiyle ayrışıyor
            // (Workbench'teki gibi, 2026-10-20). Sürükleme alanı duruyor.
        }
        // push/pop dengesiz kalırsa imleç yığını bozuluyor (ayraç üstündeyken
        // pencere değişince "pop" gelmeyebiliyor); bayrakla eşleştiriliyor.
        .onHover { hovering in
            guard hovering != isHoveringDivider else { return }
            isHoveringDivider = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHoveringDivider {
                isHoveringDivider = false
                NSCursor.pop()
            }
        }
        // translation yerine konteynerdeki mutlak konum kullanılıyor: ayraç
        // sürüklendikçe kendi koordinat uzayı da kaydığı için translation
        // geri besleme yapıp titremeye yol açıyordu.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.splitSpace))
                .onChanged { value in
                    let upper = max(Self.minSidebarWidth, min(appState.sidebarMaxWidth, totalWidth - 489))
                    sidebarWidth = min(max(value.location.x, Self.minSidebarWidth), upper)
                }
                .onEnded { _ in
                    UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
                }
        )
    }
}
