import SwiftUI
import DexBarCore

struct UsageHistoryView: View {
    private struct DaySlot: Identifiable {
        enum Kind {
            case past
            case today
            case future
        }

        let date: Date
        let record: DailyUsageRecord?
        let timeZone: TimeZone
        let kind: Kind
        let startsAt: Date?
        let endsAt: Date?

        var id: Date { date }
    }

    let windows: [UsageHistoryWindow]
    let now: Date
    let dismiss: () -> Void

    @State private var selectedWindowID: String?
    @State private var dayPageOffset = 0
    @State private var isShowingInfo = false
    @State private var isShowingResetInfo = false

    init(
        windows: [UsageHistoryWindow],
        now: Date,
        dismiss: @escaping () -> Void,
        initialWindowIndex: Int = 0
    ) {
        self.windows = windows
        self.now = now
        self.dismiss = dismiss
        _selectedWindowID = State(initialValue: windows.indices.contains(initialWindowIndex)
            ? windows[initialWindowIndex].id : windows.first?.id)
    }

    var body: some View {
        Group {
            if let window = selectedWindow {
                VStack(spacing: 4) {
                    toolbar(window)
                    dayDetail(displayDay(in: window), in: window)
                    dayStrip(window)
                }
            } else {
                VStack(spacing: 8) {
                    HStack {
                        backControl
                        Spacer()
                    }
                    Text("History starts with the next successful usage check.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: selectedWindow?.id) { _, _ in
            dayPageOffset = 0
        }
        .onChange(of: windows.first?.days.first?.timeZoneIdentifier) { _, _ in
            dayPageOffset = 0
        }
        .onChange(of: windows.map(\.id)) { _, ids in
            // Insertions and pruning can move a week within the array. Only
            // choose a replacement when the selected week is no longer present.
            if let selectedWindowID, ids.contains(selectedWindowID) { return }
            selectedWindowID = ids.first
        }
    }

    private var windowIndex: Int {
        windows.firstIndex { $0.id == selectedWindowID } ?? 0
    }

    private func selectAdjacentWindow(offset: Int) {
        let index = windowIndex + offset
        guard windows.indices.contains(index) else { return }
        selectedWindowID = windows[index].id
    }

    private var selectedWindow: UsageHistoryWindow? {
        guard windows.indices.contains(windowIndex) else { return nil }
        return windows[windowIndex]
    }

    private var backControl: some View {
        Button(action: dismiss) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Daily usage")
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.leftArrow, modifiers: [])
        .help("Back to weekly usage (Left Arrow)")
        .accessibilityLabel("Back to weekly usage")
        .focusable(false)
        .focusEffectDisabled()
    }

    private func toolbar(_ window: UsageHistoryWindow) -> some View {
        HStack(spacing: 4) {
            backControl
            Button {
                isShowingInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("About daily usage history")
            .accessibilityLabel("About daily usage history")
            .focusable(false)
            .focusEffectDisabled()
            .popover(isPresented: $isShowingInfo, arrowEdge: .top) {
                Text("History is calculated from UTC usage readings stored on this Mac. Days follow your Mac’s current time zone, including when you travel. Boundary arrows mark partial days; symbols mark estimated or incomplete totals.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 220, alignment: .leading)
                    .padding(12)
            }
            Text(displayTimeZone(for: window).abbreviation(for: now) ?? "Local")
                .font(.system(size: 9, weight: .medium))
                .help("All days are shown in the Mac’s current time zone: \(displayTimeZone(for: window).identifier).")
            Spacer(minLength: 4)
            Button {
                selectAdjacentWindow(offset: 1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 12, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(windowIndex + 1 >= windows.count)
            .help("Previous usage window")
            .focusable(false)
            .focusEffectDisabled()
            Text(windowRange(window))
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            Button {
                selectAdjacentWindow(offset: -1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 12, height: 14)
            }
            .buttonStyle(.plain)
            .disabled(windowIndex == 0)
            .help("Next usage window")
            .focusable(false)
            .focusEffectDisabled()
        }
        .frame(height: 18)
    }

    @ViewBuilder
    private func dayDetail(_ day: DailyUsageRecord?, in window: UsageHistoryWindow) -> some View {
        HStack(spacing: 4) {
            if isCurrentWindow(window) {
                if let day {
                    Text(detailText(day, in: window))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(dayValue(day))
                        .fontWeight(.semibold)
                        .foregroundStyle(day.coverage == .unavailable ? .secondary : Color.accentColor)
                        .fixedSize()
                } else {
                    Text("No readings in this time zone yet")
                    Spacer()
                }
            } else if !window.days.isEmpty {
                Text(completedWindowText(window))
                    .lineLimit(1)
                if wasResetEarly(window) {
                    Button {
                        isShowingResetInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 15)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Why this usage week ended early")
                    .accessibilityLabel("Why this usage week ended early")
                    .focusable(false)
                    .focusEffectDisabled()
                    .popover(isPresented: $isShowingResetInfo, arrowEdge: .top) {
                        Text("OpenAI started a new usage window before this one’s advertised reset. DexBar can detect that change, but the rate-limit response does not include a reason. OpenAI supports earned reset credits, so DexBar cannot tell whether a reset was redeemed or initiated by the service.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 235, alignment: .leading)
                            .padding(12)
                    }
                }
                Spacer()
            } else {
                Text("No daily observations in this window")
                Spacer()
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 3)
        .frame(height: 15)
    }

    private func dayStrip(_ window: UsageHistoryWindow) -> some View {
        let allSlots = daySlots(for: window, pageOnly: false)
        let slots = daySlots(for: window)
        return HStack(spacing: 2) {
            if allSlots.count > 8 {
                dayPageButton("chevron.left", label: "Earlier days in this usage window",
                              disabled: slots.first?.date == allSlots.first?.date) {
                    dayPageOffset = min(dayPageOffset + 8, allSlots.count - 8)
                }
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 8),
                spacing: 2
            ) {
                ForEach(slots) { slot in dayCell(slot) }
            }
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
            if allSlots.count > 8 {
                dayPageButton("chevron.right", label: "Later days in this usage window",
                              disabled: slots.last?.date == allSlots.last?.date) {
                    dayPageOffset = max(0, dayPageOffset - 8)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42)
    }

    private func dayPageButton(_ symbol: String, label: String, disabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 12, height: 39)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
        .focusable(false)
        .focusEffectDisabled()
    }

    private func dayCell(_ slot: DaySlot) -> some View {
        VStack(spacing: 1) {
            Text(dayName(slot))
                .font(.system(size: 8, weight: .medium))
                .lineLimit(1)
            Text(dayValue(slot))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .monospacedDigit()
                .foregroundStyle(valueStyle(slot))
            Text(dayCaption(slot))
                .font(.system(size: 8))
                .fontWeight(hasBoundary(slot) ? .medium : .regular)
                .foregroundStyle(hasBoundary(slot) ? .secondary : .tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 39)
        .foregroundStyle(slot.kind == .today ? Color.accentColor : Color.secondary)
        .background(
            slot.kind == .today ? Color.secondary.opacity(0.11) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            if slot.kind == .future {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        Color.secondary.opacity(0.22),
                        style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])
                    )
            }
        }
        .help(accessibilityDescription(slot))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription(slot))
    }

    private func daySlots(for window: UsageHistoryWindow, pageOnly: Bool = true) -> [DaySlot] {
        var calendar = Calendar.current
        let timeZone = displayTimeZone(for: window)
        calendar.timeZone = timeZone

        let windowStart = window.startsAt
        let windowEnd = effectiveEnd(for: window)
        let firstDay = calendar.startOfDay(for: windowStart)
        let today = calendar.startOfDay(for: now)
        let current = isCurrentWindow(window)

        let dates = pageOnly
            ? window.calendarDayPage(endingAt: windowEnd, calendar: calendar, offsetFromEnd: dayPageOffset)
            : window.calendarDays(endingAt: windowEnd, calendar: calendar)
        return dates.map { date in
            let record = window.record(on: date, timeZone: timeZone)
            let kind: DaySlot.Kind
            if current, date == today {
                kind = .today
            } else if current, date > today {
                kind = .future
            } else {
                kind = .past
            }
            let startsAt = date == firstDay && windowStart > firstDay ? windowStart : nil
            let endDay = calendar.startOfDay(for: windowEnd)
            let endsAt = date == endDay && windowEnd > endDay ? windowEnd : nil
            return DaySlot(
                date: date,
                record: record,
                timeZone: timeZone,
                kind: kind,
                startsAt: startsAt,
                endsAt: endsAt
            )
        }
    }

    private func displayTimeZone(for window: UsageHistoryWindow) -> TimeZone {
        // Every day in this derived window uses the same presentation calendar.
        window.days.first.flatMap { TimeZone(identifier: $0.timeZoneIdentifier) } ?? .current
    }

    private func displayDay(in window: UsageHistoryWindow) -> DailyUsageRecord? {
        let zone = displayTimeZone(for: window)
        if isCurrentWindow(window) {
            var calendar = Calendar.current
            calendar.timeZone = zone
            if let today = window.record(on: calendar.startOfDay(for: now), timeZone: zone) {
                return today
            }
        }
        return window.lastObservedDay(in: zone)
    }

    private func dayValue(_ day: DailyUsageRecord) -> String {
        guard let used = day.usedPercent else { return "—" }
        let value = Int(used.rounded())
        switch day.coverage {
        case .observed: return "+\(value)%"
        case .estimated: return "≈\(value)%"
        case .partial: return "≥\(value)%"
        case .unavailable: return "—"
        }
    }

    private func dayValue(_ slot: DaySlot) -> String {
        slot.record.map(dayValue) ?? "—"
    }

    private func valueStyle(_ slot: DaySlot) -> AnyShapeStyle {
        if slot.kind == .today { return AnyShapeStyle(Color.accentColor) }
        if slot.kind == .future || slot.record?.coverage == .unavailable {
            return AnyShapeStyle(Color.secondary)
        }
        return AnyShapeStyle(Color.primary)
    }

    private func detailText(_ day: DailyUsageRecord, in window: UsageHistoryWindow) -> String {
        let today = isCurrentWindow(window) && isToday(day)
        let label = today ? "Today" : dayDate(day)
        guard let start = day.startingPercent, let end = day.endingPercent else {
            return "\(label) · daily total unavailable"
        }
        let startValue = Int(start.rounded())
        let endValue = Int(end.rounded())
        switch day.coverage {
        case .observed:
            return today
                ? "Today started at \(startValue)% · last seen \(endValue)%"
                : "\(label) · \(startValue)% → \(endValue)%"
        case .estimated:
            return "\(label) \(startValue)% → \(endValue)% · estimated"
        case .partial:
            return "\(label) \(startValue)% → \(endValue)% · since first seen"
        case .unavailable:
            return "\(label) · daily total unavailable"
        }
    }

    private func completedWindowText(_ window: UsageHistoryWindow) -> String {
        window.completedDescription(resetEarly: wasResetEarly(window))
    }

    private func accessibilityDescription(_ slot: DaySlot) -> String {
        var parts = ["\(dayDate(slot)) (\(slot.timeZone.identifier))"]
        if let startsAt = slot.startsAt {
            parts.append("window began at \(fullTime(startsAt, timeZone: slot.timeZone))")
        }
        if let endsAt = slot.endsAt {
            parts.append("window ends at \(fullTime(endsAt, timeZone: slot.timeZone))")
        }
        if slot.kind == .future {
            parts.append("future day")
            return parts.joined(separator: ", ")
        }
        guard let record = slot.record else {
            parts.append("daily total unavailable")
            return parts.joined(separator: ", ")
        }
        if let start = record.startingPercent, let end = record.endingPercent {
            parts.append("started at \(Int(start.rounded())) percent")
            parts.append("ended at \(Int(end.rounded())) percent")
        }
        switch record.coverage {
        case .observed: break
        case .estimated: parts.append("daily total estimated")
        case .partial: parts.append("usage since first observation")
        case .unavailable: parts.append("daily total unavailable")
        }
        parts.append("\(dayValue(record)) used")
        return parts.joined(separator: ", ")
    }

    private func dayName(_ slot: DaySlot) -> String {
        if slot.kind == .today { return "Today" }
        return formatter("EEE", timeZone: slot.timeZone).string(from: slot.date)
    }

    private func dayDate(_ slot: DaySlot) -> String {
        formatter("dMMM", timeZone: slot.timeZone).string(from: slot.date)
    }

    private func dayCaption(_ slot: DaySlot) -> String {
        switch (slot.startsAt, slot.endsAt) {
        case let (start?, end?):
            return "\(compactTime(start, timeZone: slot.timeZone))–\(compactTime(end, timeZone: slot.timeZone))"
        case let (start?, nil):
            return "\(compactTime(start, timeZone: slot.timeZone))→"
        case let (nil, end?):
            return "→\(compactTime(end, timeZone: slot.timeZone))"
        case (nil, nil):
            return dayDate(slot)
        }
    }

    private func hasBoundary(_ slot: DaySlot) -> Bool {
        slot.startsAt != nil || slot.endsAt != nil
    }

    private func compactTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "jm",
            options: 0,
            locale: .current
        )
        formatter.amSymbol = "a"
        formatter.pmSymbol = "p"
        return formatter.string(from: date).filter { !$0.isWhitespace }
    }

    private func fullTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func isCurrentWindow(_ window: UsageHistoryWindow) -> Bool {
        window.id == windows.first?.id && window.resetsAt > now
    }

    private func isToday(_ day: DailyUsageRecord) -> Bool {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: day.timeZoneIdentifier) ?? .current
        return calendar.isDate(day.dayStart, inSameDayAs: now)
    }

    private func dayDate(_ day: DailyUsageRecord) -> String {
        formatter("d MMM", for: day).string(from: day.dayStart)
    }

    private func formatter(_ template: String, for day: DailyUsageRecord) -> DateFormatter {
        formatter(
            template,
            timeZone: TimeZone(identifier: day.timeZoneIdentifier) ?? .current
        )
    }

    private func formatter(_ template: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private func windowRange(_ window: UsageHistoryWindow) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = displayTimeZone(for: window)
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return "\(formatter.string(from: window.startsAt))–\(formatter.string(from: effectiveEnd(for: window)))"
    }

    /// OpenAI can replace a live allowance before its advertised reset. When that
    /// happens, the following cycle's start is the best boundary we have for the
    /// shortened historical window.
    private func effectiveEnd(for window: UsageHistoryWindow) -> Date {
        earlyResetBoundary(for: window) ?? window.resetsAt
    }

    private func wasResetEarly(_ window: UsageHistoryWindow) -> Bool {
        earlyResetBoundary(for: window) != nil
    }

    private func earlyResetBoundary(for window: UsageHistoryWindow) -> Date? {
        guard let index = windows.firstIndex(where: { $0.id == window.id }), index > 0 else {
            return nil
        }
        let replacementStart = windows[index - 1].startsAt
        guard replacementStart > window.startsAt, replacementStart < window.resetsAt else {
            return nil
        }
        return replacementStart
    }
}
