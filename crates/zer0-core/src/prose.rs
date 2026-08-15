//! A model's reply, split into the blocks a reading surface can set.
//!
//! A reply arrives as Markdown. Nothing about reading it is a matter of taste:
//! `**x**` is bold on every platform there will ever be, a fence opens a code
//! block whether the shell is SwiftUI or GTK, and where a list item ends is
//! settled by CommonMark rather than by whoever is drawing it. So the parse is
//! here, and the shell is handed structure. Type, colour, spacing and motion
//! are the shell's, and this module knows none of them (ADR-0071).
//!
//! ## What comes out is flat
//!
//! Markdown nests and [`ProseBlock`] does not. A list item holding a paragraph
//! and a code block comes back as three blocks in a row, each carrying how far
//! in it sits — [`ProseBlock::indent`] for list levels, [`ProseBlock::quoted`]
//! for block quotes. A renderer walks a list; it does not recurse.
//!
//! That is not only convenience. uniffi carries records and enums, and a
//! self-referential enum would need every host language to spell recursion the
//! way Swift spells `indirect`. A flat list crosses unchanged, and the shell
//! draws it in one `ForEach`.
//!
//! ## What it does with a reply that has not finished arriving
//!
//! Nothing special, and that is the decision. A reply streams, this runs on
//! every delta, and half-written Markdown is the normal case rather than the
//! error case. CommonMark already answers it the way a reader wants:
//!
//! - An **unterminated fence** is a code block that runs to the end of the
//!   input. So a fence is a code block from the moment it opens, and text does
//!   not sit as prose for four seconds and then snap into a monospaced panel
//!   when the closing fence lands.
//! - A **lone `**`** has no closing delimiter, so it is text. It becomes bold
//!   when the closer arrives, and until then it is the two characters the model
//!   actually sent.
//! - A **marker with nothing after it** is a list item with nothing in it, and
//!   is emitted as one — the bullet appears when the bullet is typed.
//!
//! The rule underneath all three: what is on screen is what has arrived, and
//! nothing is guessed ahead of it.
//!
//! ## What is deliberately not interpreted
//!
//! CommonMark, plus exactly two GFM extensions (strikethrough and autolinks).
//! No outliner dialect: `[[page]]`, `#tag`, `key:: value`, `((block-ref))` and
//! `:emoji:` are five ordinary strings, and a model that sent them sent those
//! characters. Reaching for a page behind a `[[link]]` would be guessing at
//! what was meant, and there is no page to reach.

use comrak::arena_tree::NodeEdge;
use comrak::nodes::{AstNode, ListType, NodeValue};
use comrak::{Arena, Options, parse_document};
use url::Url;

/// One run of inline text, and what is true of it.
///
/// Runs carry facts rather than fonts. Whether bold is a heavier weight or a
/// different colour is the shell's to decide; that this stretch of the sentence
/// was emphasised is not.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ProseRun {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    /// A code span: a value rather than prose.
    pub code: bool,
    pub struck: bool,
    /// Where this run points, when it is a link.
    ///
    /// Only ever an absolute `http` or `https` address. A reply is a boundary
    /// like any other and a model can write any six characters it likes;
    /// `javascript:`, `file:` and `zer0:` are addresses somebody's browser
    /// would be asked to follow on a click, so the words stay and the link does
    /// not. Refuse rather than repair: there is no safe rewriting of a
    /// `javascript:` link into something that was meant.
    pub link: Option<String>,
}

/// What a block is.
///
/// Five kinds, and adding a sixth has to break the shell's build until it earns
/// a drawing — which is why this is an enum with data rather than a record with
/// a `kind` string beside seven fields that are empty most of the time.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Enum))]
pub enum ProseKind {
    Paragraph {
        runs: Vec<ProseRun>,
    },
    Heading {
        level: u8,
        runs: Vec<ProseRun>,
    },
    /// The line a list marker sits beside. `number` is `None` for a bullet and
    /// the ordinal for a numbered list — the ordinal rather than the digits the
    /// model typed, because CommonMark counts from the first item and a model
    /// that writes `1.` three times meant one, two, three.
    ///
    /// Anything else the item holds — a second paragraph, a code block, a
    /// nested list — follows as its own block, one level further in.
    Item {
        number: Option<u32>,
        runs: Vec<ProseRun>,
    },
    /// Verbatim. `language` is the fence's info string when there was one, and
    /// is never guessed from the contents.
    Code {
        language: Option<String>,
        source: String,
    },
    Rule,
}

/// One block of a reply, and how far in it sits.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "ffi", derive(uniffi::Record))]
pub struct ProseBlock {
    /// How many list levels this block is inside. `0` is the column itself.
    ///
    /// A top-level item is at `0` and wears its marker in a gutter; everything
    /// else the item holds is at `1`, which is what lines it up under the
    /// item's own words.
    pub indent: u32,
    /// How many block quotes deep. `0` is not quoted.
    ///
    /// Reported rather than clamped: how many rails to draw, and when to stop
    /// indenting, is a question about a column of a particular width, and this
    /// module does not know one.
    pub quoted: u32,
    pub kind: ProseKind,
}

/// Split a reply into blocks.
pub fn blocks(text: &str) -> Vec<ProseBlock> {
    let arena = Arena::new();
    let root = parse_document(&arena, text, &options());

    let mut walk = Walk::default();
    // Iterative, not recursive, and on purpose: a reply is a boundary like any
    // other, and `> > > >` ten thousand deep is four bytes a level. A walk that
    // recursed once per level would take the process down with a stack
    // overflow, which is not a failure a caller can do anything about.
    for edge in root.traverse() {
        match edge {
            NodeEdge::Start(node) => walk.start(node),
            NodeEdge::End(node) => walk.end(node),
        }
    }
    walk.out
}

/// CommonMark, plus the two GFM extensions a reply really uses.
///
/// Both were argued rather than switched on wholesale. **Strikethrough**
/// because `~~x~~` is a claim about the text that survives into any renderer.
/// **Autolinks** because a bare `https://…` in a reply is an address, and
/// asking somebody to select and copy it is a chore, not a decision.
///
/// Everything else stays off, and the three worth naming are:
/// **tables**, because there is no honest way to set one in a column this
/// narrow yet and an unrendered table still reads as rows;
/// **tasklists**, because `[ ]` reads as `[ ]`;
/// and **wikilinks**, because `[[foo]]` must stay six characters.
fn options<'c>() -> Options<'c> {
    let mut options = Options::default();
    options.extension.strikethrough = true;
    options.extension.autolink = true;
    options
}

/// What is open, as the walk passes through it.
#[derive(Default)]
struct Walk {
    out: Vec<ProseBlock>,
    quoted: u32,
    /// One entry per open list: the next ordinal, or `None` for bullets.
    lists: Vec<Option<u32>>,
    /// One entry per open item. Its length is the list nesting depth.
    items: Vec<Item>,
    /// The runs of the leaf block being read, when one is open.
    runs: Option<Vec<ProseRun>>,
    bold: u32,
    italic: u32,
    struck: u32,
    /// One entry per open link, `None` for one whose address was refused. The
    /// entry is pushed either way so the stack stays level with the tree.
    links: Vec<Option<String>>,
}

struct Item {
    number: Option<u32>,
    /// Whether the marker is still waiting for the paragraph it sits beside.
    marker_pending: bool,
}

impl Walk {
    #[expect(
        clippy::wildcard_enum_match_arm,
        reason = "comrak's NodeValue is a foreign open set. It carries a variant per \
                  extension, including ones this module deliberately leaves off, so most \
                  of them cannot reach here at all — and a new comrak release may add \
                  more. Listing forty arms to ignore thirty of them would hide the six \
                  that do something."
    )]
    fn start<'a>(&mut self, node: &'a AstNode<'a>) {
        match &node.data.borrow().value {
            NodeValue::BlockQuote | NodeValue::MultilineBlockQuote(_) => self.quoted += 1,

            NodeValue::List(list) => {
                let ordered = list.list_type == ListType::Ordered;
                self.lists
                    .push(ordered.then(|| u32::try_from(list.start).unwrap_or(1)));
            }

            NodeValue::Item(_) => self.open_item(node),

            NodeValue::Paragraph | NodeValue::Heading(_) => self.runs = Some(Vec::new()),

            NodeValue::CodeBlock(block) => {
                // The info string is a language when it names one and nothing
                // when it does not. It is never inferred from the contents:
                // guessing "this looks like Python" is a claim the fence did
                // not make.
                let language = block
                    .info
                    .split_whitespace()
                    .next()
                    .map(str::to_owned)
                    .filter(|word| !word.is_empty());
                let source = block
                    .literal
                    .strip_suffix('\n')
                    .unwrap_or(&block.literal)
                    .to_owned();
                self.emit(ProseKind::Code { language, source });
            }

            NodeValue::ThematicBreak => self.emit(ProseKind::Rule),

            NodeValue::Text(text) => self.push(text, false),
            NodeValue::Code(code) => self.push(&code.literal, true),
            // A model that wrote two lines meant two lines. CommonMark folds a
            // soft break into a space because its source was hand-wrapped at 72
            // columns; nothing wraps a reply, so a newline in one is a newline
            // somebody put there.
            NodeValue::SoftBreak | NodeValue::LineBreak => self.push("\n", false),
            // Raw HTML in a reply is shown as what it is. Rendering it would
            // let a reply draw its own interface.
            NodeValue::HtmlInline(html) => self.push(html, false),

            NodeValue::Strong => self.bold += 1,
            NodeValue::Emph => self.italic += 1,
            NodeValue::Strikethrough => self.struck += 1,
            NodeValue::Link(link) => self.links.push(followable(&link.url)),
            // An image is not fetched and not drawn — a reply that could load a
            // remote image could also tell somebody it had been read. Its alt
            // text is in the children and arrives as ordinary words.
            NodeValue::Image(_) => {}

            _ => {}
        }
    }

    #[expect(
        clippy::wildcard_enum_match_arm,
        reason = "the same foreign open set as `start`; see the reason there."
    )]
    fn end<'a>(&mut self, node: &'a AstNode<'a>) {
        match &node.data.borrow().value {
            NodeValue::BlockQuote | NodeValue::MultilineBlockQuote(_) => {
                self.quoted = self.quoted.saturating_sub(1);
            }
            NodeValue::List(_) => {
                self.lists.pop();
            }
            NodeValue::Item(_) => {
                self.items.pop();
            }
            NodeValue::Paragraph => self.close_paragraph(),
            NodeValue::Heading(heading) => self.close_heading(heading.level),
            NodeValue::Strong => self.bold = self.bold.saturating_sub(1),
            NodeValue::Emph => self.italic = self.italic.saturating_sub(1),
            NodeValue::Strikethrough => self.struck = self.struck.saturating_sub(1),
            NodeValue::Link(_) => {
                self.links.pop();
            }
            _ => {}
        }
    }

    /// A list item opens: take its ordinal, and work out whether its marker has
    /// a line of words to sit beside.
    fn open_item<'a>(&mut self, node: &'a AstNode<'a>) {
        let mut number = None;
        if let Some(next) = self.lists.last_mut()
            && let Some(ordinal) = *next
        {
            number = Some(ordinal);
            *next = Some(ordinal.saturating_add(1));
        }

        // An item whose first child is a paragraph hands its marker to that
        // paragraph, so the two are one line. An item that opens with anything
        // else — a nested list, a fence, or nothing at all because somebody is
        // still typing — gets a marker of its own straight away. That last case
        // is the streaming one and it is the reason for the look-ahead: a
        // bullet that appeared only once its words arrived would leave the list
        // visibly one item short of what had been typed.
        let has_words = node
            .first_child()
            .is_some_and(|child| matches!(child.data.borrow().value, NodeValue::Paragraph));
        self.items.push(Item {
            number,
            marker_pending: has_words,
        });
        if !has_words {
            let indent = u32::try_from(self.items.len()).unwrap_or(u32::MAX) - 1;
            self.out.push(ProseBlock {
                indent,
                quoted: self.quoted,
                kind: ProseKind::Item {
                    number,
                    runs: Vec::new(),
                },
            });
        }
    }

    fn close_paragraph(&mut self) {
        let Some(runs) = self.runs.take() else { return };

        let mut claimed = None;
        if let Some(item) = self.items.last_mut()
            && item.marker_pending
        {
            item.marker_pending = false;
            claimed = Some(item.number);
        }

        match claimed {
            Some(number) => {
                let indent = u32::try_from(self.items.len()).unwrap_or(u32::MAX) - 1;
                self.out.push(ProseBlock {
                    indent,
                    quoted: self.quoted,
                    kind: ProseKind::Item { number, runs },
                });
            }
            None => self.emit(ProseKind::Paragraph { runs }),
        }
    }

    fn close_heading(&mut self, level: u8) {
        let Some(runs) = self.runs.take() else { return };
        self.emit(ProseKind::Heading { level, runs });
    }

    fn emit(&mut self, kind: ProseKind) {
        let indent = u32::try_from(self.items.len()).unwrap_or(u32::MAX);
        self.out.push(ProseBlock {
            indent,
            quoted: self.quoted,
            kind,
        });
    }

    /// Add text to the block being read, merging it into the run before it when
    /// nothing about it is different.
    ///
    /// The merge is not tidiness. comrak splits text at every entity and every
    /// delimiter it considered and rejected, so a plain sentence can arrive as
    /// a dozen nodes; each one that survives is a string allocated here and
    /// carried across the FFI on every delta of a reply.
    fn push(&mut self, text: &str, code: bool) {
        if text.is_empty() {
            return;
        }
        let bold = self.bold > 0;
        let italic = self.italic > 0;
        let struck = self.struck > 0;
        let link = self.links.last().cloned().flatten();

        let Some(runs) = self.runs.as_mut() else {
            // Inline content outside any leaf block. comrak does not produce
            // it; dropping it is still the right answer, because there is
            // nowhere to put it.
            return;
        };
        if let Some(last) = runs.last_mut()
            && last.bold == bold
            && last.italic == italic
            && last.code == code
            && last.struck == struck
            && last.link == link
        {
            last.text.push_str(text);
            return;
        }
        runs.push(ProseRun {
            text: text.to_owned(),
            bold,
            italic,
            code,
            struck,
            link,
        });
    }
}

/// The address a click may follow, or nothing.
///
/// Absolute `http` and `https` only, and normalised by the one parser that gets
/// to decide — so a shell is never handed a string it has to re-interpret, and
/// never handed a scheme that runs something.
///
/// A relative address falls out here too, and correctly: a reply has no page to
/// be relative to, so `[docs](/docs)` names nothing.
fn followable(raw: &str) -> Option<String> {
    let parsed = Url::parse(raw).ok()?;
    matches!(parsed.scheme(), "http" | "https").then(|| parsed.to_string())
}

/// Split a reply into blocks, for a shell.
#[cfg(feature = "ffi")]
#[uniffi::export]
pub fn prose_blocks(text: String) -> Vec<ProseBlock> {
    blocks(&text)
}

#[cfg(test)]
#[path = "prose_tests.rs"]
mod tests;
