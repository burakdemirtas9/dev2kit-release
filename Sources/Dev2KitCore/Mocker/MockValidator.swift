import Foundation

/// Tanımlardaki hata ve çakışmalar (kullanıcı isteği, 2026-11-07: "çakışan
/// istek olursa kullanıcıya belirt"). Sunucu çakışmayı `MockRouter`'ın sırasıyla
/// çözer; burada hangi tanımın kazandığı açıkça söylenir.
public struct MockIssue: Identifiable, Equatable, Sendable {
    public enum Severity: Sendable {
        /// Tanım sunulmaz ya da koşul hiç tutmaz.
        case error
        /// Çalışır ama büyük ihtimalle beklenen gibi değil.
        case warning
    }

    public let id: String
    public let endpointID: UUID
    public let scenarioID: UUID?
    public let conditionID: UUID?
    public let severity: Severity
    public let message: String
}

public enum MockValidator {
    /// Yol hatası; `nil`: geçerli. Hatalı yollu endpoint sunulmaz.
    public static func pathError(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return L10n.t("mocker.issue.pathSlash") }
        if trimmed.contains(where: { $0.isWhitespace }) { return L10n.t("mocker.issue.pathSpace") }
        if trimmed.contains("?") || trimmed.contains("#") { return L10n.t("mocker.issue.pathQuery") }
        var names: Set<String> = []
        for raw in MockPathPattern.split(trimmed) where raw.contains("{") || raw.contains("}") {
            guard raw.hasPrefix("{"), raw.hasSuffix("}"), raw.count > 2,
                  raw.dropFirst().dropLast().allSatisfy({ $0 != "{" && $0 != "}" }) else {
                return L10n.t("mocker.issue.pathParameter")
            }
            let name = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            guard names.insert(name).inserted else { return L10n.t("mocker.issue.pathDuplicateParameter", name) }
        }
        return nil
    }

    /// "POST /orders/{id}" gibi kısa ad (uyarı metinlerinde).
    public static func title(of endpoint: MockEndpoint) -> String {
        "\(endpoint.method.title) \(endpoint.path)"
    }

    public static func issues(for endpoints: [MockEndpoint]) -> [MockIssue] {
        var issues: [MockIssue] = []
        var patterns: [Int: MockPathPattern] = [:]
        for (index, endpoint) in endpoints.enumerated() {
            if let error = pathError(endpoint.path) {
                issues.append(MockIssue(id: "path-\(endpoint.id)", endpointID: endpoint.id, scenarioID: nil, conditionID: nil,
                                        severity: .error, message: error))
            } else {
                patterns[index] = MockPathPattern(endpoint.path)
            }
            issues += scenarioIssues(endpoint, pattern: patterns[index])
        }
        issues += conflicts(endpoints, patterns: patterns)
        return issues
    }

    // MARK: Endpoint çakışmaları

    private static func conflicts(_ endpoints: [MockEndpoint], patterns: [Int: MockPathPattern]) -> [MockIssue] {
        var issues: [MockIssue] = []
        let indices = patterns.keys.sorted()
        for (position, first) in indices.enumerated() {
            for second in indices[(position + 1)...] {
                let a = endpoints[first], b = endpoints[second]
                guard let pa = patterns[first], let pb = patterns[second],
                      a.method.overlaps(b.method), pa.overlaps(pb) else { continue }
                if pa.hasSameShape(as: pb), a.method == b.method {
                    // Alttaki hiç yanıt vermez.
                    issues.append(MockIssue(
                        id: "dup-\(b.id)-\(a.id)", endpointID: b.id, scenarioID: nil, conditionID: nil, severity: .error,
                        message: L10n.t("mocker.issue.duplicate", title(of: a))))
                    issues.append(MockIssue(
                        id: "dupwin-\(a.id)-\(b.id)", endpointID: a.id, scenarioID: nil, conditionID: nil, severity: .warning,
                        message: L10n.t("mocker.issue.duplicateWinner", title(of: b))))
                    continue
                }
                let rankA = MockRouter.Rank(pattern: pa, method: a.method)
                let rankB = MockRouter.Rank(pattern: pb, method: b.method)
                let winner = rankB > rankA ? b : a
                let reason: String
                if rankA.literals != rankB.literals {
                    reason = L10n.t("mocker.issue.reason.specificPath")
                } else if rankA.specificMethod != rankB.specificMethod {
                    reason = L10n.t("mocker.issue.reason.specificMethod")
                } else {
                    reason = L10n.t("mocker.issue.reason.order")
                }
                for (endpoint, other) in [(a, b), (b, a)] {
                    issues.append(MockIssue(
                        id: "overlap-\(endpoint.id)-\(other.id)", endpointID: endpoint.id, scenarioID: nil, conditionID: nil,
                        severity: .warning,
                        message: L10n.t("mocker.issue.overlap", title(of: other), title(of: winner), reason)))
                }
            }
        }
        return issues
    }

    // MARK: Senaryolar

    private static func scenarioIssues(_ endpoint: MockEndpoint, pattern: MockPathPattern?) -> [MockIssue] {
        var issues: [MockIssue] = []
        /// Önceki seçilebilir senaryolar: koşulları (normalize) ve gövde örneği.
        var earlier: [(scenario: MockScenario, index: Int, conditions: Set<String>, body: MockBodyMatcher.Example)] = []
        let parameterNames = Set(pattern?.parameterNames ?? [])
        for (index, scenario) in endpoint.scenarios.enumerated() {
            guard scenario.isActive else {
                issues.append(MockIssue(id: "empty-\(scenario.id)", endpointID: endpoint.id, scenarioID: scenario.id, conditionID: nil,
                                        severity: .warning, message: L10n.t("mocker.issue.noConditions")))
                continue
            }
            for condition in scenario.conditions {
                if let message = conditionError(condition, parameterNames: parameterNames) {
                    issues.append(MockIssue(id: "cond-\(condition.id)", endpointID: endpoint.id, scenarioID: scenario.id,
                                            conditionID: condition.id, severity: .error, message: message))
                }
            }
            let conditions = Set(scenario.conditions.map(normalized))
            let body = MockBodyMatcher.example(scenario.requestBody)
            // Üstteki senaryo bunun eşleşeceği her isteği zaten yakalıyorsa bu hiç seçilmez:
            // koşulları bunun koşullarının alt kümesi ve gövdesi bunu kapsıyor.
            if let shadow = earlier.first(where: { previous in
                previous.conditions.isSubset(of: conditions)
                    && MockBodyMatcher.covers(previous.body, previous.scenario.bodyMatch, body, scenario.bodyMatch)
            }) {
                issues.append(MockIssue(id: "shadow-\(scenario.id)", endpointID: endpoint.id, scenarioID: scenario.id, conditionID: nil,
                                        severity: .error,
                                        message: L10n.t("mocker.issue.shadowed", displayName(of: shadow.scenario, index: shadow.index))))
            }
            earlier.append((scenario, index, conditions, body))
        }
        return issues
    }

    public static func displayName(of scenario: MockScenario, index: Int) -> String {
        let name = scenario.name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? L10n.t("mocker.scenario.untitled", L10n.number(index + 1)) : name
    }

    private static func conditionError(_ condition: MockCondition, parameterNames: Set<String>) -> String? {
        let name = condition.name.trimmingCharacters(in: .whitespaces)
        if condition.usesName, name.isEmpty { return L10n.t("mocker.issue.conditionName") }
        switch condition.source {
        case .jsonBody:
            do {
                _ = try JSONPath.compile(name)
            } catch {
                return L10n.t("mocker.issue.jsonPath", error.localizedDescription)
            }
        case .pathParameter:
            let bare = name.trimmingCharacters(in: CharacterSet(charactersIn: "{} "))
            if !parameterNames.contains(bare) { return L10n.t("mocker.issue.pathParameterMissing", bare) }
        case .header, .query, .bodyText:
            break
        }
        if condition.usesValue, condition.comparison == .contains, condition.value.isEmpty {
            return L10n.t("mocker.issue.containsEmpty")
        }
        return nil
    }

    private static func normalized(_ condition: MockCondition) -> String {
        var name = condition.name.trimmingCharacters(in: .whitespaces)
        if condition.source == .header { name = name.lowercased() }
        if !condition.usesName { name = "" }
        let value = condition.usesValue ? condition.value.trimmingCharacters(in: .whitespaces) : ""
        return [condition.source.rawValue, name, condition.comparison.rawValue, value].joined(separator: "\u{1F}")
    }
}
