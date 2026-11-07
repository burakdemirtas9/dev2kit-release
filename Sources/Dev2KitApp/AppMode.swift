import Foundation

/// Pencerenin üst ortasındaki seçici: API istemcisi, geliştirici araçları
/// (docs/V2.md) ve yerel mock sunucusu.
enum AppMode: String, CaseIterable, Identifiable {
    case apiClient
    case workbench
    /// Yerel mock HTTP sunucusu (2026-11-07).
    case mocker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apiClient: return "API Client"
        case .workbench: return "Workbench"
        case .mocker: return "Mocker"
        }
    }
}
