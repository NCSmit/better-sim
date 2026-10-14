import Foundation

/// One build Xcode recorded in a project's DerivedData.
struct BuildRecord: Equatable, Sendable {
    let project: String
    let scheme: String
    let started: Date
    let duration: TimeInterval
    let succeeded: Bool
}

/// Build times from DerivedData. Xcode notes every build it runs in Logs/Build/LogStoreManifest.plist, with when it
/// started and stopped. Builds run with xcodebuild on the command line aren't recorded there.
enum BuildInsights {
    struct Summary: Equatable {
        let count: Int
        let average: TimeInterval
        let slowest: TimeInterval
        let failures: Int
        /// How the average compares with the period before, as a fraction: 0.2 means 20% slower.
        let change: Double?
    }

    static func parse(manifest: Data, project: String) -> [BuildRecord] {
        guard let plist = (try? PropertyListSerialization.propertyList(from: manifest, format: nil)) as? [String: Any],
              let logs = plist["logs"] as? [String: [String: Any]]
        else { return [] }
        return logs.values.compactMap { log in
            guard let title = log["title"] as? String, title.hasPrefix("Build"),
                  let start = (log["timeStartedRecording"] as? NSNumber)?.doubleValue,
                  let stop = (log["timeStoppedRecording"] as? NSNumber)?.doubleValue, stop >= start
            else { return nil }
            let status = (log["primaryObservable"] as? [String: Any])?["highLevelStatus"] as? String
            return BuildRecord(
                project: project,
                scheme: log["schemeIdentifier-schemeName"] as? String ?? project,
                started: Date(timeIntervalSinceReferenceDate: start),
                duration: stop - start,
                succeeded: status != "E"
            )
        }
        .sorted { $0.started > $1.started }
    }

    static func scan(derivedData: URL = RecentBuild.derivedData) -> [BuildRecord] {
        let projects = (try? FileManager.default.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: nil)) ?? []
        return projects.flatMap { folder -> [BuildRecord] in
            guard let data = try? Data(contentsOf: folder.appending(path: "Logs/Build/LogStoreManifest.plist")) else { return [] }
            return parse(manifest: data, project: projectName(folder.lastPathComponent))
        }
        .sorted { $0.started > $1.started }
    }

    /// DerivedData folders are named after the project, then a dash and a hash.
    static func projectName(_ folder: String) -> String {
        guard let dash = folder.lastIndex(of: "-"), folder[folder.index(after: dash)...].count >= 20 else { return folder }
        return String(folder[..<dash])
    }

    static func summary(_ records: [BuildRecord], days: Int = 7, now: Date = .now) -> Summary? {
        let period = TimeInterval(days * 86_400)
        let recent = records.filter { now.timeIntervalSince($0.started) <= period }
        guard !recent.isEmpty else { return nil }
        let earlier = records.filter { (period...period * 2).contains(now.timeIntervalSince($0.started)) }
        let average = recent.map(\.duration).reduce(0, +) / Double(recent.count)
        let previous = earlier.isEmpty ? nil : earlier.map(\.duration).reduce(0, +) / Double(earlier.count)
        return Summary(
            count: recent.count,
            average: average,
            slowest: recent.map(\.duration).max() ?? 0,
            failures: recent.filter { !$0.succeeded }.count,
            change: previous.flatMap { $0 > 0 ? (average - $0) / $0 : nil }
        )
    }

    static func format(_ duration: TimeInterval) -> String {
        duration < 60 ? "\(Int(duration.rounded()))s" : "\(Int(duration) / 60)m \(Int(duration) % 60)s"
    }
}
