import Charts
import PlannerKit
import SwiftUI

/// What you got done: this week by day and project, blocks kept, on-time rate, streak.
struct InsightsView: View {
    @Environment(AppModel.self) private var model
    @State private var weeksBack = 0

    private var weekDate: Date { Date().addingTimeInterval(Double(-7 * 86_400 * weeksBack)) }

    var body: some View {
        let insights = model.insights(weekOf: weekDate)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                weekPicker(insights)
                InsightsSummary(insights: insights, showStreak: weeksBack == 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 110)
            .animation(.planner, value: weeksBack)
        }
        .background(Color.pageBackground)
        .navigationTitle("Insights")
    }

    private func weekPicker(_ insights: WeekInsights) -> some View {
        HStack {
            Button { weeksBack += 1 } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous week")
            Spacer()
            Text(weeksBack == 0 ? "This week" : weeksBack == 1 ? "Last week" : "Week of \(insights.weekStart.formatted(.dateTime.month(.abbreviated).day()))")
                .font(.headline)
                .contentTransition(.opacity)
            Spacer()
            Button { weeksBack -= 1 } label: { Image(systemName: "chevron.right") }
                .disabled(weeksBack == 0)
                .accessibilityLabel("Next week")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }
}

/// The numbers, chart and breakdown. Also the first step of the Weekly Review.
struct InsightsSummary: View {
    let insights: WeekInsights
    var showStreak = true
    @State private var appeared = false

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: columns, spacing: 10) {
                tile("\(insights.total)", "tasks done", change: insights.lastWeekTotal > 0 || insights.total > 0 ? insights.change : nil, symbol: "checkmark.circle.fill", tint: .green)
                tile(Format.duration(insights.minutesDone), "of work", symbol: "hourglass", tint: .accentColor)
                tile(insights.keptRate.map { "\(Int($0 * 100))%" } ?? "–", "blocks kept\(insights.blocksKept + insights.blocksMissed > 0 ? " (\(insights.blocksKept)/\(insights.blocksKept + insights.blocksMissed))" : "")", symbol: "calendar.badge.checkmark", tint: .teal)
                if showStreak {
                    tile(insights.streak == 0 ? "–" : "\(insights.streak)", insights.streak == 0 ? "no streak yet" : insights.streak == 1 ? "day streak" : "days in a row", symbol: "flame.fill", tint: .orange)
                } else {
                    tile(insights.onTimeRate.map { "\(Int($0 * 100))%" } ?? "–", "on time", symbol: "flag.checkered", tint: .orange)
                }
            }

            Card(title: "By day", symbol: "chart.bar.fill") {
                if insights.total == 0 {
                    Text("Nothing ticked off this week yet. Each task you finish adds a bar here.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                Chart(insights.days) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Done", appeared ? day.count : 0)
                    )
                    .foregroundStyle(day.id == insights.busiestDay?.id ? Color.accentColor.gradient : Color.accentColor.opacity(0.45).gradient)
                    .cornerRadius(5)
                    .annotation(position: .top) {
                        if day.count > 0 { Text("\(day.count)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) }
                }
                .chartYAxis(.hidden)
                .frame(height: 140)
                .accessibilityLabel("Tasks done each day")
                }
            }

            if !insights.byProject.isEmpty {
                Card(title: "By project", symbol: "folder.fill") {
                    let most = max(1, insights.byProject.map(\.count).max() ?? 1)
                    ForEach(insights.byProject) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(row.project?.label ?? "No project").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(row.count) done · \(Format.duration(row.minutes))").font(.caption).foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                Capsule().fill(row.project.tint.gradient)
                                    .frame(width: appeared ? max(6, geo.size.width * Double(row.count) / Double(most)) : 6)
                            }
                            .frame(height: 8)
                            if row.kept + row.missed > 0 {
                                Text("Blocks: \(row.kept) kept, \(row.missed) missed").font(.caption2).foregroundStyle(row.missed > row.kept ? Color.orange : Color.secondary)
                            }
                        }
                    }
                }
            }

            let notes = insights.worthNoticing
            if !notes.isEmpty {
                Card(title: "Worth noticing", symbol: "lightbulb.fill", tint: .yellow) {
                    ForEach(notes, id: \.self) { Text($0).font(.callout).fixedSize(horizontal: false, vertical: true) }
                }
            }
        }
        .onAppear { withAnimation(.spring(duration: 0.7).delay(0.1)) { appeared = true } }
    }

    private func tile(_ value: String, _ label: String, change: Int? = nil, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol).foregroundStyle(tint).font(.subheadline.weight(.semibold))
                Spacer()
                if let change, change != 0 {
                    Label("\(abs(change))", systemImage: change > 0 ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(change > 0 ? Color.green : Color.orange)
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("\(change > 0 ? "up" : "down") \(abs(change)) on last week")
                }
            }
            Text(value).font(.title.weight(.bold)).monospacedDigit().contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }
}
