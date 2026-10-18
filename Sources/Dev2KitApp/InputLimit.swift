import AppKit
import SwiftUI
import Dev2KitCore

extension View {
    /// Metin alanına sınır (`InputLimits`). Değişiklik alana GİRMEDEN
    /// reddedilir: SwiftUI `TextField`'ının altındaki `NSTextField`'a bir
    /// biçimleyici takılır; Cocoa her tuşta ve yapıştırmada, metni
    /// yerleştirmeden önce `isPartialStringValid`'i sorar.
    ///
    /// Neden böyle: bağlamada (binding) kırpmak donmayı önlemiyordu — metin
    /// önce alana yerleşiyor (1 MB 1,7 sn, ölçüldü). Biçimleyiciyle 0 ms.
    /// `TextField`'ın kendisi değişmediği için odak, Enter, stil aynı kalır.
    func inputLimit(_ field: InputLimits.Field, english: Bool = false) -> some View {
        modifier(InputLimitModifier(field: field, english: english))
    }
}

private struct InputLimitModifier: ViewModifier {
    let field: InputLimits.Field
    let english: Bool
    @State private var notice: String?
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .background(InputLimitInstaller(limit: field.maxCharacters) { reject() })
            .overlay(alignment: .bottomLeading) {
                if let notice {
                    Text(notice)
                        .font(.tinyText)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.down, in: Capsule())
                        .fixedSize()
                        .offset(y: 18)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .zIndex(notice == nil ? 0 : 1)
    }

    private func reject() {
        NSSound.beep()
        notice = InputLimits.tooLongMessage(field, english: english)
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}

/// Uzunluğu aşan değişikliği reddeden biçimleyici. Değer dönüştürmez:
/// metin olduğu gibi kalır.
final class LengthLimitFormatter: Formatter {
    var limit: Int
    var onReject: () -> Void

    init(limit: Int, onReject: @escaping () -> Void) {
        self.limit = limit
        self.onReject = onReject
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    override func string(for obj: Any?) -> String? {
        obj as? String
    }

    override func getObjectValue(
        _ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
        for string: String,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(
        _ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?,
        originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        guard partialStringPtr.pointee.length > limit else { return true }
        // Düzenleme sırasında SwiftUI durumu değiştirilmez: bir sonraki turda.
        let onReject = onReject
        DispatchQueue.main.async { onReject() }
        return false
    }
}

/// Değiştiricinin arka planına konan görünmez görünüm: aynı yerdeki
/// `NSTextField`'ı bulup biçimleyiciyi takar. SwiftUI alanı yeniden
/// kurarsa güncellemede yeniden takılır.
private struct InputLimitInstaller: NSViewRepresentable {
    let limit: Int
    let onReject: () -> Void

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.limit = limit
        probe.onReject = onReject
        probe.scheduleAttach()
    }

    final class Probe: NSView {
        var limit = 0
        var onReject: () -> Void = {}

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleAttach()
        }

        /// Alan bu görünümle aynı turda kurulmamış olabilir: bir sonraki turda.
        func scheduleAttach() {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        /// Bulunan alan: her güncellemede yeniden aranmasın.
        private weak var attached: NSTextField?

        private func attach() {
            guard window != nil else { return }
            if let attached, attached.window === window, let formatter = attached.formatter as? LengthLimitFormatter {
                formatter.limit = limit
                formatter.onReject = onReject
                return
            }
            guard let field = nearestTextField() else { return }
            attached = field
            if let formatter = field.formatter as? LengthLimitFormatter {
                formatter.limit = limit
                formatter.onReject = onReject
            } else if field.formatter == nil {
                // Başka bir biçimleyici (ör. sayı alanı) varsa dokunulmaz.
                field.formatter = LengthLimitFormatter(limit: limit, onReject: onReject)
            }
        }

        /// Pencere koordinatlarında bu görünümle en çok örtüşen metin alanı;
        /// en yakın atadan başlayarak aranır.
        private func nearestTextField() -> NSTextField? {
            let mine = convert(bounds, to: nil)
            var ancestor = superview
            var level = 0
            while let current = ancestor, level < 8 {
                var best: (field: NSTextField, area: CGFloat)?
                for field in Self.textFields(in: current) {
                    let overlap = field.convert(field.bounds, to: nil).intersection(mine)
                    let area = overlap.isNull ? 0 : overlap.width * overlap.height
                    if area > (best?.area ?? 0) { best = (field, area) }
                }
                if let best { return best.field }
                ancestor = current.superview
                level += 1
            }
            return nil
        }

        private static func textFields(in view: NSView) -> [NSTextField] {
            var result: [NSTextField] = []
            for subview in view.subviews {
                if let field = subview as? NSTextField, field.isEditable { result.append(field) }
                result += textFields(in: subview)
            }
            return result
        }
    }
}
