#if os(iOS)
import TalqynConsultantCore
import TalqynSDK
import UIKit

/// What a row of the transcript shows. Built from ``TalqynConversation`` by
/// ``TalqynTranscriptRowBuilder``; the collection view renders it.
enum TalqynTranscriptRow {
    case user(id: UUID, text: String)
    case assistant(TalqynTurnRow)
    case suggestions([String])
}

/// How the transcript should scroll after a reload.
enum TalqynTranscriptAnchor {
    /// Keep the current position (and the pinned question, if any).
    case keep
    /// Pin the newest question to the top.
    case newestTurn
    /// Go to the end.
    case bottom
}

struct TalqynTurnRow {
    enum Block {
        case text(id: Int, content: NSAttributedString, plain: String)
        case products(id: Int, items: [TalqynProduct])

        var id: Int {
            switch self {
            case let .text(id, _, _): return id
            case let .products(id, _): return id
            }
        }
    }

    /// A proposed action with its one-line summary already written.
    enum Action {
        case filters(TalqynActionFilters, summary: String)
        case comparison(TalqynComparisonTable, summary: String)
    }

    enum Clarify {
        case pending(TalqynClarify, draft: TalqynClarifyDraft, isInteractive: Bool)
        case answered(String)
    }

    /// The controls under a settled turn: its rating, the reasons a thumb
    /// down offers, and the text to copy.
    struct Toolbar {
        var rating: TalqynAnswerRating?
        var offeredReasons: [TalqynFeedbackReason]
        var selectedReasons: [TalqynFeedbackReason]
        /// `nil` when the turn has no text worth copying — a fallback.
        var copyText: String?
    }

    struct Notice {
        var tone: TalqynNoticeView.Tone
        var text: String
        var showsRetry: Bool
    }

    let turnID: UUID
    let question: String
    let stage: TalqynConsultantStage?
    let isStreaming: Bool
    let blocks: [Block]
    /// The products a name in the text can open, by Talqyn id.
    let catalog: [Int: TalqynProduct]
    let productSections: [TalqynProductListView.Section]
    let actions: [Action]
    let clarify: Clarify?
    let redirectQuery: String?
    let notice: Notice?
    let toolbar: Toolbar?
}

/// Turns the conversation into rows, with the rendered answer cached per
/// turn: the regex pass over a long answer is not free, and a streaming turn
/// re-renders many times a second.
@MainActor
final class TalqynTranscriptRowBuilder {
    private let theme: TalqynTheme
    private let strings: TalqynUIStrings
    private let price: TalqynPriceFormatter

    /// What a thumb down offers under an answer: the parts of an answer that
    /// can be wrong.
    private static let answerReasons: [TalqynFeedbackReason] = [.notRelevant, .wrongInfo, .priceStock, .other]
    /// What it offers under a turn that gave up: the missing answer comes
    /// first, and the products that did come can still miss.
    private static let fallbackReasons: [TalqynFeedbackReason] = [.noAnswer, .notRelevant, .other]

    private struct CacheEntry {
        let text: String
        let productsCount: Int
        let catalogCount: Int
        let blocks: [TalqynTurnRow.Block]
        let copyText: String
    }

    private var cache: [UUID: CacheEntry] = [:]

    init(theme: TalqynTheme, strings: TalqynUIStrings, price: TalqynPriceFormatter) {
        self.theme = theme
        self.strings = strings
        self.price = price
    }

    func forget(turnIDs: [UUID]) {
        turnIDs.forEach { cache[$0] = nil }
    }

    func forgetAll() {
        cache = [:]
    }

    /// - Parameter dismissedClarifyTurns: Turns whose clarify sheet the
    ///   shopper dismissed, so the card shows inline instead.
    func rows(for conversation: TalqynConversation, dismissedClarifyTurns: Set<UUID>) -> [TalqynTranscriptRow] {
        var rows = conversation.turns.map { turn -> TalqynTranscriptRow in
            switch turn {
            case let .user(user):
                return .user(id: user.id, text: user.text)
            case let .assistant(assistant):
                return .assistant(turnRow(assistant, conversation: conversation, dismissedClarifyTurns: dismissedClarifyTurns))
            }
        }
        let questions = conversation.suggestedQuestions(examples: strings.exampleQuestions)
        if !questions.isEmpty {
            rows.append(.suggestions(questions))
        }
        return rows
    }

    func turnRow(
        _ turn: TalqynAssistantTurn,
        conversation: TalqynConversation,
        dismissedClarifyTurns: Set<UUID>
    ) -> TalqynTurnRow {
        let isLast = conversation.isLast(turn)
        let isActive = isLast && conversation.isStreaming
        // Cards cited by the text render as the text streams — a card takes
        // its place the moment its marker is complete, the way the words do.
        // Only the carousel of the remaining products waits for the end: its
        // contents depend on which products the text ends up citing.
        let rendered = renderedBlocks(for: turn, catalog: conversation.productsByID)
        let citedIDs = Set(rendered.blocks.flatMap { block -> [Int] in
            guard case let .products(_, items) = block else { return [] }
            return items.map(\.talqynID)
        })

        return TalqynTurnRow(
            turnID: turn.id,
            question: turn.question,
            stage: isActive ? turn.stage : nil,
            isStreaming: isActive,
            blocks: rendered.blocks,
            catalog: conversation.productsByID,
            productSections: isActive ? [] : productSections(turn, excluding: citedIDs),
            actions: turn.actions.compactMap { action(for: $0, catalog: conversation.productsByID) },
            clarify: clarifyRow(turn, conversation: conversation, isLast: isLast, dismissed: dismissedClarifyTurns),
            redirectQuery: turn.redirectQuery,
            notice: notice(turn, isLast: isLast),
            toolbar: isActive ? nil : toolbar(turn, copyText: rendered.copyText)
        )
    }

    /// Rating waits for the turn to settle: a half-written answer is neither
    /// judged nor copied. An answer is rated and copied; a turn that gave up
    /// is rated only — "no answer" is exactly what a shopper may want to say
    /// about it.
    private func toolbar(_ turn: TalqynAssistantTurn, copyText: String) -> TalqynTurnRow.Toolbar? {
        guard turn.isAnswer else { return nil }
        let isFallback = turn.fallbackReason != nil
        guard isFallback || !copyText.isEmpty else { return nil }
        return TalqynTurnRow.Toolbar(
            rating: turn.rating,
            offeredReasons: isFallback ? Self.fallbackReasons : Self.answerReasons,
            selectedReasons: turn.feedbackReasons,
            copyText: copyText.isEmpty ? nil : copyText
        )
    }

    private func renderedBlocks(
        for turn: TalqynAssistantTurn, catalog: [Int: TalqynProduct]
    ) -> (blocks: [TalqynTurnRow.Block], copyText: String) {
        if let entry = cache[turn.id],
           entry.text == turn.text,
           entry.productsCount == turn.products.count,
           entry.catalogCount == catalog.count {
            return (entry.blocks, entry.copyText)
        }
        let rendered = TalqynAnswerRenderer.blocks(text: turn.text, products: catalog)
        let blocks = rendered.map { block -> TalqynTurnRow.Block in
            switch block {
            case let .paragraph(id, lines):
                return .text(
                    id: id,
                    content: TalqynAnswerText.attributed(lines, theme: theme),
                    plain: lines.map(\.plainText).joined(separator: "\n")
                )
            case let .products(id, items):
                return .products(id: id, items: items)
            }
        }
        let copyText = TalqynAnswerRenderer.plainText(of: rendered)
        cache[turn.id] = CacheEntry(
            text: turn.text, productsCount: turn.products.count, catalogCount: catalog.count,
            blocks: blocks, copyText: copyText
        )
        return (blocks, copyText)
    }

    private func productSections(_ turn: TalqynAssistantTurn, excluding citedIDs: Set<Int>) -> [TalqynProductListView.Section] {
        // On a turn the consultant gave up on, these products are not an
        // afterthought under an answer — they are the answer.
        let header = turn.fallbackReason == nil ? strings.productsHeader : strings.fallbackProductsHeader
        if let groups = turn.groups, !groups.isEmpty {
            return groups.compactMap { group in
                // One card per product in a section: a group may list a
                // product twice, and the Android twin's carousel, keyed by id,
                // crashes on the repeat. The first occurrence stays.
                var seen = citedIDs
                let items = group.items.filter { seen.insert($0.talqynID).inserted }
                guard !items.isEmpty else { return nil }
                let label = group.role.prefix(1).uppercased() + group.role.dropFirst()
                return TalqynProductListView.Section(title: "\(label) · \(items.count)", products: items)
            }
        }
        let items = turn.products.filter { !citedIDs.contains($0.talqynID) }
        guard !items.isEmpty else { return [] }
        return [TalqynProductListView.Section(title: header, products: items)]
    }

    private func action(for action: TalqynConsultantAction, catalog: [Int: TalqynProduct]) -> TalqynTurnRow.Action? {
        switch action {
        case let .applyFilters(filters):
            return .filters(filters, summary: filters.summary(strings: strings, price: price))
        case let .showComparison(table):
            guard table.isRenderable else { return nil }
            return .comparison(table, summary: comparisonSummary(table, catalog: catalog))
        case .unknown:
            return nil
        }
    }

    /// What is being compared, in a line: the brands when they tell the
    /// products apart, otherwise how many. The full titles are on the cards
    /// right above the chip.
    private func comparisonSummary(_ table: TalqynComparisonTable, catalog: [Int: TalqynProduct]) -> String {
        let brands = table.talqynIDs.map {
            catalog[$0]?.brandName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if brands.allSatisfy({ !$0.isEmpty }), Set(brands).count == brands.count {
            return brands.joined(separator: " · ")
        }
        return strings.productsCount(table.talqynIDs.count)
    }

    private func clarifyRow(
        _ turn: TalqynAssistantTurn,
        conversation: TalqynConversation,
        isLast: Bool,
        dismissed: Set<UUID>
    ) -> TalqynTurnRow.Clarify? {
        guard let clarify = turn.clarify else { return nil }
        if let answer = turn.clarifyAnswer {
            return .answered(answer)
        }
        // While the turn that asks is still streaming there is nothing to
        // answer yet: the question comes up — as a sheet or as a card — once
        // the turn is done, not as a greyed-out card first.
        if isLast, conversation.isStreaming {
            return nil
        }
        let isInteractive = isLast
        // The latest question is asked in a sheet first; the inline card
        // takes over once the sheet was dismissed, or when the turn is no
        // longer the latest.
        if isInteractive, !dismissed.contains(turn.id) {
            return nil
        }
        return .pending(clarify, draft: conversation.clarifyDrafts[turn.id] ?? TalqynClarifyDraft(), isInteractive: isInteractive)
    }

    private func notice(_ turn: TalqynAssistantTurn, isLast: Bool) -> TalqynTurnRow.Notice? {
        if turn.wasStopped {
            return TalqynTurnRow.Notice(tone: .neutral, text: strings.aborted, showsRetry: isLast)
        }
        if let code = turn.errorCode {
            return TalqynTurnRow.Notice(tone: .error, text: strings.errorText(for: code), showsRetry: isLast)
        }
        if turn.failure != nil {
            return TalqynTurnRow.Notice(tone: .error, text: strings.errorGeneric, showsRetry: isLast)
        }
        if let reason = turn.fallbackReason {
            // The line points at the products only when the turn found some:
            // a fallback with nothing to show must not promise a carousel.
            let cause = strings.fallbackText(for: reason)
            let hasProducts = !turn.products.isEmpty || !(turn.groups?.isEmpty ?? true)
            return TalqynTurnRow.Notice(
                tone: .warning,
                text: hasProducts ? strings.filled(strings.fallbackWithProducts, with: cause) : cause,
                showsRetry: isLast && reason.invitesRetry
            )
        }
        return nil
    }
}

/// What a turn's views report back to the screen.
@MainActor
protocol TalqynTurnViewDelegate: AnyObject {
    func turnDidTapProduct(_ product: TalqynProduct, turnID: UUID)
    func turnCardView(for product: TalqynProduct, layout: TalqynProductCardLayout) -> UIView?
    func turnDidTapRetry(turnID: UUID)
    func turnDidTapRedirect(query: String)
    func turnDidTapFilters(_ filters: TalqynActionFilters, question: String)
    func turnDidTapComparison(_ table: TalqynComparisonTable)
    func turnDidSubmitClarify(answer: String, turnID: UUID)
    func turnDidUpdateClarifyDraft(_ draft: TalqynClarifyDraft, turnID: UUID)
    func turnDidTapSuggestion(_ text: String)
    func turnDidRate(_ rating: TalqynAnswerRating?, reasons: [TalqynFeedbackReason], turnID: UUID)
    func turnDidRequestEdit(question: String)
}
#endif
