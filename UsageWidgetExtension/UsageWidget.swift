import WidgetKit
import SwiftUI

// MARK: - Timeline Provider

struct UsageEntry: TimelineEntry {
    let date: Date
    let usage: UsageInfo
}

struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, usage: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let usage = UsageFetcher.loadUsageInfo()
        completion(UsageEntry(date: .now, usage: usage))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let usage = UsageFetcher.loadUsageInfo()
        let entry = UsageEntry(date: .now, usage: usage)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: .now)!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Color Helper

func barColor(for percent: Double) -> Color {
    if percent < 50 { return .green }
    if percent < 75 { return .yellow }
    if percent < 90 { return .orange }
    return .red
}

// MARK: - Usage Bar

struct UsageBarView: View {
    let title: String
    let percent: Double
    let tokens: Int
    let limit: Int
    var resetSeconds: Int = 0
    var barHeight: CGFloat = 7
    var titleSize: CGFloat = 11
    var percentSize: CGFloat = 12
    var detailSize: CGFloat = 9

    var color: Color { barColor(for: percent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: titleSize, weight: .medium))
                Spacer()
                Text("\(Int(percent))%")
                    .font(.system(size: percentSize, weight: .bold))
                    .foregroundStyle(color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(
                            colors: [color.opacity(0.7), color],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: max(0, geo.size.width * percent / 100))
                }
            }
            .frame(height: barHeight)

            HStack {
                Text(UsageFetcher.formatDuration(resetSeconds))
                    .font(.system(size: detailSize))
                    .foregroundStyle(.secondary)
                Spacer()
                if tokens > 0 {
                    Text("\(UsageFetcher.formatTokens(tokens)) / \(UsageFetcher.formatTokens(limit))")
                        .font(.system(size: detailSize))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Chart View (full version with grid)

struct ChartView: View {
    let history: [UsageSnapshot]
    let maxHours: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let chartW = w - 28
            let chartH = h - 14

            ZStack(alignment: .topLeading) {
                // Grid lines + labels
                ForEach([0.0, 25.0, 50.0, 75.0, 100.0], id: \.self) { pct in
                    let y = chartH * (1.0 - pct / 100.0)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: chartW, y: y))
                    }
                    .stroke(Color.gray.opacity(0.2), lineWidth: 0.5)

                    Text("\(Int(pct))%")
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                        .position(x: chartW + 14, y: y)
                }

                // 75% threshold dashed line
                Path { p in
                    let y = chartH * 0.25
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: chartW, y: y))
                }
                .stroke(Color.red.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                // 5h line (blue)
                chartLine(data: history, keyPath: \.fiveHourPercent, chartW: chartW, chartH: chartH)
                    .stroke(Color.blue, lineWidth: 2)

                // 7d line (orange)
                chartLine(data: history, keyPath: \.sevenDayPercent, chartW: chartW, chartH: chartH)
                    .stroke(Color.orange, lineWidth: 2)

                // Time label at center
                timeLabel(chartW: chartW, yOffset: chartH + 2)
            }
        }
    }

    func chartLine(data: [UsageSnapshot], keyPath: KeyPath<UsageSnapshot, Double>, chartW: CGFloat, chartH: CGFloat) -> Path {
        guard data.count > 1 else { return Path() }
        let now = Date()
        let start = now.addingTimeInterval(-Double(maxHours * 3600))
        let range = now.timeIntervalSince(start)

        return Path { path in
            for (i, pt) in data.enumerated() {
                let xFrac = pt.timestamp.timeIntervalSince(start) / range
                let x = chartW * CGFloat(max(0, min(1, xFrac)))
                let y = chartH * CGFloat(1.0 - pt[keyPath: keyPath] / 100.0)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    func timeLabel(chartW: CGFloat, yOffset: CGFloat) -> some View {
        let now = Date()
        let start = now.addingTimeInterval(-Double(maxHours * 3600))
        let formatter = DateFormatter()
        if maxHours <= 24 { formatter.dateFormat = "h a" }
        else { formatter.dateFormat = "M/d" }
        let midTime = start.addingTimeInterval(Double(maxHours * 3600) / 2.0)

        return Text(formatter.string(from: midTime))
            .font(.system(size: 7))
            .foregroundStyle(.secondary)
            .position(x: chartW / 2, y: yOffset + 5)
    }
}

// MARK: - Mini Chart (for small/medium)

struct MiniChartView: View {
    let history: [UsageSnapshot]
    let maxHours: Int

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            // 75% threshold line
            Path { p in
                let y = h * 0.25
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: w, y: y))
            }
            .stroke(Color.red.opacity(0.3), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))

            chartLine(data: history, keyPath: \.fiveHourPercent, width: w, height: h)
                .stroke(Color.blue, lineWidth: 1.5)

            chartLine(data: history, keyPath: \.sevenDayPercent, width: w, height: h)
                .stroke(Color.orange, lineWidth: 1.5)
        }
    }

    func chartLine(data: [UsageSnapshot], keyPath: KeyPath<UsageSnapshot, Double>, width: CGFloat, height: CGFloat) -> Path {
        guard data.count > 1 else { return Path() }
        let now = Date()
        let start = now.addingTimeInterval(-Double(maxHours * 3600))
        let range = now.timeIntervalSince(start)

        return Path { path in
            for (i, pt) in data.enumerated() {
                let xFrac = pt.timestamp.timeIntervalSince(start) / range
                let x = width * CGFloat(max(0, min(1, xFrac)))
                let y = height * CGFloat(1.0 - pt[keyPath: keyPath] / 100.0)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }
}

// MARK: - Small Widget

struct SmallWidgetView: View {
    let usage: UsageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image("ClaudeLogo")
                    .resizable()
                    .frame(width: 16, height: 16)
                Text("Claude Usage")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Link(destination: URL(string: "https://castillocanton.com")!) {
                    Image("AuthorLogo")
                        .resizable()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            UsageBarView(
                title: "5-Hour Window",
                percent: usage.fiveHourPercent,
                tokens: usage.tokensUsed5h ?? 0,
                limit: usage.tokenLimit5h ?? 1_000_000,
                resetSeconds: usage.fiveHourResetSeconds,
                barHeight: 6,
                titleSize: 10,
                percentSize: 11,
                detailSize: 8
            )

            UsageBarView(
                title: "7-Day Window",
                percent: usage.sevenDayPercent,
                tokens: usage.tokensUsed7d ?? 0,
                limit: usage.tokenLimit7d ?? 50_000_000,
                resetSeconds: usage.sevenDayResetSeconds,
                barHeight: 6,
                titleSize: 10,
                percentSize: 11,
                detailSize: 8
            )

            Spacer(minLength: 0)

            Text(timeAgo(usage.lastUpdated))
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
        }
    }

    func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "Updated \(s)s ago" }
        if s < 3600 { return "Updated \(s/60)m ago" }
        return "Updated \(s/3600)h ago"
    }
}

// MARK: - Medium Widget

struct MediumWidgetView: View {
    let usage: UsageInfo

    var body: some View {
        HStack(spacing: 12) {
            // Left: logo + bars
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image("ClaudeLogo")
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text("Claude Usage")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Link(destination: URL(string: "https://castillocanton.com")!) {
                        Image("AuthorLogo")
                            .resizable()
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }

                UsageBarView(
                    title: "5-Hour Window",
                    percent: usage.fiveHourPercent,
                    tokens: usage.tokensUsed5h ?? 0,
                    limit: usage.tokenLimit5h ?? 1_000_000,
                    resetSeconds: usage.fiveHourResetSeconds
                )

                UsageBarView(
                    title: "7-Day Window",
                    percent: usage.sevenDayPercent,
                    tokens: usage.tokensUsed7d ?? 0,
                    limit: usage.tokenLimit7d ?? 50_000_000,
                    resetSeconds: usage.sevenDayResetSeconds
                )

                Spacer(minLength: 0)

                Text(timeAgo(usage.lastUpdated))
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
            }
            .frame(maxWidth: .infinity)

            // Right: chart + legend
            VStack(alignment: .leading, spacing: 4) {
                Text("Last 6 hours")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)

                MiniChartView(history: recentHistory(hours: 6), maxHours: 6)

                HStack(spacing: 10) {
                    legendDot(color: .blue, label: "5h")
                    legendDot(color: .orange, label: "7d")
                }
                .font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
        }
    }

    func recentHistory(hours: Int) -> [UsageSnapshot] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        return usage.history.filter { $0.timestamp >= cutoff }
    }

    func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundStyle(.secondary)
        }
    }

    func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "Updated \(s)s ago" }
        if s < 3600 { return "Updated \(s/60)m ago" }
        return "Updated \(s/3600)h ago"
    }
}

// MARK: - Large Widget (full detail like the original)

struct LargeWidgetView: View {
    let usage: UsageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Image("ClaudeLogo")
                    .resizable()
                    .frame(width: 20, height: 20)
                Text("Claude Usage")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Link(destination: URL(string: "https://castillocanton.com")!) {
                    Image("AuthorLogo")
                        .resizable()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }

            // 5-Hour Window
            UsageBarView(
                title: "5-Hour Window",
                percent: usage.fiveHourPercent,
                tokens: usage.tokensUsed5h ?? 0,
                limit: usage.tokenLimit5h ?? 1_000_000,
                resetSeconds: usage.fiveHourResetSeconds,
                barHeight: 8,
                titleSize: 13,
                percentSize: 13,
                detailSize: 10
            )

            // 7-Day Window
            UsageBarView(
                title: "7-Day Window",
                percent: usage.sevenDayPercent,
                tokens: usage.tokensUsed7d ?? 0,
                limit: usage.tokenLimit7d ?? 50_000_000,
                resetSeconds: usage.sevenDayResetSeconds,
                barHeight: 8,
                titleSize: 13,
                percentSize: 13,
                detailSize: 10
            )

            // Chart with grid
            ChartView(history: recentHistory(hours: 6), maxHours: 6)
                .frame(maxHeight: .infinity)

            // Legend
            HStack(spacing: 16) {
                legendDot(color: .blue, label: "5h window")
                legendDot(color: .orange, label: "7d window")
                Spacer()
                Text(timeAgo(usage.lastUpdated))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    func recentHistory(hours: Int) -> [UsageSnapshot] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        return usage.history.filter { $0.timestamp >= cutoff }
    }

    func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    func timeAgo(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "Updated \(s)s ago" }
        if s < 3600 { return "Updated \(s/60)m ago" }
        return "Updated \(s/3600)h ago"
    }
}

// MARK: - Widget Definition

struct ClaudeUsageWidget: Widget {
    let kind: String = "ClaudeUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageTimelineProvider()) { entry in
            ClaudeUsageWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude Usage")
        .description("Monitor your Claude Code token usage in real-time.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ClaudeUsageWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: UsageEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(usage: entry.usage)
        case .systemMedium:
            MediumWidgetView(usage: entry.usage)
        case .systemLarge:
            LargeWidgetView(usage: entry.usage)
        default:
            SmallWidgetView(usage: entry.usage)
        }
    }
}

// MARK: - Previews

#Preview(as: .systemSmall) {
    ClaudeUsageWidget()
} timeline: {
    UsageEntry(date: .now, usage: UsageInfo(
        fiveHourPercent: 42.3, fiveHourResetSeconds: 0,
        sevenDayPercent: 18.7, sevenDayResetSeconds: 0,
        history: [], lastUpdated: .now,
        tokensUsed5h: 423000, tokensUsed7d: 9350000,
        tokenLimit5h: 1_000_000, tokenLimit7d: 50_000_000
    ))
}

#Preview(as: .systemMedium) {
    ClaudeUsageWidget()
} timeline: {
    UsageEntry(date: .now, usage: UsageInfo(
        fiveHourPercent: 42.3, fiveHourResetSeconds: 0,
        sevenDayPercent: 18.7, sevenDayResetSeconds: 0,
        history: [], lastUpdated: .now,
        tokensUsed5h: 423000, tokensUsed7d: 9350000,
        tokenLimit5h: 1_000_000, tokenLimit7d: 50_000_000
    ))
}

#Preview(as: .systemLarge) {
    ClaudeUsageWidget()
} timeline: {
    UsageEntry(date: .now, usage: UsageInfo(
        fiveHourPercent: 42.3, fiveHourResetSeconds: 0,
        sevenDayPercent: 18.7, sevenDayResetSeconds: 0,
        history: [], lastUpdated: .now,
        tokensUsed5h: 423000, tokensUsed7d: 9350000,
        tokenLimit5h: 1_000_000, tokenLimit7d: 50_000_000
    ))
}
