import Foundation

struct UsageSnapshot: Codable, Hashable {
    let timestamp: Date
    let fiveHourPercent: Double
    let sevenDayPercent: Double
}

struct UsageInfo: Codable {
    var fiveHourPercent: Double
    var fiveHourResetSeconds: Int
    var sevenDayPercent: Double
    var sevenDayResetSeconds: Int
    var history: [UsageSnapshot]
    var lastUpdated: Date
    var tokensUsed5h: Int?
    var tokensUsed7d: Int?
    var tokenLimit5h: Int?
    var tokenLimit7d: Int?

    static let empty = UsageInfo(
        fiveHourPercent: 0, fiveHourResetSeconds: 18000,
        sevenDayPercent: 0, sevenDayResetSeconds: 604800,
        history: [], lastUpdated: Date(),
        tokensUsed5h: 0, tokensUsed7d: 0,
        tokenLimit5h: 1_000_000, tokenLimit7d: 50_000_000
    )
}

struct UsageConfig: Codable {
    var fiveHourTokenLimit: Int
    var sevenDayTokenLimit: Int

    static let defaultConfig = UsageConfig(
        fiveHourTokenLimit: 1_000_000,
        sevenDayTokenLimit: 50_000_000
    )
}

class UsageFetcher {
    static let appGroupID = "com.alejandro.claudeusage.shared"

    // Real home directory (works even inside sandbox)
    static var realHomeDirectory: String {
        guard let pw = getpwuid(getuid()) else {
            return NSHomeDirectory()
        }
        return String(cString: pw.pointee.pw_dir)
    }

    static var sharedContainerURL: URL {
        let dir = URL(fileURLWithPath: realHomeDirectory)
            .appendingPathComponent("Library/Application Support/ClaudeUsageWidget")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var dataFileURL: URL {
        sharedContainerURL.appendingPathComponent("usage_data.json")
    }

    static var configFileURL: URL {
        sharedContainerURL.appendingPathComponent("config.json")
    }

    static func loadConfig() -> UsageConfig {
        guard let data = try? Data(contentsOf: configFileURL),
              let config = try? JSONDecoder().decode(UsageConfig.self, from: data) else {
            let defaultConfig = UsageConfig.defaultConfig
            saveConfig(defaultConfig)
            return defaultConfig
        }
        return config
    }

    static func saveConfig(_ config: UsageConfig) {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configFileURL)
        }
    }

    static func loadUsageInfo() -> UsageInfo {
        guard let data = try? Data(contentsOf: dataFileURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(UsageInfo.self, from: data)) ?? .empty
    }

    static func fetchAndSave() -> UsageInfo {
        let config = loadConfig()
        let claudeProjects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)

        var tokens5h = 0
        var tokens7d = 0
        var buckets: [String: (t5h: Int, t7d: Int)] = [:]

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjects, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return .empty }

        for projectDir in projectDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                // Skip files not modified in last 7 days
                if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
                   let modDate = attrs[.modificationDate] as? Date,
                   modDate < sevenDaysAgo { continue }

                guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }

                for line in content.components(separatedBy: .newlines) {
                    guard !line.isEmpty,
                          let lineData = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          json["type"] as? String == "assistant",
                          let tsStr = json["timestamp"] as? String,
                          let message = json["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any] else { continue }

                    // Parse timestamp
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let ts: Date
                    if let d = formatter.date(from: tsStr) { ts = d }
                    else {
                        formatter.formatOptions = [.withInternetDateTime]
                        guard let d = formatter.date(from: tsStr) else { continue }
                        ts = d
                    }

                    guard ts >= sevenDaysAgo else { continue }

                    let outTokens = usage["output_tokens"] as? Int ?? 0
                    let inTokens = usage["input_tokens"] as? Int ?? 0
                    let cacheCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let total = outTokens + inTokens + cacheCreate

                    tokens7d += total
                    if ts >= fiveHoursAgo { tokens5h += total }

                    // Bucket by 10-min intervals
                    let cal = Calendar.current
                    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: ts)
                    let bucketMin = (comps.minute ?? 0) / 10 * 10
                    let bucketKey = String(format: "%04d-%02d-%02dT%02d:%02d:00Z",
                                           comps.year ?? 0, comps.month ?? 0, comps.day ?? 0,
                                           comps.hour ?? 0, bucketMin)
                    var bucket = buckets[bucketKey] ?? (t5h: 0, t7d: 0)
                    bucket.t7d += total
                    if ts >= fiveHoursAgo { bucket.t5h += total }
                    buckets[bucketKey] = bucket
                }
            }
        }

        let fiveHPct = min(100.0, Double(tokens5h) / Double(config.fiveHourTokenLimit) * 100.0)
        let sevenDPct = min(100.0, Double(tokens7d) / Double(config.sevenDayTokenLimit) * 100.0)

        // Build history
        let sortedKeys = buckets.keys.sorted()
        let isoFormatter = ISO8601DateFormatter()
        var history: [UsageSnapshot] = []
        var cumul5h = 0, cumul7d = 0
        for key in sortedKeys {
            let b = buckets[key]!
            cumul5h += b.t5h; cumul7d += b.t7d
            if let ts = isoFormatter.date(from: key) {
                history.append(UsageSnapshot(
                    timestamp: ts,
                    fiveHourPercent: min(100, Double(cumul5h) / Double(config.fiveHourTokenLimit) * 100),
                    sevenDayPercent: min(100, Double(cumul7d) / Double(config.sevenDayTokenLimit) * 100)
                ))
            }
        }
        // Add current point
        history.append(UsageSnapshot(timestamp: now, fiveHourPercent: fiveHPct, sevenDayPercent: sevenDPct))

        let info = UsageInfo(
            fiveHourPercent: fiveHPct,
            fiveHourResetSeconds: 0,
            sevenDayPercent: sevenDPct,
            sevenDayResetSeconds: 0,
            history: history,
            lastUpdated: now,
            tokensUsed5h: tokens5h,
            tokensUsed7d: tokens7d,
            tokenLimit5h: config.fiveHourTokenLimit,
            tokenLimit7d: config.sevenDayTokenLimit
        )

        // Save
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(info) {
            try? data.write(to: dataFileURL)
        }

        return info
    }

    static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    static func formatDuration(_ seconds: Int) -> String {
        if seconds <= 0 { return "Sliding window" }
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return "Resets \(d)d \(h)h" }
        if h > 0 { return "Resets \(h)h \(m)m" }
        return "Resets \(m)m"
    }

    static func barColor(_ percent: Double) -> (r: Double, g: Double, b: Double) {
        if percent < 50 { return (0.2, 0.8, 0.3) }  // green
        if percent < 75 { return (1.0, 0.8, 0.0) }  // yellow
        if percent < 90 { return (1.0, 0.6, 0.0) }  // orange
        return (1.0, 0.2, 0.2)                        // red
    }
}
