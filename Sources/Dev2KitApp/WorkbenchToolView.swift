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
            // Sekmeler yalnızca JSON'da (kullanıcı kararı, 2026-10-19).
            if workbench.tool.supportsTabs {
                DocumentTabBar(
                    items: workbench.documents.map { .init(id: $0.id, title: workbench.title(of: $0), hasContent: !$0.input.isEmpty) },
                    selectedID: workbench.document.id,
                    onSelect: { workbench.select(documentID: $0) },
                    onClose: { workbench.closeDocument($0) },
                    onNew: { workbench.newDocument() }
                )
                Divider()
            }
            header
            Divider()
            // Sorgulu araç (JSONPath): girdi → sorgu → sonuç hiyerarşisi;
            // sorgu iki bölmenin üstünde, tam genişlikte.
            if workbench.action.usesQuery {
                queryBar
                Divider()
            }
            // Sürüklenebilir ayırıcı: girdi/çıktı genişliğini kullanıcı ayarlar.
            // Durum bilgisi tek çubuk yerine her bölmenin alt bilgisinde.
            SplitPanes(minFirst: 260, minSecond: 260, dividerBackground: Theme.editorBackground) {
                inputPane
            } second: {
                outputPane
            }
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
            if tool.actions.count > 4 {
                // Çok eylemli araç (hash: 6 algoritma): segmentler sığmıyor.
                Picker(L10n.t("wb.algorithm"), selection: Binding(
                    get: { action.id },
                    set: { workbench.select(actionID: $0) }
                )) {
                    ForEach(tool.actions) { Text($0.title).tag($0.id) }
                }
                .fixedSize()
            } else if tool.actions.count > 1 {
                Picker(L10n.t("wb.action"), selection: Binding(
                    get: { action.id },
                    set: { workbench.select(actionID: $0) }
                )) {
                    ForEach(tool.actions) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if tool.actions.count > 1, action.hasOptions {
                Divider().frame(height: 16)
            }
            if action.usesIndentation {
                Picker(L10n.t("wb.indent"), selection: Binding(
                    get: { workbench.options.indentation },
                    set: { var options = workbench.options; options.indentation = $0; workbench.update(options: options) }
                )) {
                    ForEach(Indentation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .help(L10n.t("wb.indent.help"))
            }
            if action.usesKeywordCase {
                Toggle(L10n.t("wb.uppercase"), isOn: Binding(
                    get: { workbench.options.uppercaseKeywords },
                    set: { var options = workbench.options; options.uppercaseKeywords = $0; workbench.update(options: options) }
                ))
                .help(L10n.t("wb.uppercase.help"))
            }
            if action.usesSortKeys {
                Toggle(L10n.t("wb.sortKeys"), isOn: Binding(
                    get: { workbench.options.sortKeys },
                    set: { var options = workbench.options; options.sortKeys = $0; workbench.update(options: options) }
                ))
                .help(L10n.t("wb.sortKeys.help"))
            }
            if action.usesDelimiter {
                Picker(L10n.t("wb.delimiter"), selection: Binding(
                    get: { workbench.options.csvDelimiter },
                    set: { var options = workbench.options; options.csvDelimiter = $0; workbench.update(options: options) }
                )) {
                    ForEach(CSVDelimiter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .help(L10n.t("wb.delimiter.help"))
            }
            if action.usesRootName {
                HStack(spacing: 6) {
                    Text(L10n.t("wb.root")).foregroundStyle(.secondary)
                    TextField(XMLConverter.defaultRootName, text: Binding(
                        get: { workbench.options.xmlRootName },
                        set: { var options = workbench.options; options.xmlRootName = $0; workbench.update(options: options) }
                    ))
                    .textFieldStyle(.input)
                    .inputLimit(.short)
                    .frame(width: 120)
                }
                .help(L10n.t("wb.root.help"))
            }
            if action.usesURLSafe {
                Toggle("URL-safe", isOn: optionBinding(\.base64URLSafe))
                    .help(L10n.t("wb.urlSafe.help"))
            }
            if action.usesFormEncoding {
                Toggle(L10n.t("wb.formEncoding"), isOn: optionBinding(\.formEncoding))
                    .help(L10n.t("wb.formEncoding.help"))
            }
            if action.usesCount {
                Picker(L10n.t("wb.count"), selection: optionBinding(\.generateCount)) {
                    ForEach([1, 5, 10, 50, 100, 1_000], id: \.self) { Text("\($0)").tag($0) }
                }
                .fixedSize()
                Button(L10n.t("wb.regenerate")) { workbench.runNow() }
                    .help(L10n.t("wb.regenerate.help"))
            }
            if action.usesHashOutput {
                Picker(L10n.t("wb.output"), selection: optionBinding(\.hashOutput)) {
                    ForEach(HashTool.Output.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if action.usesHMACKey {
                HStack(spacing: 6) {
                    Text(L10n.t("wb.key")).foregroundStyle(.secondary)
                    SecureField("secret", text: optionBinding(\.hmacKey))
                        .textFieldStyle(.input)
                        .inputLimit(.credential)
                        .frame(width: 160)
                }
                .help(L10n.t("wb.hmacKey.help"))
            }
            Spacer(minLength: 0)
            outputControls
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    /// Çıktıya ait kontroller üst satırın sağında (çıktı bölmesinin başlığı
    /// sadeleşir): görünüm, ara, düzenle, girdi yap, kopyala.
    @ViewBuilder
    private var outputControls: some View {
        let showsTree = workbench.showsTree
        HStack(spacing: 4) {
            if workbench.action.supportsTree {
                Picker(L10n.t("wb.view"), selection: Binding(
                    get: { workbench.document.outputMode },
                    set: { workbench.select(outputMode: $0) }
                )) {
                    ForEach(WorkbenchState.OutputMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help(L10n.t("wb.view.help"))
                .padding(.trailing, 6)
            }
            if !showsTree {
                if !workbench.outputHiddenFromEditor {
                    SearchToggleButton(search: outputSearch)
                }
                // Kalem yalnızca biçimlendiricilerde (kullanıcı kararı, 2026-10-20).
                if workbench.tool.allowsOutputEditing {
                    Button {
                        workbench.toggleOutputEditing()
                    } label: {
                        Image(systemName: workbench.isEditingOutput ? "pencil.circle.fill" : "pencil").iconHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(workbench.isEditingOutput ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    .disabled(workbench.displayedOutput.isEmpty || workbench.outputHiddenFromEditor)
                    .help(workbench.isEditingOutput
                          ? L10n.t("wb.stopEditing")
                          : L10n.t("wb.editOutput"))
                    .accessibilityLabel(L10n.t("wb.editOutput"))
                }
                Button {
                    workbench.useOutputAsInput()
                } label: {
                    Image(systemName: "arrow.uturn.left").iconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(workbench.displayedOutput.isEmpty)
                .help(L10n.t("wb.useAsInput.help"))
                .accessibilityLabel(L10n.t("wb.useAsInput"))
                CopyButton(text: workbench.displayedOutput, help: L10n.t("wb.copyOutput"))
            }
        }
    }

    // MARK: Sorgu satırı

    /// Sorgu hatası mı (girdi JSON hatası değil): girdi hataları konumlu gelir.
    private var queryIssue: WorkbenchIssue? {
        guard let issue = workbench.actionIssue, issue.offset == nil else { return nil }
        return issue
    }

    private var queryBar: some View {
        HStack(spacing: 8) {
            Text(L10n.t("wb.query"))
                .font(.secondaryText.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("$.store.book[?@.price < 10].title", text: Binding(
                get: { workbench.options.query },
                set: { workbench.update(query: $0) }
            ))
            .textFieldStyle(.input)
            .font(.system(.body, design: .monospaced))
            .inputLimit(.headerValue)
            .onSubmit { workbench.runNow() }
            .accessibilityLabel(L10n.t("wb.query.accessibility"))
            queryStatus
                .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .help(L10n.t("wb.query.help"))
    }

    /// Sorgunun durumu: çalışıyor, hata (kırmızı) ya da eşleşme sayısı (nötr).
    @ViewBuilder
    private var queryStatus: some View {
        if workbench.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.t("wb.running"))
            }
            .font(.secondaryText)
            .foregroundStyle(.secondary)
        } else if queryIssue != nil {
            Label(L10n.t("wb.queryError"), systemImage: MessageKind.error.symbol)
                .font(.secondaryText)
                .foregroundStyle(Theme.down)
        } else if let summary = workbench.outputSummary {
            Text(summary)
                .font(.secondaryText.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Tek seçeneğe bağlama: değişince araç yeniden çalışır.
    private func optionBinding<Value>(_ keyPath: WritableKeyPath<WorkbenchOptions, Value>) -> Binding<Value> {
        Binding(
            get: { workbench.options[keyPath: keyPath] },
            set: { var options = workbench.options; options[keyPath: keyPath] = $0; workbench.update(options: options) }
        )
    }

    // MARK: Girdi

    private var inputPane: some View {
        let issueOffset: Int? = {
            if case .invalid(let issue) = workbench.validation { return issue.offset }
            return nil
        }()
        let canUndo = workbench.clearedInput?.documentID == workbench.document.id
        return VStack(spacing: 0) {
            paneHeader(L10n.t("wb.input")) {
                // Boş girdide örneği gerçekten yükler (soluk ipucu yalnızca gösterir).
                if workbench.input.isEmpty, !workbench.tool.sampleInput.isEmpty {
                    Button(L10n.t("wb.loadSample")) { workbench.loadSample() }
                        .controlSize(.small)
                        .help(L10n.t("wb.loadSample.help"))
                }
                if workbench.tool.inputFormatter != nil {
                    Button {
                        workbench.formatInput()
                    } label: {
                        Image(systemName: "text.alignleft").iconHitTarget()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(workbench.input.isEmpty || workbench.inputHiddenFromEditor)
                    .help(L10n.t("wb.formatInput.help"))
                    .accessibilityLabel(L10n.t("wb.formatInput"))
                }
                if canUndo {
                    Button(L10n.t("wb.undoClear")) { workbench.undoClear() }
                        .controlSize(.small)
                        .help(L10n.t("wb.undoClear.help"))
                }
                // Editör yokken (gizli girdi) arayacak/katlayacak bir şey yok.
                if !workbench.inputHiddenFromEditor {
                    FoldButtons(folding: inputFolding)
                    SearchToggleButton(search: inputSearch)
                }
                Button {
                    workbench.clearInput()
                } label: {
                    Image(systemName: "xmark.circle").iconHitTarget()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(workbench.input.isEmpty)
                .help(L10n.t("wb.clearInput.help"))
                .accessibilityLabel(L10n.t("wb.clearInput"))
            }
            if inputSearch.isPresented {
                EditorSearchBar(search: inputSearch, mode: .workbench)
            }
            if workbench.inputHiddenFromEditor {
                OversizedTextNotice(
                    title: L10n.t("wb.inputHidden.title", TextStats.size(workbench.inputStats.bytes)),
                    detail: oversizedDetail(limit: WorkbenchLimits.maxInputBytes) + L10n.t("wb.inputHidden.detail")
                ) {
                    CopyButton(text: workbench.input, help: L10n.t("wb.copyInput"))
                    Button(L10n.t("common.clear")) { workbench.clearInput() }.controlSize(.small)
                }
            } else {
                CodeEditor(
                    text: Binding(get: { workbench.input }, set: { workbench.input = $0 }),
                    language: workbench.highlightsSyntax ? CodeLanguage(workbench.tool.syntax) : .plain,
                    // Her dilde: satır numaraları da bununla geliyor (SQL'de
                    // yoktu). Katlamayan dil boş bölge döndürür, oklar çıkmaz.
                    folding: inputFolding,
                    search: inputSearch,
                    errorOffset: issueOffset,
                    onFocus: { workbench.focus(.input) },
                    limits: EditorLimits(
                        onRejected: { workbench.reportLimit($0.localized) },
                        onLongLine: { workbench.acceptInputHiddenFromEditor($0) }
                    ),
                    onCursorChange: { workbench.updateInputCursor(line: $0, column: $1) },
                    focusRequest: workbench.inputFocusRequest
                )
                .id(workbench.document.id)
                .overlay(alignment: .topLeading) {
                    if workbench.input.isEmpty {
                        SampleInputHint(
                            sample: workbench.tool.sampleInput,
                            note: L10n.t("wb.input.note"),
                            leading: inputFolding.gutterWidth
                        )
                    }
                }
            }
            paneFooter { inputFooterLeading } trailing: {
                Text(workbench.inputStats.summary)
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.editorBackground)
    }

    /// Girdi alt bilgisinin solu: sınır uyarısı > ⌘S notu > imleç konumu.
    @ViewBuilder
    private var inputFooterLeading: some View {
        if let notice = workbench.limitNotice {
            Label(notice, systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(Theme.down)
                .help(notice)
        } else if workbench.saveNotice {
            Label(L10n.t("wb.memoryOnly"), systemImage: "memorychip")
        } else if let cursor = workbench.inputCursor, !workbench.input.isEmpty {
            Text(L10n.t("editor.cursor", L10n.number(cursor.line), L10n.number(cursor.column)))
        }
    }

    private func oversizedDetail(limit: Int) -> String {
        L10n.t("wb.oversized", TextStats.size(limit), TextStats.size(WorkbenchLimits.maxEditorLineBytes))
    }

    // MARK: Çıktı

    private var outputPane: some View {
        let showsTree = workbench.showsTree
        let outputSyntax = workbench.action.outputSyntax ?? workbench.tool.syntax
        return VStack(spacing: 0) {
            paneHeader(showsTree ? L10n.t("wb.tree") : L10n.t("wb.outputPane")) {
                if !showsTree, !workbench.outputHiddenFromEditor {
                    FoldButtons(folding: outputFolding)
                }
                Text(outputStatus)
                    .font(.secondaryMono)
                    .foregroundStyle(.tertiary)
            }
            if !showsTree, outputSearch.isPresented {
                EditorSearchBar(search: outputSearch, mode: .workbench)
            }
            Group {
                if showsTree {
                    if let tree = workbench.tree {
                        JSONTreeView(root: tree) { steps, text in
                            workbench.editTreeValue(at: steps, text: text)
                        }
                    } else {
                        placeholder(workbench.input.isEmpty ? "" : L10n.t("wb.treeNeedsJSON"))
                    }
                } else if let issue = workbench.actionIssue, workbench.displayedOutput.isEmpty {
                    placeholder(issue.localizedDescription, isError: true)
                } else if workbench.action.usesQuery, workbench.output == "[]" {
                    // Eşleşme yok ≠ hata: nötr renk, sorgu geçerli.
                    placeholder(L10n.t("wb.noMatches"))
                } else if workbench.outputHiddenFromEditor {
                    OversizedTextNotice(
                        title: L10n.t("wb.outputHidden.title", TextStats.size(workbench.outputStats.bytes)),
                        detail: oversizedDetail(limit: WorkbenchLimits.maxOutputBytes) + L10n.t("wb.outputHidden.detail")
                    ) {
                        CopyButton(text: workbench.output, help: L10n.t("wb.copyOutput"))
                    }
                } else {
                    CodeEditor(
                        text: Binding(get: { workbench.displayedOutput }, set: { workbench.editOutput($0) }),
                        language: workbench.outputStats.bytes <= WorkbenchState.highlightLimit ? CodeLanguage(outputSyntax) : .plain,
                        isEditable: workbench.isEditingOutput,
                        folding: outputFolding,
                        search: outputSearch,
                        onFocus: { workbench.focus(.output) },
                        limits: EditorLimits(
                            maxDisplayBytes: WorkbenchLimits.maxOutputBytes,
                            onRejected: { workbench.reportLimit($0.localized) },
                            onLongLine: { _ in workbench.reportLimit(WorkbenchLimits.longLineEditMessage) }
                        ),
                        onCursorChange: { workbench.updateOutputCursor(line: $0, column: $1) }
                    )
                    // Katlama editör kurulurken bağlanır: çıktının dili eylemle
                    // değişince (Escape → düz metin) editör yeniden kurulmalı.
                    .id("\(workbench.document.id)-\(outputSyntax)")
                }
            }
            .frame(maxHeight: .infinity)
            paneFooter { validationLabel } trailing: { outputFooterTrailing }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.editorBackground)
    }

    /// Çıktı başlığındaki durum: "Ready", "Running…", "Editing"…
    private var outputStatus: String {
        if workbench.isRunning { return L10n.t("wb.running") }
        // Sorgulu araçta özet sorgu satırında; burada tekrar edilmez.
        if !workbench.action.usesQuery, let summary = workbench.outputSummary, !workbench.isStale { return summary }
        if workbench.isLargeInput, workbench.isStale { return L10n.t("wb.waitingForRun") }
        if workbench.isEditingOutput { return L10n.t("wb.editing") }
        return L10n.t("wb.ready")
    }

    /// Çıktı alt bilgisinin sağı: büyük girdide "Run", değilse süre ve boyut.
    @ViewBuilder
    private var outputFooterTrailing: some View {
        if workbench.isLargeInput {
            Text(L10n.t("wb.largeInput"))
            Button(L10n.t("wb.run")) { workbench.runNow() }
                .controlSize(.mini)
                .disabled(!workbench.isStale)
        } else {
            if let cursor = workbench.outputCursor, !workbench.output.isEmpty, !workbench.showsTree {
                Text(L10n.t("editor.cursor", L10n.number(cursor.line), L10n.number(cursor.column)))
            }
            if !workbench.outputStats.summary.isEmpty, !workbench.showsTree {
                Text(workbench.outputStats.summary)
            }
            if let duration = workbench.lastRunDuration, !workbench.input.isEmpty || workbench.action.runsOnEmptyInput {
                Text(Self.milliseconds(duration))
            }
        }
    }

    static func milliseconds(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return ms < 1 ? "<1 ms" : "\(Int(ms.rounded())) ms"
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

    /// Bölme başlığı: 28 pt, başlık solda, kontroller sağda.
    private func paneHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.secondaryText.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func paneFooter<Leading: View, Trailing: View>(
        @ViewBuilder _ leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        EditorFooter(leading: leading, trailing: trailing)
    }

    @ViewBuilder
    private var validationLabel: some View {
        switch workbench.validation {
        case .empty:
            Text(" ").font(.secondaryText)
        case .valid:
            Label(L10n.t("wb.valid", workbench.tool.inputName), systemImage: "checkmark.circle.fill")
                .font(.secondaryText)
                .foregroundStyle(Theme.up)
        case .structurallyValid:
            // Alt bilgi dar: kısa hali, açıklama ipucunda.
            Label(L10n.t("wb.structureOK"), systemImage: "checkmark.circle")
                .font(.secondaryText)
                .foregroundStyle(.secondary)
                .help(L10n.t("wb.structureOK.help"))
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
            .help(L10n.t("wb.newTab"))
            .accessibilityLabel(L10n.t("wb.newTab"))
        }
        .frame(height: 30)
        .background(.bar)
        .confirmationDialog(
            L10n.t("wb.closeTab.title", pendingClose?.title ?? ""),
            isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.t("wb.closeTab.confirm"), role: .destructive) {
                if let item = pendingClose { onClose(item.id) }
                pendingClose = nil
            }
            Button(L10n.t("common.cancel"), role: .cancel) { pendingClose = nil }
        } message: {
            Text(L10n.t("wb.closeTab.message"))
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
            .help(L10n.t("wb.closeTab"))
            .accessibilityLabel(L10n.t("wb.closeNamed", title))
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .modifier(TabChrome(isSelected: isSelected, hovering: hovering))
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
    var help = L10n.t("common.copy")
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
                                .accessibilityLabel(expanded.contains(row.node.id) ? L10n.t("collection.collapse") : L10n.t("collection.expand"))
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
                    Button(L10n.t("wb.tree.root")) {
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
                CopyButton(text: selected.path, help: L10n.t("wb.tree.copyPath", selected.path))
            }
            if limitNotice {
                Text(L10n.t("wb.tree.expandedFirst", L10n.number(JSONTreeNode.expandAllLimit)))
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
            .help(L10n.t("fold.collapseAll"))
            .accessibilityLabel(L10n.t("fold.collapseAll"))
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
            .help(L10n.t("wb.tree.expandAll.help", L10n.number(JSONTreeNode.expandAllLimit)))
            .accessibilityLabel(L10n.t("fold.expandAll"))
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
                TextField(L10n.t("kv.column.value"), text: $draft)
                    .inputLimit(.treeValue)
                    .textFieldStyle(.input)
                    .font(.system(.callout, design: .monospaced))
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { cancel() }
                if let error {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(Theme.down)
                        .help(error)
                }
                Button(L10n.t("common.save"), action: commit).controlSize(.small)
                Button(L10n.t("common.cancel"), action: cancel).controlSize(.small)
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
                    .help(L10n.t("wb.tree.edit.help"))
                    .accessibilityLabel(L10n.t("wb.tree.edit"))
                }
                if node.hiddenSiblings == 0 {
                    CopyButton(text: JSONTreeView.copyValue(node), help: L10n.t("variable.copyValue"))
                }
            }
        }
        .help(node.path)
        .contextMenu {
            if node.hiddenSiblings == 0 {
                Button(L10n.t("wb.tree.copyValueMenu")) { copy(JSONTreeView.copyValue(node)) }
                if !node.path.isEmpty {
                    Button(L10n.t("wb.tree.copyPathMenu", node.path)) { copy(node.path) }
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

/// Boş girdide soluk örnek (API Client gövdesindeki gibi): editörün yazı
/// boyutu ve satır numaralarıyla hizalı, tıklamayı editöre bırakır.
struct SampleInputHint: View {
    let sample: String
    let note: String
    /// Satır numarası şeridinin genişliği (yoksa 0).
    let leading: CGFloat
    @AppStorage(EditorZoom.key) private var fontSize = EditorZoom.standard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !sample.isEmpty {
                Text(sample)
                    .font(.system(size: fontSize, design: .monospaced))
                    .lineLimit(6)
            }
            Text(note)
                .font(.secondaryText)
        }
        .foregroundStyle(.tertiary)
        .padding(.top, 8)
        .padding(.leading, leading + 5)
        .padding(.trailing, 16)
        .allowsHitTesting(false)
    }
}

/// Editör alt bilgisi (Workbench ve API Client ortak): 24 pt, 11 pt eş
/// aralıklı, ikincil renk; solda durum/imleç, sağda sayılar.
struct EditorFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading()
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 10) { trailing() }
                .lineLimit(1)
        }
        .font(.secondaryMono)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
