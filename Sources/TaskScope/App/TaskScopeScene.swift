import Foundation

/// The app's window scenes. The ids open them and the titles identify their
/// NSWindows (quiet-launch suppression, fronting the main window, and which
/// view presents reports), so both are declared once, here.
enum TaskScopeScene: String, CaseIterable {
    case main = "processes"
    case about
    case onboarding

    var id: String { rawValue }

    var title: String {
        switch self {
        case .main: "TaskScope"
        case .about: "About TaskScope"
        case .onboarding: "Onboarding"
        }
    }
}
