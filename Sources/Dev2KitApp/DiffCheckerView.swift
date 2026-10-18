import AppKit
import SwiftUI
import Dev2KitCore

/// Diff Checker (docs/V2.md "Diff"): iki girdiyi ilgili dilin
/// biçimlendiricisinden geçirip karşılaştırır. JSON'da anlamsal fark listesi
/// ("Changes") ve yan yana satırlar ("Lines"); diğer dillerde satırlar.
struct DiffCheckerView: View {
    @Environment(WorkbenchState.self) private var workbench

    private var diff: DiffCheckerState { workbench.diff }

    var body: some View {
        VStack(spacing: 0) {
            DocumentTabBar(
                items: diff.documents.map { .init(id: $0.id, title: diff.title(of: $0), hasContent: $0.hasContent) },
                selectedID: diff.selectedID,
                onSelect: { diff.select(documentID: $0) },
                onClose: { diff.closeDocument($0) },
                onNew: { diff.newDocument() }
            )
            Divider()
            header
            Divider()
            if !diff.inputsHidden {
                inputs
                    .frame(minHeight: 120, idealHeight: 220, maxHeight: 320)
                Divider()
            }
            DiffResultView(diff: diff)
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: Üst çubuk

    private var header: some View {
        let options = diff.document.options
        return HStack(spacing: 12) {
            Picker("Language", selection: Binding(
                get: { diff.document.language },
                set: { diff.select(language: $0) }
            )) {
                ForEach(DiffChecker.Language.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .help("Both sides are formatted with this language before comparing")
            Toggle("Normalize formatting", isOn: Binding(
                get: { options.normalize },
                set: { var new = options; new.normalize = $0; diff.update(options: new) }
            ))
            .help("Format both sides first (JSON keys sorted), so indentation and key order do not count as differences")
            Toggle("Ignore whitespace", isOn: Binding(
                get: { options.line.ignoreWhitespace },
                set: { var new = options; new.line.ignoreWhitespace = $0; diff.update(options: new) }
            ))
            Toggle("Ignore case", isOn: Binding(
                get: { options.line.ignoreCase },
                set: { var new = options; new.line.ignoreCase = $0; diff.update(options: new) }
            ))
            Spacer(minLength: 0)
            if let notice = diff.limitNotice {
                Label(notice, systemImage: "exclamationmark.octagon.fill")
                    .font(.secondaryText)
                    .foregroundStyle(Theme.down)
                    .lineLimit(1)
                    .help(notice)
            }
            Button {
                diff.swapSides()
            } label: {
                Image(systemName: "arrow.left.arrow.right").iconHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Swap left and right")
            .accessibilityLabel("Swap left and right")
            Button {
                diff.inputsHidden.toggle()
            } label: {
                Image(systemName: diff.inputsHidden ? "rectangle.split.2x1" : "rectangle.bottomhalf.inset.filled").iconHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(diff.inputsHidden ? "Show inputs" : "Hide inputs to give the result more room")
            .accessibilityLabel(diff.inputsHidden ? "Show inputs" : "Hide inputs")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Girdiler

    private var inputs: some View {
        let language = CodeLanguage(diff.document.language.syntax)
        return HStack(spacing: 0) {
            inputPane("Left", text: Binding(get: { diff.left }, set: { diff.left = $0 }), language: language,
                      issue: diff.result?.leftIssue, hidden: diff.document.leftTooLargeForEditor,
                      sample: diff.document.language.samples.left, focusRequest: diff.focusRequest)
            Divider()
            inputPane("Right", text: Binding(get: { diff.right }, set: { diff.right = $0 }), language: language,
                      issue: diff.result?.rightIssue, hidden: diff.document.rightTooLargeForEditor,
                      sample: diff.document.language.samples.right, focusRequest: nil)
        }
    }

    private func inputPane(_ title: String, text: Binding<String>, language: CodeLanguage, issue: String?, hidden: Bool,
                           sample: String, focusRequest: Int?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.secondaryText.weight(.semibold)).foregroundStyle(.secondary)
                Text(text.wrappedValue.isEmpty ? "" : TextStats.size(text.wrappedValue.utf8.count))
                    .font(.tinyText.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if let issue {
                    Label("Compared as-is: \(issue)", systemImage: "exclamationmark.triangle.fill")
                        .font(.tinyText)
                        .foregroundStyle(Theme.warning)
                        .lineLimit(1)
                        .help(issue)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            if hidden {
                OversizedTextNotice(
                    title: "Not shown: \(TextStats.size(text.wrappedValue.utf8.count))",
                    detail: "A line longer than \(TextStats.size(WorkbenchLimits.maxEditorLineBytes)) would freeze dev2kit in the editor. It is kept and compared."
                ) {
                    CopyButton(text: text.wrappedValue, help: "Copy")
                    Button("Clear") { text.wrappedValue = "" }.controlSize(.small)
                }
            } else {
                CodeEditor(text: text, language: language, limits: EditorLimits(
                    onRejected: { diff.reportLimit($0.english) },
                    onLongLine: { text.wrappedValue = $0 }
                ), focusRequest: focusRequest)
                .id("\(diff.document.id)-\(title)")
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        SampleInputHint(sample: sample, note: "Paste the \(title.lowercased()) side here.", leading: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Karşılaştırma sonucu: özet, gezinti, "Changes" (JSON) ve "Lines".
private struct DiffResultView: View {
    let diff: DiffCheckerState

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                summaryBar(proxy: proxy)
                Divider()
                if let result = diff.result {
                    if diff.showsChanges, let changes = result.jsonChanges {
                        JSONChangeList(changes: changes)
                    } else {
                        DiffLinesView(rows: result.rows, highlighted: highlightedRow)
                    }
                } else {
                    Text(diff.document.hasContent ? "" : "Paste two texts to compare. Inputs stay in memory only.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var highlightedRow: Int? {
        guard let index = diff.currentChange, let starts = diff.result?.changeStarts, index < starts.count else { return nil }
        return starts[index]
    }

    private func summaryBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            if let result = diff.result {
                if result.isIdentical {
                    Label("Identical", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.up)
                } else {
                    Text("+\(result.added)").foregroundStyle(Theme.up)
                    Text("−\(result.removed)").foregroundStyle(Theme.down)
                    if let changes = result.jsonChanges {
                        Text("\(changes.count) value \(changes.count == 1 ? "change" : "changes")")
                            .foregroundStyle(.secondary)
                    }
                }
                if result.isSimplified {
                    Label("Too many differences in a block; shown as replaced", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }
            if diff.isRunning { ProgressView().controlSize(.small) }
            if diff.isLarge {
                Text("Large input: not run automatically").foregroundStyle(.secondary)
                Button("Run") { diff.runNow() }.controlSize(.small).disabled(!diff.isStale)
            }
            Spacer(minLength: 0)
            if diff.document.language == .json, diff.result?.jsonChanges != nil {
                Picker("Result", selection: Binding(
                    get: { diff.document.resultMode },
                    set: { diff.select(resultMode: $0) }
                )) {
                    ForEach(DiffCheckerState.ResultMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            if !diff.showsChanges, let starts = diff.result?.changeStarts, !starts.isEmpty {
                Button {
                    if let row = diff.moveToChange(forward: false) { withAnimation { proxy.scrollTo(row, anchor: .center) } }
                } label: { Image(systemName: "chevron.up").iconHitTarget() }
                    .buttonStyle(.plain)
                    .help("Previous difference")
                    .accessibilityLabel("Previous difference")
                Text((diff.currentChange.map { "\($0 + 1)/" } ?? "") + "\(starts.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    if let row = diff.moveToChange(forward: true) { withAnimation { proxy.scrollTo(row, anchor: .center) } }
                } label: { Image(systemName: "chevron.down").iconHitTarget() }
                    .buttonStyle(.plain)
                    .help("Next difference")
                    .accessibilityLabel("Next difference")
            }
        }
        .font(.secondaryText)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
    }
}

/// Yan yana satırlar. Satırlar tembel çizilir (LazyVStack): 300 bin satırlık
/// sonuçta yalnızca görünenler oluşur.
private struct DiffLinesView: View {
    let rows: [DiffRow]
    let highlighted: Int?
    /// Kod editörleriyle aynı yazı boyutu (⌘+ / ⌘−).
    @AppStorage(EditorZoom.key) private var fontSize = EditorZoom.standard

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 0) {
                        side(row.left, kind: row.kind, isLeft: true)
                        Divider()
                        side(row.right, kind: row.kind, isLeft: false)
                    }
                    .overlay(alignment: .leading) {
                        if row.id == highlighted { Rectangle().fill(Theme.accent).frame(width: 3) }
                    }
                    .id(row.id)
                }
            }
            .font(.system(size: fontSize - 1, design: .monospaced))
        }
    }

    private func side(_ line: (number: Int, text: String)?, kind: DiffRow.Kind, isLeft: Bool) -> some View {
        let tint: Color? = {
            switch kind {
            case .equal: return nil
            case .changed: return isLeft ? Theme.down : Theme.up
            case .removed: return isLeft ? Theme.down : nil
            case .added: return isLeft ? nil : Theme.up
            }
        }()
        return HStack(spacing: 6) {
            Text(line.map { "\($0.number)" } ?? "")
                .foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing)
            // Uzun satır kırpılır: tek satırlık 5 MB bir Text arayüzü dondurur.
            Text(line.map { WorkbenchLimits.displayed(line: $0.text) } ?? "")
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line == nil ? Color.primary.opacity(0.04) : (tint?.opacity(0.16) ?? .clear))
        .help(line?.text ?? "")
    }
}

/// JSON değer farkları: yol, eski → yeni. Yol Token Factory sözdiziminde.
private struct JSONChangeList: View {
    let changes: [JSONChange]

    var body: some View {
        if changes.isEmpty {
            Label("No value differences", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.up)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(changes) { change in
                HStack(spacing: 8) {
                    symbol(change.kind)
                    Text(change.path.isEmpty ? "(root)" : change.path)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Color(nsColor: Theme.syntaxKey))
                    Text(description(change.kind))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    CopyButton(text: change.path, help: "Copy path: \(change.path)")
                }
                .contextMenu {
                    Button("Copy Path") { copy(change.path) }
                    switch change.kind {
                    case .added(let value): Button("Copy New Value") { copy(raw(value)) }
                    case .removed(let value): Button("Copy Old Value") { copy(raw(value)) }
                    case .changed(let from, let to):
                        Button("Copy Old Value") { copy(raw(from)) }
                        Button("Copy New Value") { copy(raw(to)) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func symbol(_ kind: JSONChange.Kind) -> some View {
        switch kind {
        case .added: Image(systemName: "plus.circle.fill").foregroundStyle(Theme.up).accessibilityLabel("added")
        case .removed: Image(systemName: "minus.circle.fill").foregroundStyle(Theme.down).accessibilityLabel("removed")
        case .changed: Image(systemName: "pencil.circle.fill").foregroundStyle(Theme.warning).accessibilityLabel("changed")
        }
    }

    private func description(_ kind: JSONChange.Kind) -> String {
        switch kind {
        case .added(let value): return "+ \(value.compact())"
        case .removed(let value): return "− \(value.compact())"
        case .changed(let from, let to): return "\(from.compact()) → \(to.compact())"
        }
    }

    private func raw(_ value: JSONValue) -> String {
        if case .string(let text) = value { return text }
        return value.compact()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
