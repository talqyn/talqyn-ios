# TalqynSDK

The Swift SDK for the public Talqyn API: smart search, facets, and the LLM
consultant. Three products in one package, each linked separately:

| Product | What it is |
|---|---|
| `TalqynSDK` | the client: search, the consultant, ratings, chat history, events |
| `TalqynConsultantCore` | the consultant screen's logic, for a screen of your own |
| `TalqynUI` | the ready-made consultant screen, UIKit and SwiftUI |

- **No dependencies.** Only the system frameworks: `Foundation`, `CryptoKit`, and
  `Combine`, plus `UIKit` and `SwiftUI` in `TalqynUI`.
- **iOS 15+**, Swift 5.9; builds clean in Swift 6 mode.
- **Privacy manifest included** (`PrivacyInfo.xcprivacy`): `UserDefaults` access and
  the data collected — shopper identifier, search queries, product interaction,
  questions to the consultant. Check it against what your app declares.
- **Documented in place.** This README covers integration; every public type and
  method carries its full reference in a doc comment — Option-click it in Xcode.

## Quick start

The API host, the storefront slug, and the client key — an id and a secret — are
handed out at onboarding; nothing below works without them. Four steps from an
empty project to a working consultant, each unpacked in the section of the same
name.

**1. Add the package.** `TalqynUI` brings the other two with it; take `TalqynSDK`
alone if all you need is search — see [Installation](#installation).

```swift
// Package.swift
.package(url: "https://github.com/talqyn/talqyn-ios", from: "1.0.0"),
// ...and in the target:
.product(name: "TalqynUI", package: "talqyn-ios"),
```

**2. Make one client for the whole app** and warm it up at launch, so the first
search is as fast as the rest.

```swift
import TalqynSDK

extension Talqyn {
    static let shared = Talqyn(configuration: TalqynConfiguration(
        baseURL: Secrets.talqynBaseURL,            // the API host
        credentials: TalqynDeviceTokenCredentials(
            storefront: "myshop",                  // storefront slug
            clientKeyID: "client_key_id",          // client key id
            clientSecret: Secrets.talqynClientKey, // client key secret
            identity: .persistentAnonymous         // a shopper id that survives restarts
        ),
        defaultLocale: .en,
        defaultCityID: "10"                        // city id in your catalog's numbering
    ))
}

// At launch:
Task { try? await Talqyn.shared.prepare() }
```

**3. Search.** `externalID` is your own SKU: the app opens its own product page by it.

```swift
let found = try await Talqyn.shared.search.search("iphone 15")
found.results.map { ($0.title, $0.externalID) }
```

**4. Show the consultant.** The default theme needs no setup; the delegate hands
back the three actions that lead out of the screen.

```swift
import TalqynUI

let screen = TalqynConsultantViewController(talqyn: .shared)
screen.delegate = self
navigationController?.pushViewController(screen, animated: true)

extension MyRouter: TalqynConsultantDelegate {
    func consultant(_ c: TalqynConsultantViewController, openProduct product: TalqynProduct) {
        if let sku = product.externalID { openPDP(sku) }
    }
    func consultant(_ c: TalqynConsultantViewController, openSearch query: String) { openSearch(query) }
    func consultant(_ c: TalqynConsultantViewController, applyFilters criteria: TalqynFilterCriteria) {
        openListing(TalqynFullSearchQuery(criteria: criteria))
    }
}
```

That is the whole integration: tokens, retries, and the consultant's stream are
the SDK's business, not the app's.

## Installation

```swift
// Package.swift
.package(url: "https://github.com/talqyn/talqyn-ios", from: "1.0.0"),
```

```swift
.target(name: "App", dependencies: [
    .product(name: "TalqynSDK", package: "talqyn-ios"),
    .product(name: "TalqynConsultantCore", package: "talqyn-ios"), // a consultant screen of your own
    .product(name: "TalqynUI", package: "talqyn-ios"),             // the ready-made screen; the core comes with it
])
```

Tuist: add the package to `Tuist/Package.swift` and `.external(name: "TalqynUI")` —
or whichever product you take — to the target's dependencies.

## Initialization

**One client for the whole app** — `Talqyn.shared` from the
[quick start](#quick-start). It holds what every request shares — the shopper, the
city, the language — so there must be exactly one, living as long as the app. The
SDK keeps no singleton of its own: a `static let` is enough, or your dependency
container. The initializer sends nothing and reads nothing from disk. The snippets
below call the client `talqyn`.

### The API host

`baseURL` is required and has no default. Keep it in the build configuration next
to the client key: both change together when the app moves between stands. A path
prefix is kept as given, so `https://gateway.example.com/talqyn` works too.

The host cannot change for the life of a client: another stand means another
`Talqyn`.

### The shopper

The shopper id has to survive an app restart: chat history rests on it.
`.persistentAnonymous` creates one on first launch and keeps it in `UserDefaults`.
When the shopper signs in or out, tell the client:

```swift
await talqyn.setIdentity(.user(accountUUID))     // signed in: history follows the account
await talqyn.setIdentity(.persistentAnonymous)   // back to this device's anonymous shopper
await talqyn.setIdentity(.guest)                 // no history is kept; the consultant still works
```

For a signed-in shopper, pass the same UUID every time — the account's id from
your backend, say. Skip the call when the account changes, and the next
conversation lands in the previous shopper's history.

### Defaults

```swift
talqyn.setPlace(cityID: "10", locationID: nil)  // changing the city RESETS the store
talqyn.setLocale(.kk)
talqyn.setVariant("exp-b")                      // A/B bucket: echoed into analytics
```

Every request that names no city, store, or language of its own takes these.

## Search

```swift
// Instant search — the search field with its dropdown.
let found = try await talqyn.search.search("iphone 15")
found.results        // [TalqynProduct] — externalID is YOUR SKU
found.suggestions    // suggestions; highlightFrom is the boundary of the typed text
found.categories     // categories worth navigating to for the query
found.showcase       // showcase queries (these are suggestions, not products)
found.history        // the shopper's past queries (needs events, see below)
found.correctedFrom  // set if the server quietly searched for corrected text
found.searchID       // travels into the click event

// A listing with filters and sorting, a page at a time.
let query = TalqynFullSearchQuery(
    query: "smartphone",
    limit: 24,
    sort: .priceAscending,
    filters: ["brand": ["apple"]]
)
let listing = try await talqyn.search.full(query)
if let next = query.nextPage(after: listing) {
    let more = try await talqyn.search.full(next)
}

// The filter panel and the results together, for the same selection.
let (page, panel) = try await talqyn.search.listingWithFilters(query)
panel.panelGroups        // the filters, without the city and store groups
panel.cityGroup          // the city picker: option.id goes into cityID
panel.locationGroup      // the store picker: option.id goes into locationID
panel.selectedFilters    // what is selected now, in the shape of the next request
```

`talqynID` is Talqyn's internal id and does not exist in your catalog. Everything
you do on your side, do by `externalID` — it is optional, and whether to show a
product that came without one is the app's call.

### Search as the shopper types

Cancel the previous request before starting the next one, or answers arrive out of
order:

```swift
private var inFlight: Task<Void, Never>?

func textDidChange(_ text: String) {
    inFlight?.cancel()
    inFlight = Task {
        guard let found = try? await talqyn.search.search(text), !Task.isCancelled else { return }
        render(found)
    }
}
```

## The consultant

`TalqynUI` and `TalqynConsultantCore` do everything in this section and the next
two — the stream, ratings, chat history — on their own (see
[The consultant screen](#the-consultant-screen)). Read on if you work with the
consultant's answers directly.

```swift
// Kept between questions: the conversation to continue, and the turn to rate.
var session: String?
var turn: String?

for try await event in talqyn.consultant.ask("need a laptop for school under 300000", sessionID: session) {
    switch event {
    case .status:           break   // TalqynConsultantStage: .thinking → .searching
    case .products:         break   // cards; the payload's searchID — for clicks
    case .delta:            break   // an increment of the answer, see the markers below
    case .clarify:          break   // clarifying questions: chips; the reply is sent as a question
    case .redirectToSearch: break   // this was a search query — replay it as a search
    case .fallback:         break   // there will be no text, the products are there
    case .action:           break   // .applyFilters / .showComparison
    case .followUps:        break   // 2–3 follow-up lines, send them VERBATIM
    case .error:            break   // the turn failed on Talqyn's side
    case .done(let done):           // always last
        session = done.sessionID    // the next question continues this conversation
        turn = done.turnID          // the key for rating this answer
    @unknown default:               // an event type from a newer SDK version
        break
    }
}
```

The stream always ends with `done`. If the connection drops before it, the loop
throws after the events already delivered: show that turn as failed, not as
finished. Keep the `@unknown default` branch — a newer SDK version can add event
types.

Every question is a paid call to the model, so do not ask again on your own after
an error: offer the shopper a retry instead.

For a place with no room for a stream — a widget, an answer prepared in the
background — `answer(_:)` waits for the whole turn:

```swift
let answer = try await talqyn.consultant.answer(.init(question: "a quiet dishwasher"))
```

### Product markers

The text of a `delta` may contain `[p:1234]` markers — references to cards from a
`products` event that has already arrived. Every marker that reaches you has its
card.

```swift
TalqynAnswerMarkup.segments(text)   // [.text("Take "), .product(talqynID: 1234)]
TalqynAnswerMarkup.stripped(text)   // if you do not want inline mentions
```

### Actions

```swift
case .action(.applyFilters(let filters)):     // open a listing the consultant put together
    let criteria = filters.criteria(query: lastQuery, cityID: cityID)
    let page = try await talqyn.search.full(TalqynFullSearchQuery(criteria: criteria))

case .action(.showComparison(let table)):     // a column per product, a row per characteristic
    showComparison(titles: table.titles, rows: table.rows)
```

### Fallback

`fallback` means the products are there and the text is not:

- `.userBudgetExceeded` — this shopper has used up their budget for the next few
  hours; search works as usual;
- `.budgetExceeded` — the storefront's monthly budget is used up: a matter for
  Talqyn, not for the app.

The list is open: treat a reason you do not know as "no text", not as an error.
Products are not always there either.

## Rating an answer

A thumb up or down under a finished turn — an answer, a clarification, a fallback —
keyed by the `turnID` from its `done`:

```swift
try await talqyn.consultant.submitFeedback(TalqynFeedback(
    turnID: turnID, sessionID: sessionID,
    verdict: .down,
    reasons: [.notRelevant],             // .down only
    comment: "was looking for a fridge", // .down only, up to 500 characters
    talqynIDs: [1234]                    // .down only: which cards do not belong
))
try await talqyn.consultant.withdrawFeedback(turnID: turnID)   // the shopper un-pressed the thumb
```

Rating the same turn again **overwrites** the rating, and a rating already given
comes back with the chat from history (`TalqynChatMessage.feedback`). `.notFound`
from `withdrawFeedback` means the rating is already gone — the state you wanted.

## Chat history

```swift
let chats = try await talqyn.consultant.chats(limit: 20, offset: 0)
let chat  = try await talqyn.consultant.chat(sessionID: chats[0].sessionID)
chat.products(for: chat.messages[1])       // the cards of one particular message
try await talqyn.consultant.deleteChat(sessionID: chats[0].sessionID)
```

- **History needs a shopper.** Under `.guest` the list throws `.forbidden` rather
  than coming back empty.
- **Somebody else's chat answers like a missing one** — `.notFound`.
- **Anonymous conversations stay anonymous**: signing in later does not move them
  into the account's history.

## Events

Search learns from what shoppers do, and only the storefront can report it. The
shopper's own query history (`found.history`), click-through, and ranking all rest
on these three events:

| Event | Report it when | Carries |
|---|---|---|
| `TalqynSearchSubmitEvent` | the shopper submits a query — Enter in the field, or opening a listing | the query, `source` (`.instant` or `.full`, never `.consultant`), `resultsCount` when it is known |
| `TalqynProductClickEvent` | a product card is tapped in your own search UI | the `searchID` of the results it was shown in, `talqynID` (not your SKU), the zero-based `position`, the `source` |
| `TalqynCategoryClickEvent` | a category from `found.categories` is tapped | the category id and the query it was shown for |

```swift
talqyn.events.track(TalqynSearchSubmitEvent(
    query: text, source: .instant, resultsCount: found.total
))
talqyn.events.track(TalqynProductClickEvent(
    searchID: found.searchID, talqynID: product.talqynID, position: index, source: .instant
))
talqyn.events.track(TalqynCategoryClickEvent(categoryID: category.id, query: text))
```

Where the `searchID` comes from:

- **Instant search** — `found.searchID`, one per response.
- **A listing** — `listing.searchID`, on the **first** page only: later pages
  continue the same results, so keep the id for the whole listing.
- **The consultant** — the `searchID` of the turn's `products`, with
  `source: .consultant` and `position` counted across all of the turn's products.

**Consultant clicks are reported for you**: the ready-made screen does it before
calling `openProduct`, and a screen of your own calls
`conversation.trackProductTap`. Do not report them again.

`track` returns at once and never throws. There is no offline queue: an event not
yet sent when the app is killed is lost.

## The consultant screen

Two ways, from the least work to the most.

### The ready-made screen

`TalqynUI` draws the whole consultant: the empty state with example questions, the
streaming answer, product cards inline and in a carousel, clarifying questions,
comparison, chat history, ratings, copying, retry — and reports its own clicks.
Step 4 of the quick start shows it on the default theme; on top of that, the app
can bring its brand, its title and example questions, and its own product cards.

```swift
import TalqynUI

extension TalqynTheme {
    static let brand = TalqynTheme(
        colors: Colors(                          // colors from your asset catalog follow dark mode
            accent: .brandAccent, background: .brandBackground, surface: .brandSurface,
            surfaceSecondary: .brandSurfaceSecondary, border: .brandBorder,
            textPrimary: .brandTextPrimary, textSecondary: .brandTextSecondary,
            textTertiary: .brandTextTertiary
        ),
        fonts: .custom(regular: "MuseoSansCyrl-500", bold: "MuseoSansCyrl-700")
    )
}

let screen = TalqynConsultantViewController(
    talqyn: .shared, theme: .brand, title: "Shop AI",
    exampleQuestions: ["A quiet dishwasher under 250 000 ₸", "What to give as a housewarming gift?"]
)

// The delegate and the navigation are step 4's; a card of your own is one more method.
extension MyRouter {
    func consultant(_ c: TalqynConsultantViewController, cardViewFor product: TalqynProduct,
                    layout: TalqynProductCardLayout) -> UIView? {
        switch layout {                          // nil keeps the SDK's card
        case .horizontal: return ProductRowCard(product)
        case .vertical: return ProductTileCard(product)
        }
    }
}
```

In SwiftUI the same screen is `TalqynConsultantView`: the delegate becomes
closures, and the conversation lives in a `@StateObject`, so it survives the view
being rebuilt.

```swift
struct ConsultantScreen: View {
    @StateObject private var conversation = TalqynConversation(talqyn: .shared)
    @EnvironmentObject private var router: Router

    var body: some View {
        TalqynConsultantView(
            conversation: conversation,
            theme: .brand,
            onOpenProduct: { if let sku = $0.externalID { router.openPDP(sku) } },
            onOpenSearch: { router.openSearch($0) },
            onApplyFilters: { router.openListing(TalqynFullSearchQuery(criteria: $0)) }
        )
        .ignoresSafeArea(.container, edges: .bottom)
    }
}
```

What you can set:

| | |
|---|---|
| `theme:` | colors by role, fonts, icons (SF Symbols by default), corner radii, a pinned light or dark appearance, haptics. Two flat palettes pair up for dark mode in `TalqynTheme.Colors(light:dark:)` |
| `title:` | the name in the header and above the examples |
| `exampleQuestions:` | the chips on the empty screen; `[]` removes them |
| `strings:` | the en/ru/kk copy, any line replaceable: `var s = TalqynUIStrings.en; s.placeholder = "…"` |
| `showsHeader:` | `false` keeps your own navigation bar; "new conversation" is then `conversation.reset()`, and history is `TalqynChatHistoryViewController` |
| `showsPoweredBy:` | `false` removes "Powered by Talqyn" from the empty screen |
| `priceFormatter:` | `449 990 ₸` by default |
| `imageLoader:` | your app's image cache and pipeline in place of the SDK's |
| `conversation:` | `TalqynConsultantViewController(conversation:)` takes a conversation of your own — to put a question into the field (`conversation.draft = "…"`) or keep the transcript when the screen closes |

- **Your own product cards.** `cardViewFor:layout:` (`cardView:` in SwiftUI) returns
  your view: `.horizontal` for a product cited in the text, at full width;
  `.vertical` for a tile in the carousel. The SDK sets the width and handles the
  tap — it reports the click and calls `openProduct` — so the card must not open
  the product itself; buttons inside it work as usual.
- **Dark mode, iPad, and accessibility** come with the screen: dynamic colors follow
  the appearance, the conversation keeps to a readable column on iPad, Reduce
  Motion is respected, and small controls take a tap over at least 44×44 pt.

### A screen of your own

`TalqynConsultantCore` is the same screen's logic with no UIKit in it.
`TalqynConversation` runs the conversation — streaming, clarifying questions,
retry, ratings, reopening a chat, click events — and publishes the turns for your
view to draw:

```swift
import TalqynConsultantCore

let conversation = TalqynConversation(talqyn: .shared)

conversation.$turns                                  // questions and answers, updated as the answer streams
    .sink { [weak self] turns in self?.render(turns) }
    .store(in: &cancellables)

conversation.send("A quiet dishwasher under 250 000 ₸")
conversation.stop()                                  // the stop button — and when the screen goes away
conversation.retry(turnID: turn.id)
conversation.rate(turnID: turn.id, .helpful)
conversation.trackProductTap(product, in: turn)      // before opening the product
conversation.restore(sessionID: chat.sessionID)      // a chat picked from history

// An answer as paragraphs, headings, lists, and bold, with each product's card
// right after the sentence that cites it.
let blocks = TalqynAnswerRenderer.blocks(text: turn.text, products: conversation.productsByID)
```

`TalqynChatHistory` does the same for the list of past chats, and
`TalqynUIStrings` holds the en/ru/kk copy.

## Errors

Errors come as `TalqynError`:

| Case | What it means |
|---|---|
| `.unauthorized` | the client key is revoked or wrong |
| `.forbidden` | the SDK is not enabled for the storefront; reading chat history as a guest |
| `.notFound` | no such chat or turn — or it belongs to somebody else |
| `.validation(fields:)` | the request failed validation; `fields` names what failed |
| `.rateLimited(retryAfter:)` | too many requests for now |
| `.server(status:code:retryAfter:)` | Talqyn cannot answer right now |
| `.deviceTokensNotConfigured` / `.deviceTokensUnavailable` | the storefront is not set up on Talqyn's side: a matter for support, not a retry |
| `.invalidConfiguration` | an empty client key or storefront slug, or a `baseURL` that does not parse |
| `.transport` / `.decoding` / `.encoding` / `.cancelled` | the network, the response, the request, cancellation |

Before an error reaches you, the SDK has already retried whatever was safe to
retry. `error.isRetryable` says whether a "Try again" button makes sense, and
`error.requestID` is what to quote to support. In a `catch` that sees other errors
too, `TalqynError.wrap(error)` brings anything to a `TalqynError`, and cancellation
to `.cancelled`.

## Diagnostics

```swift
let configuration = TalqynConfiguration(
    baseURL: Secrets.talqynBaseURL,
    credentials: credentials,
    logHandler: { event in Log.debug("[Talqyn] \(event.message) \(event.requestID ?? "")") }
)
```

Nothing secret reaches a log: the client secret, the token, and the shopper id never
appear in `logHandler`, and `print`, `dump`, and the debugger show them masked.

Quote `Talqyn.version` together with `error.requestID` when contacting support.
Certificate pinning, a proxy, or a traffic logger plug in as your own `transport:`.

## Tests

```
swift test                                            # 195 tests, macOS
xcodebuild test -scheme TalqynSDK-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'   # 229 tests
```

`swift test` runs on macOS and skips the UIKit layer; the simulator run covers the
screen as well.
