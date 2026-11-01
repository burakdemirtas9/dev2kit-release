import Foundation

/// Önizleyiciler (v2 step 4, 2026-11-01): solda düzenle, sağda görüntüle
/// (IntelliJ'deki gibi). Çıktı yalıtılmış görüntüleyicide çizilir: script
/// kapalı, dış kaynak yüklenmez, bağlantıya tıklamak hiçbir yere gitmez
/// (kullanıcı kararı; yanıt önizlemesiyle aynı kural).
extension WorkbenchTools {
    /// HTML olduğu gibi çizilir; girdi bölmesinde "Format input" biçimlendirir.
    public static let htmlViewer = WorkbenchTool(
        id: "html-viewer",
        title: "HTML Viewer",
        inputName: "HTML",
        category: .preview,
        keywords: ["html", "preview", "render", "browser", "web", "önizle", "görüntüle", "sayfa"],
        syntax: .html,
        actions: [
            WorkbenchAction(id: "preview", title: "Preview", rendersPreview: true) { input, _ in input },
        ],
        validate: { MarkupTools.checkHTML($0) },
        sampleInput: PreviewSamples.html,
        inputFormatter: { input, options in
            try MarkupFormatter.beautify(input, flavor: .html, indent: options.indentation.unit)
        }
    )

    /// Markdown çizilir ("Preview") ya da üretilen HTML kodu gösterilir ("HTML"):
    /// kopyalanıp başka yerde kullanılabilir (kullanıcı kararı, 2026-11-01).
    public static let markdownViewer = WorkbenchTool(
        id: "markdown-viewer",
        title: "Markdown Viewer",
        inputName: "Markdown",
        category: .preview,
        keywords: ["markdown", "md", "readme", "preview", "render", "önizle", "görüntüle", "doküman"],
        syntax: .markdown,
        actions: [
            WorkbenchAction(id: "preview", title: "Preview", rendersPreview: true) { input, _ in
                MarkdownRenderer.document(input)
            },
            WorkbenchAction(id: "html", title: "HTML", outputSyntax: .html) { input, _ in
                MarkdownRenderer.html(input)
            },
        ],
        validate: { MarkdownFormatter.check($0) },
        sampleInput: PreviewSamples.markdown,
        inputFormatter: { input, _ in try MarkdownFormatter.beautify(input) }
    )
}

/// Boş girdide soluk gösterilen örnekler (gerçek veri değil).
public enum PreviewSamples {
    public static let html = """
    <!DOCTYPE html>
    <html>
    <head>
      <style>
        body { font-family: -apple-system, sans-serif; margin: 24px; }
        .card { padding: 12px 16px; border: 1px solid #ccc; border-radius: 8px; }
      </style>
    </head>
    <body>
      <div class="card">
        <h2>dev2kit</h2>
        <p>Local-first <b>API client</b> and developer toolbox.</p>
      </div>
    </body>
    </html>
    """

    public static let markdown = """
    # dev2kit

    Local-first, **security-focused** API client. Works *offline*; input never leaves the Mac.

    ## Features

    - [x] Collections and environments
    - [x] Workbench tools
    - [ ] Something next

    | Tool | Category |
    |:-----|:--------:|
    | JSON | Format |
    | JWT | Encode |

    > Secrets stay in the Keychain; collections only hold `{{secret:name}}`.

    ```json
    { "id": 42, "name": "dev2kit" }
    ```
    """
}
