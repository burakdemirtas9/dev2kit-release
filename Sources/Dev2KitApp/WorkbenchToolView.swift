import AppKit
import SwiftUI
import Dev2KitCore

/// Her aracın ortak ekranı: sekmeler, eylem ve seçenekler, solda girdi,
/// sağda çıktı (metin ya da ağaç), altta doğrulama durumu. Yeni araç için
/// yeni ekran yazılmaz (docs/V2.md "Mimari"). Workbench arayüzü İngilizce.
struct WorkbenchToolView: View {
    @Environment(WorkbenchState.self) private var workbench
    @StateObject private var inputSearch = EditorSearchController()
    @StateObject private var outputSearch = EditorSearchController()
    @StateObject private var inputFolding = CodeFoldingController()
    @StateObject private var outputFolding = CodeFoldingController()

    var body: some View {
        VStack(spacing: 0) {
            DocumentTabBar(
                items: workbench.documents.map { .init(id: $0.id, title: workbench.title(of: $0), hasContent: !$0.input.isEmpty) },
                selectedID: workbench.document.id,
                onSelect: { workbench.select(documentID: $0) },
                onClose: { workbench.closeDocument($0) },
                onNew: { workbench.newDocument() }
            )
            Divider()
            header
            Divider()
            HStack(spacing: 0) {
                inputPane
                Divider()
                outputPane
            }
            Divider()
            statusBar
        }
        // ⌘F: odaktaki bölmede (son tıklanan editör) arama.
        .onChange(of: workbench.searchRequest) {
            if workbench.focusedPane == .output, !workbench.showsTree {
                if !workbench.outputHiddenFromEditor { outputSearch.open() }
            } else if !workbench.inputHiddenFromEditor {
                inputSearch.open()
            }
        }
        .onChange(of: workbench.document.id) {
            inputSearch.close()
            outputSearch.close()
        }
        .onChange(of: workbench.inputHiddenFromEditor) { if workbench.inputHiddenFromEditor { inputSearch.close() } }
        .onChange(of: workbench.outputHiddenFromEditor) { if workbench.outputHiddenFromEditor { outputSearch.close() } }
    }

    // MARK: Üst çubuk

    private var header: some View {
        let tool = workbench.tool
        let action = workbench.action
        return HStack(spacing: 12) {
            if tool.actions.count > 1 {
                Picker("Action", selection: Binding(
                    get: { action.id },
                    set: { workbench.select(actionID: $0) }
                )) {
                    ForEach(tool.actions) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if action.usesIndentation {
                Picker("Indent", selection: Binding(
                    get: { workbench.options.indentation },
                    set: { var options = workbench.options; options.indentation = $0; workbench.update(options: options) }
                )) {
                    ForEach(Indentation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .help("Indentation")
            }
            if action.usesKeywordCase {
                Toggle("Uppercase keywords", isOn: Binding(
                    get: { workbench.options.uppercaseKeywords },
                    set: { var options = workbench.options; options.uppercaseKeywords = $0; workbench.update(options: options) }
                ))
                .help("Write SQL keywords (SELECT, FROM…) in upper case")
            }
            if action.usesSortKeys {
                Toggle("Sort keys", isOn: Binding(
                    get: { workbench.options.sortKeys },
                    set: { var options = workbench.options; options.sortKeys = $0; workbench.update(options: options) }
                ))
                .help("Sort object keys alphabetically at every level. Comments are dropped when sorting.")
            }
            if action.usesDelimiter {
                Picker("Delimiter", selection: Binding(
                    get: { workbench.options.csvDelimiter },
                    set: { var options = workbench.options; options.csvDelimiter = $0; workbench.update(options: options) }
                )) {
                    ForEach(CSVDelimiter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .help("Semicolon is what Excel expects in Turkish and most European locales")
            }
            if action.usesRootName {
                HStack(spacing: 6) {
                    Text("Root").foregroundStyle(.secondary)
                    TextField(XMLConverter.defaultRootName, text: Binding(
                        get: { workbench.options.xmlRootName },
                        set: { var options = workbench.options; options.xmlRootName = $0; workbench.update(options: options) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                }
                .help("Name of the root element. Invalid XML names are made safe.")
            }
            if action.usesDetectTypes {
                Toggle("Detect types", isOn: Binding(
                    get: { workbench.options.detectTypes },
                    set: { var options = workbench.options; options.detectTypes = $0; workbench.update(options: options) }
                ))
                .help("Write 12 as a number, true/false as booleans and empty cells as null. Leading zeros (012) and numbers over 15 digits stay text.")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Girdi

    private var inputPane: some View {
        let issueOffset: Int? = {
            if case .invalid(let issue) = workbench.validation { return issue.offset }
            return nil
        }()
        let canUndo = workbench.clearedInput?.documentID == workbench.document.id
        return VStack(spacing: 0) {
            paneHeader("Input", stats: workbench.inputStats) {
                if canUndo {
                    Button("Undo Clear") { workbench.undoClear() }
                        .controlSize(.small)
                        .help("Restore the cleared input")
                }
                // Editör yokken (gizli girdi) arayacak/katlayacak bir şey yok.
                if !workbench.inputHiddenFromEditor {
                    FoldButtons(folding: inputFolding, english: true)
                    SearchToggleButton(search: inputSearch, strings: .english)
                }
                Button {
                    workbench.clearInput()
                } label: {
                    Image(systemName: "xmark.circle").iconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(workbench.input.isEmpty)
                .help("Clear input (can be undone for a few seconds)")
                .accessibilityLabel("Clear input")
            }
            if inputSearch.isPresented {
                EditorSearchBar(search: inputSearch, strings: .english)
            }
            if workbench.inputHiddenFromEditor {
                OversizedTextNotice(
                    title: "Input not shown: \(TextStats.size(workbench.inputStats.bytes))",
                    detail: oversizedDetail(limit: WorkbenchLimits.maxInputBytes) + " The input is kept and the tools work on it: run an action (e.g. Format) and use its output."
                ) {
                    CopyButton(text: workbench.input, help: "Copy input")
                    Button("Clear") { workbench.clearInput() }.controlSize(.small)
                }
            } else {
                CodeEditor(
                    text: Binding(get: { workbench.input }, set: { workbench.input = $0 }),
                    language: workbench.highlightsSyntax ? CodeLanguage(workbench.tool.syntax) : .plain,
                    folding: CodeLanguage(workbench.tool.syntax).supportsFolding ? inputFolding : nil,
                    search: inputSearch,
                    errorOffset: issueOffset,
                    onFocus: { workbench.focus(.input) },
                    limits: EditorLimits(
                        onRejected: { workbench.reportLimit($0) },
                        onLongLine: { workbench.acceptInputHiddenFromEditor($0) }
                    )
                )
                .id(workbench.document.id)
                .overlay {
                    if workbench.input.isEmpty {
                        Text("Paste content here. Input stays in memory only; it is never written to disk or history.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(40)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func oversizedDetail(limit: Int) -> String {
        "Text over \(TextStats.size(limit)) or with a line longer than \(TextStats.size(WorkbenchLimits.maxEditorLineBytes)) (minified JSON is one line) would freeze dev2kit in the editor."
    }

    // MARK: Çıktı

    private var outputPane: some View {
        let showsTree = workbench.showsTree
        let outputSyntax = workbench.action.outputSyntax ?? workbench.tool.syntax
        return VStack(spacing: 0) {
            paneHeader(showsTree ? "Tree" : "Output", stats: showsTree ? .empty : workbench.outputStats) {
                if workbench.action.supportsTree {
                    Picker("View", selection: Binding(
                        get: { workbench.document.outputMode },
                        set: { workbench.select(outputMode: $0) }
                    )) {
                        ForEach(WorkbenchState.OutputMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .help("Show the output as text or as a tree of the input")
                }
                if !showsTree {
                    if !workbench.outputHiddenFromEditor {
                        FoldButtons(folding: outputFolding, english: true)
                        SearchToggleButton(search: outputSearch, strings: .english)
                    }
                    Button {
                        workbench.toggleOutputEditing()
                    } label: {
                        Image(systemName: workbench.isEditingOutput ? "pencil.circle.fill" : "pencil").iconHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(workbench.isEditingOutput ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .disabled(workbench.displayedOutput.isEmpty || workbench.outputHiddenFromEditor)
                    .help(workbench.isEditingOutput
                          ? "Stop editing. Edits are replaced when the input or options change."
                          : "Edit output")
                    .accessibilityLabel("Edit output")
                    Button {
                        workbench.useOutputAsInput()
                    } label: {
                        Image(systemName: "arrow.uturn.left").iconHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(workbench.displayedOutput.isEmpty)
                    .help("Use output as input (chain another action)")
                    .accessibilityLabel("Use output as input")
                    CopyButton(text: workbench.displayedOutput, help: "Copy output")
                }
            }
            if !showsTree, outputSearch.isPresented {
                EditorSearchBar(search: outputSearch, strings: .english)
            }
            Group {
                if showsTree {
                    if let tree = workbench.tree {
                        JSONTreeView(root: tree) { steps, text in
                            workbench.editTreeValue(at: steps, text: text)
                        }
                    } else {
                        placeholder(workbench.input.isEmpty ? "" : "The input must be valid JSON to show a tree.")
                    }
                } else if let issue = workbench.actionIssue, workbench.displayedOutput.isEmpty {
                    placeholder(issue.localizedDescription, isError: true)
                } else if workbench.outputHiddenFromEditor {
                    OversizedTextNotice(
                        title: "Output not shown: \(TextStats.size(workbench.outputStats.bytes))",
                        detail: oversizedDetail(limit: WorkbenchLimits.maxOutputBytes) + " Copy it, or pick an action with multi-line output (e.g. Format)."
                    ) {
                        CopyButton(text: workbench.output, help: "Copy output")
                    }
                } else {
                    CodeEditor(
                        text: Binding(get: { workbench.displayedOutput }, set: { workbench.editOutput($0) }),
                        language: workbench.outputStats.bytes <= WorkbenchState.highlightLimit ? CodeLanguage(outputSyntax) : .plain,
                        isEditable: workbench.isEditingOutput,
                        folding: CodeLanguage(outputSyntax).supportsFolding ? outputFolding : nil,
                        search: outputSearch,
                        onFocus: { workbench.focus(.output) },
                        limits: EditorLimits(
                            maxDisplayBytes: WorkbenchLimits.maxOutputBytes,
                            onRejected: { workbench.reportLimit($0) },
                            onLongLine: { _ in workbench.reportLimit(WorkbenchLimits.longLineEditMessage) }
                        )
                    )
                    // Katlama editör kurulurken bağlanır: çıktının dili eylemle
                    // değişince (Escape → düz metin) editör yeniden kurulmalı.
                    .id("\(workbench.document.id)-\(outputSyntax)")
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    private func placeholder(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(isError ? AnyShapeStyle(Theme.down) : AnyShapeStyle(.secondary))
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paneHeader<Trailing: View>(_ title: String, stats: TextStats, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.secondaryText.weight(.semibold)).foregroundStyle(.secondary)
            Text(stats.summary)
                .font(.tinyText.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    // MARK: Durum

    private var statusBar: some View {
        HStack(spacing: 8) {
            validationLabel
            Spacer(minLength: 0)
            if let notice = workbench.limitNotice {
                Label(notice, systemImage: "exclamationmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .lineLimit(1)
                    .help(notice)
            }
            if workbench.saveNotice {
                Label("Kept in memory only — cleared when dev2kit quits. Nothing is written to disk.", systemImage: "memorychip")
                    .font(.secondaryText)
                    .foregroundStyle(.secondary)
            }
            if workbench.isRunning {
                ProgressView().controlSize(.small)
            }
            if workbench.isLargeInput {
                Text("Large input: not run automatically").font(.secondaryText).foregroundStyle(.secondary)
                Button("Run") { workbench.runNow() }
                    .controlSize(.small)
                    .disabled(!workbench.isStale)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
    }

    @ViewBuilder
    private var validationLabel: some View {
        switch workbench.validation {
        case .empty:
            Text(" ").font(.secondaryText)
        case .valid:
            Label("Valid \(workbench.tool.inputName)", systemImage: "checkmark.circle.fill")
                .font(.secondaryText)
                .foregroundStyle(Theme.up)
        case .structurallyValid:
            Label("Structure OK (full syntax not checked)", systemImage: "checkmark.circle")
                .font(.secondaryText)
                .foregroundStyle(.secondary)
        case .invalid(let issue):
            Label(issue.localizedDescription, systemImage: "exclamationmark.octagon.fill")
                .font(.secondaryText)
                .foregroundStyle(Theme.down)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

/// Açık belgelerin sekmeleri (araç ekranı ve Diff Checker ortak). API Client
/// sekme çubuğunun görsel dili (seçili sekmede editör zemini + üstte vurgu
/// çizgisi), daha sade. İçi dolu sekme kapatılırken onay ister: içerik
/// yalnızca bellekte, kapanınca gider.
struct DocumentTabBar: View {
    struct Item: Identifiable {
        let id: UUID
        let title: String
        let hasContent: Bool
    }

    let items: [Item]
    let selectedID: UUID
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: () -> Void
    @State private var pendingClose: Item?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        WorkbenchTab(
                            title: item.title,
                            isSelected: item.id == selectedID,
                            onSelect: { onSelect(item.id) },
                            onClose: { if item.hasContent { pendingClose = item } else { onClose(item.id) } }
                        )
                    }
                }
            }
            Button(action: onNew) {
                Image(systemName: "plus").iconHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .help("New tab")
            .accessibilityLabel("New tab")
        }
        .frame(height: 30)
        .background(.bar)
        .confirmationDialog(
            "Close \"\(pendingClose?.title ?? "")\"?",
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
            titleVisibility: .visible
        ) {
            Button("Close Tab", role: .destructive) {
                if let item = pendingClose { onClose(item.id) }
                pendingClose = nil
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: {
            Text("Its content is kept in memory only and will be lost.")
        }
    }
}

private struct WorkbenchTab: View {
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.callout).lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || isSelected ? 1 : 0)
            .help("Close tab")
            .accessibilityLabel("Close \(title)")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(isSelected ? Theme.editorBackground : (hovering ? Color.primary.opacity(0.05) : .clear),
                    ignoresSafeAreaEdges: [])
        .overlay(alignment: .top) {
            if isSelected { Rectangle().fill(Theme.accent).frame(height: 2) }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Panoya kopyalar; kısa süre "kopyalandı" işareti gösterir. Pano yalnızca
/// kullanıcı basınca yazılır (README: pano kuralı).
struct CopyButton: View {
    let text: String
    var help = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").iconHitTarget()
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? AnyShapeStyle(Theme.up) : AnyShapeStyle(.secondary))
        .disabled(text.isEmpty)
        .help(help)
        .accessibilityLabel(help)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// JSON ağacı: açık dalları kendisi takip eden düz liste.
///
/// `OutlineGroup` dalları koddan açıp kapatmaya izin vermiyor ("tümünü aç/
/// kapat" yapılamıyordu); burada görünen satırlar Core'da hesaplanır
/// (`visibleRows`), kapalı dalların düğümleri hiç oluşmaz. Açık dallar ve
/// seçim yol kimliğiyle tutulur: girdi değişip ağaç yeniden kurulsa da
/// yerinde kalır.
///
/// Satırlara tıklama hareketi BAĞLANMAZ (UI-KURALLARI §2c): seçim listenin
/// kendi seçimi, açma/kapama ok düğmesiyle; kalem ve kopyala satır sonunda,
/// yol sağ tıkta ve breadcrumb'da.
struct JSONTreeView: View {
    let root: JSONTreeNode
    /// Düzenlenen yaprak değer; hata metni döner (satırda gösterilir).
    let onEdit: ([JSONPathStep], String) -> String?

    @State private var expanded: Set<String> = []
    @State private var selection: String?
    @State private var limitNotice = false

    var body: some View {
        let rows = root.visibleRows(expanded: expanded)
        let selectedNode = rows.first { $0.id == selection }?.node
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                treeBar(selected: selectedNode, proxy: proxy)
                Divider()
                List(selection: $selection) {
                    ForEach(rows) { row in
                        HStack(spacing: 4) {
                            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
                            if row.node.isExpandable {
                                Button {
                                    toggle(row.node.id)
                                } label: {
                                    Image(systemName: expanded.contains(row.node.id) ? "chevron.down" : "chevron.right")
                                        .font(.tinyText.weight(.semibold))
                                        .frame(width: 14)
                                        .iconHitTarget(18)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(expanded.contains(row.node.id) ? "Collapse" : "Expand")
                            } else {
                                Color.clear.frame(width: 18, height: 1)
                            }
                            JSONTreeRow(node: row.node, onEdit: onEdit)
                        }
                        .tag(row.id)
                        .id(row.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    /// Üst şerit: seçili düğümün yolu (breadcrumb) ve tümünü kapat/aç.
    private func treeBar(selected: JSONTreeNode?, proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    Button("root") {
                        selection = nil
                        if let first = root.children?.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    if let selected {
                        let trail = root.ancestry(to: selected)
                        ForEach(trail, id: \.id) { node in
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                            Button(node.label) {
                                // Üst düğüme git: görünür olsun diye yolu açık tut.
                                for ancestor in root.ancestry(to: node).dropLast() { expanded.insert(ancestor.id) }
                                selection = node.id
                                proxy.scrollTo(node.id, anchor: .center)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(node.id == selected.id ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .help(node.path)
                        }
                    }
                }
                .font(.secondaryMono)
            }
            if let selected, !selected.path.isEmpty {
                CopyButton(text: selected.path, help: "Copy path: \(selected.path)")
            }
            if limitNotice {
                Text("Expanded first \(JSONTreeNode.expandAllLimit) branches")
                    .font(.tinyText)
                    .foregroundStyle(.secondary)
            }
            Button {
                expanded.removeAll()
                limitNotice = false
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left").iconHitTarget(20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(expanded.isEmpty)
            .help("Collapse all")
            .accessibilityLabel("Collapse all")
            Button {
                let result = root.expandableIDs()
                expanded = result.ids
                limitNotice = result.truncated
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").iconHitTarget(20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!(root.children ?? []).contains(where: \.isExpandable))
            .help("Expand all (up to \(JSONTreeNode.expandAllLimit) branches)")
            .accessibilityLabel("Expand all")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Metin değeri tırnaksız ham haliyle (token'ı kopyalayan kullanıcı
    /// tırnakları silmek zorunda kalmasın); nesne/dizi sıkıştırılmış JSON.
    static func copyValue(_ node: JSONTreeNode) -> String {
        if case .string(let text) = node.value { return text }
        return node.value.compact()
    }
}

private struct JSONTreeRow: View {
    let node: JSONTreeNode
    let onEdit: ([JSONPathStep], String) -> String?
    @State private var isEditing = false
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if !node.label.isEmpty {
                Text(node.label)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Color(nsColor: Theme.syntaxKey))
            }
            if isEditing {
                TextField("Value", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { cancel() }
                if let error {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(Theme.down)
                        .help(error)
                }
                Button("Save", action: commit).controlSize(.small)
                Button("Cancel", action: cancel).controlSize(.small)
            } else {
                Text(node.summary)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(summaryStyle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if node.isEditableLeaf {
                    Button {
                        draft = node.editableText
                        error = nil
                        isEditing = true
                        focused = true
                    } label: {
                        Image(systemName: "pencil").iconHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Edit value (⏎ saves, Esc cancels)")
                    .accessibilityLabel("Edit value")
                }
                if node.hiddenSiblings == 0 {
                    CopyButton(text: JSONTreeView.copyValue(node), help: "Copy value")
                }
            }
        }
        .help(node.path)
        .contextMenu {
            if node.hiddenSiblings == 0 {
                Button("Copy Value") { copy(JSONTreeView.copyValue(node)) }
                if !node.path.isEmpty {
                    Button("Copy Path (\(node.path))") { copy(node.path) }
                }
            }
        }
    }

    private func commit() {
        if let message = onEdit(node.steps, draft) {
            error = message
        } else {
            isEditing = false
        }
    }

    private func cancel() {
        isEditing = false
        error = nil
    }

    private var summaryStyle: AnyShapeStyle {
        switch node.value {
        case .string: return AnyShapeStyle(Color(nsColor: Theme.syntaxString))
        case .number: return AnyShapeStyle(Color(nsColor: Theme.syntaxNumber))
        case .bool, .null: return AnyShapeStyle(Color(nsColor: Theme.syntaxKeyword))
        case .object, .array: return AnyShapeStyle(.tertiary)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Editörde gösterilemeyen metin (`WorkbenchLimits`): editör yerine açıklama
/// ve eylemler. Workbench girdi/çıktı bölmeleri ve Diff Checker ortak.
struct OversizedTextNotice<Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.warning)
            Text(detail)
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions() }
        }
        .padding(24)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
