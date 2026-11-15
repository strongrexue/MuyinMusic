# Changelog

All notable changes to MuyinMusic (沐音) are documented here.

This project is a second-development (二开) fork of
[CyShineMusic (栖弦)](https://github.com/KevinllBin/CyShineMusic),
baseline release **v1.1.2** (commit `24a87ce`). The upstream changelog /
release notes are not reproduced here; see the upstream repository for those.

## [1.1.7] — 2026-11-16

Soda music (汽水音乐) is now a catalogue-only source. Playback is resolved by
imported JS music sources, exactly like every other platform.

### Changed
- `MusicSource.qishui` -> `MusicSource.qs`, matching the upstream source code
  so imported scripts resolve it; stored `qishui` codes are still accepted via
  a legacy alias, and `qishui_featured_pool_v1` / existing settings keys keep
  working. Icon renamed to `assets/platform_icons/qs.png`, brand color is now
  the platform green `#2BFF6A`.
- `lib/core/sdk/qishui_sdk.dart` rewritten as `lib/core/sdk/qs_sdk.dart` and
  re-pointed at the Windows client API (`https://api.qishui.com/luna/pc`) with
  its public parameters. The old Android endpoint family stopped returning
  results.
- Reads now register a throw-away desktop device on first use and are
  serialized 600 ms apart, because the gateway answers an empty 200 to
  unthrottled or unidentified clients. Empty answers are retried three times
  with backoff.
- Artist and album details use the official `/luna/pc/artists/{id}` and
  `/luna/pc/albums/{id}` endpoints instead of falling back to name search.
- The leaderboard directory is read from the discover blocks at runtime, so
  each board keeps its real title, description, cover and preview tracks.
  `chart:<id>` still imports a board as a playlist.

### Removed
- Native playback resolution for Soda: `resolveUrl`, `prefetch`, the relay
  fallback, the gorgon request signing, the URL cache and the per-track quality
  ladder are gone, together with their crypto test. `kNativeSourceQualities` is
  now empty and the player no longer prefetches Soda tracks.
- The `qishui_session_id` setting and its startup wiring, superseded by device
  registration.

### Fixed
- Users upgrading from a build without Soda no longer stay without Soda search
  results: a one-time `qs_search_added_v1` migration adds the source to
  `enabledSearchSources`.
- Featured playlists could take ~31 s on first load because a stale pool kept
  re-fetching for 24 rounds; it now refreshes for a single round (~1.4 s).

## [1.1.6] — 2026-11-16

### Added
- Pausable, resumable and cancellable downloads. The queue sheet was replaced
  by per-task chips showing progress, and paused tasks can be resumed from the
  downloads page. `DownloadPausedException` and `pauseTask` / `resumeTask` /
  `discardTask` were added to the download service.

## [1.1.5] — 2026-11-16

### Fixed
- Soda playlist sharing links now import correctly: `qishui.douyin.com`,
  `music.douyin.com` and bare `qishui.com` hosts are accepted, `chart:` ids
  import a leaderboard, short links are followed, and links pasted without an
  `http` scheme are recognised.

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
