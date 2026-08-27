use std::cell::{Cell, RefCell};
use std::os::unix::fs::PermissionsExt;
use std::rc::Rc;

use super as image_copy;

#[test]
fn terminal_claim_skips_late_work() {
    let reported = Rc::new(Cell::new(None));
    let reported_for_callback = Rc::clone(&reported);
    let Some(temporary_file) = image_copy::TemporaryImage::new().ok() else {
        panic!("temporary image directory could not be created");
    };
    let state = Rc::new(RefCell::new(image_copy::CopyState {
        temporary_file,
        report: Some(Box::new(move |outcome| {
            reported_for_callback.set(Some(outcome));
        })),
        completed: Cell::new(false),
    }));

    image_copy::complete(
        &state,
        image_copy::Outcome::Failed(image_copy::Failure::Unreachable),
    );
    let mut evaluated = false;
    image_copy::complete_with(&state, || {
        evaluated = true;
        image_copy::Outcome::Copied
    });

    assert!(!evaluated);
    assert_eq!(
        reported.get(),
        Some(image_copy::Outcome::Failed(
            image_copy::Failure::Unreachable
        ))
    );
}

#[test]
fn cancellation_claims_no_tab_before_late_download_failure() {
    let reported = Rc::new(Cell::new(None));
    let reported_for_callback = Rc::clone(&reported);
    let Some(temporary_file) = image_copy::TemporaryImage::new().ok() else {
        panic!("temporary image directory could not be created");
    };
    let state = Rc::new(RefCell::new(image_copy::CopyState {
        temporary_file,
        report: Some(Box::new(move |outcome| {
            reported_for_callback.set(Some(outcome));
        })),
        completed: Cell::new(false),
    }));

    image_copy::cancel(&state);
    image_copy::complete(
        &state,
        image_copy::Outcome::Failed(image_copy::Failure::Unreachable),
    );

    assert_eq!(
        reported.get(),
        Some(image_copy::Outcome::Failed(image_copy::Failure::NoTabPage))
    );
}

#[test]
fn copy_image_download_is_rejected_above_32_mib() {
    assert!(image_copy::copy_image_download_within_limit(
        image_copy::COPY_IMAGE_MAX_BYTES
    ));
    assert!(!image_copy::copy_image_download_within_limit(
        image_copy::COPY_IMAGE_MAX_BYTES + 1
    ));
}

#[test]
fn response_length_limit_preserves_zero_as_unknown() {
    assert!(image_copy::copy_image_response_within_limit(0));
    assert!(image_copy::copy_image_response_within_limit(
        image_copy::COPY_IMAGE_MAX_BYTES
    ));
    assert!(!image_copy::copy_image_response_within_limit(
        image_copy::COPY_IMAGE_MAX_BYTES + 1
    ));
}

#[test]
fn temporary_image_drop_removes_private_directory() {
    let Some(temporary) = image_copy::TemporaryImage::new().ok() else {
        panic!("temporary image directory could not be created");
    };
    let directory = temporary.directory.clone();
    let Ok(metadata) = std::fs::metadata(&directory) else {
        panic!("temporary image metadata could not be read");
    };
    let mode = metadata.permissions().mode();

    assert_eq!(mode & 0o077, 0);
    assert!(directory.is_dir());

    drop(temporary);

    assert!(!directory.exists());
}

#[test]
fn temporary_image_directories_are_unique() {
    let Some(first) = image_copy::TemporaryImage::new().ok() else {
        panic!("first temporary image directory could not be created");
    };
    let Some(second) = image_copy::TemporaryImage::new().ok() else {
        panic!("second temporary image directory could not be created");
    };

    assert_ne!(first.directory, second.directory);
}

#[test]
fn copy_image_dimensions_enforce_positive_pixel_ceiling() {
    assert!(image_copy::copy_image_dimensions_within_limit(
        10_000, 8_000
    ));
    assert!(!image_copy::copy_image_dimensions_within_limit(0, 1));
    assert!(!image_copy::copy_image_dimensions_within_limit(
        80_000_001, 1
    ));
}

#[test]
fn copy_image_accepts_successful_responses_only() {
    assert!(!image_copy::is_success_status(199));
    assert!(image_copy::is_success_status(200));
    assert!(image_copy::is_success_status(299));
    assert!(!image_copy::is_success_status(300));
    assert!(image_copy::is_success_status(0));
}
