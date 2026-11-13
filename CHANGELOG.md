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

### Theme & glass (second batch, 2026-11-13)
- Collapsed the four "配色风格" variants into one fixed `fidelity` scheme and
  made every surface permanently neutral, so seed colors only affect accents;
  removed the "配色风格" setting row and the `AppColorStyle` enum (R1/R2).
- Removed dynamic color (Material You wallpaper seed) entirely: its switch,
  the "跟随系统" swatch, and the `dynamic_color` / `material_color_utilities`
  dependencies are gone (R4).
- Removed the iOS system-gray preset and the unused seed-picker / color-picker
  / color-style widgets (R3/R5).
- Reworked the "材质" card into a single 玻璃特效 switch plus a "玻璃设置"
  sheet with three tabs (磨砂 / 透明 / 色调), per-tab sliders, live draft
  preview and 重置 / 保存. Glass quality is fixed to the `ultra` tier (R6).
- Added a `styleTransform` injection hook to the vendored prism_ui glass
  renderer so one place overrides every pane's style; see NOTICE section 6
  for the GPLv3 section 5(a) modification notice.
