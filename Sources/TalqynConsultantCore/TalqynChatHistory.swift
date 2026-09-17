import Combine
import Foundation
import TalqynSDK

/// The shopper's list of conversations: paged loading, refresh, deletion.
///
/// Backs `TalqynChatHistoryViewController`; public for a storefront that lists
/// chats in its own screen.
@MainActor
public final class TalqynChatHistory: ObservableObject {
    /// What the list shows.
    public enum State: Equatable, Sendable {
        case loading
        case empty
        case failed(TalqynError)
        case loaded(chats: [TalqynChatSummary], isLoadingMore: Bool)
    }

    @Published public private(set) var state: State = .loading

    public let talqyn: Talqyn
    private let pageSize: Int
    private var chats: [TalqynChatSummary] = []
    private var isLoadingPage = false
    private var hasMore = true
    private var loadTask: Task<Void, Never>?

    /// Creates a history list.
    ///
    /// - Parameters:
    ///   - talqyn: The client to load through.
    ///   - pageSize: How many chats per page.
    public init(talqyn: Talqyn, pageSize: Int = 20) {
        self.talqyn = talqyn
        self.pageSize = pageSize
    }

    /// Loads the first page, replacing what is shown.
    public func load() {
        loadPage(reset: true)
    }

    /// Loads the next page once the shopper is near the end of the list.
    ///
    /// - Parameter chat: The chat that just became visible.
    public func loadMoreIfNeeded(after chat: TalqynChatSummary) {
        guard let index = chats.firstIndex(where: { $0.sessionID == chat.sessionID }),
              index >= chats.count - 5 else { return }
        loadPage(reset: false)
    }

    /// Deletes a conversation. The row goes at once; a failed deletion
    /// reloads the list so the row comes back.
    ///
    /// - Parameter sessionID: The conversation to delete.
    public func delete(sessionID: String) {
        chats.removeAll { $0.sessionID == sessionID }
        render()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.talqyn.consultant.deleteChat(sessionID: sessionID)
            } catch {
                self.loadPage(reset: true)
            }
        }
    }

    private func loadPage(reset: Bool) {
        if reset {
            loadTask?.cancel()
            isLoadingPage = false
            hasMore = true
        }
        guard !isLoadingPage, reset || hasMore else { return }
        isLoadingPage = true
        render()

        let offset = reset ? 0 : chats.count
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.talqyn.consultant.chats(limit: self.pageSize, offset: offset)
                guard !Task.isCancelled else { return }
                self.isLoadingPage = false
                self.hasMore = page.count == self.pageSize
                self.chats = reset ? page : Self.appending(page, to: self.chats)
                self.render()
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoadingPage = false
                if self.chats.isEmpty {
                    self.state = .failed(TalqynError.wrap(error))
                } else {
                    self.render()
                }
            }
        }
    }

    private static func appending(_ page: [TalqynChatSummary], to chats: [TalqynChatSummary]) -> [TalqynChatSummary] {
        let known = Set(chats.map(\.sessionID))
        return chats + page.filter { !known.contains($0.sessionID) }
    }

    private func render() {
        guard !chats.isEmpty else {
            state = isLoadingPage ? .loading : .empty
            return
        }
        state = .loaded(chats: chats, isLoadingMore: isLoadingPage)
    }

    /// The subtitle of a row: the time for today, "yesterday", otherwise the
    /// date, with the year only when it is not this one.
    ///
    /// The shapes are templates, not fixed formats: the locale decides the
    /// order, the separators, and whether the time has a 12-hour clock.
    ///
    /// - Parameters:
    ///   - date: When the last message was written.
    ///   - strings: For the word "yesterday".
    ///   - locale: The locale to write the date in —
    ///     ``TalqynUIStrings/locale`` on the screen.
    ///   - calendar: The calendar that decides what "today" is.
    ///   - now: The current moment; injectable for tests.
    public static func subtitle(
        for date: Date?,
        strings: TalqynUIStrings,
        locale: Locale,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> String {
        guard let date else { return "" }
        if calendar.isDate(date, inSameDayAs: now) {
            return formatted(date, template: "jmm", locale: locale, calendar: calendar)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return strings.historyYesterday
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatted(date, template: sameYear ? "dMMM" : "dMMMy", locale: locale, calendar: calendar)
    }

    private static func formatted(_ date: Date, template: String, locale: Locale, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
