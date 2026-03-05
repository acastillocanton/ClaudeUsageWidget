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
    var orgId: String?

    static let defaultConfig = UsageConfig(
        fiveHourTokenLimit: 1_000_000,
        sevenDayTokenLimit: 50_000_000,
        orgId: nil
    )
}

// API response structures
struct ClaudeAPIUsageResponse: Codable {
    let five_hour: ClaudeAPIWindow?
    let seven_day: ClaudeAPIWindow?
}

struct ClaudeAPIWindow: Codable {
    let utilization: Double
    let resets_at: String
}

class UsageFetcher {
    static let appGroupID = "com.alejandro.claudeusage.shared"

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

    // MARK: - Chrome API Fetch (primary method)

    /// Detect org ID from Claude Code session files
    static func detectOrgId() -> String? {
        let sessionsDir = URL(fileURLWithPath: realHomeDirectory)
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let accounts = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        for account in accounts {
            if let orgs = try? FileManager.default.contentsOfDirectory(at: account, includingPropertiesForKeys: nil) {
                for org in orgs {
                    let name = org.lastPathComponent
                    // UUID format check
                    if name.count == 36 && name.contains("-") {
                        return name
                    }
                }
            }
        }
        return nil
    }

    /// Fetch usage data from Claude API via osascript + Chrome
    static func fetchFromChromeAPI(orgId: String) -> ClaudeAPIUsageResponse? {
        // Use osascript process which handles AppleEvents properly
        let script = [
            "tell application \"Google Chrome\"",
            "    set theTab to missing value",
            "    repeat with w in every window",
            "        repeat with t in every tab of w",
            "            if URL of t contains \"claude.ai\" then",
            "                set theTab to t",
            "                exit repeat",
            "            end if",
            "        end repeat",
            "        if theTab is not missing value then exit repeat",
            "    end repeat",
            "    if theTab is missing value then return \"ERROR: No claude.ai tab\"",
            "    execute theTab javascript \"window.__usageResult = 'pending'; fetch('/api/organizations/\(orgId)/usage').then(r => r.json()).then(d => { window.__usageResult = JSON.stringify(d); }).catch(e => { window.__usageResult = 'ERROR:' + e.message; }); 'started'\"",
            "    delay 3",
            "    set result to execute theTab javascript \"window.__usageResult\"",
            "    return result",
            "end tell"
        ].joined(separator: "\n")

        // Write to temp file to avoid shell escaping issues
        let tmpFile = sharedContainerURL.appendingPathComponent("fetch_usage.applescript")
        do {
            try script.write(to: tmpFile, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [tmpFile.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let jsonString = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            try? FileManager.default.removeItem(at: tmpFile)

            if !errStr.isEmpty || jsonString.isEmpty || jsonString.starts(with: "ERROR") || jsonString == "pending" {
                let logMsg = "Exit: \(process.terminationStatus)\nStderr: \(errStr)\nStdout: \(jsonString)\n"
                try? logMsg.write(to: sharedContainerURL.appendingPathComponent("fetch_error.log"), atomically: true, encoding: .utf8)
                return nil
            }

            guard let jsonData = jsonString.data(using: .utf8) else { return nil }
            try? FileManager.default.removeItem(at: sharedContainerURL.appendingPathComponent("fetch_error.log"))
            return try? JSONDecoder().decode(ClaudeAPIUsageResponse.self, from: jsonData)
        } catch {
            try? FileManager.default.removeItem(at: tmpFile)
            try? "Process error: \(error)\n".write(to: sharedContainerURL.appendingPathComponent("fetch_error.log"), atomically: true, encoding: .utf8)
            return nil
        }
    }

    // MARK: - Main fetch method

    static func fetchAndSave() -> UsageInfo {
        var config = loadConfig()

        // Detect org ID if not set
        if config.orgId == nil {
            config.orgId = detectOrgId()
            if config.orgId != nil {
                saveConfig(config)
            }
        }

        // Try Chrome API first
        if let orgId = config.orgId, let apiResponse = fetchFromChromeAPI(orgId: orgId) {
            return processAPIResponse(apiResponse, config: config)
        }

        // Fallback: read JSONL files
        return fetchFromJSONL(config: config)
    }

    static func processAPIResponse(_ response: ClaudeAPIUsageResponse, config: UsageConfig) -> UsageInfo {
        let now = Date()
        let fiveHPct = response.five_hour?.utilization ?? 0
        let sevenDPct = response.seven_day?.utilization ?? 0

        // Parse reset times
        let reset5h = parseResetSeconds(response.five_hour?.resets_at, from: now)
        let reset7d = parseResetSeconds(response.seven_day?.resets_at, from: now)

        // Load existing history and append current point
        let existing = loadUsageInfo()
        var history = existing.history
        // Keep only last 6 hours of history
        let cutoff = now.addingTimeInterval(-6 * 3600)
        history = history.filter { $0.timestamp >= cutoff }
        history.append(UsageSnapshot(timestamp: now, fiveHourPercent: fiveHPct, sevenDayPercent: sevenDPct))

        let info = UsageInfo(
            fiveHourPercent: fiveHPct,
            fiveHourResetSeconds: reset5h,
            sevenDayPercent: sevenDPct,
            sevenDayResetSeconds: reset7d,
            history: history,
            lastUpdated: now
        )

        // Save
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(info) {
            try? data.write(to: dataFileURL)
        }

        return info
    }

    static func parseResetSeconds(_ isoString: String?, from now: Date) -> Int {
        guard let isoString = isoString else { return 0 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return max(0, Int(date.timeIntervalSince(now)))
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoString) {
            return max(0, Int(date.timeIntervalSince(now)))
        }
        // Try with timezone offset format
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
        df.locale = Locale(identifier: "en_US_POSIX")
        if let date = df.date(from: isoString) {
            return max(0, Int(date.timeIntervalSince(now)))
        }
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        if let date = df.date(from: isoString) {
            return max(0, Int(date.timeIntervalSince(now)))
        }
        return 0
    }

    // MARK: - JSONL Fallback

    static func fetchFromJSONL(config: UsageConfig) -> UsageInfo {
        let claudeProjects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        let now = Date()
        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)

        var tokens5h = 0
        var tokens7d = 0
        var earliest5h: Date? = nil
        var earliest7d: Date? = nil
        var buckets: [String: (t5h: Int, t7d: Int)] = [:]

        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeProjects, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return .empty }

        for projectDir in projectDirs {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
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
                    if earliest7d == nil || ts < earliest7d! { earliest7d = ts }
                    if ts >= fiveHoursAgo {
                        tokens5h += total
                        if earliest5h == nil || ts < earliest5h! { earliest5h = ts }
                    }

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
        history.append(UsageSnapshot(timestamp: now, fiveHourPercent: fiveHPct, sevenDayPercent: sevenDPct))

        let reset5h: Int
        if let e = earliest5h {
            reset5h = max(0, Int(e.addingTimeInterval(5 * 3600).timeIntervalSince(now)))
        } else { reset5h = 0 }

        let reset7d: Int
        if let e = earliest7d {
            reset7d = max(0, Int(e.addingTimeInterval(7 * 86400).timeIntervalSince(now)))
        } else { reset7d = 0 }

        let info = UsageInfo(
            fiveHourPercent: fiveHPct,
            fiveHourResetSeconds: reset5h,
            sevenDayPercent: sevenDPct,
            sevenDayResetSeconds: reset7d,
            history: history,
            lastUpdated: now,
            tokensUsed5h: tokens5h,
            tokensUsed7d: tokens7d,
            tokenLimit5h: config.fiveHourTokenLimit,
            tokenLimit7d: config.sevenDayTokenLimit
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(info) {
            try? data.write(to: dataFileURL)
        }

        return info
    }

    // MARK: - Formatting helpers

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
        if percent < 50 { return (0.2, 0.8, 0.3) }
        if percent < 75 { return (1.0, 0.8, 0.0) }
        if percent < 90 { return (1.0, 0.6, 0.0) }
        return (1.0, 0.2, 0.2)
    }
}
