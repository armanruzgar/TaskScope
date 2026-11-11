import Carbon.HIToolbox
import SwiftUI
import ViewInspector
import XCTest
@testable import TaskScope

@MainActor
final class SystemIntegrationRegressionTests: XCTestCase {
    func testLoginRecoveryStatesCanUnregisterFromPresets() throws {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for state in [LoginItemState.requiresApproval, .notFound] {
            let service = IntegrationLoginService(state: state)
            let manager = LoginItemManager(service: service)
            let view = presets(manager: manager, defaults: defaults)

            try view.inspect().find(button: state == .notFound ? "Remove Stale Login Item" : "Turn Off Launch at Login").tap()

            XCTAssertEqual(service.unregisterCount, 1)
            XCTAssertEqual(service.registerCount, 0)
            XCTAssertEqual(service.settingsCount, 0)
            XCTAssertEqual(manager.state, .notRegistered)
            XCTAssertNoThrow(try view.inspect().find(text: "Launch at Login is off."))
        }
    }

    func testLoginRecoveryStatesShowUnregisterFailureInPresets() throws {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for state in [LoginItemState.requiresApproval, .notFound] {
            let service = IntegrationLoginService(state: state)
            service.refusesUnregister = true
            let manager = LoginItemManager(service: service)
            let view = presets(manager: manager, defaults: defaults)

            try view.inspect().find(button: state == .notFound ? "Remove Stale Login Item" : "Turn Off Launch at Login").tap()

            XCTAssertEqual(service.unregisterCount, 1)
            XCTAssertEqual(manager.state, state)
            XCTAssertNoThrow(try view.inspect().find(text: "Could not update Launch at Login: Removal refused."))
        }
    }

    func testEveryInvalidSavedHotkeyMigratesAndRegistersWithAReason() {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts: [(UInt32, UInt32, String)] = [
            (UInt32(kVK_Space), UInt32(optionKey), "Command or Control"),
            (UInt32(kVK_F5), UInt32(shiftKey), "Command or Control"),
            (UInt32(kVK_ANSI_T), UInt32(optionKey | shiftKey), "Command or Control"),
            (UInt32.max, UInt32(cmdKey), "supported key")
        ]
        for (key, modifiers, reason) in shortcuts {
            for enabled in [true, false] {
                defaults.set(["enabled": enabled, "keyCode": key, "modifiers": modifiers], forKey: "hotkey")
                let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
                defer { manager.unregister() }
                manager.register()

                XCTAssertEqual(manager.displayString, "⌃⌥⌘T")
                XCTAssertEqual(manager.hotkeyEnabled, enabled)
                XCTAssertEqual(manager.registrationStatus, enabled ? .registered : .disabled)
                XCTAssertEqual(manager.isRegistered, enabled)
                XCTAssertTrue(manager.migrationNotice?.contains(reason) == true)
                let reloaded = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
                XCTAssertEqual(reloaded.displayString, "⌃⌥⌘T")
                XCTAssertEqual(reloaded.migrationNotice, manager.migrationNotice)
            }
        }
    }

    func testMigrationNoticeSurvivesRelaunchUntilAShortcutIsRecorded() {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["enabled": true, "keyCode": UInt32(kVK_ANSI_K), "modifiers": UInt32(cmdKey)], forKey: "hotkey")
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
        let reloaded = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
        defer { reloaded.unregister() }

        XCTAssertNotNil(manager.migrationNotice)
        XCTAssertEqual(reloaded.migrationNotice, manager.migrationNotice)
        XCTAssertTrue(reloaded.updateShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey)))
        let recorded = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
        XCTAssertNil(recorded.migrationNotice)
    }

    func testRefusedRecordingPreservesActiveAndFailedRegistrationStatus() {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for refusesRegistration in [false, true] {
            let backend = IntegrationHotkeyBackend()
            backend.refusesRegistration = refusesRegistration
            let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: backend)
            defer { manager.unregister() }
            manager.register()
            let status = manager.registrationStatus

            XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey)))
            XCTAssertEqual(manager.registrationStatus, status)
            XCTAssertEqual(manager.isRegistered, !refusesRegistration)
            XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey)))
            XCTAssertEqual(manager.registrationStatus, status)
        }
    }

    func testWrongTypeHotkeyIsBackedUpAndCannotBeOverwrittenByEdits() throws {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let payloads: [Any] = ["unreadable shortcut", ["unreadable", "array"], Data([0, 1, 2])]
        for payload in payloads {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(payload, forKey: "hotkey")
            let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
            defer { manager.unregister() }
            manager.hotkeyEnabled = false
            _ = manager.updateShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey))

            XCTAssertTrue((defaults.object(forKey: "hotkey") as? NSObject)?.isEqual(payload) == true)
            let backup = try XCTUnwrap(defaults.data(forKey: "hotkey.corruptBackup"))
            let restored = try PropertyListSerialization.propertyList(from: backup, format: nil)
            XCTAssertTrue((restored as? NSObject)?.isEqual(payload) == true)
        }
    }

    func testActivityMonitorNotGrantedMessageDoesNotClaimDenial() async {
        let coordinator = ActivityMonitorCoordinator(
            opener: IntegrationActivityOpener(),
            processChecker: IntegrationActivityChecker(),
            selector: IntegrationActivitySelector(result: .accessibilityDenied("macOS has not granted access.")),
            sleep: { _ in }
        )
        let outcome = await coordinator.openAndSelect(identity: ProcessIdentity(pid: 42, startTime: "fixture", command: "fixture", executablePath: "/fixture"))
        XCTAssertTrue(outcome.message(for: 42).contains("Accessibility access is not granted"))
        XCTAssertFalse(outcome.message(for: 42).contains("was denied"))
        XCTAssertTrue(outcome.message(for: 42).contains("Privacy & Security > Accessibility"))
    }

    func testActivityMonitorContextMenuPassesTheRowsIdentityInBothPresentations() async throws {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let process = AppProcess.fixture(
            pid: 42, parentPID: 1, cpu: 0, memoryMB: 1, command: "Original",
            executablePath: "/Applications/Original.app/Contents/MacOS/Original", elapsedTime: "00:01",
            startTime: "Fri Oct 16 10:00:00 2026", netInKB: nil, netOutKB: nil, diskReadBytes: nil, diskWriteBytes: nil
        )
        for style in [TaskScopePresentationStyle.expandedWindow, .menuBarCompact] {
            let called = expectation(description: "handoff requested")
            let activity = IntegrationActivityCoordinator(onRequest: { called.fulfill() })
            let view = TaskScopePopoverView(
                processManager: processManager(),
                loginItemManager: LoginItemManager(service: IntegrationLoginService(state: .notRegistered)),
                settings: SettingsStore(userDefaults: defaults, key: "settings"),
                watchedApps: WatchedAppsStore(userDefaults: defaults, key: "presets"),
                savedSelections: SavedSelectionsStore(userDefaults: defaults, key: "selections"),
                autoStopRules: AutoStopRulesStore(userDefaults: defaults, key: "rules", eventsKey: "events", inventory: ScriptedInventory(processes: [])),
                history: ProcessHistory(inventory: ScriptedInventory(processes: [])),
                presentationStyle: style,
                activityMonitor: activity,
                commandBus: AppCommandBus(),
                quitAction: {}
            )
            try view.processContextMenu(for: process).inspect().find(button: "Open in Activity Monitor").tap()
            await fulfillment(of: [called], timeout: 2)
            // The coordinator protocol no longer has a PID-only entry, so the
            // identity handoff is the only one a view can request.
            XCTAssertEqual(activity.requestedIdentity, process.identity)
        }
    }

    func testLoginToggleKeepsItsEnableAndDisableBehavior() throws {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for state in [LoginItemState.requiresApproval, .notFound, .notRegistered, .enabled] {
            let service = IntegrationLoginService(state: state)
            let view = presets(manager: LoginItemManager(service: service), defaults: defaults)
            try view.inspect().find(ViewType.Toggle.self).tap()
            XCTAssertEqual(service.registerCount, state == .notFound || state == .notRegistered ? 1 : 0)
            XCTAssertEqual(service.settingsCount, state == .requiresApproval ? 1 : 0)
            XCTAssertEqual(service.unregisterCount, state == .enabled ? 1 : 0)
        }
    }

    func testHotkeyNoticeDismissalPersistsAndPreservesUnknownFields() throws {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([
            "enabled": false, "keyCode": UInt32(kVK_ANSI_K), "modifiers": UInt32(cmdKey),
            "futureField": ["value": "keep me"]
        ], forKey: "hotkey")
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
        let view = HotkeySettingsView(hotkey: manager)
        XCTAssertNoThrow(try view.inspect().find(text: XCTUnwrap(manager.migrationNotice)))
        try view.inspect().find(button: "Dismiss Shortcut Notice").tap()

        let reloaded = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
        XCTAssertNil(reloaded.migrationNotice)
        XCTAssertEqual(defaults.dictionary(forKey: "hotkey")?["futureField"] as? [String: String], ["value": "keep me"])
    }

    func testHotkeyRefusalAndRegistrationStatusAreBothVisible() throws {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
        defer { manager.unregister() }
        manager.register()
        XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey)))
        let view = HotkeySettingsView(hotkey: manager)
        XCTAssertNoThrow(try view.inspect().find(text: "Hotkey is registered."))
        XCTAssertNoThrow(try view.inspect().find(text: XCTUnwrap(manager.lastRecordingError)))
        try view.inspect().find(button: "Record New Hotkey").tap()
        XCTAssertNil(manager.lastRecordingError)
        XCTAssertEqual(manager.registrationStatus, .registered)
    }

    func testHotkeyRecoveryResetRequiresExplicitActionAndKeepsPriorBackups() throws {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let older = try PropertyListSerialization.data(fromPropertyList: "older", format: .binary, options: 0)
        defaults.set(older, forKey: "hotkey.corruptBackup")
        defaults.set("unreadable shortcut", forKey: "hotkey")
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
        defer { manager.unregister() }
        manager.register()
        XCTAssertTrue(manager.isReadOnlyAfterCorruption)
        XCTAssertFalse(manager.isRegistered)
        XCTAssertFalse(manager.updateShortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | shiftKey)))
        let view = HotkeySettingsView(hotkey: manager)
        XCTAssertTrue(try view.inspect().find(ViewType.Toggle.self).isDisabled())
        XCTAssertNoThrow(try view.inspect().find(text: XCTUnwrap(manager.recoveryMessage)))
        let backup = try XCTUnwrap(defaults.data(forKey: "hotkey.corruptBackup.2"))
        XCTAssertEqual(try PropertyListSerialization.propertyList(from: backup, format: nil) as? String, "unreadable shortcut")

        try view.inspect().find(button: "Reset Hotkey Settings After Backup").tap()

        XCTAssertFalse(manager.isReadOnlyAfterCorruption)
        XCTAssertNil(manager.recoveryMessage)
        XCTAssertTrue(manager.isRegistered)
        XCTAssertEqual(manager.displayString, "⌃⌥⌘T")
        XCTAssertEqual(defaults.data(forKey: "hotkey.corruptBackup"), older)
        XCTAssertEqual(defaults.data(forKey: "hotkey.corruptBackup.2"), backup)
        let reloaded = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
        XCTAssertFalse(reloaded.isReadOnlyAfterCorruption)
        XCTAssertTrue(reloaded.hotkeyEnabled)
    }

    func testHotkeyRecoveryWithFullBackupSlotsLeavesPrimaryUntouched() {
        let suite = "TaskScope.SystemIntegration.\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for slot in 1...PersistenceRecovery.maximumBackupSlots {
            defaults.set(Data([UInt8(slot)]), forKey: slot == 1 ? "hotkey.corruptBackup" : "hotkey.corruptBackup.\(slot)")
        }
        defaults.set("unreadable shortcut", forKey: "hotkey")
        let manager = HotkeyManager(defaults: defaults, defaultsKey: "hotkey", backend: IntegrationHotkeyBackend())
        manager.hotkeyEnabled = true
        XCTAssertTrue(manager.isReadOnlyAfterCorruption)
        XCTAssertFalse(manager.isRegistered)
        XCTAssertTrue(manager.recoveryMessage?.contains("not backed up") == true)
        XCTAssertEqual(defaults.string(forKey: "hotkey"), "unreadable shortcut")
        for slot in 1...PersistenceRecovery.maximumBackupSlots {
            XCTAssertEqual(defaults.data(forKey: slot == 1 ? "hotkey.corruptBackup" : "hotkey.corruptBackup.\(slot)"), Data([UInt8(slot)]))
        }
    }

    func testActivityMonitorRejectsReusedPIDAndChangedOrUnavailableKernelPathBeforeOpening() async {
        let expected = activityIdentity()
        for variant in 0..<5 {
            let evidence = IntegrationProcessEvidence()
            switch variant {
            case 0: evidence.start = (1_600_000_001, 0)
            case 1: evidence.path = "/Applications/Replacement"
            case 2: evidence.start = nil
            case 3: evidence.path = nil
            default: evidence.onPathRead = { evidence.start = (1_600_000_000, 1) }
            }
            let opener = IntegrationActivityOpener()
            let selector = IntegrationActivitySelector(result: .selected)
            let coordinator = identityCoordinator(evidence: evidence, opener: opener, selector: selector)

            let outcome = await coordinator.openAndSelect(identity: expected)

            XCTAssertEqual(outcome, .missingProcess)
            XCTAssertEqual(opener.openCount, 0)
            XCTAssertTrue(selector.requestedPIDs.isEmpty)
        }
    }

    func testActivityMonitorRechecksIdentityAfterOpeningAndOnEachRetry() async {
        for changeDuringOpen in [true, false] {
            let evidence = IntegrationProcessEvidence()
            let opener = IntegrationActivityOpener()
            let selector = IntegrationActivitySelector(results: [.notReady, .selected])
            if changeDuringOpen { opener.onOpen = { evidence.start = (1_600_000_001, 0) } }
            let coordinator = identityCoordinator(evidence: evidence, opener: opener, selector: selector) { _ in
                evidence.path = "/Applications/Replacement"
            }

            let outcome = await coordinator.openAndSelect(identity: activityIdentity())

            XCTAssertEqual(outcome, .missingProcess)
            XCTAssertEqual(opener.openCount, 1)
            XCTAssertEqual(selector.requestedPIDs, changeDuringOpen ? [] : [42])
        }
    }

    func testActivityMonitorDoesNotReportSuccessIfIdentityChangesDuringSelection() async {
        let evidence = IntegrationProcessEvidence()
        let selector = IntegrationActivitySelector(result: .selected)
        selector.onSelect = { evidence.start = (1_600_000_001, 0) }
        let coordinator = identityCoordinator(evidence: evidence, opener: IntegrationActivityOpener(), selector: selector)

        let outcome = await coordinator.openAndSelect(identity: activityIdentity())

        XCTAssertEqual(outcome, .missingProcess)
        XCTAssertEqual(selector.requestedPIDs, [42])
    }

    func testActivityMonitorAcceptsMatchingKernelIdentityRegardlessOfDisplayCommand() async {
        let evidence = IntegrationProcessEvidence()
        let opener = IntegrationActivityOpener()
        let selector = IntegrationActivitySelector(results: [.notReady, .selected])
        let coordinator = identityCoordinator(evidence: evidence, opener: opener, selector: selector)
        var expected = activityIdentity()
        expected.command = "argv can change"

        let outcome = await coordinator.openAndSelect(identity: expected)

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(opener.openCount, 1)
        XCTAssertEqual(selector.requestedPIDs, [42, 42])
        XCTAssertEqual(evidence.startReadCount, 8) // before open, each attempt, and after selection
    }

    private func activityIdentity() -> ProcessIdentity {
        ProcessIdentity(pid: 42, startTime: "Sun Sep 13 12:26:40 2020", command: "Original", executablePath: "/Applications/Original")
    }

    private func identityCoordinator(
        evidence: IntegrationProcessEvidence,
        opener: IntegrationActivityOpener,
        selector: IntegrationActivitySelector,
        sleep: @escaping @MainActor (UInt64) async -> Void = { _ in }
    ) -> ActivityMonitorCoordinator {
        ActivityMonitorCoordinator(
            opener: opener,
            processChecker: SystemActivityMonitorProcessChecker(
                readStartTime: { _ in evidence.startReadCount += 1; return evidence.start },
                executablePathForPID: { _ in evidence.onPathRead(); return evidence.path }
            ),
            selector: selector, maximumSelectionAttempts: 3, retryDelayNanoseconds: 0, sleep: sleep
        )
    }

    private func presets(manager: LoginItemManager, defaults: UserDefaults) -> PresetsSectionView {
        PresetsSectionView(
            processManager: processManager(), loginItemManager: manager,
            settings: SettingsStore(userDefaults: defaults, key: "settings"),
            watchedApps: WatchedAppsStore(userDefaults: defaults, key: "presets"),
            confirmationState: ProcessConfirmationState()
        )
    }

    private func processManager() -> ProcessManager {
        ProcessManager(
            processInventory: ScriptedInventory(processes: []), verificationInventory: ScriptedInventory(processes: []),
            processSignaler: FakeSignaler.forbidding("Unexpected signal"), lifecycle: FakeLifecycle(), settleAfterProcessChange: {},
            dependencies: .inert
        )
    }
}

private final class IntegrationLoginService: LoginItemServicing {
    var state: LoginItemState
    var refusesUnregister = false
    var unregisterCount = 0
    var registerCount = 0
    var settingsCount = 0
    init(state: LoginItemState) { self.state = state }
    func register() throws { registerCount += 1; state = .enabled }
    func unregister() throws {
        unregisterCount += 1
        if refusesUnregister { throw IntegrationLoginError.refused }
        state = .notRegistered
    }
    func openSystemSettings() { settingsCount += 1 }
}

private enum IntegrationLoginError: LocalizedError {
    case refused
    var errorDescription: String? { "Removal refused." }
}

@MainActor
private final class IntegrationHotkeyBackend: HotkeyRegistrationBackend {
    var refusesRegistration = false
    func installEventHandler(for manager: HotkeyManager) -> OSStatus { noErr }
    func register(keyCode: UInt32, modifiers: UInt32, identifier: EventHotKeyID) -> (status: OSStatus, reference: EventHotKeyRef?) {
        refusesRegistration ? (OSStatus(eventHotKeyExistsErr), nil) : (noErr, OpaquePointer(bitPattern: 1))
    }
    func unregister(_ reference: EventHotKeyRef) {}
}

@MainActor
private final class IntegrationActivityCoordinator: ActivityMonitorCoordinating {
    var requestedIdentity: ProcessIdentity?
    let onRequest: () -> Void
    init(onRequest: @escaping () -> Void) { self.onRequest = onRequest }
    func openAndSelect(identity: ProcessIdentity) async -> ActivityMonitorHandoffOutcome {
        requestedIdentity = identity
        onRequest()
        return .missingProcess
    }
}

@MainActor
private final class IntegrationActivityOpener: ActivityMonitorOpening {
    var openCount = 0
    var onOpen: () -> Void = {}
    func open() async throws { openCount += 1; onOpen() }
}

@MainActor
private struct IntegrationActivityChecker: ActivityMonitorProcessChecking {
    func processMatches(identity: ProcessIdentity) -> Bool { true }
}

@MainActor
private final class IntegrationActivitySelector: ActivityMonitorProcessSelecting {
    var results: [ActivityMonitorSelectionAttempt]
    var requestedPIDs: [Int32] = []
    var onSelect: () -> Void = {}
    init(result: ActivityMonitorSelectionAttempt) { results = [result] }
    init(results: [ActivityMonitorSelectionAttempt]) { self.results = results }
    func select(pid: Int32, timeout: TimeInterval) async -> ActivityMonitorSelectionAttempt {
        requestedPIDs.append(pid)
        onSelect()
        return results.isEmpty ? .notReady : results.removeFirst()
    }
}

@MainActor
private final class IntegrationProcessEvidence {
    var start: (seconds: UInt64, microseconds: UInt64)? = (1_600_000_000, 0)
    var path: String? = "/Applications/Original"
    var startReadCount = 0
    var onPathRead: () -> Void = {}
}
