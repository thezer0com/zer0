use std::cell::{Cell, RefCell};
use std::fs;
use std::io;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};

use gtk::gdk;
use gtk::gdk_pixbuf::prelude::PixbufLoaderExt;
use gtk::gio;
use gtk::gio::prelude::FileExt;
use gtk::prelude::*;
use gtk4 as gtk;
use webkit6::prelude::WebViewExt;
use webkit6::{Download, URIResponse, WebView};

pub(crate) const COPY_IMAGE_MAX_BYTES: u64 = 32 * 1024 * 1024;
const COPY_IMAGE_MAX_PIXELS: i64 = 80_000_000;
const TEMPORARY_DIRECTORY_MODE: u32 = 0o700;
static NEXT_TEMPORARY_DIRECTORY: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Outcome {
    Copied,
    Failed(Failure),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Failure {
    InvalidAddress,
    NoTabPage,
    NotAnImage,
    TooLarge,
    Unreachable,
    Clipboard,
}

pub(crate) struct ActiveCopy {
    download: Download,
    state: Rc<RefCell<CopyState>>,
}

impl ActiveCopy {
    pub(crate) fn cancel(self) {
        cancel(&self.state);
        self.download.cancel();
    }
}

struct CopyState {
    temporary_file: TemporaryImage,
    report: Option<Box<dyn FnOnce(Outcome) + 'static>>,
    completed: Cell<bool>,
}

struct TemporaryImage {
    directory: PathBuf,
    path: PathBuf,
}

impl TemporaryImage {
    fn new() -> io::Result<Self> {
        loop {
            let sequence = NEXT_TEMPORARY_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            let directory =
                std::env::temp_dir().join(temporary_directory_name(std::process::id(), sequence));
            let mut builder = fs::DirBuilder::new();
            builder.mode(TEMPORARY_DIRECTORY_MODE);
            match builder.create(&directory) {
                Ok(()) => {
                    let path = directory.join("image");
                    return Ok(Self { directory, path });
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error),
            }
        }
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TemporaryImage {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_file(&self.path)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            eprintln!("zer0-linux: could not remove temporary image: {error}");
        }
        if let Err(error) = fs::remove_dir(&self.directory)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            eprintln!("zer0-linux: could not remove temporary image directory: {error}");
        }
    }
}

fn temporary_directory_name(process_id: u32, sequence: u64) -> String {
    format!("zer0-copy-image-{process_id}-{sequence}")
}

pub(crate) fn start<F>(view: &WebView, url: &str, report: F) -> Result<ActiveCopy, Failure>
where
    F: FnOnce(Outcome) + 'static,
{
    if url::Url::parse(url).is_err() {
        return Err(Failure::InvalidAddress);
    }

    let Some(session) = view.network_session() else {
        return Err(Failure::Unreachable);
    };
    let temporary_file = TemporaryImage::new().map_err(|_| Failure::Unreachable)?;
    let Some(download) = session.download_uri(url) else {
        return Err(Failure::Unreachable);
    };

    let destination = gio::File::for_path(temporary_file.path()).uri();
    download.set_allow_overwrite(false);
    download.set_destination(destination.as_str());

    let state = Rc::new(RefCell::new(CopyState {
        temporary_file,
        report: Some(Box::new(report)),
        completed: Cell::new(false),
    }));

    let state_for_response = Rc::clone(&state);
    download.connect_response_notify(move |download| {
        if let Some(response) = download.response()
            && !copy_image_response_within_limit(response.content_length())
        {
            complete(&state_for_response, Outcome::Failed(Failure::TooLarge));
            download.cancel();
        }
    });

    let state_for_received = Rc::clone(&state);
    download.connect_received_data(move |download, _| {
        if !copy_image_download_within_limit(download.received_data_length()) {
            complete(&state_for_received, Outcome::Failed(Failure::TooLarge));
            download.cancel();
        }
    });

    let state_for_finished = Rc::clone(&state);
    download.connect_finished(move |download| {
        complete_with(&state_for_finished, || {
            finished_outcome(download, &state_for_finished)
        });
    });

    let state_for_failed = Rc::clone(&state);
    download.connect_failed(move |_, _| {
        complete(&state_for_failed, Outcome::Failed(Failure::Unreachable));
    });

    Ok(ActiveCopy { download, state })
}

pub(crate) const fn copy_image_download_within_limit(received_bytes: u64) -> bool {
    received_bytes <= COPY_IMAGE_MAX_BYTES
}

const fn copy_image_response_within_limit(content_length: u64) -> bool {
    content_length == 0 || content_length <= COPY_IMAGE_MAX_BYTES
}

fn copy_image_dimensions_within_limit(width: i32, height: i32) -> bool {
    width > 0 && height > 0 && i64::from(width) * i64::from(height) <= COPY_IMAGE_MAX_PIXELS
}

fn finished_outcome(download: &Download, state: &Rc<RefCell<CopyState>>) -> Outcome {
    if !copy_image_download_within_limit(download.received_data_length()) {
        return Outcome::Failed(Failure::TooLarge);
    }

    if let Some(response) = download.response() {
        if !is_success_response(&response) {
            return Outcome::Failed(Failure::NotAnImage);
        }
        if !copy_image_response_within_limit(response.content_length()) {
            return Outcome::Failed(Failure::TooLarge);
        }
    }

    let path = state.borrow().temporary_file.path().to_path_buf();
    let file_size = match fs::metadata(&path) {
        Ok(metadata) => metadata.len(),
        Err(_) => return Outcome::Failed(Failure::Unreachable),
    };
    if !copy_image_download_within_limit(file_size) {
        return Outcome::Failed(Failure::TooLarge);
    }
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(_) => return Outcome::Failed(Failure::Unreachable),
    };
    if !copy_image_download_within_limit(bytes.len() as u64) {
        return Outcome::Failed(Failure::TooLarge);
    }

    let loader = gtk::gdk_pixbuf::PixbufLoader::new();
    let decode_failure = Rc::new(Cell::new(None));
    let failure_for_size = Rc::clone(&decode_failure);
    loader.connect_size_prepared(move |loader, width, height| {
        if !copy_image_dimensions_within_limit(width, height) {
            failure_for_size.set(Some(Failure::TooLarge));
            loader.set_size(1, 1);
        }
    });
    let decode_result = loader.write(&bytes).and_then(|()| loader.close());
    if let Some(failure) = decode_failure.get() {
        return Outcome::Failed(failure);
    }
    if decode_result.is_err() {
        return Outcome::Failed(Failure::NotAnImage);
    }
    let Some(pixbuf) = loader.pixbuf() else {
        return Outcome::Failed(Failure::NotAnImage);
    };
    let texture = gdk::Texture::for_pixbuf(&pixbuf);

    let Some(display) = gdk::Display::default() else {
        return Outcome::Failed(Failure::Clipboard);
    };
    display.clipboard().set_texture(&texture);
    Outcome::Copied
}

fn is_success_response(response: &URIResponse) -> bool {
    is_success_status(response.status_code())
}

const fn is_success_status(status: u32) -> bool {
    status == 0 || (200 <= status && status < 300)
}

fn complete(state: &Rc<RefCell<CopyState>>, outcome: Outcome) {
    complete_with(state, || outcome);
}

fn cancel(state: &Rc<RefCell<CopyState>>) {
    complete(state, Outcome::Failed(Failure::NoTabPage));
}

fn complete_with<F>(state: &Rc<RefCell<CopyState>>, outcome: F)
where
    F: FnOnce() -> Outcome,
{
    let report = {
        let mut state = state.borrow_mut();
        let CopyState {
            report, completed, ..
        } = &mut *state;
        if completed.replace(true) {
            None
        } else {
            report.take()
        }
    };
    if let Some(report) = report {
        report(outcome());
    }
}

#[cfg(test)]
#[path = "image_copy_tests.rs"]
mod tests;
