import Foundation

@MainActor
final class PollScheduler {
    private var timer: DispatchSourceTimer?
    private var scheduledInterval: TimeInterval?
    private var suspended = false
    private let poll: () async -> Void

    var idleFor: () -> TimeInterval = { .infinity }
    var worstPercent: () -> Int = { 0 }

    init(poll: @escaping () async -> Void) {
        self.poll = poll
    }

    static func interval(idleFor: TimeInterval, worstPercent: Int) -> TimeInterval {
        if worstPercent >= 80 { return 60 }
        if idleFor < 5 * 60 { return 60 }
        if idleFor < 30 * 60 { return 3 * 60 }
        return 5 * 60
    }

    func reschedule() {
        let wanted = Self.interval(idleFor: idleFor(), worstPercent: worstPercent())
        if timer != nil, scheduledInterval == wanted { return }

        timer?.cancel()
        timer = nil
        scheduledInterval = wanted
        guard !suspended else { return }

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + wanted,
            leeway: .seconds(max(5, Int(wanted / 4)))
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.timer = nil
                await self.poll()
                self.reschedule()
            }
        }
        source.resume()
        timer = source
    }

    func suspend() {
        suspended = true
        timer?.cancel()
        timer = nil
        scheduledInterval = nil
    }

    func resume() {
        suspended = false
        reschedule()
    }
}
