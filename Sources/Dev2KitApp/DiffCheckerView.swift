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
            Picker(L10n.t("diff.language"), selection: Binding(
                get: { diff.document.language },
                set: { diff.select(language: $0) }
            )) {
                ForEach(DiffChecker.Language.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .help(L10n.t("diff.language.help"))
            Toggle(L10n.t("diff.normalize"), isOn: Binding(
                get: { options.normalize },
                set: { var new = options; new.normalize = $0; diff.update(options: new) }
            ))
            .help(L10n.t("diff.normalize.help"))
            Toggle(L10n.t("diff.ignoreWhitespace"), isOn: Binding(
                get: { options.line.ignoreWhitespace },
                set: { var new = options; new.line.ignoreWhitespace = $0; diff.update(options: new) }
            ))
            Toggle(L10n.t("diff.ignoreCase"), isOn: Binding(
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
            .help(L10n.t("diff.swap"))
            .accessibilityLabel(L10n.t("diff.swap"))
            Button {
                diff.inputsHidden.toggle()
            } label: {
                Image(systemName: diff.inputsHidden ? "rectangle.split.2x1" : "rectangle.bottomhalf.inset.filled").iconHitTarget()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(diff.inputsHidden ? L10n.t("diff.showInputs") : L10n.t("diff.hideInputs.help"))
            .accessibilityLabel(diff.inputsHidden ? L10n.t("diff.showInputs") : L10n.t("diff.hideInputs"))
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
                Text(title == "Left" ? L10n.t("diff.left") : L10n.t("diff.right")).font(.secondaryText.weight(.semibold)).foregroundStyle(.secondary)
                Text(text.wrappedValue.isEmpty ? "" : TextStats.size(text.wrappedValue.utf8.count))
                    .font(.tinyText.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if let issue {
                    Label(L10n.t("diff.comparedAsIs", issue), systemImage: "exclamationmark.triangle.fill")
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
                    title: L10n.t("diff.hidden.title", TextStats.size(text.wrappedValue.utf8.count)),
                    detail: L10n.t("diff.hidden.detail", TextStats.size(WorkbenchLimits.maxEditorLineBytes))
                ) {
                    CopyButton(text: text.wrappedValue, help: L10n.t("common.copy"))
                    Button(L10n.t("common.clear")) { text.wrappedValue = "" }.controlSize(.small)
                }
                .background(Theme.editorBackground)
            } else {
                CodeEditor(text: text, language: language, limits: EditorLimits(
                    onRejected: { diff.reportLimit($0.localized) },
                    onLongLine: { text.wrappedValue = $0 }
                ), focusRequest: focusRequest)
                .id("\(diff.document.id)-\(title)")
                // Workbench'teki editörlerle aynı zemin (TASARIM: editör zemini).
                .background(Theme.editorBackground)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        SampleInputHint(sample: sample, note: title == "Left" ? L10n.t("diff.pasteLeft") : L10n.t("diff.pasteRight"), leading: 0)
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
                    Text(diff.document.hasContent ? "" : L10n.t("diff.empty"))
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
                    Label(L10n.t("diff.identical"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.up)
                } else {
                    Text("+\(result.added)").foregroundStyle(Theme.up)
                    Text("−\(result.removed)").foregroundStyle(Theme.down)
                    if let changes = result.jsonChanges {
                        Text(L10n.plural("diff.valueChanges", count: changes.count))
                            .foregroundStyle(.secondary)
                    }
                }
                if result.isSimplified {
                    Label(L10n.t("diff.tooMany"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }
            if diff.isRunning { ProgressView().controlSize(.small) }
            if diff.isLarge {
                Text(L10n.t("wb.largeInput")).foregroundStyle(.secondary)
                Button(L10n.t("wb.run")) { diff.runNow() }.controlSize(.small).disabled(!diff.isStale)
            }
            Spacer(minLength: 0)
            if diff.document.language == .json, diff.result?.jsonChanges != nil {
                Picker(L10n.t("diff.result"), selection: Binding(
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
                    .help(L10n.t("diff.previous"))
                    .accessibilityLabel(L10n.t("diff.previous"))
                Text((diff.currentChange.map { "\($0 + 1)/" } ?? "") + "\(starts.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    if let row = diff.moveToChange(forward: true) { withAnimation { proxy.scrollTo(row, anchor: .center) } }
                } label: { Image(systemName: "chevron.down").iconHitTarget() }
                    .buttonStyle(.plain)
                    .help(L10n.t("diff.next"))
                    .accessibilityLabel(L10n.t("diff.next"))
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
            Label(L10n.t("diff.noValueChanges"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.up)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(changes) { change in
                HStack(spacing: 8) {
                    symbol(change.kind)
                    Text(change.path.isEmpty ? L10n.t("diff.root") : change.path)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(Color(nsColor: Theme.syntaxKey))
                    Text(description(change.kind))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    CopyButton(text: change.path, help: L10n.t("wb.tree.copyPath", change.path))
                }
                .contextMenu {
                    Button(L10n.t("diff.copyPath")) { copy(change.path) }
                    switch change.kind {
                    case .added(let value): Button(L10n.t("diff.copyNew")) { copy(raw(value)) }
                    case .removed(let value): Button(L10n.t("diff.copyOld")) { copy(raw(value)) }
                    case .changed(let from, let to):
                        Button(L10n.t("diff.copyOld")) { copy(raw(from)) }
                        Button(L10n.t("diff.copyNew")) { copy(raw(to)) }
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
