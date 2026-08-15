import Foundation
import Zer0Core

/// Whatever actually talks to a provider and to the tool servers.
///
/// The seam exists for the same reason `EngineHost` does: the core decides
/// what to ask for and never learns how it was asked. Everything here is a
/// command the reducer emitted, and every answer goes back in as an `Action`.
///
/// Nothing in this protocol names a provider, a model or a transport. A host
/// reads the configuration, resolves all three, and reports what it used.
@MainActor
protocol ChatHost: AnyObject {
    /// Ask for a reply and stream it back.
    ///
    /// The contract the core relies on: report `chatReplyStarted`, then any
    /// number of `chatReplyDelta` and `chatToolCallRequested`, then exactly one
    /// of `chatReplyFinished` or `chatFailed`. A request that ends in neither
    /// leaves a thread spinning forever with nothing on screen explaining why.
    func startReply(
        conversation: ConversationId,
        message: MessageId,
        transcript: [Message],
        tools: [ToolDescriptor]
    )

    func cancelReply(message: MessageId)

    /// Run a tool. Only ever called for a call somebody approved — the gate is
    /// in the core, and there is no path from a model's request to here that
    /// does not go through it.
    func runToolCall(conversation: ConversationId, invocation: ToolInvocation)

    func cancelToolCall(call: ToolCallId)

    /// Ask a configured server what it can do, reporting it with `toolsListed`.
    ///
    /// `nil` means every configured server, which is what a cold start asks
    /// for. Either way the answer is one `toolsListed` per server, and a server
    /// that has nothing to say still answers with an empty list — that is what
    /// stops its tools being callable.
    func listTools(server: String?)
}

/// What happens when nothing is configured to answer.
///
/// Not a silent drop. A question that vanishes is the worst outcome on the
/// list: the panel would sit there having accepted something and done nothing.
/// This says the one true thing the browser knows — nobody has set a provider
/// up — which is the error whose useful action is a settings screen rather
/// than "try again".
@MainActor
final class UnconfiguredChatHost: ChatHost {
    private let emit: @MainActor (Action) -> Void

    init(emit: @escaping @MainActor (Action) -> Void) {
        self.emit = emit
    }

    func startReply(
        conversation: ConversationId,
        message: MessageId,
        transcript _: [Message],
        tools _: [ToolDescriptor]
    ) {
        emit(.chatFailed(
            conversation: conversation,
            message: message,
            kind: .noProviderConfigured,
            detail: ""
        ))
    }

    func cancelReply(message _: MessageId) {}

    func runToolCall(conversation _: ConversationId, invocation: ToolInvocation) {
        emit(.toolCallFailed(
            call: invocation.id,
            kind: .toolUnavailable,
            detail: invocation.server
        ))
    }

    func cancelToolCall(call _: ToolCallId) {}

    /// Nothing to list, and saying so is not the same as saying nothing: the
    /// core replaces the whole list per server, so an empty report from a
    /// server that has gone away is what stops its tools being callable.
    func listTools(server _: String?) {}
}
