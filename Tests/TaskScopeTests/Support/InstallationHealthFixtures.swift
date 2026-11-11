import Foundation
@testable import TaskScope

// Health inputs and reports shared by the Health tests.

let healthDate = Date(timeIntervalSince1970: 1_000)

let healthInput = InstallationHealthInput(presets: [], presetsReadable: true, notificationsEnabled: true)

func healthReport(
    notifications: NotificationService.AuthorizationState = .authorized,
    available: Bool = true, accessibility: Bool = true, login: LoginItemState = .enabled,
    signature: HealthSignature = .signed, identity: InstallationHealthReport.State = .healthy,
    metadata: InstallationHealthReport.State = .healthy,
    paths: [HealthPathFinding] = [], input: InstallationHealthInput = healthInput,
    recoveries: Set<InstallationHealthReport.Recovery> = Set(InstallationHealthReport.Recovery.allCases),
    date: Date = healthDate
) -> InstallationHealthReport {
    InstallationHealthAssessment.report(
        input: input,
        permissions: .init(notificationsAvailable: available, notifications: notifications,
                           accessibilityTrusted: accessibility, loginItem: login),
        bundle: .init(identity: identity, identityDetail: "Bundle evidence", signature: signature, metadata: metadata),
        paths: paths, recoveries: recoveries, checkedAt: date
    )
}

extension InstallationHealthReport {
    subscript(_ category: Category) -> Finding { findings.first { $0.category == category }! }
}
