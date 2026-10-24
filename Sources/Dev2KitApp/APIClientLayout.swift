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
    private static let splitSpace = "splitContainer"

    /// İlk açılışta minimum; sonraki açılışlarda kullanıcının bıraktığı
    /// genişlik. Asgari logo ölçülünce kesinleşir; kayıtlı değer asgarinin
    /// altındaysa gösterimde sınıra çekilir (`effectiveSidebarWidth`),
    /// geçerli tercih olduğu gibi kalır.
    @State private var sidebarWidth: CGFloat = SidebarSizing.restoredPreference(
        UserDefaults.standard.double(forKey: APIClientLayout.sidebarWidthKey),
        minimum: SidebarSizing.baseMinimum
    )

    @State private var dragStartWidth: CGFloat?

    /// Genişlik sınırları (`SidebarSizing`): alt sınır logonun panelin
    /// üstünde sığması, üst sınır en uzun ad — ve detay paneline en az
    /// 480 pt kalacak şekilde pencereye göre kırpılır. Çelişirse alt kazanır.
    private func sidebarUpperBound(totalWidth: CGFloat) -> CGFloat {
        SidebarSizing.upperBound(contentMaximum: appState.sidebarMaxWidth, totalWidth: totalWidth, divider: SplitDivider.thickness)
    }

    private func effectiveSidebarWidth(totalWidth: CGFloat) -> CGFloat {
        SidebarSizing.width(preferred: sidebarWidth, minimum: appState.sidebarMinimumWidth, upper: sidebarUpperBound(totalWidth: totalWidth))
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
                    if let content = appState.openExampleContent, let ref = appState.openExample,
                       let draft = appState.exampleBinding(ref) {
                        // Kayıtlı örnek: istek editörü (ve Gönder'i) yerinde yok.
                        ExampleDetailView(request: content.request, example: content.example, draft: draft)
                    } else if let requestBinding = appState.selectedRequest {
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
        .modifier(ExampleDialogs())
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
                                               lower: appState.sidebarMinimumWidth, upper: sidebarUpperBound(totalWidth: totalWidth))
        } onEnd: {
            dragStartWidth = nil
            UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
        }
    }
}

/// Örnek kaydetme akışının uyarı ve sayfası, örnek yeniden adlandırma ve
/// silme kutuları. Kenar çubuğu ve örnek görünümü aynı kutuları kullanır.
private struct ExampleDialogs: ViewModifier {
    @Environment(AppState.self) private var appState
    @State private var renameText = ""

    func body(content: Content) -> some View {
        content
            .alert(
                L10n.t("example.limit.title"),
                // Kapanmayı düğmeler yönetir: "Yönet" sayfaya geçer, "Vazgeç" bitirir.
                isPresented: Binding(get: { appState.pendingExampleSave?.phase == .limitWarning }, set: { _ in })
            ) {
                Button(L10n.t("example.limit.manage")) { appState.manageExamplesForPendingSave() }
                Button(L10n.t("common.cancel"), role: .cancel) { appState.cancelSavingExample() }
            } message: {
                Text(L10n.t("example.limit.message"))
            }
            .sheet(item: Binding(
                get: { appState.pendingExampleSave?.phase == .naming ? appState.pendingExampleSave : nil },
                set: { newValue in
                    // Esc ile kapanış; uyarıya dönüşte akış sürer.
                    if newValue == nil, appState.pendingExampleSave?.phase == .naming { appState.cancelSavingExample() }
                }
            )) { pending in
                SaveExampleSheet(pending: pending)
            }
            .alert(
                L10n.t("example.rename.title"),
                isPresented: Binding(
                    get: { appState.exampleRenameTarget != nil },
                    set: { if !$0 { appState.exampleRenameTarget = nil } }
                )
            ) {
                TextField(L10n.t("example.sheet.namePlaceholder"), text: $renameText)
                    .inputLimit(.name)
                Button(L10n.t("example.rename.confirm")) {
                    if let target = appState.exampleRenameTarget {
                        appState.renameExample(target, to: renameText)
                    }
                    appState.exampleRenameTarget = nil
                }
                Button(L10n.t("common.cancel"), role: .cancel) { appState.exampleRenameTarget = nil }
            }
            .onChange(of: appState.exampleRenameTarget) {
                renameText = appState.exampleRenameTarget.flatMap(appState.example)?.name ?? ""
            }
            .alert(
                L10n.t("example.delete.title", appState.exampleDeleteTarget.flatMap(appState.example)?.name ?? ""),
                isPresented: Binding(
                    get: { appState.exampleDeleteTarget != nil },
                    set: { if !$0 { appState.exampleDeleteTarget = nil } }
                )
            ) {
                Button(L10n.t("example.delete"), role: .destructive) {
                    if let target = appState.exampleDeleteTarget { appState.deleteExample(target) }
                    appState.exampleDeleteTarget = nil
                }
                Button(L10n.t("common.cancel"), role: .cancel) { appState.exampleDeleteTarget = nil }
            } message: {
                Text(L10n.t("common.deletePermanent"))
            }
    }
}
