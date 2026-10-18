import SwiftUI
import Dev2KitCore

/// Workbench modu: solda araç listesi, sağda açık araç.
struct WorkbenchView: View {
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        HStack(spacing: 0) {
            WorkbenchSidebar()
                .frame(width: 220)
            Divider()
            if workbench.showsDiffChecker {
                DiffCheckerView()
            } else {
                WorkbenchToolView()
            }
        }
    }
}

/// Kategoriye göre gruplu araç listesi ve arama.
struct WorkbenchSidebar: View {
    @Environment(WorkbenchState.self) private var workbench

    var body: some View {
        @Bindable var state = workbench
        let tools = WorkbenchCatalog.matching(workbench.searchQuery)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search tools", text: $state.searchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            List(selection: Binding(
                get: { workbench.selectedToolID },
                set: { if let id = $0 { workbench.select(toolID: id) } }
            )) {
                if tools.isEmpty, !WorkbenchCatalog.diffCheckerMatches(workbench.searchQuery) {
                    Text("No tools match \"\(workbench.searchQuery)\"")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(WorkbenchTool.Category.allCases, id: \.self) { category in
                    let inCategory = tools.filter { $0.category == category }
                    if category == .compare, WorkbenchCatalog.diffCheckerMatches(workbench.searchQuery) {
                        Section(category.title) {
                            ToolLabel(title: "Diff Checker", symbol: "arrow.left.arrow.right.square")
                                .tag(WorkbenchCatalog.diffCheckerID)
                        }
                    } else if !inCategory.isEmpty {
                        Section(category.title) {
                            ForEach(inCategory) { tool in
                                ToolLabel(title: tool.title, symbol: tool.symbol)
                                    .tag(tool.id)
                            }
                        }
                    }
                }
            }
        }
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
        default:
            switch category {
            case .format: return "text.alignleft"
            case .encode: return "lock.rotation"
            case .convert: return "arrow.left.arrow.right"
            case .compare: return "arrow.left.arrow.right.square"
            case .preview: return "eye"
            }
        }
    }
}
