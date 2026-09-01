import Foundation

public func shortDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let days = total / 86_400
    let hours = (total % 86_400) / 3_600
    let minutes = (total % 3_600) / 60
    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

public func clockTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    formatter.dateStyle = .none
    return formatter.string(from: date)
}

public func resetDescription(_ date: Date, relativeTo now: Date = Date()) -> String {
    let calendar = Calendar.current
    let time = clockTime(date)
    if calendar.isDate(date, inSameDayAs: now) { return time }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
       calendar.isDate(date, inSameDayAs: tomorrow) {
        return "tomorrow \(time)"
    }
    let days = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: now),
        to: calendar.startOfDay(for: date)
    ).day ?? 0
    let formatter = DateFormatter()
    formatter.dateFormat = DateFormatter.dateFormat(
        fromTemplate: days < 7 ? "EEE" : "EEEdMMM",
        options: 0,
        locale: .current
    )
    return "\(formatter.string(from: date)) \(time)"
}

public func displayPlan(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    return raw.replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}
