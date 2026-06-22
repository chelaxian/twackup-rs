use std::{
    ffi::OsString,
    path::{Path, PathBuf},
};

pub(crate) const LICENSE_PATH: &str = "/usr/share/doc/ru.danpashin.twackup/LICENSE";

#[cfg(target_os = "macos")]
pub(crate) fn dpkg_admin_dir() -> &'static str {
    "/usr/local/var/lib/dpkg"
}

#[cfg(target_os = "ios")]
pub(crate) fn dpkg_admin_dir() -> OsString {
    jb_root_path("/var/lib/dpkg").into_os_string()
}

#[cfg(not(any(target_os = "macos", target_os = "ios")))]
pub(crate) fn dpkg_admin_dir() -> OsString {
    "/var/lib/dpkg".into()
}

#[cfg(target_os = "ios")]
pub(crate) fn jb_root_path(path: &str) -> PathBuf {
    let input = Path::new(path);
    let relative_path = input.strip_prefix("/").unwrap_or(input);

    let candidates = [
        PathBuf::from(path),
        Path::new("/var/jb").join(relative_path),
    ];

    for candidate in candidates {
        if std::fs::metadata(&candidate).is_ok() {
            return candidate;
        }
    }

    if let Some(roothide_path) = roothide_jbroot_path(relative_path) {
        return roothide_path;
    }

    PathBuf::from(path)
}

#[cfg(target_os = "ios")]
fn roothide_jbroot_path(relative_path: &Path) -> Option<PathBuf> {
    let containers = Path::new("/var/containers/Bundle/Application");
    let entries = std::fs::read_dir(containers).ok()?;

    let mut matches: Vec<_> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(".jbroot-"))
        })
        .map(|path| path.join(relative_path))
        .filter(|path| std::fs::metadata(path).is_ok())
        .collect();

    matches.sort();
    matches.pop()
}

#[cfg(not(target_os = "ios"))]
pub(crate) fn jb_root_path(path: &str) -> PathBuf {
    PathBuf::from(path)
}

#[cfg(target_os = "ios")]
pub(crate) fn debs_target_dir() -> OsString {
    "/var/mobile/Documents/twackup".into()
}

#[cfg(target_os = "ios")]
pub(crate) fn shared_output_path(path: &Path) -> PathBuf {
    let mobile_root = Path::new("/var/mobile");
    let rootfs_mobile = Path::new("/rootfs/private/var/mobile");
    if rootfs_mobile.is_dir() {
        if let Ok(relative) = path.strip_prefix(mobile_root) {
            return rootfs_mobile.join(relative);
        }
    }
    path.to_path_buf()
}

#[cfg(not(target_os = "ios"))]
pub(crate) fn shared_output_path(path: &Path) -> PathBuf {
    path.to_path_buf()
}

#[cfg(not(target_os = "ios"))]
pub(crate) fn debs_target_dir() -> OsString {
    match std::env::current_dir() {
        Ok(current_dir) => current_dir.join("twackup").into_os_string(),
        Err(_) => "./twackup".into(),
    }
}
