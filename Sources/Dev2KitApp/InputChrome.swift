import SwiftUI

/// Yazı alanlarının ortak görünümü: zemin, kenarlık, üzerine gelme, odak
/// halkası ve kapalı durum. Renkler `Theme.input*` tokenlarından (kullanıcı
/// seçimi 2026-10-20, "lila zemin"). Eskiden dört ayrı zemin ve iki ayrı odak
/// rengi vardı; `.roundedBorder` alanların halkası sistem mavisiydi.
///
/// Yerleşimi değiştirmez: kenarlık içe çizilir, halka alanın dışına taşar.
struct InputChrome: ViewModifier {
    var cornerRadius: CGFloat = 6
    /// Tablo hücresi: dinlenmede çerçevesiz (ızgara çizgileri yeterli),
    /// yalnızca odaktayken zemin ve kenarlık. Halka yok; komşu hücreye taşar.
    var onlyWhenFocused = false
    /// Alan odağını kendisi izliyorsa (ör. `TemplateTextField`) buradan
    /// verilir; verilmezse içerikteki alanın odağı burada izlenir.
    var isFocused: Bool?

    @FocusState private var ownFocus: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        Group {
            if isFocused == nil {
                content.focused($ownFocus)
            } else {
                content
            }
        }
        .background(background, in: shape)
        .overlay { shape.strokeBorder(border, lineWidth: active ? 1.5 : 1) }
        .overlay {
            if active && !onlyWhenFocused {
                RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                    .strokeBorder(Theme.inputFocusRing, lineWidth: 3)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
    }

    private var active: Bool { isEnabled && (isFocused ?? ownFocus) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    private var background: Color {
        if onlyWhenFocused { return active ? Theme.inputBackground : .clear }
        return isEnabled ? Theme.inputBackground : Theme.inputDisabledBackground
    }

    private var border: Color {
        if active { return Theme.inputFocus }
        if onlyWhenFocused { return .clear }
        if !isEnabled { return Theme.inputDisabledBorder }
        return hovering ? Theme.inputBorderHover : Theme.inputBorder
    }
}

extension View {
    /// Bkz. `InputChrome`.
    func inputChrome(cornerRadius: CGFloat = 6, onlyWhenFocused: Bool = false, isFocused: Bool? = nil) -> some View {
        modifier(InputChrome(cornerRadius: cornerRadius, onlyWhenFocused: onlyWhenFocused, isFocused: isFocused))
    }
}

/// `.roundedBorder` yerine: aynı yükseklik ve metin girintisi, `InputChrome`
/// renkleriyle. `SecureField` da bu stili kullanır.
struct InputFieldStyle: TextFieldStyle {
    /// Metnin kenara uzaklığı; `.roundedBorder` ile aynı (TemplateTextField
    /// vurgu katmanı buna göre hizalanır).
    static let textInset: CGFloat = 6

    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<_Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, Self.textInset)
            .padding(.vertical, 4)
            .inputChrome()
    }
}

extension TextFieldStyle where Self == InputFieldStyle {
    static var input: InputFieldStyle { InputFieldStyle() }
}
