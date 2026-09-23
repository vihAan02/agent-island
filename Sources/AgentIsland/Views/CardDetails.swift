import IslandCore
import SwiftUI

/// Everything the card's drop-down shows, as plain values, so the island can be
/// drawn offscreen as well as live.
struct CardConversation {
    var ask: PendingAsk?
    var activity: [ActivityItem]
    var route: ReplyRoute
    var queued: String?
    var notice: String?
    /// The message is on its way into the Claude app.
    var isPasting = false
    /// Pasted messages are sent with Return, not just left in the box.
    var pasteSends = true

    static let empty = CardConversation(ask: nil, activity: [], route: .unavailable(""), queued: nil, notice: nil)
}

/// What the card's controls do. Offscreen renders pass nothing, and the controls
/// are drawn but inert.
@MainActor
struct CardActions {
    var openChat: () -> Void
    var toggleDetails: () -> Void
    var collapse: () -> Void
    var answer: ([String: String]) -> Void
    var approvePlan: (_ acceptEdits: Bool) -> Void
    var revisePlan: (String) -> Void
    var send: (String) -> Void
    var unqueue: () -> Void
    var draft: Binding<String>
    var picks: Binding<[String: Set<String>]>

    static let inert = CardActions(
        openChat: {}, toggleDetails: {}, collapse: {}, answer: { _ in }, approvePlan: { _ in },
        revisePlan: { _ in }, send: { _ in }, unqueue: {}, draft: .constant(""), picks: .constant([:])
    )
}

/// Below the fold: the question or plan Claude is waiting on, what it has been
/// doing, and a field for the next message.
struct CardDetails: View {
    let session: AgentSession
    let conversation: CardConversation
    let actions: CardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch conversation.ask {
            case .questions(let questions):
                QuestionForm(questions: questions, actions: actions)
            case .plan(let plan):
                PlanReview(plan: plan, actions: actions)
            case nil:
                EmptyView()
            }
            Timeline(items: conversation.activity, kind: session.kind)
                .frame(maxHeight: .infinity)
            MessageBar(conversation: conversation, actions: actions)
        }
        .padding(.horizontal, 13)
        .padding(.top, 8)
        .padding(.bottom, 11)
    }
}

// MARK: - Questions

/// AskUserQuestion, answered here. A single question with a single answer goes as
/// soon as an option is clicked; anything more is picked, then sent.
private struct QuestionForm: View {
    let questions: [AgentQuestion]
    let actions: CardActions

    private var sendsOnClick: Bool { questions.count == 1 && !questions[0].multiSelect }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: questions.count == 1 ? "Claude is asking" : "Claude is asking \(questions.count) things",
                         symbol: "questionmark.bubble.fill", color: IslandStyle.question)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(questions, id: \.question) { question in
                        QuestionBlock(question: question, picked: picked(question)) { label in
                            choose(label, for: question)
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)

            if !sendsOnClick {
                Button("Send answers") {
                    actions.answer(answers())
                }
                .buttonStyle(CardButtonStyle(tint: IslandStyle.question, prominent: true))
                .disabled(questions.contains { picked($0).isEmpty })
            }
        }
        .padding(9)
        .background(IslandStyle.question.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func picked(_ question: AgentQuestion) -> Set<String> {
        actions.picks.wrappedValue[question.question] ?? []
    }

    private func choose(_ label: String, for question: AgentQuestion) {
        if sendsOnClick {
            actions.answer([question.question: label])
            return
        }
        var all = actions.picks.wrappedValue
        var chosen = all[question.question] ?? []
        if question.multiSelect {
            if chosen.contains(label) { chosen.remove(label) } else { chosen.insert(label) }
        } else {
            chosen = [label]
        }
        all[question.question] = chosen
        actions.picks.wrappedValue = all
    }

    /// Picks in the order the options were offered; several are comma-separated,
    /// the way Claude's own form sends them.
    private func answers() -> [String: String] {
        var result: [String: String] = [:]
        for question in questions {
            let chosen = picked(question)
            result[question.question] = question.options.map(\.label).filter(chosen.contains).joined(separator: ", ")
        }
        return result
    }
}

private struct QuestionBlock: View {
    let question: AgentQuestion
    let picked: Set<String>
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let header = question.header, !header.isEmpty {
                    Text(header)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(IslandStyle.question)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(IslandStyle.question.opacity(0.16), in: Capsule())
                }
                Text(question.question)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(question.options, id: \.label) { option in
                Button { choose(option.label) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: symbol(for: option))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(picked.contains(option.label) ? IslandStyle.question : .white.opacity(0.4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(2)
                            if let description = option.description, !description.isEmpty {
                                Text(description)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.white.opacity(0.48))
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (picked.contains(option.label) ? IslandStyle.question.opacity(0.18) : Color.white.opacity(0.06)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func symbol(for option: AgentQuestion.Option) -> String {
        let on = picked.contains(option.label)
        if question.multiSelect { return on ? "checkmark.square.fill" : "square" }
        return on ? "largecircle.fill.circle" : "circle"
    }
}

// MARK: - Plan

/// ExitPlanMode, reviewed here: the plan itself, and the two ways to say yes. Asking
/// for changes goes through the message field below.
private struct PlanReview: View {
    let plan: String
    let actions: CardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "Plan ready for review", symbol: "list.bullet.clipboard.fill", color: IslandStyle.plan)
            ScrollView {
                Text(Self.render(plan))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)
            // A long plan fades at the fold, so it reads as more to scroll.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 12)
                }
            }

            HStack(spacing: 6) {
                Button("Approve") { actions.approvePlan(false) }
                    .buttonStyle(CardButtonStyle(tint: IslandStyle.plan, prominent: true))
                Button("Approve, auto-accept edits") { actions.approvePlan(true) }
                    .buttonStyle(CardButtonStyle(tint: IslandStyle.plan, prominent: false))
                Spacer(minLength: 0)
            }
        }
        .padding(9)
        .background(IslandStyle.plan.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Plans are Markdown. Headings turn bold and list marks become bullets, line by
    /// line; bold, italics, and code inside a line render as usual.
    static func render(_ plan: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = AttributedString()
        for (index, raw) in plan.components(separatedBy: "\n").enumerated() {
            var line = raw
            var isHeading = false
            if let mark = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                line.removeSubrange(mark)
                isHeading = true
            } else if let mark = line.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) {
                let indent = line[mark].prefix { $0 == " " }
                line.replaceSubrange(mark, with: indent + "\u{2022} ")
            }
            var part = (try? AttributedString(markdown: line, options: options)) ?? AttributedString(line)
            if isHeading {
                part.font = .system(size: 11, weight: .semibold)
                part.foregroundColor = .white
            }
            if index > 0 { result += AttributedString("\n") }
            result += part
        }
        return result
    }
}

// MARK: - Timeline

/// What the agent has been doing, newest at the bottom.
private struct Timeline: View {
    let items: [ActivityItem]
    let kind: AgentKind

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Activity", symbol: "clock.arrow.circlepath", color: .white.opacity(0.5))
            if items.isEmpty {
                Text("Nothing yet. What the agent reads, runs, and says shows up here.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            Row(item: item, kind: kind)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom)
                // Older rows fade out under the label rather than being cut in half.
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 14)
                        Color.black
                    }
                }
            }
        }
    }

    private struct Row: View {
        let item: ActivityItem
        let kind: AgentKind

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 12)
                Text(item.text)
                    .font(.system(size: 10.5, design: item.kind == .tool ? .monospaced : .default))
                    .foregroundStyle(textColor)
                    .lineLimit(item.kind == .reply || item.kind == .prompt ? 3 : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private var symbol: String {
            switch item.kind {
            case .prompt: "person.fill"
            case .reply: "sparkle"
            case .tool: "chevron.right"
            case .error: "exclamationmark.triangle.fill"
            case .note: "info.circle"
            case .sent: "paperplane.fill"
            }
        }

        private var tint: Color {
            switch item.kind {
            case .prompt, .sent: .white.opacity(0.85)
            case .reply: IslandStyle.brand(kind)
            case .tool: .white.opacity(0.4)
            case .error: IslandStyle.error
            case .note: .white.opacity(0.4)
            }
        }

        private var textColor: Color {
            switch item.kind {
            case .prompt, .sent: .white.opacity(0.95)
            case .reply: .white.opacity(0.8)
            case .tool, .note: .white.opacity(0.55)
            case .error: IslandStyle.error.opacity(0.9)
            }
        }
    }
}

// MARK: - Message field

/// The next message: sent now if the turn is over, queued if the agent is busy.
/// While a question or a plan is waiting, it answers that instead.
private struct MessageBar: View {
    let conversation: CardConversation
    let actions: CardActions
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let queued = conversation.queued {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text("Sends when Claude stops: \(queued)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button { actions.unqueue() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .help("Take it back")
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
            }
            if let notice = conversation.notice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(IslandStyle.error)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                // AppKit draws a field's own placeholder in its colors, not the card's.
                ZStack(alignment: .leading) {
                    if actions.draft.wrappedValue.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: actions.draft)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .focused($focused)
                        .onSubmit(submit)
                        .onExitCommand { actions.collapse() }
                        .disabled(!isEnabled)
                }
                .font(.system(size: 12))
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(canSubmit ? IslandStyle.brand(.claude) : .white.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
            }
            .padding(.leading, 10)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(.white.opacity(isEnabled ? 0.09 : 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(focused ? 0.25 : 0.08), lineWidth: 1)
            }

            if let hint {
                Text(hint)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
    }

    private var draft: String { actions.draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isEnabled: Bool {
        if conversation.ask != nil { return true }
        if case .unavailable = conversation.route { return false }
        return true
    }

    private var canSubmit: Bool { isEnabled && !draft.isEmpty && !conversation.isPasting }

    private var placeholder: String {
        switch conversation.ask {
        case .plan: return "Or tell Claude what to change\u{2026}"
        case .questions: return "Or type your own answer\u{2026}"
        case nil: break
        }
        switch conversation.route {
        case .paste: return "Message this chat\u{2026}"
        case .now: return "Message Claude\u{2026}"
        case .whenDone: return "Message Claude when it's done\u{2026}"
        case .unavailable(let reason): return reason
        }
    }

    private var hint: String? {
        guard conversation.ask == nil else { return nil }
        if conversation.isPasting { return "Pasting into the chat in Claude\u{2026}" }
        return switch conversation.route {
        case .paste: conversation.pasteSends
            ? "Return pastes it into this chat in Claude and sends it."
            : "Return pastes it into this chat in Claude."
        case .now: "Goes to Claude as your next message."
        case .whenDone: "Claude is busy. This goes as soon as its turn ends."
        case .unavailable: nil
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let text = draft
        switch conversation.ask {
        case .plan:
            actions.revisePlan(text)
        case .questions(let questions):
            // A typed answer goes to the first question still without one; the
            // others keep what was picked for them.
            var answers: [String: String] = [:]
            var typedUsed = false
            for question in questions {
                let chosen = actions.picks.wrappedValue[question.question] ?? []
                if chosen.isEmpty, !typedUsed {
                    answers[question.question] = text
                    typedUsed = true
                } else {
                    answers[question.question] = question.options.map(\.label).filter(chosen.contains).joined(separator: ", ")
                }
            }
            if !typedUsed, let first = questions.first { answers[first.question] = text }
            actions.answer(answers)
        case nil:
            // The model clears the draft once the message has actually gone.
            actions.send(text)
            return
        }
        actions.draft.wrappedValue = ""
    }
}

// MARK: - Pieces

private struct SectionLabel: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text.uppercased())
                .kerning(0.4)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(color)
    }
}

/// A small pill button in a card color: filled for the main action, outlined for
/// the rest.
struct CardButtonStyle: ButtonStyle {
    let tint: Color
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? .black : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background {
                Capsule().fill(prominent ? tint : tint.opacity(0.14))
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Capsule())
    }
}
