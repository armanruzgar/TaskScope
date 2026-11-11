import XCTest
@testable import TaskScope

final class Batch04CompatibilityFixTests: XCTestCase {
    func testSessionServiceIsVerifiedByJobPIDOwnerAndKernelPath() async {
        for scenario in ["root", "user", "wrong-owner", "wrong-path", "missing-path", "absent"] {
            let uid: uid_t = scenario == "root" ? 0 : (scenario == "wrong-owner" ? 502 : 501)
            let process = batch04Process(pid: 42, uid: uid, path: "/Applications/GlobalProtect.app/Contents/Resources/PanGPS")
            let runtime = GlobalProtectCompatibilityRuntime(userID: 501, inspectPlist: { _ in .installed(disabledByDefault: false) }, runProbe: { probe in
                switch probe {
                case .service(let service):
                    if service == .pangps && scenario != "absent" { return batch04Result(launchctlPrintOutput(pid: 42)) }
                    return batch04Result(error: "Could not find service \"\(service.label)\" in domain", code: 113)
                case .userDisabled, .systemDisabled: return batch04Result("disabled services = {\n}")
                case .macOSVersion: return batch04Result("14.0")
                case .macOSBuild: return batch04Result("23A344")
                }
            }, loadInventory: { .success([process]) }, versions: { (nil, nil, nil, nil) }, executablePathForPID: { _ in
                scenario == "wrong-path" ? "/tmp/PanGPS" : (scenario == "missing-path" ? nil : process.executablePath)
            })
            let report = await GlobalProtectCompatibilityChecker(runtime: runtime).check(keepOffRequested: false)
            XCTAssertEqual(report.sessionProcessVerified, ["root", "user"].contains(scenario))
            XCTAssertTrue(report.redactedSummary.contains("Login-session VPN service process:"))
            XCTAssertTrue(report.redactedSummary.contains("Root PanGPS can belong to the login-session job (setuid)"))
            XCTAssertTrue(report.redactedSummary.contains("login-session VPN service, optional install"))
            if scenario == "absent" { XCTAssertTrue(report.redactedSummary.contains("Login-session VPN service process:\nNot loaded.")) }
            XCTAssertFalse(report.redactedSummary.contains("424242"))
        }
    }
}
