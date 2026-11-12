# Changelog

All notable changes to MuyinMusic (沐音) are documented here.

This project is a second-development (二开) fork of
[CyShineMusic (栖弦)](https://github.com/KevinllBin/CyShineMusic),
baseline release **v1.1.2** (commit `24a87ce`). The upstream changelog /
release notes are not reproduced here; see the upstream repository for those.

## [Unreleased] — 沐音 re-brand / 二开初始版本

Forked from CyShineMusic v1.1.2 for personal use and small-scale sharing among
friends. Source is published publicly at
<https://github.com/strongrexue/MuyinMusic>.

### Changed
- Re-branded application identity: name 栖弦 -> 沐音, package
  `com.cyshine.music` -> `com.muyin.muyinmusic` (dev channel `...dev`),
  plus all user-visible labels (startup, shell header, home widget, vivo
  empty-queue hint) and the default download / WebDAV directories.
- Re-pointed the in-app online update checker and dialog to this repository's
  GitHub Releases (`strongrexue/MuyinMusic/releases/latest`) instead of
  upstream. Release APKs are signed with a self-owned keystore that is kept
  local and never committed.
- Re-branded internal log / cache / probe / temp-file / equalizer /
  notification-channel identifiers from `cyshine` / `CyShineMusic` to
  `muyin` / `MuyinMusic`.

### Added
- `NOTICE` — provenance, change list, and mixed-license disclosures
  (prism_ui is GPL-3.0-only).
- `CHANGELOG.md` (this file).
- `packages/prism_ui/LICENSE` (GPLv3 full text) and
  `packages/heroine/LICENSE` (MIT full text), which upstream vendored without
  bundling the license texts.

### Compliance / removed
- Root `LICENSE` retains upstream's MIT text and `Copyright (c) 2026
  KevinllBin` verbatim (MIT requirement).
- Removed the upstream QQ group number / QR image and GitHub links from
  README; kept the "no bundled music, user-configured legal sources"
  disclaimer and the closing disclaimer.
- `.gitignore` now ignores `android/signing/*.jks` and `*.properties` so the
  signing keystore is never committed.
