import SwiftUI
import Dev2KitCore

/// Workbench modu: solda araç listesi, sağda açık araç.
struct WorkbenchView: View {
    @Environment(WorkbenchState.self) private var workbench
    /// Araç listesinin genişliği: logo iki modda da aynı yerde, liste de
    /// onun genişliğinde (`AppState.sidebarMinimumWidth`, ContentView verir).
    var sidebarWidth: CGFloat = SidebarSizing.baseMinimum

    var body: some View {
        HStack(spacing: 0) {
            WorkbenchSidebar()
                .frame(width: sidebarWidth)
            Divider()
            if workbench.showsDiffChecker {
                DiffCheckerView()
            } else {
                WorkbenchToolView()
            }
        }
        // API Client'tan Workbench'e geçince imleç girdide olsun.
        .onAppear { workbench.requestInputFocus() }
        // Hesaplanmış mesajlar (doğrulama, özet) seçili dilde kalsın.
        .onChange(of: Localizer.shared.language) { workbench.languageChanged() }
    }
}

/// Kategoriye göre gruplu araç listesi ve arama.
struct WorkbenchSidebar: View {
    @Environment(WorkbenchState.self) private var workbench
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var state = workbench
        let tools = WorkbenchCatalog.matching(workbench.searchQuery)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
                TextField(L10n.t("wb.searchTools"), text: $state.searchQuery)
                    .inputLimit(.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                // ⌘K ipucu: arama kutusuna kısayolla gidilir.
                Text("⌘K")
                    .font(.tinyMono)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                    .opacity(workbench.searchQuery.isEmpty ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .inputChrome(isFocused: searchFocused)
            .padding(8)
            .background {
                // Görünmez düğme: ⌘K arama kutusuna odaklar.
                Button("") { searchFocused = true }
                    // API Client açıkken (Workbench gizli ama canlı) ⌘K burayı odaklamasın.
                    .keyboardShortcut(KeyboardShortcut("k", modifiers: .command), onlyIn: .workbench)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            Divider()
            List(selection: Binding(
                get: { workbench.selectedToolID },
                set: { if let id = $0 { workbench.select(toolID: id) } }
            )) {
                if tools.isEmpty, !WorkbenchCatalog.diffCheckerMatches(workbench.searchQuery) {
                    Text(L10n.t("wb.noToolsMatch", workbench.searchQuery))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(WorkbenchTool.Category.allCases, id: \.self) { category in
                    let inCategory = tools.filter { $0.category == category }
                    if category == .compare, WorkbenchCatalog.diffCheckerMatches(workbench.searchQuery) {
                        Section {
                            ToolLabel(title: "Diff Checker", symbol: "arrow.left.arrow.right.square")
                                .tag(WorkbenchCatalog.diffCheckerID)
                        } header: {
                            SectionTitle(category.title)
                        }
                    } else if !inCategory.isEmpty {
                        Section {
                            ForEach(inCategory) { tool in
                                ToolLabel(title: tool.title, symbol: tool.symbol)
                                    .tag(tool.id)
                            }
                        } header: {
                            SectionTitle(category.title)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // Sıkı satırlar (önerideki ~28 pt): sistemin küçük kenar çubuğu
            // boyutu; özel çizim yok.
            .environment(\.sidebarRowSize, .small)
            Divider()
            localBadge
        }
    }

    /// Güvenlik durumu görünür (TASARIM §1.3): Workbench araçları ağa çıkmaz,
    /// girdi yalnızca bellekte. ("Offline Mode" değil: API Client ağa çıkıyor.)
    private var localBadge: some View {
        HStack(spacing: 6) {
            Text(L10n.t("wb.localOnly"))
                .font(.secondaryMono)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Circle().fill(Theme.up).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .help(L10n.t("wb.localOnly.help"))
        .accessibilityElement(children: .combine)
    }
}

/// Bölüm başlığı: 10,5 pt, büyük harf, aralıklı, eş aralıklı (vurgu
/// tipografiyle, TASARIM §1.4).
private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
    }
}

/// Araç satırı. Simge rengi açıkça veriliyor: kenar çubuğu listesi simgeleri
/// sistem vurgu rengiyle (mavi) boyuyor, uygulamanın `.tint`'ini dikkate
/// almıyordu; uygulama genelinde vurgu mor (docs/TASARIM.md §2).
private struct ToolLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.purple)
        }
    }
}

extension WorkbenchTool {
    /// Listedeki simge. Görünüm olduğu için Core'da değil burada.
    var symbol: String {
        switch id {
        case "json": return "curlybraces"
        case "xml": return "chevron.left.forwardslash.chevron.right"
        case "html": return "globe"
        case "css": return "paintbrush"
        case "sql": return "cylinder.split.1x2"
        case "markdown": return "text.document"
        case "jwt": return "key.horizontal"
        case "base64": return "b.square"
        case "url-encode": return "link"
        case "timestamp": return "clock"
        case "uuid": return "number"
        case "hash": return "checkmark.seal"
        case "hex": return "number.square"
        case "yaml-to-properties": return "list.bullet.indent"
        case "properties-to-yaml": return "list.bullet.rectangle"
        case "json-to-java": return "cup.and.saucer"
        case "json-to-kotlin": return "k.square"
        case "json-to-swift": return "swift"
        case "json-to-ts-interface", "json-to-ts-type": return "t.square"
        case "json-to-python": return "p.square"
        case "jsonpath": return "text.magnifyingglass"
        default:
            switch category {
            case .format: return "text.alignleft"
            case .encode: return "lock.rotation"
            case .convert: return "arrow.left.arrow.right"
            case .objects: return "shippingbox"
            case .compare: return "arrow.left.arrow.right.square"
            case .preview: return "eye"
            case .others: return "ellipsis.circle"
            }
        }
    }
}
