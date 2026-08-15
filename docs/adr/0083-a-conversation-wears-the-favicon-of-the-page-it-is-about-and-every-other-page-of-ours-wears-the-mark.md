# ADR-0083: A conversation wears the favicon of the page it is about, and every other page of ours wears the mark

- **Status:** Accepted
- **Date:** 2026-08-10
- **Lock:** `apple/Tests/Zer0ShellTests/SiteIconTests.swift::SiteIconTests/aConversationWearsTheSiteOfThePageItIsAbout`, `apple/Tests/Zer0ShellTests/SiteIconTests.swift::SiteIconTests/threeConversationsAreThreeDifferentBadges`, `apple/Tests/Zer0ShellTests/SiteIconTests.swift::SiteIconTests/closingThePagesTabDoesNotChangeTheBadge`, `apple/Tests/Zer0ShellTests/SiteIconTests.swift::SiteIconTests/aConversationAboutNoPageWearsTheMark`, `apple/Tests/Zer0ShellTests/SiteIconTests.swift::SiteIconTests/ourOwnPagesWearOurOwnMark`, `apple/Tests/Zer0ShellTests/SiteIconTests.swift::SiteIconTests/anOrdinaryTabStillWearsItsOwnSite`, `apple/Tests/Zer0ShellTests/SiteIconTests.swift::SiteIconTests/aConversationDrawsItsPagesIcon`, `apple/Tests/Zer0ShellTests/SiteIconTests.swift::SiteIconTests/anEphemeralConversationDrawsNoIcon`, `apple/Tests/Zer0ShellTests/Zer0MarkTests.swift::Zer0MarkTests/theSmallSizesGetTheirOwnDrawing`

## Context

A chat tab's address is `zer0://chat?conversation=7`, and the sidebar drew every
row's badge from `URL(string: tab.url)?.host()`. So a conversation's host was
the string `chat`, and `SiteBadge` hashed a colour out of it and stamped a `C`.

With three threads open the sidebar showed three identical `C` tiles. Nothing
about them was wrong — the colour is stable, the contrast holds, the letter is
the first character of the host — and there was no way to tell them apart. That
is the whole of the reported defect, and it is worth naming precisely: the badge
was answering a question nobody asked. It said what the *address* was about
rather than what the *thread* was about, and for a conversation those are
different things.

They are different things because ADR-0060 made them so. A conversation is
anchored to a page, it outlives every tab that ever showed that page, and the
anchor is the one place the answer lives. Before that ADR "what is this thread
about" had no answer a badge could draw; after it, the answer is sitting on the
scope.

Three things had to be settled before the obvious change was safe.

**A thread about no page.** One started from the command bar is about nothing in
particular (`ConversationScope::Space`). There is no favicon that would be true,
and both easy answers are lies: a letter taken from a host it does not have, and
the icon of whatever tab happens to be in front.

**Fetching.** ADR-0044 promises an ephemeral space never fetches a site icon,
and names itself as the place that promise had to be spelled out. A new reader
of the icon cache must not become a new route to a request.

**The browser's own pages.** `zer0://history` and `zer0://downloads` had the same
problem quietly — an `H` and a `D` hashed out of a word that is not a hostname —
and any rule written only for chat would leave them there.

## Decision

**A page whose address is ours wears our mark. Chat is the exception: it wears
the favicon of the page the conversation is about.**

### One door, and the scheme is not recognised in the shell

`BrowserModel.badge(for:)` is the only place that turns a tab into a badge.
Everything else — the sidebar, the command bar, history, bookmarks, the chat
page's subject bar — asks it, and none of them contains a rule.

Whether an address is one of ours is asked of `internal_url::internal_address`,
which is already the single place that knows. So the shell does not match on
`zer0://` anywhere: a new internal page inherits the mark by existing, and the
`switch` over `InternalAddress` breaks the build if it wants something else
(ADR-0031).

The split follows AGENTS.md's tie-breaker exactly. *Is this address ours* is a
question two platforms could not disagree about, so it is the core's. *What an
address of ours should look like* is a question they could, so it is the shell's.

### What a conversation resolves to, and from where

`badge(for: Conversation)` reads the **anchor**, never the tab showing it:

- `ConversationScope::Page { space, page }` → the host of `page`, with the icon
  read out of `space`'s cookie jar.
- `ConversationScope::Space` → the mark.

The tab has no standing on purpose. The same thread opens from a different tab
and the page it is about does not change; and a thread routinely outlives the
tab its page was open in, which is precisely when "read the host off whatever is
open" would start answering with somebody else's site.

The space comes from the anchor for the same reason and one more: the icon is
cached per cookie jar (ADR-0044), and `ConversationScope::space()` is total,
where a lookup through a tab can fail.

### The unanchored thread falls back rather than inventing

A thread about no page wears the same mark every other page of ours wears. That
is an answer rather than an absence: it is true (this is the browser's own page),
it is the same thing `zer0://history` says, and it is distinguishable at a glance
from the threads that do name a site. It asserts nothing about a page that does
not exist (ADR-0018).

### Nothing here fetches

Reading a badge reads the core's cache. Whether a fetch ever happens is decided
in the reducer when a page declares its icons, and for an ephemeral space the
answer there is no — so a conversation in a private window names its page and
draws the letter, which is honest twice over: the address is a fact, and the
picture was never fetched. `anEphemeralConversationDrawsNoIcon` hands the core
bytes for that jar anyway and demands the badge stay a letter.

### The mark at badge size is a second drawing, chosen by pixels

A sidebar badge is 16pt. ADR-0040 says the canonical `zer0.svg` is not used at or
below 32 rendered pixels because its cut closes under antialiasing, and names as
its first regression somebody scaling it to 16px and shipping a plain O. A 16pt
badge is 32 pixels at 2× and 16 at 1×, so it is entirely inside that band.

So `design/logo/zer0-small.svg` is ported alongside the canonical drawing, and
`Zer0MarkGlyph` — a `View`, because the display scale is only knowable from the
environment — picks between them at `Zer0Mark.hintMaxPixels`, the same 32 that
`apple/scripts/make-icon.sh` routes the icon set by. Every drawing of the mark in
the shell goes through that view.

**Measured, not assumed.** Both masters were rasterised at exactly 16, 32 and 64
pixels and looked at magnified. At 16 pixels the canonical drawing is a closed
ring at every threshold — a plain O — while the hinted one opens its gap at a
mid threshold. At 32 the difference is not subtle: the hinted mark shows two
obvious wedges, the canonical one a hairline nick. Forcing the canonical drawing
into the badge and re-photographing the sidebar produced an O, which is also how
the instrument was shown to be able to see the difference at all.

### What is not decided here

The chat tab's **title** is still the word "Chat" for every thread. The badges now
differ and the titles do not, so a sidebar of conversations is half-distinguished.
That is a core decision about `internal_url::title` and it is left alone.

## Consequences

**What hurts:**

- **A conversation's row is a copy of its page's row.** Same icon, adjacent in
  the list, and the only thing separating them is the word "Chat". At a glance
  that reads as a duplicate rather than as a pair, and it will look like a bug
  to somebody before it looks like a relationship. The title is the fix and it is
  not made here.
- **And none of it is spoken.** `SiteBadge` is `accessibilityHidden`, correctly,
  because for an ordinary row the title beside it already names the site. For a
  conversation the title is the word "Chat", so this change tells a sighted
  person which thread is which and tells VoiceOver nothing new. Labelling the
  badge is the wrong fix — it would read the host before every ordinary row too.
  The title is the right one, and it is the same gap as the bullet above.
- **A thread whose page never got an icon is a letter forever**, and the letter
  is hashed from a host the row does not print. Two threads about two pages on
  the same site are then two identical badges again — one level down from the
  defect this fixes, and much rarer.
- **An unanchored thread and `zer0://history` wear the same badge.** They are
  different things wearing one mark, and the mark says only "this is ours".
- **A second drawing of the mark now lives in Swift as well as in SVG.** ADR-0040
  already pays for two masters that must agree; this makes it four artefacts,
  and nothing checks a Swift port against its SVG.
- **`SiteBadge` no longer takes a host.** Five call sites changed to pass a
  `Subject`. The type is what makes "a host and the browser's mark at once"
  unrepresentable, and the cost is that every future caller has to say which
  kind of thing it is drawing.

**What we get:**

- Three conversations that look like three conversations.
- A thread and the page it is about wearing the same mark, so they read as one
  thing across the sidebar, the subject bar and history.
- One place that decides what a row stands for, asked by five views.
- The browser's own pages saying so, including the ones that were quietly
  drawing a letter out of a word.
- The mark drawn from the master its size can carry, in the one place people see
  it most.

## How this regresses

**"All my conversations look the same again."** `badge(for: tab)` stops resolving
the chat case through the conversation — most plausibly during a tidy-up that
notices `tab.host` is already computed one line away and reaches for it.
`threeConversationsAreThreeDifferentBadges` goes red and prints the symptom
verbatim: three hosts, all of them `chat`.
`aConversationWearsTheSiteOfThePageItIsAbout` is its narrow half and asserts, by
name, that the host is not `chat`.

**"It showed the wrong site."** The host starts coming from the tab showing the
thread rather than from the anchor. Both tests above stay green while the page's
tab is open, which is the whole difficulty — so
`closingThePagesTabDoesNotChangeTheBadge` closes that tab first and demands the
same answer.

**"The command-bar thread wears somebody else's icon."** The `ConversationScope::Space`
branch grows a fallback, because a thread with no icon feels unfinished. It is
not unfinished; there is nothing true to draw.
`aConversationAboutNoPageWearsTheMark` is the fence.

**"History has a letter H again."** The `switch` over `InternalAddress` is
flattened into "chat is special, everything else is a site" — which is a smaller
function and is wrong for three addresses. `ourOwnPagesWearOurOwnMark` walks
`zer0://history`, `zer0://downloads` and a chat tab with no thread, and
`anOrdinaryTabStillWearsItsOwnSite` is the other side of the pair, so the fix
cannot be "everything wears the mark".

**"My private window fetched a favicon."** Somebody makes the badge trigger a
fetch on a miss, because a letter where an icon should be reads as a cache that
was never filled. `anEphemeralConversationDrawsNoIcon` fails, and it fails from
the other end too: it feeds the core bytes for the ephemeral jar and demands the
badge still draw nothing.

**"The logo is an O in the sidebar."** ADR-0040's first named regression, now
reachable from a new place. `theSmallSizesGetTheirOwnDrawing` asserts the routing
at 16pt@1x, 16pt@2x and 32pt@1x, and the other direction at 32pt@2x, so "always
hint" does not pass either. It is a routing test and not a pixel test, which is
its limit: it cannot tell whether the hinted drawing is any good, only that it is
the one being used. `ZZConversationBadgeShots` is where somebody looks.

**And the one with no lock:** whether the badge is *legible* — whether a hand
lands on the right row faster with icons than with letters — is an opinion, and
no assertion holds one. The boards in `ZZConversationBadgeShots` render the same
sidebar with icons and with letters so the pair can be compared, and that is the
whole of the evidence. Declared debt.

## When to revisit

- **When a conversation's tab gets a title of its own.** That is the other half
  of "tell three threads apart", it lives in `internal_url::title`, and it
  probably wants the page rather than the word "Chat".
- **If a conversation's row and its page's row being identical becomes the
  complaint.** The answer is not to take the icon away; it is that one of them
  should say what kind of thing it is.
- **When something other than chat wants to point at a site.** The moment there
  is a second exception, "our address means our mark" stops being a default and
  becomes a table, and the table belongs next to `InternalAddress`.
- **If the Swift port of a master drifts from its SVG.** ADR-0040 offers the
  cheap fence for the SVGs; nothing at all watches the ports, and there are now
  two of them.
