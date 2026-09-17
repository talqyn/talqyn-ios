import TalqynSDK

public extension TalqynConsultantStage {
    /// Products are in, the first token of the text is not. Not a server
    /// stage: derived on the client so the status line has something to say
    /// between the two.
    static let composing = TalqynConsultantStage(rawValue: "composing")
}

public extension TalqynFallbackReason {
    /// The reason without its detail: the wire value may carry a suffix after
    /// a `:`, and copy and decisions key off what comes before it.
    var base: TalqynFallbackReason {
        guard let colon = rawValue.firstIndex(of: ":") else { return self }
        return TalqynFallbackReason(rawValue: String(rawValue[..<colon]))
    }

    /// Whether asking the same question again could plausibly work.
    ///
    /// Not after a spent budget — the shopper's or the account's — nor after
    /// a turn that ran out of its own budget or that the model refused: the
    /// repeat would meet the same wall. A timeout or an open circuit may
    /// clear, and an unknown reason is given the benefit of the doubt.
    var invitesRetry: Bool {
        let base = self.base
        return !(base.isBudgetExhausted || base == .turnBudget || base == .refusal)
    }
}
