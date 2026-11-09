import Foundation

/// Single source of truth for the user-facing version. Keep in sync with
/// MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml.
enum AppVersion {
    static let marketing = "1.1.0"
    static let build = "3"
    static var display: String { "\(marketing) (\(build))" }
}
