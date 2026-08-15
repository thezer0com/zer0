use super::*;

fn framed(json: &str) -> Vec<u8> {
    frame(json).expect("a small JSON object frames")
}

#[test]
fn a_message_is_a_little_endian_length_and_then_the_json() {
    let bytes = framed(r#"{"a":1}"#);

    assert_eq!(&bytes[0..4], &[7, 0, 0, 0]);
    assert_eq!(&bytes[4..], br#"{"a":1}"#);
}

/// The one thing about this format that is easy to get backwards, and getting
/// it backwards is invisible for small messages on a little-endian machine
/// only because every other byte is zero.
#[test]
fn the_length_is_little_endian_and_not_big_endian() {
    let json = format!(r#"{{"a":"{}"}}"#, "x".repeat(300));
    let bytes = framed(&json);

    assert_eq!(bytes[0..4], (json.len() as u32).to_le_bytes());
    assert_ne!(bytes[0..4], (json.len() as u32).to_be_bytes());
}

#[test]
fn a_whole_message_reads_back_and_says_what_it_used() {
    let bytes = framed(r#"{"hello":"world"}"#);

    assert_eq!(
        step(&bytes),
        NativeMessageStep::Message {
            json: r#"{"hello":"world"}"#.to_string(),
            consumed: bytes.len() as u64,
        }
    );
}

#[test]
fn two_messages_in_one_chunk_are_read_one_at_a_time() {
    let mut bytes = framed(r#"{"one":1}"#);
    bytes.extend(framed(r#"{"two":2}"#));

    let NativeMessageStep::Message { json, consumed } = step(&bytes) else {
        panic!("the first message is whole");
    };
    assert_eq!(json, r#"{"one":1}"#);

    assert_eq!(
        step(&bytes[consumed as usize..]),
        NativeMessageStep::Message {
            json: r#"{"two":2}"#.to_string(),
            consumed: 13,
        }
    );
}

/// The property that keeps a reader from being quadratic: an answer of
/// `Waiting` says how big the buffer has to get, so a host writing a large
/// reply in small chunks is scanned once rather than once per chunk.
#[test]
fn waiting_says_how_many_bytes_it_is_waiting_for() {
    assert_eq!(
        step(&[]),
        NativeMessageStep::Waiting {
            needed: LENGTH_PREFIX_BYTES
        }
    );
    assert_eq!(
        step(&[1, 2]),
        NativeMessageStep::Waiting {
            needed: LENGTH_PREFIX_BYTES
        }
    );

    // A prefix claiming 1000 bytes with none of them here yet.
    let mut partial = 1000u32.to_le_bytes().to_vec();
    partial.extend([b'{'; 10]);
    assert_eq!(step(&partial), NativeMessageStep::Waiting { needed: 1004 });
}

/// A host that writes and never stops must not buy the browser's memory a
/// chunk at a time. The prefix is refused before a byte of the body is kept.
#[test]
fn a_length_beyond_the_cap_ends_the_connection_rather_than_being_buffered() {
    let mut bytes = (MAX_NATIVE_MESSAGE_BYTES as u32 + 1).to_le_bytes().to_vec();
    bytes.extend(b"{}");

    assert_eq!(
        step(&bytes),
        NativeMessageStep::TooLarge {
            declared: MAX_NATIVE_MESSAGE_BYTES + 1,
            limit: MAX_NATIVE_MESSAGE_BYTES,
        }
    );
}

#[test]
fn a_length_exactly_on_the_cap_is_still_waited_for() {
    let bytes = (MAX_NATIVE_MESSAGE_BYTES as u32).to_le_bytes().to_vec();

    assert_eq!(
        step(&bytes),
        NativeMessageStep::Waiting {
            needed: MAX_NATIVE_MESSAGE_BYTES + LENGTH_PREFIX_BYTES,
        }
    );
}

/// There is no resynchronising mark in this format, so there is nothing to skip
/// forward to. Carrying on would hand the extension messages assembled out of
/// the middle of other messages.
#[test]
fn a_body_that_is_not_json_is_refused_rather_than_skipped() {
    let mut bytes = 5u32.to_le_bytes().to_vec();
    bytes.extend(b"hello");

    assert!(matches!(step(&bytes), NativeMessageStep::Malformed { .. }));
}

#[test]
fn a_body_that_is_not_utf8_is_refused() {
    let mut bytes = 2u32.to_le_bytes().to_vec();
    bytes.extend([0xff, 0xfe]);

    assert!(matches!(step(&bytes), NativeMessageStep::Malformed { .. }));
}

#[test]
fn an_empty_message_is_not_a_message() {
    assert!(matches!(
        step(&0u32.to_le_bytes()),
        NativeMessageStep::Malformed { .. }
    ));
}

/// An extension can call `postMessage` in a loop as easily as a host can write
/// in one, so the cap is refused in both directions.
#[test]
fn nothing_over_the_cap_is_sent_either() {
    let big = format!(r#""{}""#, "x".repeat(MAX_NATIVE_MESSAGE_BYTES as usize));

    assert!(frame(&big).is_none());
}

#[test]
fn something_that_is_not_json_is_never_framed() {
    assert!(frame("not json").is_none());
    assert!(frame("").is_none());
}
