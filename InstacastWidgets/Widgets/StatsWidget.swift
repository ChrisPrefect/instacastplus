import WidgetKit
import SwiftUI

struct StatsWidget: Widget {
    let kind = ICWidgetConstants.statsWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StatsProvider()) { entry in
            StatsWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("widget.stats.name", comment: ""))
        .description(NSLocalizedString("widget.stats.description", comment: ""))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Views

struct StatsWidgetView: View {
    let entry: StatsEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        Group {
            if entry.needsData {
                WidgetEmptyStateView(icon: "arrow.down.circle",
                                     message: NSLocalizedString("widget.needsdata", comment: ""),
                                     hint: NSLocalizedString("widget.needsdata.hint", comment: ""))
            } else if let stats = entry.stats {
                switch family {
                case .systemSmall:
                    smallView(stats: stats)
                default:
                    mediumView(stats: stats)
                }
            } else {
                WidgetEmptyStateView(icon: "chart.bar", message: NSLocalizedString("widget.empty.nostats", comment: ""))
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(entry.needsData ? ICWidgetConstants.refreshWidgetsURL() : ICWidgetConstants.playerURL())
    }

    // MARK: - Small

    private func smallView(stats: WStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "headphones")
                    .font(.system(size: 14))
                    .foregroundColor(WidgetAccentColor.color)
                Text(NSLocalizedString("widget.today", comment: ""))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text(stats.listenedTodayFormatted)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(WidgetAccentColor.color)
                Text(NSLocalizedString("widget.stat.newtoday", comment: "") + ": \(stats.newEpisodesTodayCount)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 10))
                Text(NSLocalizedString("widget.week", comment: "") + ": \(stats.listenedWeekFormatted)")
                    .font(.system(size: 11))
            }
            .foregroundColor(.secondary)
        }
        .padding(2)
    }

    // MARK: - Medium

    private func mediumView(stats: WStats) -> some View {
        HStack(spacing: 16) {
            // Left: Listening time
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "headphones")
                        .font(.system(size: 14))
                        .foregroundColor(WidgetAccentColor.color)
                    Text(NSLocalizedString("widget.listened.header", comment: ""))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(NSLocalizedString("widget.today", comment: ""))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .leading)
                        Text(stats.listenedTodayFormatted)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    HStack(spacing: 6) {
                        Text(NSLocalizedString("widget.week", comment: ""))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .leading)
                        Text(stats.listenedWeekFormatted)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }

                Spacer(minLength: 0)
            }

            Divider()

            // Right: Counts
            VStack(alignment: .leading, spacing: 6) {
                statRow(icon: "sparkles", label: NSLocalizedString("widget.stat.newtoday", comment: ""), value: "\(stats.newEpisodesTodayCount)")
                statRow(icon: "tray.full", label: NSLocalizedString("widget.stat.unplayed", comment: ""), value: "\(stats.unplayedCount)")
                statRow(icon: "arrow.down.circle", label: NSLocalizedString("widget.stat.downloaded", comment: ""), value: "\(stats.downloadedCount) · \(stats.downloadedSizeFormatted)")
                statRow(icon: "moon.zzz", label: NSLocalizedString("widget.stat.sleeptimer", comment: ""), value: "\(stats.sleepTimerUsedCount)")
                statRow(icon: "antenna.radiowaves.left.and.right", label: NSLocalizedString("widget.stat.subscribed", comment: ""), value: "\(stats.subscribedCount)")

                Spacer(minLength: 0)
            }
        }
        .padding(2)
    }

    private func statRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(WidgetAccentColor.color)
                .frame(width: 16)

            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}
