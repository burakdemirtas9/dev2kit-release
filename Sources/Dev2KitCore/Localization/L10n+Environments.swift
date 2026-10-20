// Metinler: anahtar → (Türkçe, English). Bkz. L10n.swift, docs/LOCALIZATION.md.

extension L10nTable {
    static let environments: [String: L10nEntry] = [
        "environment.none": L10nEntry("Environment Yok", "No Environment"),
        "environment.active": L10nEntry("Aktif environment", "Active environment"),
        "environment.active.named": L10nEntry("Aktif environment: %1$@", "Active environment: %1$@"),
        "environment.select.title": L10nEntry("Environment seç", "Select an Environment"),
        "environment.variable.disabled": L10nEntry("{{%1$@}} bu environment'ta var ama satırı kapalı; işaretleyince kullanılır.", "{{%1$@}} exists in this environment but its row is disabled; enable it to use it."),
        "environment.variable.saved": L10nEntry("{{%1$@}} kaydedildi; request'te artık çözülüyor.", "{{%1$@}} saved; it now resolves in the request."),
        "environment.variable.duplicate": L10nEntry("Bu environment'ta bu adla bir değişken zaten var.", "This environment already has a variable with this name."),
        "environment.variable.emptyName": L10nEntry("Değişken adı boş olamaz.", "The variable name can’t be empty."),
        "environment.variable.new": L10nEntry("Yeni değişken", "New variable"),
        "environment.variable.name": L10nEntry("isim", "name"),
        "environment.variable.value": L10nEntry("değer", "value"),
        "environment.variable.chooseTarget": L10nEntry("Etkin environment yok; hangisine ekleneceğini seç.", "No environment is active; choose where to add it."),
        "environment.variable.willCreate": L10nEntry("Henüz environment yok; kaydedince “Environment” oluşturulup etkin yapılır.", "There’s no environment yet; saving creates “Environment” and makes it active."),
        "environment.variable.target": L10nEntry("“%1$@” environment'ına eklenecek.", "It will be added to the “%1$@” environment."),
        "environment.name.placeholder": L10nEntry("Environment adı", "Environment name"),
        "environment.isActive": L10nEntry("Aktif", "Active"),
        "environment.makeActive": L10nEntry("Aktif Yap", "Make Active"),
        "environment.variables.help": L10nEntry("Değişkenler: request'lerde {{isim}} olarak kullanılır. Secret değerleri buraya değil Secrets'a yaz.", "Variables are used in requests as {{name}}. Put secret values in Secrets, not here."),
        "environment.key.placeholder": L10nEntry("isim (ör: baseUrl)", "name (e.g. baseUrl)"),
        "environment.value.placeholder": L10nEntry("değer (ör: https://api.example.com)", "value (e.g. https://api.example.com)"),
        "environment.tokenVariables": L10nEntry("Token Factory'den gelen değişkenler", "Variables from Token Factory"),
        "environment.tokenVariables.empty": L10nEntry("Bu environment'ta Token Factory değişkeni yok. Sol panelin altındaki Token Factory'den ekleyebilirsin.", "This environment has no Token Factory variables. You can add them from Token Factory at the bottom of the left panel."),
        "environment.tokenVariables.shadows": L10nEntry("aynı adlı değişkeni ezer", "overrides a variable with the same name"),
        "environment.tokenVariables.shadows.help": L10nEntry("Bu environment'ta %1$@ adlı bir değişken de var; request'lerde Token Factory'deki token kullanılır.", "This environment also has a variable named %1$@; requests use the token from Token Factory."),
    ]
}
