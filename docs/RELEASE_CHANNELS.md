# Release channels

Three long-lived branches, one per build channel. The channel decides packaging
— app identity, data folder, cloud root and update source — and the watermark
default. It no longer decides whether developer mode is on.

| Branch    | Channel   | Dev mode default | Watermark default   | Audience              |
|-----------|-----------|------------------|---------------------|-----------------------|
| `stable`  | `stable`  | off              | on while `0.x`      | public releases       |
| `staging` | `staging` | off              | **on**              | testers / release RCs |
| `nightly` | `nightly` | off              | **on**              | daily internal builds |
| any other | `nightly` | off              | **on**              | feature branches      |

Developer mode is hidden on every channel, local `flutter run` included, and is
unlocked only through the 7-tap easter egg on the version badge in About. The
build watermark is shown on every current version — `stable` only drops it once
the app leaves `0.x`, since a beta needs its screenshots identifiable.

`stable` is the repository default branch. Branching and promotion rules live in
[`WORKFLOW.md`](./WORKFLOW.md).

## How the channel reaches the app

CI derives the channel from the branch it is building and injects it as a
compile-time define (`.github/workflows/build-branch.yml`, `metadata` job):

```bash
case "$BUILD_BRANCH" in
  stable)  BUILD_CHANNEL=stable  ;;
  staging) BUILD_CHANNEL=staging ;;
  *)       BUILD_CHANNEL=nightly ;;
esac
```

It is passed to all three build jobs (Android, Windows, iOS) alongside the
existing defines:

```
--dart-define=BUILD_CHANNEL=${{ needs.metadata.outputs.build_channel }}
```

`lib/core/constants/build_channel.dart` reads it back:

```dart
const buildChannel = String.fromEnvironment('BUILD_CHANNEL', defaultValue: 'nightly');
const isStableChannel = buildChannel == 'stable';
```

The default is `nightly`, so a local `flutter run` — which never passes the
define — is packaged like an internal build.

## What the channel still controls

Of the two persisted settings in `lib/core/state/dev_mode_provider.dart`, only
the watermark is channel-aware now:

```dart
// devModeProvider — hidden until unlocked in About, on every channel
return prefs?.getBool(prefsKey) ?? false;

// hideBuildWatermarkProvider (note: "hide") — only a non-beta stable hides it
return prefs?.getBool(_prefsKey) ?? (isStableChannel && !isBetaVersion);
```

- **Dev settings are opt-in everywhere.** The Dev group in
  `lib/features/menu/menu_screen.dart` is gated on `devModeProvider`, and the
  only thing that flips it is tapping the version badge seven times in
  `lib/features/menu/about_screen.dart`. A nightly build looks exactly like a
  stable one until someone does that — no channel gives it away for free.
- **The watermark ships on every current version.** `isBetaVersion` is true for
  the whole `0.x` line (`lib/core/constants/app_version.dart`), so even a stable
  build stamps its date and branch today; the stamp disappears from `stable` on
  its own at `1.0`. Turning it off before then means unlocking dev mode first.
- **A user's own choice still wins.** Both values are persisted in
  `SharedPreferences`; the defaults above are only used when nothing has been
  stored yet, so an install that already toggled either setting keeps what it
  had.

### One-time dev-mode reset

Older `nightly`/`staging` builds defaulted dev mode to **on**, and that `true`
was written to `SharedPreferences` the moment the user touched any dev toggle —
a stored value outranks the new default, so those installs would have kept the
Dev group forever. `resetLegacyDevModeFlag`
(`lib/core/services/dev_mode_flag_migration.dart`) removes the `devModeEnabled`
key once at startup, guarded by a `devModeDefaultResetV1` marker, and runs after
`migrateLegacyWindowsPreferences` because that one rewrites the preferences file
on disk before `SharedPreferences` is first opened. After the marker is written
the flag is the user's own again and is never touched.

If a future channel ever needs different behaviour here, add a derived `const`
to `build_channel.dart` and use it for the default rather than reading
`buildChannel` in feature code.

## Side-by-side installs

Each channel ships under its own package identity, so all three builds can sit
on one device or one machine at the same time instead of upgrading over each
other. `stable` keeps the bare identifiers it has always used, so existing
installs are untouched.

| Channel   | Android applicationId       | iOS bundle id                     | Launcher name    | Desktop data folder | Cloud sync root |
|-----------|-----------------------------|-----------------------------------|------------------|---------------------|-----------------|
| `stable`  | `app.glaze.flutter`         | `com.glaze.glazeFlutter`          | `Glaze`          | `Glaze`             | `Glaze`         |
| `staging` | `app.glaze.flutter.staging` | `com.glaze.glazeFlutter.staging`  | `Glaze Staging`  | `Glaze-staging`     | `Glaze-staging` |
| `nightly` | `app.glaze.flutter.nightly` | `com.glaze.glazeFlutter.nightly`  | `Glaze Nightly`  | `Glaze-nightly`     | `Glaze-nightly` |

**Signing does not change.** All three channels are signed with the same CI
keystore (`ANDROID_KEYSTORE_BASE64` and friends). Android only refuses to
co-install packages that share an `applicationId`; a shared certificate is fine
— and keeping it shared is what lets a build promoted from `nightly` to
`stable` install as an update rather than a fresh app.

### How each platform gets its identity

- **Android** — CI exports `BUILD_CHANNEL` as an *environment variable* to the
  "Build APK" step (`--dart-define` never reaches Gradle).
  `android/app/build.gradle.kts` reads it with `System.getenv`, the same
  mechanism the signing config already uses, and derives the `applicationId`
  suffix plus the `appLabel` manifest placeholder. The `namespace` stays
  `app.glaze.flutter`, so `.MainActivity` and the `MethodChannel` names are
  unaffected.
- **iOS** — xcconfig files cannot read the environment, so CI writes
  `ios/Flutter/Channel.xcconfig` before building. It defines
  `BUNDLE_ID_SUFFIX` (consumed by `PRODUCT_BUNDLE_IDENTIFIER` in the Runner
  target) and `APP_DISPLAY_NAME` (consumed by `CFBundleDisplayName`). The file
  is checked in with `nightly` defaults for local builds.
- **Desktop** — Windows/Linux/macOS builds have no package manager to separate
  them, so the channel goes into the data path instead:
  `glazeDataFolderName` in `lib/core/constants/build_channel.dart` drives
  `_desktopDataDir()` in `lib/core/utils/platform_paths.dart`. Without this the
  three installs would share one `glaze.db`.

## Cloud sync

Local separation is only half the problem: two channels pointed at the same
Dropbox or Google Drive account would still write through one shared manifest
and overwrite each other's characters, chats and presets. So the cloud tree is
split per channel too, named exactly like the desktop data folder.

Everything hangs off one constant — `cloudBase` in
`lib/features/cloud_sync/sync_models.dart`, which is `'/$cloudRootFolderName'`
and reuses `glazeDataFolderName`. All ~50 cloud paths in the sync layer are
built from it.

### Google Drive

Nothing else to do: the root folder is looked up by name under the Drive root,
so `Glaze-nightly` simply becomes a sibling of `Glaze`. `GDriveFolders`
takes its `_folderName` from `cloudRootFolderName`.

### Dropbox

Dropbox hands the app its **App folder** as the API root, which is why paths get
stripped down to `''` rather than used as-is. That folder is named by the
Dropbox app registration, not by us, so it cannot carry the channel — and a
single `DROPBOX_APP_KEY` means all three channels land in the same place.

Two configurations are therefore supported, and the code is correct under both:

1. **Shared app key** (the default, and what happens until the extra secrets
   exist). Each non-stable channel lives in a sub-folder of the shared App
   folder: `/Apps/Glaze/nightly/…`. `stable` keeps the flat layout it has
   always had, so its existing files never move.
2. **Per-channel app key** — set `DROPBOX_APP_KEY_STAGING` /
   `DROPBOX_APP_KEY_NIGHTLY` in the repository secrets and register a separate
   Dropbox app for that channel. The channel then gets its own App folder, and
   the sub-folder is just one harmless extra level inside it. CI falls back to
   `DROPBOX_APP_KEY` whenever the channel secret is empty, so adding them is
   safe to do one at a time.

Three things in `dropbox_adapter.dart` make this work:

- `_stripPrefix` maps a canonical path to the App-folder-relative one
  (`/Glaze-nightly/characters/x.json` → `/nightly/characters/x.json`).
- `_unmapChannelPath` is its inverse on the way back, so listings still reach
  `normalizeCloudSyncPath` relative to the Glaze root — the invariant that lines
  manifest entries up against `list_folder` results. Without it every entry
  would look missing on a non-stable channel and each sync would re-upload the
  whole library.
- `_belongsToAnotherChannel` keeps one channel out of another's sub-tree. This
  matters for exactly one operation: wiping cloud data from `stable` goes
  through `_deleteAllInRoot`, which lists the App folder root *recursively* —
  without the guard it would delete `nightly/` and `staging/` along with its
  own files. It also hides sibling channel folders from `listFolder`, which is
  what used to keep the post-wipe "waiting for cloud to finalize" poll spinning
  until it timed out.

### Migrating existing installs

Cloud data written before this split stays where it is, under the `Glaze` root.
A `stable` build keeps seeing it unchanged. A `staging` / `nightly` build starts
against an empty root and pushes its local library up on the first sync — the
old data is not touched or deleted, just no longer read by that channel. There
is no automatic copy, and for a nightly channel that seems like the right
trade rather than a gap worth closing.

### Known limitations

- **The `com.hydall.glaze://` OAuth scheme is still shared.** All three Android
  builds register it, so a Dropbox/Google Drive callback can raise an app
  chooser. Making it per-channel means registering the extra redirect URIs
  (`com.hydall.glaze.nightly://oauth/…`, `…staging…`) in the Google and Dropbox
  consoles first, otherwise sync auth breaks outright on those channels.
- **macOS and Linux bundle identities are not split** — CI produces no builds
  for them, so only the data folder is channel-aware there.
- Switching an existing desktop install to `staging`/`nightly` starts from an
  empty data folder; the old `%APPDATA%\Glaze` contents stay put and are picked
  up again by a `stable` build. The same applies to a local `flutter run`,
  which defaults to `nightly`.

## Adding a new channel

1. Add the branch name to the `case` in the `metadata` job of **both**
   `build-branch.yml` and `build-release.yml`.
2. Add it to the `case` in the "Configure iOS channel identity" step of both
   workflows, and to the two `when` blocks in `android/app/build.gradle.kts`.
3. Add it to the `case` in the "Create .env from secrets" step of both
   workflows (all three build jobs each) if it gets its own Dropbox app key,
   and to `_foreignChannelFolders` in `dropbox_adapter.dart` so a wipe from
   `stable` leaves it alone.
4. If it needs dev-tooling behaviour that differs from the "hidden everywhere,
   watermark everywhere" default, extend `build_channel.dart` — keep the derived
   flags `const` so they tree-shake.

Do not read `buildChannel` directly in feature code; depend on the derived
booleans instead, so the channel list stays in one place.
