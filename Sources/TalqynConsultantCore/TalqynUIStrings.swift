import Foundation
import TalqynSDK

/// Every piece of copy the consultant screens show.
///
/// Ships in English, Russian, and Kazakh — the locales the API serves — as
/// plain values rather than a strings table, so an app can replace a single
/// line without shipping a bundle. Pick a set with ``forLocale(_:)`` or start
/// from ``en`` / ``ru`` / ``kk`` and change what needs changing.
public struct TalqynUIStrings: Sendable {
    /// The locale numbers and dates are written in: a rating score, a date in
    /// the history. Follows the copy, not the device — a Russian screen on an
    /// English phone still writes `4,8`.
    ///
    /// English uses `en_US` rather than an `en_KZ` matching the other two:
    /// Foundation and ICU disagree on what `en_KZ` means — one reads it as a
    /// comma decimal separator and a 24-hour clock, the other as a dot and a
    /// 12-hour clock — and the three SDKs have to write a score the same way.
    public var locale: Locale
    public var title: String
    public var introSubtitle: String
    public var placeholder: String
    public var thinking: String
    public var searching: String
    public var composing: String
    public var retry: String
    public var aborted: String
    public var redirectNotice: String
    public var openSearch: String
    public var applyFilters: String
    public var productsHeader: String
    /// The header over the products of a turn the consultant gave up on.
    /// They are not a recommendation on top of an answer — they are all the
    /// turn has — so they do not get the ordinary header.
    public var fallbackProductsHeader: String
    public var comparisonTitle: String
    public var comparisonOnlyDifferences: String
    public var comparisonNoDifferences: String
    public var openComparison: String
    public var newChat: String
    public var newChatConfirm: String
    public var cancel: String
    public var ok: String
    public var close: String
    /// The accessibility label of the button that goes back to the screen the
    /// consultant was opened from.
    public var back: String
    /// The prompts offered on an empty screen and after the first answer.
    public var exampleQuestions: [String]
    public var clarifySubmit: String
    public var clarifySkip: String
    /// What is sent when the shopper skips a clarification.
    public var clarifySkipValue: String
    public var clarifyAnsweredLabel: String
    public var clarifyCustomPlaceholder: String
    public var fallbackGeneric: String
    /// Fallback copy by reason, keyed by the wire value before any `:` suffix.
    ///
    /// Each line says only what went wrong. What the turn still has to offer
    /// is ``fallbackWithProducts``, added when there is something to show.
    public var fallbackByReason: [String: String]
    /// The fallback line when the turn found products anyway: `%@` is the
    /// reason. A turn that found none shows the reason alone — the copy must
    /// not point at products that are not there.
    public var fallbackWithProducts: String
    public var errorGeneric: String
    /// Error copy by code.
    public var errorByCode: [String: String]
    /// `%@` is the formatted price.
    public var filterFrom: String
    /// `%@` is the formatted price.
    public var filterUpTo: String
    public var filterDiscount: String
    public var scrollToBottom: String
    public var send: String
    public var stop: String
    public var answerReady: String
    public var noReviews: String
    public var historyTitle: String
    public var historyEmpty: String
    public var historyUntitled: String
    public var historyYesterday: String
    public var historyError: String
    public var historyUnavailable: String
    public var historyGone: String
    public var historyDelete: String
    public var historyDeleteTitle: String
    public var historyDeleteConfirm: String
    /// The mark on a product card that cannot be bought right now.
    public var outOfStock: String
    /// "N products", one form per CLDR plural category the locale needs:
    /// `[one, few, many]` for Russian, `[one, other]` for English, a single
    /// form for Kazakh. `%d` is the count. See ``productsCount(_:)``.
    public var productsCountForms: [String]
    /// The accessibility label of the copy button under an answer.
    public var copyAnswer: String
    /// What the copy button says once the answer is on the pasteboard.
    public var copied: String
    /// The accessibility label of the "helpful" button under an answer.
    public var rateHelpful: String
    /// The accessibility label of the "not helpful" button under an answer.
    public var rateNotHelpful: String
    /// The line over the reasons offered once an answer is rated unhelpful.
    public var feedbackReasonsTitle: String
    /// The reasons' labels, keyed by ``TalqynFeedbackReason/rawValue``. A
    /// reason with no label here is not offered.
    public var feedbackReasons: [String: String]
    /// The shopper's own message: copy it.
    public var copyQuestion: String
    /// The shopper's own message: put it back into the composer to change it.
    public var editQuestion: String
    /// The line under the composer: the consultant can be wrong, so check
    /// its answers. `%@` is ``title``, so the line follows a screen the app
    /// renamed. Empty hides the line.
    public var disclaimer: String

    /// The strings for a locale.
    ///
    /// - Parameter locale: The locale the consultant answers in.
    public static func forLocale(_ locale: TalqynLocale) -> TalqynUIStrings {
        switch locale {
        case .en: return .en
        case .ru: return .ru
        case .kk: return .kk
        }
    }

    /// A line with its `%@` filled in.
    ///
    /// Substitution is a plain replacement rather than `String(format:)`: copy
    /// an app replaced may carry a bare `%` — a price, a percentage — and that
    /// must not be read as a placeholder.
    ///
    /// - Parameters:
    ///   - template: The line, with or without a `%@`.
    ///   - value: What to put in its place.
    /// - Returns: The line, unchanged when it carries no placeholder.
    package func filled(_ template: String, with value: String) -> String {
        template.replacingOccurrences(of: "%@", with: value)
    }

    /// The copy for a fallback reason, generic when the reason is unknown.
    public func fallbackText(for reason: TalqynFallbackReason) -> String {
        fallbackByReason[reason.base.rawValue] ?? fallbackGeneric
    }

    /// The copy for an error code, generic when the code is unknown.
    public func errorText(for code: String) -> String {
        errorByCode[code] ?? errorGeneric
    }

    /// The label of a feedback reason, or `nil` when the copy has none.
    public func feedbackReasonText(for reason: TalqynFeedbackReason) -> String? {
        feedbackReasons[reason.rawValue]
    }

    /// "N products" in the plural form the count calls for: one, few, or
    /// many in Russian, one or other in English, the single form in Kazakh.
    ///
    /// - Parameter count: How many.
    public func productsCount(_ count: Int) -> String {
        guard let first = productsCountForms.first else { return String(count) }
        var form = first
        if productsCountForms.count >= 3 {
            // Russian: one for 1, 21, 31…; few for 2–4, 22–24…; many for the
            // rest, 11–14 included.
            let mod10 = count % 10, mod100 = count % 100
            if mod10 == 1, mod100 != 11 {
                form = productsCountForms[0]
            } else if (2...4).contains(mod10), !(12...14).contains(mod100) {
                form = productsCountForms[1]
            } else {
                form = productsCountForms[2]
            }
        } else if productsCountForms.count == 2 {
            // English: one for 1, other for everything else.
            form = count == 1 ? productsCountForms[0] : productsCountForms[1]
        }
        return form.replacingOccurrences(of: "%d", with: String(count))
    }

    /// English. The default.
    public static let en = TalqynUIStrings(
        locale: Locale(identifier: "en_US"),
        title: "AI consultant",
        introSubtitle: "I will find products for your request and explain the choice",
        placeholder: "Ask about products…",
        thinking: "Thinking it over…",
        searching: "Looking through the options…",
        composing: "Writing the answer…",
        retry: "Try again",
        aborted: "Answer stopped",
        redirectNotice: "This looks like a search query — results come up faster that way",
        openSearch: "Open results",
        applyFilters: "Show in search",
        productsHeader: "Also worth a look",
        fallbackProductsHeader: "What turned up for your request",
        comparisonTitle: "Comparison",
        comparisonOnlyDifferences: "Differences only",
        comparisonNoDifferences: "Every specification matches",
        openComparison: "Open comparison",
        newChat: "New chat",
        newChatConfirm: "Start a new chat? The current one stays in your history.",
        cancel: "Cancel",
        ok: "OK",
        close: "Close",
        back: "Back",
        exampleQuestions: [
            "Find me an affordable smartphone",
            "Which fridge should I pick for a family?",
            "A laptop for studying under 300,000 ₸",
        ],
        clarifySubmit: "Continue",
        clarifySkip: "No preference",
        clarifySkipValue: "no preference",
        clarifyAnsweredLabel: "Your choice",
        clarifyCustomPlaceholder: "Something else…",
        fallbackGeneric: "Could not explain the choice",
        fallbackByReason: [
            // The shopper's own limit clears in hours; the account's is not
            // theirs to wait out, and not theirs to be told about.
            "user_budget_exceeded": "You have used up your questions for the next few hours",
            "budget_exceeded": "The consultant is unavailable right now",
            "turn_budget": "This chat has run too long",
            "empty_answer": "Could not put an answer together",
            "timeout": "The answer took too long",
            "ttft_timeout": "The service is answering slower than usual",
            "tool_deadline": "Could not look up the details in time",
            "circuit_open": "The consultant is temporarily unavailable",
            "refusal": "Could not answer this request",
        ],
        fallbackWithProducts: "%@, but here is what matches",
        errorGeneric: "Could not get an answer, please try again",
        errorByCode: [
            "retrieval_failed": "Could not find any products, please try again",
        ],
        filterFrom: "from %@",
        filterUpTo: "up to %@",
        filterDiscount: "on sale",
        scrollToBottom: "To the latest message",
        send: "Send",
        stop: "Stop the answer",
        answerReady: "Answer ready",
        noReviews: "No reviews",
        historyTitle: "Chat history",
        historyEmpty: "Your chats with the AI consultant will show up here",
        historyUntitled: "Untitled chat",
        historyYesterday: "Yesterday",
        historyError: "Could not load the history, please try again",
        historyUnavailable: "Chat history is not available yet",
        historyGone: "This chat has been deleted",
        historyDelete: "Delete",
        historyDeleteTitle: "Delete this chat?",
        historyDeleteConfirm: "The conversation will be gone for good.",
        outOfStock: "Out of stock",
        productsCountForms: ["%d product", "%d products"],
        copyAnswer: "Copy the answer",
        copied: "Copied",
        rateHelpful: "Helpful answer",
        rateNotHelpful: "Unhelpful answer",
        feedbackReasonsTitle: "What went wrong?",
        feedbackReasons: [
            "not_relevant": "Not what I was looking for",
            "wrong_info": "Something in the answer is wrong",
            "too_many_questions": "Too many questions",
            "no_answer": "No answer",
            "price_stock": "Price or availability",
            "other": "Other",
        ],
        copyQuestion: "Copy",
        editQuestion: "Edit the question",
        disclaimer: "%@ can be wrong. Double-check its answers."
    )

    /// Russian.
    public static let ru = TalqynUIStrings(
        locale: Locale(identifier: "ru_KZ"),
        title: "AI-консультант",
        introSubtitle: "Подберу товары под ваш запрос и объясню выбор",
        placeholder: "Спросите про товары…",
        thinking: "Думаю над запросом…",
        searching: "Подбираю варианты…",
        composing: "Формулирую ответ…",
        retry: "Повторить",
        aborted: "Ответ остановлен",
        redirectNotice: "Похоже на поисковый запрос — так выдача найдётся быстрее",
        openSearch: "Открыть результаты",
        applyFilters: "Показать в поиске",
        productsHeader: "Также рекомендуем посмотреть",
        fallbackProductsHeader: "Что нашлось по запросу",
        comparisonTitle: "Сравнение",
        comparisonOnlyDifferences: "Только отличия",
        comparisonNoDifferences: "Все характеристики совпадают",
        openComparison: "Открыть сравнение",
        newChat: "Новый диалог",
        newChatConfirm: "Начать новый диалог? Текущий сохранится в истории.",
        cancel: "Отмена",
        ok: "Ок",
        close: "Закрыть",
        back: "Назад",
        exampleQuestions: [
            "Подбери недорогой смартфон",
            "Какой холодильник выбрать для семьи?",
            "Ноутбук для учёбы до 300 000 ₸",
        ],
        clarifySubmit: "Продолжить",
        clarifySkip: "Не важно",
        clarifySkipValue: "не важно",
        clarifyAnsweredLabel: "Ваш выбор",
        clarifyCustomPlaceholder: "Свой вариант…",
        fallbackGeneric: "Не получилось объяснить выбор",
        fallbackByReason: [
            // The shopper's own limit clears in hours; the account's is not
            // theirs to wait out, and not theirs to be told about.
            "user_budget_exceeded": "Лимит вопросов на ближайшие часы исчерпан",
            "budget_exceeded": "Консультант сейчас недоступен",
            "turn_budget": "Диалог получился слишком длинным",
            "empty_answer": "Не получилось сформировать ответ",
            "timeout": "Ответ занял слишком много времени",
            "ttft_timeout": "Сервис отвечает медленнее обычного",
            "tool_deadline": "Не успел уточнить детали",
            "circuit_open": "Консультант временно недоступен",
            "refusal": "Не получилось ответить на этот запрос",
        ],
        fallbackWithProducts: "%@, но вот подходящие товары",
        errorGeneric: "Не получилось получить ответ, попробуйте ещё раз",
        errorByCode: [
            "retrieval_failed": "Не получилось найти товары, попробуйте ещё раз",
        ],
        filterFrom: "от %@",
        filterUpTo: "до %@",
        filterDiscount: "со скидкой",
        scrollToBottom: "К последнему сообщению",
        send: "Отправить",
        stop: "Остановить ответ",
        answerReady: "Ответ готов",
        noReviews: "Нет отзывов",
        historyTitle: "История диалогов",
        historyEmpty: "Здесь появятся ваши диалоги с AI-консультантом",
        historyUntitled: "Диалог без названия",
        historyYesterday: "Вчера",
        historyError: "Не получилось загрузить историю, попробуйте ещё раз",
        historyUnavailable: "История диалогов пока недоступна",
        historyGone: "Этот диалог удалён",
        historyDelete: "Удалить",
        historyDeleteTitle: "Удалить диалог?",
        historyDeleteConfirm: "Переписка удалится безвозвратно.",
        outOfStock: "Нет в наличии",
        productsCountForms: ["%d товар", "%d товара", "%d товаров"],
        copyAnswer: "Скопировать ответ",
        copied: "Скопировано",
        rateHelpful: "Полезный ответ",
        rateNotHelpful: "Бесполезный ответ",
        feedbackReasonsTitle: "Что не так?",
        feedbackReasons: [
            "not_relevant": "Не то, что искал",
            "wrong_info": "Ошибка в ответе",
            "too_many_questions": "Слишком много вопросов",
            "no_answer": "Нет ответа",
            "price_stock": "Цена или наличие",
            "other": "Другое",
        ],
        copyQuestion: "Скопировать",
        editQuestion: "Изменить вопрос",
        disclaimer: "%@ может ошибаться. Перепроверяйте ответы."
    )

    /// Kazakh.
    public static let kk = TalqynUIStrings(
        locale: Locale(identifier: "kk_KZ"),
        title: "AI-кеңесші",
        introSubtitle: "Сұранысыңызға сай тауарларды таңдап, таңдауымды түсіндіремін",
        placeholder: "Тауарлар туралы сұраңыз…",
        thinking: "Сұранысты ойлануда…",
        searching: "Нұсқаларды таңдауда…",
        composing: "Жауапты құрастыруда…",
        retry: "Қайталау",
        aborted: "Жауап тоқтатылды",
        redirectNotice: "Іздеу сұранысына ұқсайды — нәтиже жылдамырақ табылады",
        openSearch: "Нәтижелерді ашу",
        applyFilters: "Іздеуден көрсету",
        productsHeader: "Мынаны да қарауды ұсынамыз",
        fallbackProductsHeader: "Сұраныс бойынша табылғаны",
        comparisonTitle: "Салыстыру",
        comparisonOnlyDifferences: "Тек айырмашылықтар",
        comparisonNoDifferences: "Барлық сипаттамалар бірдей",
        openComparison: "Салыстыруды ашу",
        newChat: "Жаңа диалог",
        newChatConfirm: "Жаңа диалог бастау керек пе? Ағымдағысы тарихта сақталады.",
        cancel: "Бас тарту",
        ok: "Жарайды",
        close: "Жабу",
        back: "Артқа",
        exampleQuestions: [
            "Арзан смартфон таңда",
            "Отбасыға қандай тоңазытқыш таңдауға болады?",
            "Оқуға арналған ноутбук, 300 000 ₸ дейін",
        ],
        clarifySubmit: "Жалғастыру",
        clarifySkip: "Маңызды емес",
        clarifySkipValue: "маңызды емес",
        clarifyAnsweredLabel: "Сіздің таңдауыңыз",
        clarifyCustomPlaceholder: "Өз нұсқаңыз…",
        fallbackGeneric: "Таңдауды түсіндіру мүмкін болмады",
        fallbackByReason: [
            "user_budget_exceeded": "Жақын сағаттарға сұрақ лимиті таусылды",
            "budget_exceeded": "Кеңесші қазір қолжетімсіз",
            "turn_budget": "Диалог тым ұзақ болды",
            "empty_answer": "Жауап қалыптаспады",
            "timeout": "Жауап тым ұзаққа созылды",
            "ttft_timeout": "Қызмет әдеттегіден баяу жауап беруде",
            "tool_deadline": "Толық ақпаратты нақтылауға үлгермедім",
            "circuit_open": "Кеңесші уақытша қолжетімсіз",
            "refusal": "Бұл сұранысқа жауап беру мүмкін болмады",
        ],
        fallbackWithProducts: "%@, бірақ сәйкес тауарлар осында",
        errorGeneric: "Жауап алу мүмкін болмады, қайталап көріңіз",
        errorByCode: [
            "retrieval_failed": "Тауарларды табу мүмкін болмады, қайталап көріңіз",
        ],
        filterFrom: "%@ бастап",
        filterUpTo: "%@ дейін",
        filterDiscount: "жеңілдікпен",
        scrollToBottom: "Соңғы хабарламаға",
        send: "Жіберу",
        stop: "Жауапты тоқтату",
        answerReady: "Жауап дайын",
        noReviews: "Пікірлер жоқ",
        historyTitle: "Диалогтар тарихы",
        historyEmpty: "Мұнда AI-кеңесшімен диалогтарыңыз шығады",
        historyUntitled: "Атауы жоқ диалог",
        historyYesterday: "Кеше",
        historyError: "Тарихты жүктеу мүмкін болмады, қайталап көріңіз",
        historyUnavailable: "Диалогтар тарихы әзірге қолжетімсіз",
        historyGone: "Бұл диалог жойылған",
        historyDelete: "Жою",
        historyDeleteTitle: "Диалогты жою керек пе?",
        historyDeleteConfirm: "Жазысу қайтарымсыз жойылады.",
        outOfStock: "Қоймада жоқ",
        productsCountForms: ["%d тауар"],
        copyAnswer: "Жауапты көшіру",
        copied: "Көшірілді",
        rateHelpful: "Пайдалы жауап",
        rateNotHelpful: "Пайдасыз жауап",
        feedbackReasonsTitle: "Не ұнамады?",
        feedbackReasons: [
            "not_relevant": "Іздегенім емес",
            "wrong_info": "Жауапта қате бар",
            "too_many_questions": "Сұрақ тым көп",
            "no_answer": "Жауап жоқ",
            "price_stock": "Баға не қолда бары",
            "other": "Басқа",
        ],
        copyQuestion: "Көшіру",
        editQuestion: "Сұрақты өзгерту",
        disclaimer: "%@ қателесуі мүмкін. Жауаптарды қайта тексеріңіз."
    )
}
