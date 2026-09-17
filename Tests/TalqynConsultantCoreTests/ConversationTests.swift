import XCTest
import TalqynSDK
import TalqynTestSupport
@testable import TalqynConsultantCore

@MainActor
final class ConversationTests: XCTestCase {
    private func event(_ name: String, _ data: String) -> [String] { ["event: \(name)", "data: \(data)", ""] }

    private func fullTurn(sessionID: String = "sess-1", turnID: String? = nil) -> [String] {
        let turn = turnID.map { #","turn_id":"\#($0)""# } ?? ""
        return event("status", #"{"stage":"thinking"}"#)
            + event("status", #"{"stage":"searching"}"#)
            + event("products", #"{"items":[{"talqyn_id":1,"title":"Acer"},{"talqyn_id":2,"title":"Lenovo"}],"search_id":"srch-1"}"#)
            + event("delta", #"{"text":"Take "}"#)
            + event("delta", #"{"text":"[p:1]."}"#)
            + event("action", #"{"type":"apply_filters","filters":{"price_max":300000}}"#)
            + event("follow_ups", #"{"items":[" Quieter? ","quieter?","","Cheaper","More","Extra"]}"#)
            + event("done", #"{"session_id":"\#(sessionID)"\#(turn),"ttft_ms":300,"total_ms":900}"#)
    }

    private let turnID = "3f2a9c1e-7b4d-4e8a-9c0f-1a2b3c4d5e6f"

    private func feedbackRequests(_ transport: StubTransport) -> [StubTransport.Sent] {
        transport.sent.filter { $0.path.contains("/consultant/feedback") }
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail(message)
    }

    private func makeConversation(_ transport: StubTransport) async throws -> TalqynConversation {
        TalqynConversation(talqyn: try await TestFixtures.preparedClient(transport: transport))
    }

    private func settle(_ conversation: TalqynConversation) async {
        for _ in 0..<200 {
            if !conversation.isStreaming { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the turn never settled")
    }

    func testTurnStreamsIntoAnAssistantTurn() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: fullTurn())
        let conversation = try await makeConversation(transport)

        conversation.draft = "  need a laptop  "
        conversation.send(conversation.draft)
        XCTAssertTrue(conversation.isStreaming)
        XCTAssertEqual(conversation.draft, "", "the composer empties on send")
        await settle(conversation)

        XCTAssertEqual(conversation.turns.count, 2)
        guard case let .user(user)? = conversation.turns.first else { return XCTFail("expected a user turn") }
        XCTAssertEqual(user.text, "need a laptop", "trimmed")
        let turn = try XCTUnwrap(conversation.turns.last?.assistant)
        XCTAssertEqual(turn.question, "need a laptop")
        XCTAssertEqual(turn.text, "Take [p:1].")
        XCTAssertEqual(turn.products.map(\.talqynID), [1, 2])
        XCTAssertEqual(turn.searchID, "srch-1")
        XCTAssertNil(turn.stage, "settled")
        XCTAssertEqual(turn.actions.count, 1)
        XCTAssertEqual(turn.followUps, ["Quieter?", "Cheaper", "More"], "trimmed, deduplicated, capped at three")
        XCTAssertEqual(turn.timeToFirstTokenMs, 300)
        XCTAssertEqual(conversation.sessionID, "sess-1")
        XCTAssertEqual(conversation.productsByID.keys.sorted(), [1, 2])
        XCTAssertTrue(turn.isAnswer)
        XCTAssertEqual(transport.sent.last?.bodyJSON["question"] as? String, "need a laptop")
    }

    func testSecondTurnCarriesTheSession() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: fullTurn(sessionID: "sess-1"))
        transport.enqueueStream(lines: fullTurn(sessionID: "sess-1"))
        let conversation = try await makeConversation(transport)

        conversation.send("first")
        await settle(conversation)
        conversation.send("second")
        await settle(conversation)

        XCTAssertEqual(transport.sent.last?.bodyJSON["session_id"] as? String, "sess-1")
        XCTAssertEqual(conversation.turns.count, 4)
    }

    func testSendIsIgnoredWhileStreamingOrEmpty() async throws {
        let transport = SlowStreamTransport()
        transport.responses.enqueueDeviceToken()
        transport.enqueueStream(lines: fullTurn())
        let conversation = TalqynConversation(talqyn: TestFixtures.client(transport: transport))

        conversation.send("   ")
        XCTAssertTrue(conversation.turns.isEmpty)
        conversation.send("question")
        conversation.send("another question")
        XCTAssertEqual(conversation.turns.count, 2, "a second send during a stream is dropped")
        await settle(conversation)
    }

    func testStopMarksTheTurnStoppedAndKeepsWhatArrived() async throws {
        let transport = SlowStreamTransport()
        transport.responses.enqueueDeviceToken()
        transport.enqueueStream(lines: fullTurn())
        let conversation = TalqynConversation(talqyn: TestFixtures.client(transport: transport))

        conversation.send("question")
        // Let the products through, then stop before the text.
        for _ in 0..<100 {
            if conversation.turns.last?.assistant?.products.isEmpty == false { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        conversation.stop()
        await settle(conversation)

        let turn = try XCTUnwrap(conversation.turns.last?.assistant)
        XCTAssertTrue(turn.wasStopped)
        XCTAssertTrue(turn.didFail)
        XCTAssertFalse(turn.products.isEmpty, "what arrived stays")
        XCTAssertNil(turn.stage)
        XCTAssertTrue(transport.wasTerminated, "stopping cancels the request")
    }

    func testServerErrorEventAndTransportFailureAreRecorded() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: event("status", #"{"stage":"searching"}"#)
            + event("error", #"{"code":"retrieval_failed"}"#)
            + event("done", #"{"session_id":"s"}"#))
        transport.enqueueStream(lines: [#"{"detail":"Rate limit exceeded"}"#], status: 429)
        let conversation = try await makeConversation(transport)

        conversation.send("one")
        await settle(conversation)
        XCTAssertEqual(conversation.turns.last?.assistant?.errorCode, "retrieval_failed")

        conversation.send("two")
        await settle(conversation)
        let failed = try XCTUnwrap(conversation.turns.last?.assistant)
        guard case .rateLimited? = failed.failure else { return XCTFail("expected the transport failure on the turn") }
        XCTAssertTrue(failed.didFail)
        XCTAssertFalse(failed.isAnswer)
    }

    func testRetryReplacesTheTurnWithoutANewBubble() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: [#"{"detail":"boom"}"#], status: 500)
        transport.enqueueStream(lines: fullTurn())
        let conversation = try await makeConversation(transport)

        conversation.send("question")
        await settle(conversation)
        XCTAssertNotNil(conversation.turns.last?.assistant?.failure)
        let failedID = try XCTUnwrap(conversation.turns.last?.id)

        conversation.retry(turnID: failedID)
        await settle(conversation)

        XCTAssertEqual(conversation.turns.count, 2, "the failed turn is replaced, not appended")
        XCTAssertNotEqual(conversation.turns.last?.id, failedID)
        XCTAssertEqual(conversation.turns.last?.assistant?.question, "question")
        XCTAssertNil(conversation.turns.last?.assistant?.failure)
        XCTAssertEqual(transport.sent.last?.bodyJSON["question"] as? String, "question")
    }

    func testClarifyAnswerIsRecordedAndSentAsTheNextQuestion() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: event("status", #"{"stage":"thinking"}"#)
            + event("clarify", #"{"message":"clarify","questions":[{"id":"budget","label":"Budget?","multi":false,"options":["under 300k"]}]}"#)
            + event("done", #"{"session_id":"sess-1"}"#))
        transport.enqueueStream(lines: fullTurn())
        let conversation = try await makeConversation(transport)

        conversation.send("recommend something")
        await settle(conversation)
        let asking = try XCTUnwrap(conversation.turns.last?.assistant)
        XCTAssertNotNil(asking.clarify)
        XCTAssertTrue(conversation.isClarifyInteractive(asking))
        XCTAssertTrue(conversation.suggestedQuestions(examples: ["example"]).isEmpty, "no prompts under a question")

        var draft = TalqynClarifyDraft()
        draft.toggle("under 300k", in: asking.clarify!.questions[0])
        conversation.submitClarify(turnID: asking.id, answer: draft.answer(for: asking.clarify!.questions))
        await settle(conversation)

        XCTAssertEqual(conversation.turns.count, 3, "no user bubble for a clarify answer")
        XCTAssertEqual(conversation.turns[1].assistant?.clarifyAnswer, "Budget: under 300k.")
        XCTAssertFalse(conversation.isClarifyInteractive(conversation.turns[1].assistant!), "not the latest turn any more")
        XCTAssertEqual(transport.sent.last?.bodyJSON["question"] as? String, "Budget: under 300k.")
        XCTAssertEqual(transport.sent.last?.bodyJSON["session_id"] as? String, "sess-1")
    }

    func testSuggestedQuestions() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: event("delta", #"{"text":"ok"}"#) + event("done", #"{"session_id":"s"}"#))
        transport.enqueueStream(lines: fullTurn())
        let conversation = try await makeConversation(transport)
        let examples = ["Pick a smartphone", "Which fridge?", "A laptop under 300k"]

        XCTAssertTrue(conversation.suggestedQuestions(examples: examples).isEmpty, "nothing before the first answer")
        conversation.send("pick a smartphone")
        await settle(conversation)
        XCTAssertEqual(
            conversation.suggestedQuestions(examples: examples),
            ["Which fridge?", "A laptop under 300k"],
            "after the first answer: the examples not yet asked, case-insensitively"
        )

        conversation.send("more")
        XCTAssertTrue(conversation.suggestedQuestions(examples: examples).isEmpty, "nothing while streaming")
        await settle(conversation)
        XCTAssertEqual(conversation.suggestedQuestions(examples: examples), ["Quieter?", "Cheaper", "More"], "the turn's follow-ups win")
    }

    func testRatingIsKeptOnTheTurnAndTakenBackWithNil() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: fullTurn())
        let conversation = try await makeConversation(transport)
        conversation.send("need a laptop")
        await settle(conversation)
        let turnID = try XCTUnwrap(conversation.turns.last?.assistant?.id)
        XCTAssertNil(conversation.turns.last?.assistant?.rating)
        let requestsBefore = transport.sent.count

        conversation.rate(turnID: turnID, .helpful)
        XCTAssertEqual(conversation.turns.last?.assistant?.rating, .helpful)
        conversation.rate(turnID: turnID, .notHelpful)
        XCTAssertEqual(conversation.turns.last?.assistant?.rating, .notHelpful)
        conversation.rate(turnID: turnID, nil)
        XCTAssertNil(conversation.turns.last?.assistant?.rating)

        conversation.rate(turnID: UUID(), .helpful)
        XCTAssertNil(conversation.turns.last?.assistant?.rating, "an unknown turn changes nothing")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(
            transport.sent.count, requestsBefore,
            "a turn from a server without turn ids is rated on the device only"
        )
    }

    /// The thumb is saved under the turn's id, and every change after it —
    /// a reason picked, the rating taken back — reaches Talqyn in order.
    func testRatingIsSavedWithTalqyn() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: fullTurn(turnID: turnID))
        transport.enqueue(json: "", status: 204)
        transport.enqueue(json: "", status: 204)
        transport.enqueue(json: "", status: 204)
        let conversation = try await makeConversation(transport)
        conversation.send("need a laptop")
        await settle(conversation)
        let turn = try XCTUnwrap(conversation.turns.last?.assistant)
        XCTAssertEqual(turn.talqynTurnID, turnID)
        XCTAssertEqual(turn.sessionID, "sess-1")
        XCTAssertTrue(turn.isRatedRemotely)

        conversation.rate(turnID: turn.id, .notHelpful)
        await waitUntil("the dislike was never sent") { self.feedbackRequests(transport).count == 1 }
        conversation.rate(turnID: turn.id, .notHelpful, reasons: [.notRelevant, .notRelevant])
        await waitUntil("the reason was never sent") { self.feedbackRequests(transport).count == 2 }
        XCTAssertEqual(conversation.turns.last?.assistant?.feedbackReasons, [.notRelevant], "a reason counts once")
        conversation.rate(turnID: turn.id, nil)
        await waitUntil("the withdrawal was never sent") { self.feedbackRequests(transport).count == 3 }

        let sent = feedbackRequests(transport)
        XCTAssertEqual(sent[0].bodyJSON["verdict"] as? String, "down")
        XCTAssertEqual(sent[0].bodyJSON["turn_id"] as? String, turnID)
        XCTAssertEqual(sent[0].bodyJSON["session_id"] as? String, "sess-1")
        XCTAssertNil(sent[0].bodyJSON["reasons"])
        XCTAssertEqual(sent[1].bodyJSON["reasons"] as? [String], ["not_relevant"])
        XCTAssertEqual(sent[2].request.httpMethod, "DELETE")
        XCTAssertNil(conversation.turns.last?.assistant?.rating)
        XCTAssertNil(conversation.feedbackFailure)
    }

    /// Taps faster than the network are not queued: what is sent is where the
    /// taps ended, and taps that end where they started send nothing.
    func testTapsThatEndWhereTheyStartedSendNothing() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: fullTurn(turnID: turnID))
        let conversation = try await makeConversation(transport)
        conversation.send("need a laptop")
        await settle(conversation)
        let turnID = try XCTUnwrap(conversation.turns.last?.id)

        conversation.rate(turnID: turnID, .helpful)
        conversation.rate(turnID: turnID, .notHelpful)
        conversation.rate(turnID: turnID, nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(feedbackRequests(transport).isEmpty)
    }

    /// A thumb that looks pressed must be pressed: a rating Talqyn did not
    /// take goes back to what Talqyn holds.
    func testARatingTalqynRefusesIsPutBack() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: fullTurn(turnID: turnID))
        transport.enqueue(json: #"{"error":"internal_error"}"#, status: 500)
        let conversation = try await makeConversation(transport)
        conversation.send("need a laptop")
        await settle(conversation)
        let turnID = try XCTUnwrap(conversation.turns.last?.id)

        conversation.rate(turnID: turnID, .helpful)
        XCTAssertEqual(conversation.turns.last?.assistant?.rating, .helpful, "shown at once")
        await waitUntil("the refusal never came back") { conversation.feedbackFailure != nil }
        XCTAssertNil(conversation.turns.last?.assistant?.rating)
        XCTAssertEqual(conversation.feedbackFailure?.statusCode, 500)
    }

    /// Taking back a rating Talqyn no longer has is done, not failed — a
    /// repeat of a withdrawal that went through answers exactly this.
    func testWithdrawingARatingThatIsAlreadyGoneIsDone() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: fullTurn(turnID: turnID))
        transport.enqueue(json: "", status: 204)
        transport.enqueue(json: #"{"detail":"feedback not found"}"#, status: 404)
        let conversation = try await makeConversation(transport)
        conversation.send("need a laptop")
        await settle(conversation)
        let turnID = try XCTUnwrap(conversation.turns.last?.id)

        conversation.rate(turnID: turnID, .helpful)
        await waitUntil("the like was never sent") { self.feedbackRequests(transport).count == 1 }
        conversation.rate(turnID: turnID, nil)
        await waitUntil("the withdrawal was never sent") { self.feedbackRequests(transport).count == 2 }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(conversation.turns.last?.assistant?.rating)
        XCTAssertNil(conversation.feedbackFailure)
    }

    /// A chat reopened from history shows the thumb that is already down, and
    /// taking it back is a withdrawal of the rating Talqyn holds.
    func testARestoredRatingIsTheOneTalqynHolds() async throws {
        let transport = StubTransport()
        transport.enqueue(json: """
        {"session_id":"s1","messages":[
          {"role":"user","text":"laptop","talqyn_ids":[],"turn_id":"\(turnID)","feedback":"down"},
          {"role":"assistant","text":"here","talqyn_ids":[],"turn_id":"\(turnID)","feedback":"down"}],
         "products":[]}
        """)
        transport.enqueue(json: "", status: 204)
        let conversation = try await makeConversation(transport)
        conversation.restore(sessionID: "s1")
        await waitUntil("the chat never opened") { !conversation.isRestoring }

        let turn = try XCTUnwrap(conversation.turns.last?.assistant)
        XCTAssertEqual(turn.rating, .notHelpful)
        XCTAssertEqual(turn.talqynTurnID, turnID)
        XCTAssertEqual(turn.sessionID, "s1")

        conversation.rate(turnID: turn.id, nil)
        await waitUntil("the withdrawal was never sent") { self.feedbackRequests(transport).count == 1 }
        XCTAssertEqual(feedbackRequests(transport).first?.request.httpMethod, "DELETE")
    }

    /// A turn is compared as a whole: every property that changes redraws it.
    func testTurnsCompareByEveryProperty() {
        var turn = TalqynAssistantTurn(id: UUID(), question: "q")
        let original = turn
        turn.feedbackReasons = [.other]
        XCTAssertNotEqual(turn, original)
        turn = original
        turn.failure = .transport(URLError(.timedOut))
        XCTAssertNotEqual(turn, original)
        var same = original
        same.failure = .transport(URLError(.timedOut))
        XCTAssertEqual(turn, same, "the same failure twice is no change")
    }

    func testProductTapIsReportedWithSearchIDAndPosition() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: fullTurn())
        transport.enqueue(json: "", status: 204)
        let conversation = try await makeConversation(transport)

        conversation.send("question")
        await settle(conversation)
        let turn = try XCTUnwrap(conversation.turns.last?.assistant)
        conversation.trackProductTap(turn.products[1], in: turn)

        for _ in 0..<100 {
            if transport.sent.contains(where: { $0.path.hasSuffix("/events/product-click") }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let click = try XCTUnwrap(transport.sent.last { $0.path.hasSuffix("/events/product-click") })
        XCTAssertEqual(click.bodyJSON["search_id"] as? String, "srch-1")
        XCTAssertEqual(click.bodyJSON["talqyn_id"] as? Int, 2)
        XCTAssertEqual(click.bodyJSON["position"] as? Int, 1)
        XCTAssertEqual(click.bodyJSON["source"] as? String, "cip")
    }

    func testResetAndDiscardIfOpen() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: fullTurn(sessionID: "sess-1"))
        let conversation = try await makeConversation(transport)

        conversation.send("question")
        await settle(conversation)
        conversation.discardIfOpen(sessionID: "other")
        XCTAssertEqual(conversation.turns.count, 2, "another chat's deletion changes nothing")

        conversation.discardIfOpen(sessionID: "sess-1")
        XCTAssertTrue(conversation.turns.isEmpty)
        XCTAssertNil(conversation.sessionID)
        XCTAssertTrue(conversation.productsByID.isEmpty)
    }

    func testRestoreLoadsATranscript() async throws {
        let transport = StubTransport()
        transport.enqueue(json: """
        {"session_id":"s1","messages":[
          {"role":"user","text":"iphone","talqyn_ids":[],"route":"redirect"},
          {"role":"assistant","text":"iphone 15","talqyn_ids":[]},
          {"role":"user","text":"laptop","talqyn_ids":[]},
          {"role":"assistant","text":"here [p:1]","talqyn_ids":[1,9]},
          {"role":"assistant","text":"and more","talqyn_ids":[]}],
         "products":[{"talqyn_id":1,"title":"Acer"}]}
        """)
        let conversation = try await makeConversation(transport)

        conversation.restore(sessionID: "s1")
        XCTAssertTrue(conversation.isRestoring)
        for _ in 0..<100 {
            if !conversation.isRestoring { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertNil(conversation.restoreFailure)
        XCTAssertEqual(conversation.sessionID, "s1")
        XCTAssertEqual(conversation.turns.count, 5)
        XCTAssertEqual(conversation.turns[1].assistant?.redirectQuery, "iphone 15", "a redirect row is a query, not prose")
        XCTAssertEqual(conversation.turns[1].assistant?.text, "")
        XCTAssertEqual(conversation.turns[3].assistant?.text, "here [p:1]")
        XCTAssertEqual(conversation.turns[3].assistant?.products.map(\.talqynID), [1], "an id with no card behind it is skipped")
        XCTAssertEqual(conversation.turns[4].assistant?.question, "", "an orphan assistant row keeps its place")
        XCTAssertNil(conversation.turns[3].assistant?.stage)
        XCTAssertEqual(transport.sent.last?.query, "locale=en")
    }

    /// One card per product in a turn: a payload that repeats an item — its
    /// own, or one the turn already has — adds it once, where it first came.
    func testAProductRepeatedInAPayloadIsKeptOnce() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines:
            event("products", #"{"items":[{"talqyn_id":1,"title":"Acer"},{"talqyn_id":2,"title":"Lenovo"},{"talqyn_id":1,"title":"Acer"}]}"#)
            + event("products", #"{"items":[{"talqyn_id":2,"title":"Lenovo"},{"talqyn_id":3,"title":"Asus"},{"talqyn_id":3,"title":"Asus"}]}"#)
            + event("done", #"{"session_id":"sess-1"}"#))
        let conversation = try await makeConversation(transport)

        conversation.send("laptop")
        await settle(conversation)

        XCTAssertEqual(conversation.turns.last?.assistant?.products.map(\.talqynID), [1, 2, 3])
    }

    /// A reopened chat lists each product of a turn once, in the order it was
    /// first shown.
    func testARestoredTurnListsEachProductOnce() async throws {
        let transport = StubTransport()
        transport.enqueue(json: """
        {"session_id":"s1","messages":[
          {"role":"user","text":"laptop","talqyn_ids":[]},
          {"role":"assistant","text":"here","talqyn_ids":[2,1,2,9,1]}],
         "products":[{"talqyn_id":1,"title":"Acer"},{"talqyn_id":2,"title":"Lenovo"}]}
        """)
        let conversation = try await makeConversation(transport)

        conversation.restore(sessionID: "s1")
        await waitUntil("the chat never opened") { !conversation.isRestoring }

        XCTAssertEqual(conversation.turns.last?.assistant?.products.map(\.talqynID), [2, 1])
    }

    func testRestoreFailureIsSurfaced() async throws {
        let transport = StubTransport()
        transport.enqueue(json: #"{"detail":"chat not found"}"#, status: 404)
        let conversation = try await makeConversation(transport)

        conversation.restore(sessionID: "gone")
        for _ in 0..<100 {
            if !conversation.isRestoring { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .notFound? = conversation.restoreFailure else {
            return XCTFail("expected notFound, got \(String(describing: conversation.restoreFailure))")
        }
        XCTAssertTrue(conversation.turns.isEmpty)
    }

    /// Coming back from a modal re-checks the identity. The shopper id was a
    /// local UUID before the first token and the server's form after it; that
    /// is the same shopper, and the transcript must stay.
    func testTokenIssuanceIsNotAnIdentityChange() async throws {
        let transport = StubTransport()
        transport.enqueueDeviceToken(userID: "6f1c2b9a-3e47-4b8f-9a10-2c5d8e7f4a01") // not the local UUID
        transport.enqueueStream(lines: fullTurn())
        let talqyn = TestFixtures.client(credentials: TestFixtures.deviceToken(identity: .persistentAnonymous), transport: transport)
        let conversation = TalqynConversation(talqyn: talqyn)

        await conversation.refreshIdentity()
        conversation.send("question")
        await settle(conversation)
        XCTAssertEqual(conversation.turns.count, 2)

        await conversation.refreshIdentity()
        XCTAssertEqual(conversation.turns.count, 2, "the token names the same shopper the app did")
    }

    func testIdentityChangeDropsTheTranscript() async throws {
        let transport = StubTransport()
        transport.enqueueStream(lines: fullTurn())
        let talqyn = try await TestFixtures.preparedClient(transport: transport)
        let conversation = TalqynConversation(talqyn: talqyn)

        await conversation.refreshIdentity()
        conversation.send("question")
        await settle(conversation)
        await conversation.refreshIdentity()
        XCTAssertEqual(conversation.turns.count, 2, "same shopper, same transcript")

        transport.enqueueDeviceToken(token: "tlqd_named", userID: "6f1c2b9a-3e47-4b8f-9a10-2c5d8e7f4a01")
        await talqyn.setIdentity(.user(UUID()))
        await conversation.refreshIdentity()
        XCTAssertTrue(conversation.turns.isEmpty, "a new shopper starts clean")
    }
}
