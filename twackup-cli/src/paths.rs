use std::{ffi::OsString, path::PathBuf};

pub(crate) const LICENSE_PATH: &str = "/usr/share/doc/ru.danpashin.twackup/LICENSE";

#[cfg(target_os = "macos")]
pub(crate) fn dpkg_admin_dir() -> &'static str {
    "/usr/local/var/lib/dpkg"
}

#[cfg(target_os = "ios")]
pub(crate) fn dpkg_admin_dir() -> &'static str {
    let rootfull_path = "/var/lib/dpkg";
    let rootless_path = "/var/jb/var/lib/dpkg";

    if std::fs::metadata(&rootfull_path).is_ok() {
        rootfull_path
    } else {
        rootless_path
    }
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
pub(crate) fn dpkg_admin_dir() -> OsString {
    "/var/lib/dpkg".into()
}

#[cfg(target_os = "ios")]
pub(crate) fn jb_root_path(path: &str) -> PathBuf {
    let rootful_path = PathBuf::from(path);
    if std::fs::metadata(&rootful_path).is_ok() {
        return rootful_path;
    }

    let relative_path = std::path::Path::new(path)
        .strip_prefix("/")
        .unwrap_or_else(|_| std::path::Path::new(path));
    let rootless_path = std::path::Path::new("/var/jb").join(relative_path);
    if std::fs::metadata(&rootless_path).is_ok() {
        rootless_path
    } else {
        rootful_path
    }
}

#[cfg(not(target_os = "ios"))]
pub(crate) fn jb_root_path(path: &str) -> PathBuf {
    PathBuf::from(path)
}

#[cfg(target_os = "ios")]
pub(crate) fn debs_target_dir() -> OsString {
    "/var/mobile/Documents/twackup".into()
}

#[cfg(not(target_os = "ios"))]
pub(crate) fn debs_target_dir() -> OsString {
    match std::env::current_dir() {
        Ok(current_dir) => current_dir.join("twackup").into_os_string(),
        Err(_) => "./twackup".into(),
    }
}
