import Foundation

enum PresetInputParser {
    struct ParseResult<Value> {
        var value: Value
        var errors: [String]
    }

    static func list(from value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func parseUserLaunchAgentJobs(
        labels: String,
        paths: String
    ) -> ParseResult<[UserLaunchAgentJob]> {
        let labelList = list(from: labels)
        let pathList = list(from: paths)
        guard !labelList.isEmpty || !pathList.isEmpty else {
            return ParseResult(value: [], errors: [])
        }
        guard labelList.count == pathList.count else {
            return ParseResult(
                value: [],
                errors: ["Launch-agent labels and plist paths must have the same item count."]
            )
        }

        return ParseResult(
            value: zip(labelList, pathList).map {
                UserLaunchAgentJob(label: $0, plistPath: $1)
            },
            errors: []
        )
    }

}
