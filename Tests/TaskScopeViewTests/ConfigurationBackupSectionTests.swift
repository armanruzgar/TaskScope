import Carbon.HIToolbox
import ViewInspector
import XCTest
@testable import TaskScope

@MainActor
final class ConfigurationBackupSectionTests: XCTestCase {
    func testTheGeneralTabOffersExportAndImportAndShowsTheOutcome() throws {
        let defaults = try XCTUnwrap(InMemoryUserDefaults(suiteName: "TaskScope.ConfigurationBackupSectionTests.\(UUID().uuidString)"))
        let settings = SettingsStore(userDefaults: defaults, key: "settings")
        let actions = ConfigurationBackupActions()
        var calls: [String] = []
        let tab = GeneralSettingsTab(
            settings: settings, notificationService: .forTests(),
            backupSection: ConfigurationBackupSection(
                actions: actions,
                exportConfiguration: { calls.append("export") },
                importConfiguration: { calls.append("import") }
            )
        )
        try tab.inspect().find(button: "Export Configuration…").tap()
        try tab.inspect().find(button: "Import Configuration…").tap()
        XCTAssertEqual(calls, ["export", "import"])

        actions.importSummary = "Imported settings."
        actions.exportNote = "The backup leaves out settings."
        XCTAssertNoThrow(try tab.inspect().find(text: "Imported settings."))
        XCTAssertNoThrow(try tab.inspect().find(text: "The backup leaves out settings."))
        XCTAssertThrowsError(
            try GeneralSettingsTab(settings: settings, notificationService: .forTests()).inspect()
                .find(button: "Export Configuration…"),
            "Without the stores a backup needs, the section is not shown"
        )
    }
}
