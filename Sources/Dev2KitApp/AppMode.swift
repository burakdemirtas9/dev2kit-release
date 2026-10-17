import Foundation

/// Pencerenin üst ortasındaki seçici: bugüne kadarki API istemcisi ve
/// geliştirici araçları (docs/V2.md).
enum AppMode: String, CaseIterable, Identifiable {
    case apiClient
    case workbench

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apiClient: return "API Client"
        case .workbench: return "Workbench"
        }
    }
}
