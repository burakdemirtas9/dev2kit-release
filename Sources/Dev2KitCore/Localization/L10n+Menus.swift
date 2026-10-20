// Metinler: anahtar → (Türkçe, English). Bkz. L10n.swift, docs/LOCALIZATION.md.

extension L10nTable {
    static let menus: [String: L10nEntry] = [
        "menu.newRequest": L10nEntry("Yeni Request", "New Request"),
        "menu.newCollection": L10nEntry("Yeni Koleksiyon", "New Collection"),
        "menu.save": L10nEntry("Kaydet", "Save"),
        "menu.closeTab": L10nEntry("Sekmeyi Kapat", "Close Tab"),
        "menu.closeWindow": L10nEntry("Pencereyi Kapat", "Close Window"),
        "menu.find": L10nEntry("Ara", "Find"),
        "menu.findInBody": L10nEntry("Body'de Ara", "Find in Body"),
        "menu.findInResponse": L10nEntry("Response'ta Ara", "Find in Response"),
        "menu.zoomIn": L10nEntry("Yazıyı Büyüt", "Increase Text Size"),
        "menu.zoomOut": L10nEntry("Yazıyı Küçült", "Decrease Text Size"),
        "menu.actualSize": L10nEntry("Gerçek Boyut", "Actual Size"),
        "menu.request": L10nEntry("Request", "Request"),
        "menu.nextTab": L10nEntry("Sonraki Sekme", "Next Tab"),
        "menu.previousTab": L10nEntry("Önceki Sekme", "Previous Tab"),
        "menu.resetApprovals": L10nEntry("Güvenlik Onaylarını Sıfırla…", "Reset Security Approvals…"),
        "menu.language": L10nEntry("Dil", "Language"),
        "approvals.reset.title": L10nEntry("Güvenlik onayları sıfırlansın mı?", "Reset security approvals?"),
        "approvals.reset.message": L10nEntry("“Yine de Gönder” ile onayladığın uyarılar unutulur; aynı durumlar yeniden sorulur.", "Warnings you approved with “Send Anyway” are forgotten, and the same situations will be asked about again."),
        "approvals.reset.confirm": L10nEntry("Onayları Sıfırla", "Reset Approvals"),
        "approvals.reset.failed": L10nEntry("Güvenlik onayları sıfırlanamadı", "Couldn’t reset security approvals"),
        "approvals.reset.failedDetail": L10nEntry("%1$@\n\nOnayların değişmedi.", "%1$@\n\nYour approvals are unchanged."),
        "toolbar.mode": L10nEntry("Mod", "Mode"),
    ]
}
