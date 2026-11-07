import Foundation
import Dev2KitCore

// MARK: - Donma bekçisi: anlık durum ve açılış bildirimi

extension AppState {
    /// Bekçinin her yoklamasında (saniyede bir, ana iş parçacığında): hangi
    /// ekran ve verinin kaba büyüklüğü. İçerik yok (`DiagnosticContext`).
    /// Ucuz: uzunluklar UTF-8 sayımı, `{{` taraması sınırlı.
    var diagnosticContext: DiagnosticContext {
        switch mode {
        case .workbench: return DiagnosticContext(screen: .workbench)
        case .mocker: return DiagnosticContext(screen: .mocker)
        case .apiClient: break
        }
        guard let id = selectedRequestID, let request = request(withID: id) else {
            return DiagnosticContext(screen: .apiClientNoRequest)
        }
        let headers = DiagnosticContext.headerFigures(request.headers)
        var context = DiagnosticContext(
            screen: openExample != nil ? .apiClientExample : Self.diagnosticScreen(editorTab),
            headerCount: headers.count,
            longestHeaderValue: headers.longest,
            headerVariables: headers.variables,
            bodySize: DiagnosticSize(Self.diagnosticBodyLength(request.body))
        )
        if case .success(let display)? = responses[id] {
            context.responseSize = DiagnosticSize(display.data.body.count)
            context.responseKind = Self.diagnosticKind(display.language)
        }
        return context
    }

    /// Bekçi önceki oturumu kapattıysa açılışta bir kez söylenir; başka bir
    /// açılış mesajı varsa onun altına satır olarak eklenir.
    func noteWatchdogTermination(_ record: WatchdogTermination) {
        let title = L10n.t("watchdog.terminated.title")
        let text = L10n.t("watchdog.terminated.message", L10n.number(record.stallSeconds),
                          String(format: "%.1f", Double(record.memoryMB) / 1024))
        if let startupMessage {
            self.startupMessage = Self.adding(MessageLine(.warning, "\(title) \(text)"), to: startupMessage)
        } else {
            startupMessage = ResultMessage(kind: .warning, title: title, message: text)
        }
    }

    private static func diagnosticScreen(_ tab: EditorTab) -> DiagnosticContext.Screen {
        switch tab {
        case .headers: .apiClientHeaders
        case .body: .apiClientBody
        case .auth: .apiClientAuth
        case .params: .apiClientParams
        case .token: .apiClientToken
        }
    }

    private static func diagnosticBodyLength(_ body: RequestBody) -> Int {
        switch body {
        case .none: 0
        case .raw(let content, _): content.utf8.count
        case .formURLEncoded(let fields), .multipartForm(let fields):
            fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        }
    }

    private static func diagnosticKind(_ language: CodeLanguage) -> DiagnosticContext.ContentKind {
        switch language {
        case .json: .json
        case .markup: .markup
        case .javascript: .javascript
        case .css: .css
        case .sql: .sql
        case .markdown: .markdown
        case .plain: .plain
        }
    }
}
