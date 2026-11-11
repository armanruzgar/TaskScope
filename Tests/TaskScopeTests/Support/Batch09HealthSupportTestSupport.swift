import Security
import SwiftUI
import XCTest
@testable import TaskScope

let batch09HealthInput = InstallationHealthInput(presets: [], presetsReadable: true, notificationsEnabled: true)

extension InstallationHealthReport {
    subscript(batch09 category: Category) -> Finding { findings.first { $0.category == category }! }
}
