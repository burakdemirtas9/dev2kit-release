import AppKit
import SwiftUI
import Dev2KitCore

/// İstek metodu seçici: her metot kendi renginde (`Theme.color(for:)`),
/// hem açılan listede hem düğmede (kullanıcı isteği, 2026-10-19).
///
/// Neden AppKit: SwiftUI `Picker`'ın menü öğeleri rengi atıyor; menü öğesinin
/// `attributedTitle`'ı ise renkli çiziliyor.
struct MethodPicker: NSViewRepresentable {
    @Binding var selection: HTTPMethod
    /// Çerçevesiz: adres kapsülünün solunda (2026-10-20).
    var bordered = true

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = bordered
        for method in HTTPMethod.allCases {
            let item = NSMenuItem(title: method.rawValue, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(string: method.rawValue, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                .foregroundColor: NSColor(Theme.color(for: method)),
            ])
            item.representedObject = method.rawValue
            button.menu?.addItem(item)
        }
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setAccessibilityLabel("Metot")
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        if let index = HTTPMethod.allCases.firstIndex(of: selection), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    final class Coordinator: NSObject {
        var selection: Binding<HTTPMethod>
        init(selection: Binding<HTTPMethod>) { self.selection = selection }

        @objc func changed(_ sender: NSPopUpButton) {
            guard HTTPMethod.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
            selection.wrappedValue = HTTPMethod.allCases[sender.indexOfSelectedItem]
        }
    }
}
