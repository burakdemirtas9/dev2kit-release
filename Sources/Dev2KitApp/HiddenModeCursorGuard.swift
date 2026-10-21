import AppKit
import SwiftUI

/// Gizli moddaki metin alanları imleci etkilemesin (kullanıcı bildirimi,
/// 2026-10-21: API Client'ta Gönder düğmesinde ve boş alanlarda I-beam).
///
/// Sebep: iki mod da canlı; gizli olan yalnızca `opacity(0)` (`modeLayer`).
/// SwiftUI bunu AppKit'te sarmalayıcının `alphaValue = 0` olarak uyguluyor,
/// `isHidden` değil. AppKit saydam görünümün cursor rect'ini ve izleme
/// alanını (tracking area) çalıştırmaya devam ediyor: Workbench'in görünmeyen
/// editörleri (`NSTextView`) API Client'ın üstüne I-beam yayıyordu; tersi de
/// (API Client'ın alanları Workbench düğmelerinin üstünde).
///
/// Çözüm yalnızca imleç sahiplerinde: metin görünümü ve düzenlenebilir/seçilebilir
/// metin alanı tamamen saydamsa (kendisi ya da bir atası `alphaValue == 0`)
/// AppKit'te de gizlenir; kaydırma görünümü içindeyse onunla birlikte (klip
/// görünümü de I-beam ekliyor). Mod geri gelince yalnızca burada gizlenenler
/// açılır. Saydam düğmelere (ör. ⌘K'nın görünmez düğmesi) dokunulmaz;
/// kısayolları çalışmaya devam eder. Metin, seçim ve kaydırma korunur.
enum HiddenModeCursorGuard {
    /// Bu modülün gizlediği görünümler (zayıf referans).
    @MainActor private static let hiddenByGuard = NSHashTable<NSView>.weakObjects()

    /// Penceredeki imleç sahiplerini görünürlüğe göre gizler/açar.
    @MainActor
    static func sync(_ root: NSView) {
        // Önce açılacaklar: görünür hale gelen mod imlecini geri alsın.
        for view in hiddenByGuard.allObjects where !isTransparent(view) {
            view.isHidden = false
            hiddenByGuard.remove(view)
        }
        for owner in cursorOwners(in: root) {
            // Editörün kendi kaydırma görünümü (belge görünümü odur); metin
            // alanının etrafındaki SwiftUI kaydırma alanı değil.
            let scroll = owner.enclosingScrollView
            let target = scroll?.documentView === owner ? scroll! : owner
            guard !target.isHidden, isTransparent(target) else { continue }
            // Gizlenen görünüm klavyeyi tutmasın; AppKit sonraki anahtar
            // görünümü (rastgele bir alan) odaklamasın diye pencereye bırakılır.
            if let responder = root.window?.firstResponder as? NSView, responder.isDescendant(of: target) {
                root.window?.makeFirstResponder(nil)
            }
            target.isHidden = true
            hiddenByGuard.add(target)
        }
    }

    /// I-beam koyan görünümler: metin görünümleri ve düzenlenebilir ya da
    /// seçilebilir metin alanları (düğme etiketleri gibi düz metin değil).
    @MainActor
    static func cursorOwners(in view: NSView) -> [NSView] {
        if view.isHidden { return [] }
        if let text = view as? NSTextView { return [text] }
        if let field = view as? NSTextField, field.isEditable || field.isSelectable { return [field] }
        return view.subviews.flatMap(cursorOwners)
    }

    /// Kendisi ya da bir atası tamamen saydam mı.
    @MainActor
    static func isTransparent(_ view: NSView?) -> Bool {
        var current = view
        while let view = current {
            if view.alphaValue == 0 { return true }
            current = view.superview
        }
        return false
    }
}

/// Mod değişince ve gizli mod ilk kurulunca eşitlemeyi tetikler. Girdileri
/// yalnızca bu küçük görünümü günceller (mod katmanlarına yayılmaz).
struct HiddenModeCursorGuardView: NSViewRepresentable {
    let mode: AppMode
    let keepsAPIClient: Bool
    let keepsWorkbench: Bool

    func makeNSView(context: Context) -> NSView { PassThroughView() }

    func updateNSView(_ view: NSView, context: Context) {
        // SwiftUI opaklığı bu güncellemeden sonra uyguluyor; bir tur sonra.
        DispatchQueue.main.async {
            guard let root = view.window?.contentView else { return }
            HiddenModeCursorGuard.sync(root)
        }
    }
}

/// Tıklamayı ve odağı hiç almayan boş görünüm.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}
