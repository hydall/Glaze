<p align="center">
  <img src="assets/logos/glaze.png" width="256" alt="Glaze Logo">
</p>

# Glaze

[![Discord](https://img.shields.io/discord/1355184294868484196?color=5865F2&logo=discord&logoColor=white)](https://discord.gg/jnGhd7p6Ht)
[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-FFDD00?style=flat&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/hydall)

[Русский](README.ru.md)

Glaze is a local, user-friendly AI roleplay chat client. It works with any OpenAI-compatible (Chat Completion) LLM provider, and keeps your data on your own device.

> [!WARNING]
> Glaze is still under heavy development. The app is not yet stable and may contain bugs.
>
> 🧪 **Disclaimer**: This app was **vibecoded** using a plethora of models. Curb your expectations.

## ✨ Key Features

- **User-Friendly Installation and Interface** — You don't need an IT degree to use the app. Just install it and start chatting.
- **Actually Working User Statistics** — Gain insights into how many messages you've sent, how many tokens you've burned, and how many hours you've spent chatting.
- **Native Reasoning Model Support** — No complex regex needed. Native reasoning is properly parsed and injected into a separate block that is not sent back to the model. If your preset has its own reasoning tags, Glaze can parse those too.
- **Customizable Theming** — Change colors, fonts, and background images, then export your theme as a JSON file to share with others. Material 3 throughout, with separate desktop and mobile layouts.
- **Background Generation** — Glaze can generate responses in the background and notify you once they are ready.
- **Lorebooks and Memory** — Attach lorebooks, memory books, author's notes, and personas to keep long-running roleplay coherent.
- **Image Generation** — Generate images from inside the app and wire image output into roleplay flows and extension blocks.
- **Cloud Sync** — Optional Dropbox and Google Drive sync for moving your local data between devices.
- **Local-First Storage** — Characters, sessions, presets, API configuration, personas, lorebooks, and extension data all live in a local SQLite database.
- **Extensions (ExtBlocks)** — Automate post-generation actions: info blocks, image generation, JS scripts, and interactive HTML panels. *(under development)*
- **Glaze Studio** — A multi-agent pipeline for improving response quality: cleanup, fact-checking, entity tracking, and constraint enforcement. *(under development)*

## 🤝 Basic SillyTavern Compatibility

- **Presets** — All JSON presets from SillyTavern are compatible with Glaze. Several popular presets come preinstalled.
- **Advanced Macro System** — Basic macro support is available (full SillyTavern compatibility is in progress). Variables (setvars/getvars), random choices, dice rolls, and character/user data substitution are fully supported.
- **Character Card Compatibility** — Import and export character cards in SillyTavern V2 format (JSON and PNG).
- **Lorebooks (World Info)** — Full support for lorebooks to enhance your roleplay experience.
- **Regex Support** — Full support for regex scripts, including those built into your favorite presets.

## 🧩 Extensions

Glaze includes a sandboxed extension system for post-generation automation and interactive UI blocks.

- **Post-generation blocks** — Run `infoblock`, `imageGen`, `jsRunner`, and `interactive` blocks after assistant messages and after user messages.
- **Interactive panels** — Render extension-owned HTML panels under assistant messages without giving scripts same-origin access to the app.
- **JS extension SDK** — Sandboxed scripts can use `window.glaze.*` APIs for variables, text generation, prompt injection, audio, command execution, toasts, and more.
- **Capability permissions** — Every bridge method is gated by explicit per-preset capabilities. The default is deny.
- **Scoped variables** — Extensions can use `chat`, `character`, `global`, and `message` variable scopes through dedicated storage APIs.

See `docs/ARCHITECTURE.md` section 9 and `docs/INVARIANTS.md` for the bridge architecture and security invariants.

## 📥 Installation

Download the latest release from the [Releases](../../releases) page.

- **Android** — Install the APK directly on your device.
- **iOS** — Sideload the IPA using [AltStore](https://altstore.io/) or a similar tool. App Store distribution is not yet available.
- **Windows** — Download the Windows build and run it directly on your PC.
- **macOS / Linux** — Buildable from source, but not published as prebuilt releases yet; packaging and signing are still to be set up.

Backups from **SillyTavern** (`.zip`) can be imported via **Menu → Backups**.

## 🛠️ Development

Built with Flutter, using local SQLite storage, native desktop support, and a sandboxed extension runtime. Powered by Riverpod, Drift/SQLite, Dio, GoRouter, and a WebView-based chat renderer.

### 📋 Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) 3.44+ (or newer, compatible with Dart 3.12+)
- A toolchain for the platform you want to build — [Android Studio](https://developer.android.com/studio) for Android, Xcode for iOS/macOS, Visual Studio with the C++ desktop workload for Windows
- Git

### 🏗️ Setup

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

### 🚀 Dev Run

```bash
flutter run -d windows   # or: -d android, -d chrome, ...
```

### 🏭 Builds

```bash
flutter build apk        # Android
flutter build windows    # Windows
flutter build ios        # iOS
```

### ⚙️ Code Generation

Drift, Freezed, and JSON-serializable models are generated. After editing any of them:

```bash
dart run build_runner build
```

### 🧪 Tests and Analysis

```bash
flutter analyze
flutter test
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

Primary technical references: `docs/ARCHITECTURE.md`, `docs/INVARIANTS.md`, `docs/rules/`, `docs/WORKFLOW.md`, and `docs/BUILD_NOTES.md` for Windows build and dependency-override context.

## 🙏 Studio References

Glaze Studio was informed by prior work from:

- [Marinara Engine](https://github.com/Pasta-Devs/Marinara-Engine)
- [Lumiverse](https://github.com/prolix-oc/Lumiverse)

## 📜 License

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE).
