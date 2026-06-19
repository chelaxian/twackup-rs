
<div align="center">
<img src="https://github.com/danpashin/twackup-rs/raw/master/assets/logo-rounded.png" alt="Logo"/>
<br>
<br>

![Release](https://img.shields.io/github/v/release/danpashin/twackup-rs)
![Supported platforma](https://img.shields.io/badge/supported_platforms-ios-red?style=flat)
<br>
![Current CI state](https://img.shields.io/github/actions/workflow/status/danpashin/twackup-rs/run-tests.yml)
![License](https://img.shields.io/github/license/danpashin/twackup-rs)
</div>

## Twackup

Twackup is a simple iOS tool for re-packaging installed packages to DEB's or
backing up and restoring packages or repos. CLI version works from iOS 6 and later and GUI from iOS 14 and later.
This fork also carries 2026 packaging updates for standard rootless jailbreaks
and RootHide Bootstrap 2.2.x on iOS 17 arm64e devices.
CLI can be also compiled and work fine on any Debian-based linux, though I do not support this platforms.

Twackup uses custom dpkg database parser written and Rust - and it parses dpkg database a bit faster than dpkg itself.
It means it can be used on that platforms that have no support of dpkg - primarily, iOS.
There already are some tweaks for jailbreak with the same target, but they all are poorly
written in something like Bash and do not really work as they expected to. That's why Twackup exists at all.

## Screenshots

| Leaves | Detail | Settings |
|---|---|---|
| ![First](assets/screenshots/screen-1.png?raw=true) | ![Second](assets/screenshots/screen-2.png?raw=true) | ![Third](assets/screenshots/screen-3.png?raw=true) |

## Building from source

1. Make sure you have Rust installed. If not,  I would recommend installing it via [rustup](https://rustup.rs).
2. Clone the source with git:

	```sh
	$ git clone --recursive https://github.com/danpashin/twackup-rs.git
	$ cd twackup-rs
	```

3. * If you are targeting to run twackup on host platform, you can directly run `cargo build --release`
and you'll find binary in `target` directory.
   * If you decided to build for iOS and run all tests, then
     1. Install dependencies
        ```shell
        # Install building system
        $ cargo install cargo-make

        # Install different building utils if you don't have them
        $ brew install dpkg ldid coreutils

        # Install utils from rubygems
        $ bundle install
        ```
     2. Make sure you have nightly rust with sources as well as iOS and iOS Simulator platforms support
        ```shell
        $ rustup target add aarch64-apple-ios x86_64-apple-ios
        $ rustup toolchain install nightly
        $ rustup component add rust-src --toolchain nightly
        ```
     3. Install GUI libraries from cocoapods
        ```shell
        $ cd twackup-gui
        $ pod install
        ```
     4. And finally start build
        ```shell
        $ cargo build-ios
        ```
        This will take a relatively large amount of time.It is about 30 mins for GitHub actions and 10 mins for my Mac.

### Rootless and RootHide packages

`cargo build-ios` emits separate artifacts:

* `target/artifacts/rootless/*_iphoneos-arm64.deb` for standard rootless jailbreaks.
* `target/artifacts/roothide/*_iphoneos-arm64e.deb` for RootHide Bootstrap.

At runtime Twackup resolves the dpkg database in this order:

1. the current bootstrap namespace, e.g. `/var/lib/dpkg`;
2. standard rootless `/var/jb/var/lib/dpkg`;
3. RootHide's active `.jbroot-*` directory under `/var/containers/Bundle/Application`.

## Contributing
I'll be really glad to see you in contributors for this project.
I spent a lot of time of in writing it to its current state and this is really exhausting.

## MSRV
**1.70** for main library

**1.74.1** for CLI

## License

Twackup is licensed under GNU General Public License v3.0

See [COPYING](COPYING) for the full text.
