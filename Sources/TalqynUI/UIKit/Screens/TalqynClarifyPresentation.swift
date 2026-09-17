#if os(iOS)
import Foundation
import TalqynConsultantCore

/// When a clarifying question comes up as a sheet and when it stays a card in
/// the transcript.
///
/// The policy on its own, apart from the screen that presents: which turns
/// already asked, which sheet the shopper swiped away, and whether this
/// question of theirs has had its sheet.
@MainActor
final class TalqynClarifyPresentation {
    /// How a turn's clarification is shown once its answer has settled.
    enum Decision: Equatable {
        /// Nothing to show — no question, already answered, or already shown.
        case none
        /// A card in the transcript.
        case inline
        /// A sheet over the transcript.
        case sheet
    }

    /// Turns whose question stays inline: the sheet was dismissed, or never
    /// came up.
    private(set) var inlineTurns: Set<UUID> = []
    private var decidedTurns: Set<UUID> = []
    private var hasShownSheetForRequest = false

    /// The shopper typed a new question: it may have a sheet of its own.
    func beginRequest() {
        hasShownSheetForRequest = false
    }

    /// Decides once per turn, when its answer has settled.
    ///
    /// One sheet per question the shopper typed. A clarification that follows
    /// a clarify answer shows inline: a second sheet in a row is an
    /// interrogation. So does one that cannot be presented right now —
    /// something else is already on screen.
    ///
    /// - Parameters:
    ///   - turn: The latest turn.
    ///   - canPresent: Whether a sheet can come up at all.
    func decide(for turn: TalqynAssistantTurn, canPresent: Bool) -> Decision {
        guard turn.clarify != nil, turn.clarifyAnswer == nil, !decidedTurns.contains(turn.id) else { return .none }
        decidedTurns.insert(turn.id)
        guard !hasShownSheetForRequest, canPresent else {
            inlineTurns.insert(turn.id)
            return .inline
        }
        hasShownSheetForRequest = true
        return .sheet
    }

    /// The shopper dismissed a turn's sheet: the question moves into the
    /// transcript.
    func sheetDismissed(turnID: UUID) {
        inlineTurns.insert(turnID)
    }

    /// Forgets turns that left the conversation.
    func forget(turnIDs: [UUID]) {
        for id in turnIDs {
            decidedTurns.remove(id)
            inlineTurns.remove(id)
        }
    }

    /// Forgets everything: a new or restored conversation.
    func forgetAll() {
        decidedTurns = []
        inlineTurns = []
        hasShownSheetForRequest = false
    }
}
#endif
