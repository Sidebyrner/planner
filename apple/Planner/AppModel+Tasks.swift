import Foundation
import PlannerKit

/// What the Tasks page needs: a sensible time guess, one plain next step, the next free slot,
/// and grouping by when.
extension AppModel {
    /// The server's default length for a task nobody sized.
    static let defaultEstimate = 30

    /// How long a task will likely take. A task someone sized keeps its estimate; one still on the
    /// default is guessed from finished tasks with shared words or in the same project, then from
    /// what the title says it is (a call, an email, a draft…).
    func likelyMinutes(_ task: PlannerTask) -> Int {
        guard task.estimateMin == Self.defaultEstimate else { return task.estimateMin }
        let words = Self.keywords(task.title)
        let done = (state?.tasks ?? []).filter { $0.isDone && $0.id != task.id && $0.estimateMin != Self.defaultEstimate }
        let similar = done.filter { !Self.keywords($0.title).isDisjoint(with: words) }
        if similar.count >= 2 { return Self.median(similar.map(\.estimateMin)) }
        if let project = task.projectId {
            let same = done.filter { $0.projectId == project }
            if same.count >= 3 { return Self.median(same.map(\.estimateMin)) }
        }
        return Self.guessFromTitle(task.title) ?? task.estimateMin
    }

    private static let stopWords: Set<String> = ["the", "a", "an", "and", "or", "to", "for", "of", "on", "in", "with", "my", "at", "by", "from", "up"]

    static func keywords(_ title: String) -> Set<String> {
        Set(title.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 2 && !stopWords.contains($0) })
    }

    static func guessFromTitle(_ title: String) -> Int? {
        let t = title.lowercased()
        let table: [([String], Int)] = [
            (["call", "text", "ping", "remind", "pay ", "book ", "order", "renew", "schedule"], 10),
            (["email", "reply", "respond", "send", "follow up", "invoice"], 15),
            (["review", "read", "check", "update", "fix", "plan"], 30),
            (["draft", "write", "design", "build", "prepare", "research", "outline", "proposal"], 60),
            (["clean", "paint", "organize", "organise", "move", "deep "], 90),
        ]
        for (words, minutes) in table where words.contains(where: { t.contains($0) }) { return minutes }
        return nil
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        let mid = sorted[sorted.count / 2]
        // Round to 5 minutes so it reads naturally.
        return max(5, Int((Double(mid) / 5).rounded()) * 5)
    }

    // MARK: The next step

    enum NextStep {
        case chase(String)
        case waiting(String, Date?)
        case step(String)
        case booked(Date)
        case takes(Int)
    }

    /// The one thing to do next, so a row can say it without opening the task.
    func nextStep(for task: PlannerTask) -> NextStep {
        if let who = task.waitingOn {
            return task.isWaiting ? .waiting(Nudge.firstName(who), task.followUpAt) : .chase(Nudge.firstName(who))
        }
        if let item = task.checklist.first(where: { !$0.done }) { return .step(item.text) }
        if let block = nextBlock(for: task) { return .booked(block.startAt) }
        return .takes(likelyMinutes(task))
    }

    // MARK: Next free slot

    /// The first stretch today with room for `minutes`, starting no earlier than now.
    func freeSlotToday(minutes: Int, now: Date = Date()) -> Date? {
        todayGaps(minMinutes: minutes, now: now).first?.start
    }

    // MARK: Grouping

    enum TaskGroup: String, CaseIterable, Identifiable {
        case overdue = "Overdue", today = "Today", week = "This week", later = "Later", waiting = "Waiting on others"
        var id: String { rawValue }
    }

    /// Which group an open task belongs in: by due date or, failing that, its booked time.
    func group(for task: PlannerTask, now: Date = Date()) -> TaskGroup {
        if task.isWaiting { return .waiting }
        let calendar = Calendar.current
        if let due = task.dueAt, due < now { return .overdue }
        let when = task.dueAt ?? nextBlock(for: task)?.startAt
        guard let when else { return .later }
        if calendar.isDate(when, inSameDayAs: now) { return .today }
        if when < now.addingTimeInterval(7 * 86_400) { return .week }
        return .later
    }
}
