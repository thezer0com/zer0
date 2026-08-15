use super::*;

// ---------------------------------------------------------------------------
// Reading a result without spelling out a whole tree
// ---------------------------------------------------------------------------

/// The plain text of a block, with every mark thrown away.
fn text_of(block: &ProseBlock) -> String {
    runs_of(block).iter().map(|run| run.text.as_str()).collect()
}

fn runs_of(block: &ProseBlock) -> &[ProseRun] {
    match &block.kind {
        ProseKind::Paragraph { runs }
        | ProseKind::Heading { runs, .. }
        | ProseKind::Item { runs, .. } => runs,
        ProseKind::Code { .. } | ProseKind::Rule => &[],
    }
}

/// A one-word name for what each block is, so a test can say what shape it
/// expects without writing out every run.
fn shape(blocks: &[ProseBlock]) -> Vec<&'static str> {
    blocks
        .iter()
        .map(|block| match &block.kind {
            ProseKind::Paragraph { .. } => "paragraph",
            ProseKind::Heading { .. } => "heading",
            ProseKind::Item { .. } => "item",
            ProseKind::Code { .. } => "code",
            ProseKind::Rule => "rule",
        })
        .collect()
}

fn only(text: &str) -> ProseBlock {
    let blocks = blocks(text);
    assert_eq!(
        blocks.len(),
        1,
        "expected one block from {text:?}: {blocks:?}"
    );
    blocks.into_iter().next().unwrap()
}

// ---------------------------------------------------------------------------
// The marks a reply actually uses
// ---------------------------------------------------------------------------

#[test]
fn a_reply_carries_bold_italic_code_and_links_as_facts_not_characters() {
    let block = only("**Copita** and *tulipa*, see `glass()` and [why](https://a.example).");
    let runs = runs_of(&block);

    // Nothing renders the delimiters: that was the defect.
    assert!(
        !text_of(&block).contains('*') && !text_of(&block).contains('`'),
        "delimiters survived into the text: {runs:?}"
    );
    assert_eq!(text_of(&block), "Copita and tulipa, see glass() and why.");

    let bold = runs.iter().find(|run| run.bold).expect("a bold run");
    assert_eq!(bold.text, "Copita");
    let italic = runs.iter().find(|run| run.italic).expect("an italic run");
    assert_eq!(italic.text, "tulipa");
    let code = runs.iter().find(|run| run.code).expect("a code run");
    assert_eq!(code.text, "glass()");
    let link = runs.iter().find(|run| run.link.is_some()).expect("a link");
    assert_eq!(link.text, "why");
    // Normalised by the one parser that gets to decide, so a shell is never
    // handed a string it has to re-interpret. Hence the path that was not typed.
    assert_eq!(link.link.as_deref(), Some("https://a.example/"));
}

#[test]
fn every_block_a_reply_uses_comes_back_as_its_own_kind() {
    let reply = "\
# Heading

A paragraph.

- one
- two

1. first
2. second

```swift
let x = 1
```

> quoted

---
";
    let blocks = blocks(reply);
    assert_eq!(
        shape(&blocks),
        vec![
            "heading",
            "paragraph",
            "item",
            "item",
            "item",
            "item",
            "code",
            "paragraph",
            "rule",
        ]
    );

    assert!(matches!(
        blocks[0].kind,
        ProseKind::Heading { level: 1, .. }
    ));
    assert_eq!(text_of(&blocks[2]), "one");
    assert!(matches!(
        blocks[2].kind,
        ProseKind::Item { number: None, .. }
    ));
    assert!(matches!(
        blocks[5].kind,
        ProseKind::Item {
            number: Some(2),
            ..
        }
    ));
    assert_eq!(
        blocks[6].kind,
        ProseKind::Code {
            language: Some("swift".into()),
            source: "let x = 1".into(),
        }
    );
    assert_eq!(blocks[7].quoted, 1);
    assert_eq!(text_of(&blocks[7]), "quoted");
    assert_eq!(blocks[8].kind, ProseKind::Rule);
}

#[test]
fn a_numbered_list_counts_from_where_it_started_not_from_what_was_typed() {
    // A model writing `1.` three times meant one, two, three, and CommonMark
    // says so. A list starting at 3 keeps its 3.
    let numbers: Vec<Option<u32>> = blocks("1. a\n1. b\n1. c")
        .iter()
        .filter_map(|block| match block.kind {
            ProseKind::Item { number, .. } => Some(number),
            ProseKind::Paragraph { .. }
            | ProseKind::Heading { .. }
            | ProseKind::Code { .. }
            | ProseKind::Rule => None,
        })
        .collect();
    assert_eq!(numbers, vec![Some(1), Some(2), Some(3)]);

    let later = blocks("3. c\n4. d");
    assert!(matches!(
        later[0].kind,
        ProseKind::Item {
            number: Some(3),
            ..
        }
    ));
}

#[test]
fn one_level_of_nesting_comes_back_as_one_step_of_indent() {
    let blocks = blocks("- outer\n    - inner\n- outer again");
    assert_eq!(shape(&blocks), vec!["item", "item", "item"]);
    assert_eq!(blocks[0].indent, 0);
    assert_eq!(blocks[1].indent, 1);
    assert_eq!(blocks[2].indent, 0);
    assert_eq!(text_of(&blocks[1]), "inner");
}

#[test]
fn a_block_inside_a_list_item_sits_one_step_in_from_the_marker() {
    let blocks = blocks("1. Run it:\n\n   ```sh\n   ls\n   ```\n");
    assert_eq!(shape(&blocks), vec!["item", "code"]);
    assert_eq!(blocks[0].indent, 0);
    // The fence belongs to the item, so it lines up under the item's words
    // rather than under its marker.
    assert_eq!(blocks[1].indent, 1);
}

#[test]
fn a_quote_reports_how_deep_it_is_rather_than_only_that_it_is_one() {
    let quoted = blocks("> one\n>\n> > two\n");
    assert_eq!(quoted[0].quoted, 1);
    assert_eq!(quoted[1].quoted, 2);
    // Unquoted prose is back at zero, so the shell has something to tell them
    // apart by.
    assert_eq!(only("plain").quoted, 0);
}

#[test]
fn a_soft_break_is_a_break_because_a_model_that_wrote_two_lines_meant_two() {
    let block = only("first line\nsecond line");
    assert_eq!(text_of(&block), "first line\nsecond line");
}

#[test]
fn text_that_is_not_markdown_comes_back_as_the_words_that_were_sent() {
    let block = only("Just a sentence, with commas and a - hyphen and 2 * 3 = 6.");
    assert_eq!(
        text_of(&block),
        "Just a sentence, with commas and a - hyphen and 2 * 3 = 6."
    );
    assert!(
        runs_of(&block).iter().all(|run| {
            !run.bold && !run.italic && !run.code && !run.struck && run.link.is_none()
        })
    );
}

// ---------------------------------------------------------------------------
// A reply that has not finished arriving
// ---------------------------------------------------------------------------

#[test]
fn an_unterminated_fence_is_a_code_block_from_the_moment_it_opens() {
    // This is the whole anti-strobe decision. Every prefix of a reply that has
    // opened a fence must already be a code block: if any one of them came back
    // as a paragraph, the answer would sit as prose and then snap into a panel
    // when the closing fence landed, in the middle of somebody reading it.
    let reply = "Here:\n\n```rust\nfn main() {\n    println!(\"hi\");\n}\n```\n";
    let opened = reply.find("```").unwrap() + 3;

    for end in opened..=reply.len() {
        if !reply.is_char_boundary(end) {
            continue;
        }
        let so_far = blocks(&reply[..end]);
        assert!(
            so_far
                .iter()
                .any(|block| matches!(block.kind, ProseKind::Code { .. })),
            "the fence stopped being a code block at {end} bytes: {so_far:?}"
        );
    }
}

#[test]
fn a_lone_emphasis_delimiter_is_the_characters_that_arrived() {
    // It becomes bold when the closer lands, and until then it is what was
    // sent. Guessing that a closer is coming is guessing.
    assert_eq!(text_of(&only("a **partial")), "a **partial");
    assert!(runs_of(&only("a **partial")).iter().all(|run| !run.bold));

    let closed = only("a **partial**");
    assert!(closed.kind != ProseKind::Rule);
    assert!(runs_of(&closed).iter().any(|run| run.bold));
}

#[test]
fn a_marker_with_nothing_after_it_is_already_a_list_item() {
    // The bullet appears when the bullet is typed, not when its words arrive.
    let blocks = blocks("- done\n- ");
    assert_eq!(shape(&blocks), vec!["item", "item"]);
    assert_eq!(text_of(&blocks[1]), "");
}

#[test]
fn a_reply_never_loses_a_block_it_had_already_shown() {
    // The property that matters while streaming: block *n* of a longer prefix
    // is the same kind as block *n* of a shorter one, for every block that had
    // already settled. A parser that re-read earlier text differently as more
    // arrived is a page that re-flows under a reader.
    let reply = "\
# Notes

Some prose with **weight**.

- one
- two

```sh
ls -la
```

> and a quote
";
    let mut previous: Vec<&'static str> = Vec::new();
    for end in 1..=reply.len() {
        if !reply.is_char_boundary(end) {
            continue;
        }
        let shape = shape(&blocks(&reply[..end]));
        // Everything but the block still arriving keeps its kind.
        let settled = shape.len().min(previous.len()).saturating_sub(1);
        assert_eq!(
            shape[..settled],
            previous[..settled],
            "the settled blocks changed at {end} bytes"
        );
        previous = shape;
    }
}

// ---------------------------------------------------------------------------
// No outliner dialect
// ---------------------------------------------------------------------------

#[test]
fn no_outliner_dialect_is_interpreted() {
    // A model that replies with `[[foo]]` wrote six characters and we render
    // six characters. Reaching for content behind any of these would be
    // guessing at a reference to something that does not exist.
    for source in [
        "[[a page]]",
        "#tag",
        "key:: value",
        "((blk-1234))",
        ":smile:",
        "[[page|title]]",
    ] {
        let block = only(source);
        assert_eq!(
            shape(std::slice::from_ref(&block)),
            vec!["paragraph"],
            "{source} became a block"
        );
        assert_eq!(text_of(&block), source, "{source} was rewritten");
        assert!(
            runs_of(&block).iter().all(|run| run.link.is_none()),
            "{source} grew a link"
        );
    }
}

#[test]
fn a_table_is_left_as_the_rows_that_were_typed() {
    // Decided rather than overlooked: there is no honest way to set a table in
    // a column this narrow yet, and unrendered pipes still read as rows.
    let blocks = blocks("| a | b |\n| --- | --- |\n| 1 | 2 |");
    assert_eq!(shape(&blocks), vec!["paragraph"]);
    assert!(text_of(&blocks[0]).contains('|'));
}

#[test]
fn a_task_list_marker_reads_as_the_brackets_that_were_typed() {
    let blocks = blocks("- [ ] not yet\n- [x] done");
    assert_eq!(shape(&blocks), vec!["item", "item"]);
    assert_eq!(text_of(&blocks[0]), "[ ] not yet");
}

#[test]
fn only_an_address_a_browser_can_follow_comes_back_as_a_link() {
    // A reply is a boundary. The words stay either way; what is refused is the
    // click.
    for refused in [
        "[run](javascript:alert(1))",
        "[read](file:///etc/passwd)",
        "[here](/docs/relative)",
        "[mail](mailto:someone@example.com)",
        "[inside](zer0://settings)",
    ] {
        let block = only(refused);
        assert!(
            runs_of(&block).iter().all(|run| run.link.is_none()),
            "{refused} was left clickable"
        );
        assert!(
            !text_of(&block).is_empty(),
            "{refused} lost its words as well as its link"
        );
    }

    let allowed = only("[go](https://a.example/x?y=1)");
    assert_eq!(
        runs_of(&allowed)[0].link.as_deref(),
        Some("https://a.example/x?y=1")
    );
}

#[test]
fn raw_html_is_shown_rather_than_obeyed() {
    let block = only("a <b>bold</b> attempt");
    assert_eq!(text_of(&block), "a <b>bold</b> attempt");
    assert!(runs_of(&block).iter().all(|run| !run.bold));
}

#[test]
fn an_image_contributes_its_words_and_never_an_address_to_fetch() {
    let block = only("look: ![a cat](https://tracker.example/pixel.png)");
    assert_eq!(text_of(&block), "look: a cat");
    assert!(
        runs_of(&block).iter().all(|run| run.link.is_none()),
        "an image left something to fetch"
    );
}

// ---------------------------------------------------------------------------
// Hostile input
// ---------------------------------------------------------------------------

#[test]
fn a_line_of_a_hundred_thousand_characters_is_one_paragraph() {
    let long = "x".repeat(100_000);
    let block = only(&long);
    assert_eq!(text_of(&block).len(), 100_000);
}

#[test]
fn nesting_thousands_deep_does_not_take_the_process_down() {
    // The walk is iterative for this reason. `> ` is two bytes a level, so a
    // reply well under any message cap can nest deeper than a recursive walk
    // would survive.
    let deep = format!("{}text", "> ".repeat(5_000));
    let quoted = blocks(&deep);
    assert!(!quoted.is_empty());
    assert!(quoted.iter().all(|block| block.quoted > 0));

    let mut nested_lists = String::new();
    for level in 0..2_000 {
        nested_lists.push_str(&"  ".repeat(level));
        nested_lists.push_str("- deep\n");
    }
    assert!(!blocks(&nested_lists).is_empty());
}

#[test]
fn an_empty_reply_is_no_blocks_at_all() {
    assert!(blocks("").is_empty());
    assert!(blocks("   \n\n  \n").is_empty());
}

#[test]
fn a_fence_that_never_closes_over_a_long_reply_stays_one_block() {
    let long = format!("```\n{}", "line\n".repeat(20_000));
    let blocks = blocks(&long);
    assert_eq!(shape(&blocks), vec!["code"]);
}

// ---------------------------------------------------------------------------
// What it costs per delta
// ---------------------------------------------------------------------------

/// Not an assertion about a machine's speed — a floor loose enough that only a
/// change of order breaks it. A reply re-read on every delta is the whole
/// performance question, and the number this prints is the one to argue with.
///
/// **The fastest round, not the average of them, and that is what makes it an
/// assertion about the code.** An average over two hundred rounds is decided by
/// whichever one of them was descheduled: `cargo test` runs the suite across
/// every core while `check.sh` competes with whatever else the machine is
/// doing, so a single stalled round moves the mean by more than a rewrite of
/// the parser would. Scheduling noise can only ever make a round *slower*, so
/// the minimum converges on what the work actually costs and needs every one
/// of two hundred rounds to be starved before it can lie. The ten milliseconds
/// is untouched, and is still the same distance from the measurement ADR-0071
/// recorded: 1.6–1.8 ms per read in debug, on a machine that was compiling.
#[test]
fn a_reply_is_cheap_enough_to_re_read_on_every_delta() {
    let reply = "\
# A heading

A paragraph with **bold**, *italic*, `code` and a [link](https://a.example) in it.

- one
- two
    - nested

```rust
fn main() { println!(\"hi\"); }
```

> A quote.
"
    .repeat(40);
    assert!(reply.len() > 5_000, "the sample is not a long reply");

    let mut each = std::time::Duration::MAX;
    for _ in 0..200 {
        let started = std::time::Instant::now();
        std::hint::black_box(blocks(&reply));
        each = each.min(started.elapsed());
    }
    println!("prose::blocks over {} bytes: {each:?} at best", reply.len());
    assert!(
        each < std::time::Duration::from_millis(10),
        "re-reading a {}-byte reply took {each:?} at its fastest of two hundred tries, \
         which is not a per-delta cost",
        reply.len()
    );
}
