# Release channels

Three long-lived branches, one per build channel. The channel decides whether a
build ships developer tooling — developer mode and the build watermark.

| Branch    | Channel   | Dev mode default | Watermark default | Audience              |
|-----------|-----------|------------------|-------------------|-----------------------|
| `stable`  | `stable`  | off              | off               | public releases       |
| `staging` | `staging` | **on**           | **on**            | testers / release RCs |
| `nightly` | `nightly` | **on**           | **on**            | daily internal builds |
| any other | `nightly` | **on**           | **on**            | feature branches      |

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
const devToolingEnabledByDefault = !isStableChannel;
```

The default is `nightly`, so a local `flutter run` — which never passes the
define — keeps dev tooling on. Nothing about the developer experience changes.

## What the channel actually controls

Only the **defaults** of two persisted settings in
`lib/core/state/dev_mode_provider.dart`:

```dart
// devModeProvider
return prefs?.getBool(_prefsKey) ?? devToolingEnabledByDefault;

// hideBuildWatermarkProvider  (note: "hide", so stable → hidden)
return prefs?.getBool(_prefsKey) ?? isStableChannel;
```

Two consequences worth being explicit about:

- **A user's own choice still wins.** Both values are persisted in
  `SharedPreferences`; the channel only supplies the value used when nothing has
  been stored yet.
- **`stable` is not a lockout.** The 7-tap easter egg on the version badge
  (`lib/features/menu/about_screen.dart`) still unlocks dev mode on a stable
  build, and the watermark can then be switched back on from the Dev group for
  diagnostics. This is deliberate — it keeps production builds debuggable.

If you ever need the watermark to be genuinely unreachable on `stable`, gate the
widget itself on `!isStableChannel` in `lib/app.dart` rather than changing the
default — that is a behaviour change, not a default change.

## Side-by-side installs

Each channel ships under its own package identity, so all three builds can sit
on one device or one machine at the same time instead of upgrading over each
other. `stable` keeps the bare identifiers it has always used, so existing
installs are untouched.

| Channel   | Android applicationId       | iOS bundle id                     | Launcher name    | Desktop data folder |
|-----------|-----------------------------|-----------------------------------|------------------|---------------------|
| `stable`  | `app.glaze.flutter`         | `com.glaze.glazeFlutter`          | `Glaze`          | `Glaze`             |
| `staging` | `app.glaze.flutter.staging` | `com.glaze.glazeFlutter.staging`  | `Glaze Staging`  | `Glaze-staging`     |
| `nightly` | `app.glaze.flutter.nightly` | `com.glaze.glazeFlutter.nightly`  | `Glaze Nightly`  | `Glaze-nightly`     |

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

### Known limitations

- **The `com.hydall.glaze://` OAuth scheme is still shared.** All three Android
  builds register it, so a Dropbox/Google Drive callback can raise an app
  chooser. Making it per-channel means registering the extra redirect URIs
  (`com.hydall.glaze.nightly://oauth/…`, `…staging…`) in the Google and Dropbox
  consoles first, otherwise sync auth breaks outright on those channels.
- **The Google Drive sync folder is shared** (`_folderName = 'Glaze'` in
  `gdrive_folders.dart`), so two channels syncing the same account write into
  one remote folder.
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
3. If it needs different dev-tooling behaviour, extend
   `build_channel.dart` — keep the derived flags `const` so they tree-shake.

Do not read `buildChannel` directly in feature code; depend on the derived
booleans instead, so the channel list stays in one place.
