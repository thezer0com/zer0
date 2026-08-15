import Foundation
import Testing
import Zer0Core

@testable import Zer0Shell

/// A program that never exists. Every gate below is proved by what it does
/// *not* start, so the fake has to be able to say it was never asked.
@MainActor
final class FakeHostLink: NativeHostLink {
    var onMessage: (@MainActor (String) -> Void)?
    var onClose: (@MainActor (String) -> Void)?

    private(set) var sent: [String] = []
    private(set) var closed = false

    func send(_ json: String) { sent.append(json) }
    func close() { closed = true }

    /// Pretend the program wrote something.
    func says(_ json: String) { onMessage?(json) }
    /// Pretend the program went away.
    func dies(_ detail: String) { onClose?(detail) }
}

/// The extension end.
@MainActor
final class FakePeer: NativeMessagingPeer {
    var onMessage: (@MainActor (String) -> Void)?
    var onHangUp: (@MainActor () -> Void)?

    private(set) var delivered: [String] = []
    private(set) var ended: [String?] = []

    func deliver(_ json: String) { delivered.append(json) }
    func end(reason: String?) { ended.append(reason) }

    /// Pretend the extension called `port.postMessage`.
    func says(_ json: String) { onMessage?(json) }
}

@MainActor
private func aHost(program: String = "/Applications/Thing.app/helper") -> ResolvedHost {
    ResolvedHost(
        applicationId: "com.example.thing",
        program: program,
        manifestPath: "/somewhere/com.example.thing.json",
        registrar: "Google Chrome",
        registrarIsOurs: false
    )
}

/// A host wired to fakes, with a record of everything it was asked to start.
@MainActor
private final class Rig {
    let host = NativeMessagingHost()
    var outcome: NativeHostOutcome = .refused(refusal: .permissionNotGranted, sentence: "No.")
    private(set) var started: [ResolvedHost] = []
    private(set) var asked: [ResolvedHost] = []
    private(set) var links: [FakeHostLink] = []
    /// Set to make starting fail the way a program that has been deleted does.
    var launchFails = false

    struct LaunchFailure: Error {}

    init() {
        host.lookUp = { [weak self] _, _ in
            self?.outcome ?? .refused(refusal: .permissionNotGranted, sentence: "No.")
        }
        host.ask = { [weak self] _, host in self?.asked.append(host) }
        host.makeLink = { [weak self] resolved, _ in
            guard let self else { throw LaunchFailure() }
            if self.launchFails { throw LaunchFailure() }
            self.started.append(resolved)
            let link = FakeHostLink()
            self.links.append(link)
            return link
        }
    }
}

@MainActor
@Suite("nothing starts a program that the core did not name")
struct NativeMessagingGateTests {
    /// The whole point of a single door. Whatever the reason, a refusal is a
    /// sentence back and no process.
    @Test func aRefusalStartsNothingAndSaysWhy() {
        let rig = Rig()
        rig.outcome = .refused(
            refusal: .notForThisExtension(manifestPath: "/m.json"),
            sentence: "/m.json does not list this extension."
        )
        var failure: String?

        rig.host.connect(
            extensionId: "a", applicationId: "com.example.thing", peer: FakePeer()
        ) { failure = $0 }

        #expect(rig.started.isEmpty)
        #expect(rig.asked.isEmpty)
        #expect(failure == "/m.json does not list this extension.")
    }

    /// Absence is *not asked*, and not asked is not yes. Nothing starts while
    /// the question is on screen.
    @Test func aProgramNobodyHasBeenAskedAboutDoesNotStartYet() {
        let rig = Rig()
        rig.outcome = .ask(host: aHost())
        var opened = false

        rig.host.connect(
            extensionId: "a", applicationId: "com.example.thing", peer: FakePeer()
        ) { _ in opened = true }

        #expect(rig.asked.count == 1)
        #expect(rig.started.isEmpty)
        #expect(!opened, "the extension is told nothing until somebody answers")
    }

    @Test func sayingYesCarriesOutTheRequestThatWasWaiting() {
        let rig = Rig()
        rig.outcome = .ask(host: aHost())
        var failure: String? = "not called"

        rig.host.connect(
            extensionId: "a", applicationId: "com.example.thing", peer: FakePeer()
        ) { failure = $0 }
        rig.host.answer(extensionId: "a", program: aHost().program, allowed: true)

        #expect(rig.started.count == 1)
        #expect(failure == nil, "a live connection is reported as one")
    }

    @Test func sayingNoAnswersTheRequestAndStartsNothing() {
        let rig = Rig()
        rig.outcome = .ask(host: aHost())
        var failure: String?

        rig.host.connect(
            extensionId: "a", applicationId: "com.example.thing", peer: FakePeer()
        ) { failure = $0 }
        rig.host.answer(extensionId: "a", program: aHost().program, allowed: false)

        #expect(rig.started.isEmpty)
        #expect(failure?.contains(aHost().program) == true, "said instead: \(failure ?? "nothing")")
    }

    /// 1Password's extension asks for `com.1password.1password` and then
    /// `com.1password.1password7` on the first press of its button. Both
    /// resolve to one program, and two sheets for one decision is the defect
    /// keying the answer on the program exists to avoid.
    @Test func twoRequestsForOneProgramRaiseOneQuestionAndBothAreAnswered() {
        let rig = Rig()
        rig.outcome = .ask(host: aHost())
        var opened = 0

        for applicationId in ["com.example.thing", "com.example.thing7"] {
            rig.host.connect(
                extensionId: "a", applicationId: applicationId, peer: FakePeer()
            ) { failure in if failure == nil { opened += 1 } }
        }

        #expect(rig.asked.count == 1, "one program, one question")

        rig.host.answer(extensionId: "a", program: aHost().program, allowed: true)

        #expect(opened == 2, "everything queued behind the question is carried out")
        #expect(rig.started.count == 2)
    }

    /// An answer is about one extension starting one program. Neither half
    /// travels, so a second extension asking for the same program is asked.
    @Test func answeringForOneExtensionDoesNotAnswerForAnother() {
        let rig = Rig()
        rig.outcome = .ask(host: aHost())
        var opened = false

        rig.host.connect(
            extensionId: "a", applicationId: "com.example.thing", peer: FakePeer()
        ) { _ in }
        rig.host.connect(
            extensionId: "b", applicationId: "com.example.thing", peer: FakePeer()
        ) { failure in if failure == nil { opened = true } }

        rig.host.answer(extensionId: "a", program: aHost().program, allowed: true)

        #expect(!opened)
        #expect(rig.host.isWaiting(extensionId: "b", program: aHost().program))
    }

    @Test func aProgramThatWillNotStartIsReportedRatherThanHung() {
        let rig = Rig()
        rig.outcome = .start(host: aHost())
        rig.launchFails = true
        var failure: String?

        rig.host.connect(
            extensionId: "a", applicationId: "com.example.thing", peer: FakePeer()
        ) { failure = $0 }

        #expect(failure?.contains(aHost().program) == true)
        #expect(rig.host.liveCount == 0)
    }
}

@MainActor
@Suite("a conversation, once one is allowed")
struct NativeMessagingConversationTests {
    private func connected(_ rig: Rig, peer: FakePeer) {
        rig.outcome = .start(host: aHost())
        rig.host.connect(
            extensionId: "a", applicationId: "com.example.thing", peer: peer
        ) { _ in }
    }

    /// Nothing here reads a message. What one means is between the extension
    /// and the program, and a browser that looked would be one that could get
    /// it wrong.
    @Test func whatTheExtensionSendsReachesTheProgramUnchanged() throws {
        let rig = Rig()
        let peer = FakePeer()
        connected(rig, peer: peer)

        peer.says(#"{"hello":"world"}"#)

        let link = try #require(rig.links.first)
        #expect(link.sent == [#"{"hello":"world"}"#])
    }

    @Test func whatTheProgramSendsReachesTheExtensionUnchanged() throws {
        let rig = Rig()
        let peer = FakePeer()
        connected(rig, peer: peer)

        try #require(rig.links.first).says(#"{"answer":42}"#)

        #expect(peer.delivered == [#"{"answer":42}"#])
    }

    /// A program that dies must not leave an extension waiting on a pipe that
    /// no longer exists.
    @Test func aProgramThatDiesEndsTheConversationAndSaysSo() throws {
        let rig = Rig()
        let peer = FakePeer()
        connected(rig, peer: peer)

        try #require(rig.links.first).dies("it exploded")

        #expect(peer.ended == ["it exploded"])
        #expect(rig.host.liveCount == 0)
    }

    /// A child that outlives its parent is a program nothing will ever stop.
    @Test func hangingUpFromTheExtensionSideClosesTheProgram() throws {
        let rig = Rig()
        let peer = FakePeer()
        connected(rig, peer: peer)

        peer.onHangUp?()

        let link = try #require(rig.links.first)
        #expect(link.closed)
        #expect(rig.host.liveCount == 0)
    }

    @Test func stoppingEverythingClosesEveryProgram() throws {
        let rig = Rig()
        rig.outcome = .start(host: aHost())
        for id in ["a", "b"] {
            rig.host.connect(
                extensionId: id, applicationId: "com.example.thing", peer: FakePeer()
            ) { _ in }
        }

        rig.host.stopAll()

        #expect(rig.links.count == 2)
        #expect(rig.links.filter(\.closed).count == 2)
        #expect(rig.host.liveCount == 0)
    }

    /// `sendNativeMessage` is one question and one answer. A second message
    /// from a program that was asked one question is not an answer to it, and
    /// the conversation is over.
    @Test func aOneShotExchangeEndsAtItsFirstAnswer() throws {
        let rig = Rig()
        rig.outcome = .start(host: aHost())
        var answers: [String?] = []

        rig.host.send(
            extensionId: "a", applicationId: "com.example.thing", message: #"{"ping":1}"#
        ) { answer, _ in answers.append(answer) }

        let link = try #require(rig.links.first)
        #expect(link.sent == [#"{"ping":1}"#], "the message goes as soon as the program is up")

        link.says(#"{"pong":1}"#)
        link.says(#"{"pong":2}"#)

        #expect(answers == [#"{"pong":1}"#])
        #expect(link.closed)
    }

    /// The message waits with the request rather than beside it, so a one-shot
    /// that had to be asked about still sends what it meant to send.
    @Test func aOneShotHeldForAnAnswerStillSendsItsMessage() throws {
        let rig = Rig()
        rig.outcome = .ask(host: aHost())

        rig.host.send(
            extensionId: "a", applicationId: "com.example.thing", message: #"{"ping":1}"#
        ) { _, _ in }
        rig.host.answer(extensionId: "a", program: aHost().program, allowed: true)

        let link = try #require(rig.links.first)
        #expect(link.sent == [#"{"ping":1}"#])
    }
}

/// Chrome's framing, spoken to a real child process.
///
/// The program writes back exactly what it is given, so a message that comes
/// back is a message that was framed correctly, written correctly, read
/// correctly and unframed correctly. Everything else in this file uses fakes;
/// this is the one place the bytes are real, and it is what would catch a
/// length written big-endian — invisible for small messages on this machine,
/// because every other byte is zero.
///
/// A script rather than `/bin/cat`, because a native messaging host is started
/// with the calling extension's origin as its one argument: `cat` treats that
/// as a file name, fails to open it and exits before reading a byte. Which is
/// itself worth knowing — it is what every program that is not expecting to be
/// a native messaging host does.
@MainActor
@Suite(.serialized)
struct NativeHostFramingTests {
    /// An executable that copies its input to its output and ignores its
    /// arguments, removed when the test is done with it.
    private func echoProgram() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-nm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("echo")
        try "#!/bin/sh\nexec cat\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )
        return (script, { try? FileManager.default.removeItem(at: directory) })
    }

    private func started(_ program: URL) throws -> NativeHostProcess {
        try NativeHostProcess(
            host: ResolvedHost(
                applicationId: "com.example.echo",
                program: program.path,
                manifestPath: "/nowhere/com.example.echo.json",
                registrar: "zer0",
                registrarIsOurs: true
            ),
            extensionId: String(repeating: "a", count: 32)
        )
    }

    @Test("a message framed by zer0 comes back through a real pipe")
    func aRealPipeRoundTripsAMessage() async throws {
        let (program, clean) = try echoProgram()
        defer { clean() }
        let process = try started(program)
        defer { process.close() }

        var received: [String] = []
        process.onMessage = { received.append($0) }

        // Long enough that the length prefix has a non-zero second byte, which
        // is the only thing here that tells little-endian from big-endian.
        let payload = String(repeating: "x", count: 400)
        process.send(#"{"say":"\#(payload)"}"#)

        #expect(await eventually { !received.isEmpty }, "nothing came back through the pipe")
        #expect(received == [#"{"say":"\#(payload)"}"#])
    }

    /// A body the core will not frame is one that is not sent at all, rather
    /// than a length a program then waits on for ever.
    @Test func nothingUnframeableIsWrittenToAProgram() async throws {
        let (program, clean) = try echoProgram()
        defer { clean() }
        let process = try started(program)
        defer { process.close() }

        var received: [String] = []
        process.onMessage = { received.append($0) }

        process.send("not json")
        process.send(#"{"real":true}"#)

        #expect(await eventually { !received.isEmpty }, "nothing came back through the pipe")
        #expect(received == [#"{"real":true}"#])
    }

    /// A program that dies is a connection that ends, rather than an extension
    /// waiting on a pipe nobody is on the other end of.
    @Test func aProgramThatExitsSaysSo() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zer0-nm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("dies")
        try "#!/bin/sh\necho 'it went wrong' >&2\nexit 3\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path
        )

        let process = try started(script)
        defer { process.close() }

        var said: String?
        process.onClose = { said = $0 }

        #expect(await eventually { said != nil }, "the program's death was never reported")
        // Quotable rather than archived: what it printed on the way out is the
        // only thing anybody can act on.
        #expect(said?.contains("it went wrong") == true, "said instead: \(said ?? "nothing")")
    }
}

@MainActor
@Suite("what the Extensions screen says about a program")
struct NativeHostRowTests {
    /// Nearly every extension has been allowed nothing, and a row saying so
    /// about all of them is noise that trains people past the one that matters.
    @Test func anExtensionAllowedNothingSaysNothing() {
        #expect(extensionProgramLine([]) == nil)
    }

    /// "May start 1 program" is the shape ADR-0018 refuses: the number is true
    /// and the fact somebody needs is which one.
    @Test func theProgramIsNamedRatherThanCounted() {
        let line = extensionProgramLine(["/Applications/1Password.app/helper"])

        #expect(line == "You allowed this extension to start /Applications/1Password.app/helper.")
    }

    @Test func severalProgramsAreAllNamed() {
        let line = extensionProgramLine(["/one", "/two", "/three"])

        #expect(line == "You allowed this extension to start /one, /two and /three.")
    }
}
