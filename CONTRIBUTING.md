# Contributing to Glaze

Thanks for your interest in Glaze. This document covers everything you need to
build, run, and test the app locally. For git branching, PR, CI and
task-tracking rules, see [`docs/WORKFLOW.md`](docs/WORKFLOW.md). For the agent /
maintainer conventions, see [`CLAUDE.md`](CLAUDE.md).

## 📋 Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) 3.44+ (or newer, compatible with Dart 3.12+)
- A toolchain for the platform you want to build — [Android Studio](https://developer.android.com/studio) for Android, Xcode for iOS/macOS, Visual Studio with the C++ desktop workload for Windows
- Git

## 🏗️ Setup

```bash
git clone https://github.com/hydall/Glaze.git
cd Glaze
flutter pub get
```

A `.env` file in the project root is **required to build** — it is declared as an asset in `pubspec.yaml`, so the build fails if it is missing:

```bash
cp .env.example .env
```

It holds the OAuth credentials for cloud sync. Leaving the values empty is fine — the app builds and runs, and only Dropbox / Google Drive sync stays unavailable.

## 🚀 Dev Run

```bash
flutter run -d windows   # or: -d android, -d ios, -d macos, -d linux
```

> Web is **not** a target platform. `lib/` imports `dart:io` without conditional
> stubs, and Drift/`sqlite3_flutter_libs`, `photo_manager` and the WebView bridge
> have no web support. Target Windows, Android, iOS, macOS or Linux.

## 🏭 Builds

```bash
flutter build apk        # Android
flutter build windows    # Windows
flutter build ios        # iOS
```

## ⚙️ Code Generation

Drift, Freezed, and JSON-serializable models are generated. After editing any of them:

```bash
dart run build_runner build
```

Localization keys are generated too:

```bash
dart run easy_localization:generate -S assets/translations -s en.json -f keys -o locale_keys.g.dart
```

## 🧪 Tests and Analysis

```bash
flutter analyze
flutter test
```

Only analyzer **errors** fail CI (`--no-fatal-infos --no-fatal-warnings`); infos
and hints from the strict lint set are not build-breaking.

The WebView render suite is separate from the Flutter tests — it loads the real
`assets/chat_webview/` modules in a headless Chromium:

```bash
cd test/webview_js && npm ci && npx playwright install chromium && npm test
```

## 📚 Project Layout

```text
lib/
  main.dart                 # Entry point
  app.dart                  # GlazeApp: router and boot-time initialization
  core/                     # Models, services, providers, LLM pipeline, navigation
  features/
    chat/                   # Chat UI, WebView bridge, generation flow
    extensions/             # Post-generation blocks and JS bridge SDK
    character_list/         # Character CRUD and editor
    lorebooks/              # Lorebook UI and management
    presets/                # Prompt preset editor
    image_gen/              # Image generation UI and services
    cloud_sync/             # Dropbox / Google Drive sync
    settings/               # API, app, and theme settings
  shared/                   # Shell, theme, shared widgets
assets/chat_webview/        # WebView HTML/JS/CSS renderer and bridge assets
assets/translations/        # Localization files
docs/                       # Architecture, invariants, rules, workflow, build notes
test/                       # Unit, characterization, extension, and asset-guard tests
```

## 📖 Technical References

| Topic | Document |
|-------|----------|
| Architecture and full flow | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| Formal invariants with code references | [`docs/INVARIANTS.md`](docs/INVARIANTS.md) |
| Git, PR, CI, release and Trello rules | [`docs/WORKFLOW.md`](docs/WORKFLOW.md) |
| Build channels and `--dart-define` wiring | [`docs/RELEASE_CHANNELS.md`](docs/RELEASE_CHANNELS.md) |
| Windows build and dependency overrides | [`docs/BUILD_NOTES.md`](docs/BUILD_NOTES.md) |
| Code style and decomposition | [`docs/CODE_STYLE.md`](docs/CODE_STYLE.md) |
| UI kit — which widget to reach for | [`docs/UI_KIT.md`](docs/UI_KIT.md) |
| Generation, race conditions, database rules | [`docs/rules/`](docs/rules/) |
| JS extension bridge and security invariants | `docs/ARCHITECTURE.md` § 9 + `docs/INVARIANTS.md` |
