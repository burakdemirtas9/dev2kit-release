import SwiftUI
import Dev2KitCore

/// Açık isteklerin sekmeleri (Postman benzeri).
///
/// Önizleme sekmesi italik görünür ve bir sonraki açılan istekle yer
/// değiştirir; istek kullanılınca (düzenleme, gönderme, çift tıklama)
/// kalıcı olur. Kalıcı sekmeler sürüklenerek sıralanır ve kapatılır.
///
/// Sabit sekmeler başta, sabitlenme sırasıyla (kural `RequestTabs`'ta);
/// çarpının yerinde iğne durur. Sağdaki + koleksiyonsuz yeni istek açar
/// (⌘T, boş ekrandaki bağlantıyla aynı).
///
/// Sürükleyerek sıralama fare takibiyle (tarayıcı sekme şeridi gibi,
/// 2026-10-31): sekme imlecin altında kayar, komşusunun ortasını geçince
/// yer değiştirir (`RequestTabs.reorderTarget`). Neden sistem sürükle-bırakı
/// değil: o oturum yükü "kopya" başlatıyor, hedef "taşı" diyor; macOS bırakmayı
/// başarısız sayıp sürükleme görüntüsünü ~1 sn geri kaydırıyordu (kullanıcı
/// bildirimi: bırakınca donukluk).
struct RequestTabBar: View {
    @Environment(AppState.self) private var appState
    /// Sürüklenen sekme ve sürükleme durumu (yalnızca bu görünümde).
    @State private var drag: TabDrag?
    /// Sekmelerin şerit içindeki çerçeveleri (kaydırmadan bağımsız).
    @State private var frames: [UUID: CGRect] = [:]
    /// Sürükleme hareketi sürüyor mu: hareket biter ya da İPTAL olursa
    /// SwiftUI kendiliğinden `false` yapar (iptalde `onEnded` gelmez).
    @GestureState private var gestureActive = false

    private static let space = "requestTabStrip"

    /// Sürükleme: başlangıçtaki yerleşim konumu, şimdiki yerleşim konumu
    /// (yer değiştirdikçe geçilen sekmelerin genişliği kadar kayar) ve
    /// grubun sınırları. Görsel konum = başlangıç + öteleme, grupta kalır.
    private struct TabDrag {
        let id: UUID
        /// Hareketin başladığı nokta: yeni bir sürükleme eskisinin durumunu devralmaz.
        let start: CGPoint
        let originMinX: CGFloat
        var layoutMinX: CGFloat
        let width: CGFloat
        let groupMinX: CGFloat
        let groupMaxX: CGFloat
        var translation: CGFloat = 0

        var visualMinX: CGFloat {
            min(max(originMinX + translation, groupMinX), groupMaxX - width)
        }

        /// Sekmeyi yerleşim konumundan imlecin altına taşıyan öteleme.
        var offset: CGFloat { visualMinX - layoutMinX }
    }

    var body: some View {
        HStack(spacing: 0) {
            tabs
            Button {
                appState.createUngroupedRequest()
            } label: {
                Image(systemName: "plus").iconHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .help(L10n.t("tabs.new.help"))
            .accessibilityLabel(L10n.t("menu.newUngroupedRequest"))
        }
        .frame(height: 32)
        .background(.bar)
    }

    private var tabs: some View {
        ScrollViewReader { proxy in
            // Kirli istekler sekme başına değil, render başına tek kez.
            let dirty = appState.dirtyRequestIDs
            // Açık sekmelerin özeti TEK geçişte. Sekme başına `request(withID:)`
            // her seferinde tüm koleksiyonları tarıyordu (sekme × istek); sürükleme
            // sırasında her yer değiştirmede çizimin yarısı buydu (ölçüldü,
            // 2026-10-31, 300 istek: profilde `locateRequest`).
            let summaries = RequestTab.summaries(of: appState.openTabs, in: appState.workspace.collections)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(appState.openTabs, id: \.self) { id in
                        if let summary = summaries[id] {
                            RequestTab(
                                request: summary,
                                isSelected: appState.selectedRequestID == id,
                                isPreview: appState.previewTabID == id,
                                isPinned: appState.isTabPinned(id),
                                isDirty: dirty.contains(id)
                            )
                            .id(id)
                            // Yerleşim çerçevesi (ötelemeden ÖNCE ölçülür).
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[id] = $0 }
                            .offset(x: drag?.id == id ? drag?.offset ?? 0 : 0)
                            .zIndex(drag?.id == id ? 1 : 0)
                            // Sürüklenen sekme imleci anında izler; diğerleri kayarken o kaymaz.
                            .transaction { if drag?.id == id { $0.animation = nil } }
                        }
                    }
                }
                .coordinateSpace(name: Self.space)
                // Hareket ŞERİDE bağlı, tek tek sekmelere değil: sekmeye bağlıyken
                // sürüklenen sekme ilk yer değiştirmede yeni konumuna taşınınca
                // SwiftUI hareketi iptal ediyordu; sekme bir adımda kalıyor, durum
                // yarım kaldığı için sonraki sürüklemeler de çalışmıyordu
                // (kullanıcı bildirimi, fare olaylarıyla yeniden üretildi).
                // Şerit yer değiştirmez; tutulan sekme başlangıç noktasından bulunur.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .local)
                        .updating($gestureActive) { _, active, _ in active = true }
                        .onChanged { dragChanged($0) }
                        .onEnded { _ in dragEnded() }
                )
                .onChange(of: gestureActive) { _, active in
                    if !active { dragEnded() }
                }
            }
            .onChange(of: appState.selectedRequestID) {
                // Yeni seçilen sekme görünür alana kaydırılır.
                if let id = appState.selectedRequestID {
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    // MARK: Sürükleyerek sıralama

    private func dragChanged(_ value: DragGesture.Value) {
        if drag?.start != value.startLocation {
            // Yeni sürükleme: tutulan sekme başlangıç noktasındaki (şerit
            // koordinatı, çerçevelerle aynı uzay).
            guard let id = appState.openTabs.first(where: { frames[$0]?.contains(value.startLocation) == true }),
                  let frame = frames[id] else {
                drag = nil
                return
            }
            // Grup sınırları: sekme kendi grubunun (sabit / sabit olmayan) dışına çıkmaz.
            let pinned = appState.isTabPinned(id)
            let group = appState.openTabs.filter { appState.isTabPinned($0) == pinned }.compactMap { frames[$0] }
            drag = TabDrag(
                id: id, start: value.startLocation, originMinX: frame.minX, layoutMinX: frame.minX, width: frame.width,
                groupMinX: group.map(\.minX).min() ?? frame.minX,
                groupMaxX: group.map(\.maxX).max() ?? frame.maxX
            )
        }
        guard var current = drag else { return }
        let id = current.id
        current.translation = value.translation.width
        // Karar SINIRLANMAMIŞ konumla: görsel konum grup sınırında durur ama
        // uçtaki komşunun ortası tam sınırda; sınırlanmış merkez onu hiç
        // geçemiyordu, en sola / en sağa yer değiştirilemiyordu (kullanıcı
        // bildirimi; kayıtlarla doğrulandı: merkez 227, uçtaki orta 227,5).
        let center = Double(current.originMinX + current.translation + current.width / 2)
        if let target = appState.tabs.reorderTarget(for: id, center: center, midX: frames.mapValues { Double($0.midX) }),
           let from = appState.openTabs.firstIndex(of: id),
           let to = appState.openTabs.firstIndex(of: target) {
            // Yeni yerleşim konumu, geçilen sekmelerin genişliği kadar: ötelemeyle
            // aynı adımda hesaplanır, yer değiştirirken sekme titremez.
            let passed = (from < to ? appState.openTabs[(from + 1)...to] : appState.openTabs[to..<from])
                .compactMap { frames[$0]?.width }.reduce(0, +)
            current.layoutMinX += from < to ? passed : -passed
            drag = current
            withAnimation(.easeInOut(duration: 0.12)) {
                appState.moveTab(id, before: target)
            }
        } else {
            drag = current
        }
    }

    /// Bitiş ya da iptal (iki yoldan da gelebilir; ikincisi bir şey yapmaz).
    private func dragEnded() {
        guard let id = drag?.id else { return }
        // Bilinçli yerleştirilen önizleme sekmesi artık kalıcıdır.
        appState.keepTab(id)
        withAnimation(.easeOut(duration: 0.12)) { drag = nil }
    }
}

private struct RequestTab: View {
    @Environment(AppState.self) private var appState
    /// Sekmenin gösterdiği kadarı. İsteğin TAMAMI (gövde, header, kayıtlı
    /// örnekler) verilmez: SwiftUI her güncellemede görünüm girdilerini
    /// karşılaştırıyor; büyük workspace'te sürüklerken taşıma başına
    /// ~20 ms sekme çubuğuna gidiyordu (ölçüldü, 2026-10-31).
    struct Summary: Equatable {
        let id: UUID
        let method: HTTPMethod
        let name: String
    }

    /// Açık sekmelerin özeti, koleksiyonlar üzerinde tek geçişte. İstek
    /// değerleri kopyalanmaz: yalnızca kimliği açık sekmelerde olanın
    /// metodu ve adı okunur.
    static func summaries(of open: [UUID], in collections: [CollectionModel]) -> [UUID: Summary] {
        let wanted = Set(open)
        var result: [UUID: Summary] = [:]
        result.reserveCapacity(wanted.count)
        for collection in collections {
            for index in collection.requests.indices where wanted.contains(collection.requests[index].id) {
                let id = collection.requests[index].id
                result[id] = Summary(id: id, method: collection.requests[index].method, name: collection.requests[index].name)
            }
        }
        return result
    }

    let request: Summary
    let isSelected: Bool
    let isPreview: Bool
    let isPinned: Bool
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
            if isPinned {
                // Sabit sekme (VS Code gibi): çarpının yerinde iğne; basınca
                // sabitleme kalkar. Kapatma sağ tık menüsünden ya da ⌘W ile.
                if isDirty {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(Theme.warning)
                }
                Button {
                    appState.unpinTab(request.id)
                } label: {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.t("tabs.unpin"))
                .accessibilityLabel(L10n.t("tabs.unpin"))
            } else {
                closeSlot
            }
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
                appState.keepTab(request.id)
            } else {
                // Açık örneğin sekmesine basmak istek editörüne döner.
                appState.openExample = nil
                appState.selectedRequestID = request.id
            }
        }
        .help(isPreview ? L10n.t("tabs.preview.help", request.name)
              : isPinned ? L10n.t("tabs.pinned.help", request.name) : request.name)
        .contextMenu {
            if isPinned {
                Button(L10n.t("tabs.unpin")) { appState.unpinTab(request.id) }
            } else {
                Button(L10n.t("tabs.pin")) { appState.pinTab(request.id) }
            }
            if isPreview {
                Button(L10n.t("tabs.keep")) { appState.keepTab(request.id) }
            }
            Divider()
            Button(L10n.t("common.close")) { appState.closeTab(request.id) }
            Button(L10n.t("tabs.closeOthers")) { appState.closeOtherTabs(request.id) }
            Button(L10n.t("tabs.closeRight")) { appState.closeTabsToRight(of: request.id) }
        }
    }

    /// Kirli işaret ile kapat düğmesi aynı yeri paylaşır (Xcode/Safari gibi):
    /// üzerine gelince kapat düğmesine döner.
    private var closeSlot: some View {
        ZStack {
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
}

