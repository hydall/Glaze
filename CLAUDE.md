# Glaze

Native LLM frontend for AI roleplay. Flutter rewrite of the original Vue + Capacitor
app, which is archived on the `legacy-vue` branch.
**Stack:** Flutter 3.44 + Riverpod 2 + Drift (SQLite) + GoRouter. **Language:** Dart only. **License:** AGPL-3.0.

Architecture: `docs/ARCHITECTURE.md`. Workflow (git, PRs, Trello): `docs/WORKFLOW.md`.

## Commands

Flutter SDK is at `Z:\GlazeProject\flutter`. The agent's shell may not have `flutter` on PATH. Try `flutter` first; if it fails with "not recognized", fall back to the full path.

```powershell
# Preferred — try PATH first:
flutter analyze

# Fallback if flutter is not on PATH:
& "Z:\GlazeProject\flutter\bin\flutter.bat" <subcommand>
```

Full examples:

```powershell
flutter analyze                          # Lint + typecheck
flutter analyze lib/foo.dart             # Analyze single file
flutter test                             # Run all tests
flutter test test/bar_test.dart          # Run single test file
flutter build windows                    # Production build
dart run build_runner build              # Regenerate after editing freezed/drift models

# Same commands via full path (fallback if flutter not on PATH):
& "Z:\GlazeProject\flutter\bin\flutter.bat" analyze
& "Z:\GlazeProject\flutter\bin\flutter.bat" test
& "Z:\GlazeProject\flutter\bin\flutter.bat" test test/bar_test.dart
& "Z:\GlazeProject\flutter\bin\flutter.bat" build windows
& "Z:\GlazeProject\flutter\bin\dart.bat" run build_runner build
```

For `flutter run` (dev server), see below — the agent cannot run it.

**`flutter run` and `flutter test --watch` are permanently unavailable to the agent.**

Reason: both commands are **long-running / blocking**. `flutter run` starts a persistent dev server and keeps the terminal occupied until the app is manually closed. The agent session would freeze indefinitely, unable to continue any work, issue further commands, or report results.

Only run one-shot, non-interactive commands:
- `flutter analyze` (with optional file path argument)
- `flutter test` (non-watch, one-shot)
- `dart run build_runner build` when required

(Fall back to the full `& "Z:\GlazeProject\flutter\bin\flutter.bat"` path if `flutter` is not on PATH.)

If you need to verify runtime behavior or hot-reload changes, ask the user to run `flutter run -d <platform>` in a separate terminal and report back. The agent cannot drive or observe a live Flutter session.

Web is **not** a target platform — `lib/` imports `dart:io` without conditional stubs, and Drift/`sqlite3_flutter_libs`, `photo_manager` and the WebView bridge have no web support. Target Windows, Android, iOS, macOS or Linux.

**Hot restart after JS asset changes:**
When files in `assets/chat_webview/` are modified, the user must **hot restart** (press `R`). Hot reload (`r`) doesn't rebuild the asset bundle.

## Diagnostic error capture commands (PowerShell — user terminal)

Run these from the project root in **your PowerShell terminal**. These are for the user's convenience; the agent runs `flutter analyze`/`flutter test` directly via the bat file.

These commands:
- Run `flutter analyze` / `flutter test`
- Keep **only build-crashing errors** (or test failures) — warnings/hints are filtered out
- Overwrite `analyze_errors.txt` / `test_failures.txt` on every run (the files are gitignored, see `.gitignore`)
- Print the result in the terminal so you can easily select & copy

**Analyze — only errors that would crash a build + final count:**

```powershell
flutter analyze 2>&1 | Select-String -Pattern '^(error|• error|\d+ errors)' | Set-Content -Path analyze_errors.txt -Encoding UTF8; Get-Content analyze_errors.txt
```

**Tests — failures + summary:**

```powershell
flutter test 2>&1 | Select-String -Pattern '(FAIL|error|failed|^\d+ tests? failed|^\d+ passing)' | Set-Content -Path test_failures.txt -Encoding UTF8; Get-Content test_failures.txt
```

After running the command, just tell the agent:
- "Прочитай analyze_errors.txt"
- "Прочитай test_failures.txt"

The agent will read the file from the workspace root using its tools and can then analyze/fix the issues.

If you ever want the **full** raw output (including warnings), use:

```powershell
flutter analyze 2>&1 | Tee-Object -FilePath analyze_full.txt -Encoding UTF8; Get-Content analyze_full.txt
```

(And the same pattern for `flutter test` → `test_full.txt`.)

## Code Conventions

### Flutter Widgets
- **ConsumerWidget / ConsumerStatefulWidget** for anything that reads Riverpod
- **StatelessWidget / StatefulWidget** for pure UI with no state
- Keep widgets small — extract sub-widgets when > 200 lines
- Use `const` constructors everywhere possible

### State Management
- **Riverpod** only — no Provider, no BLoC, no GetX
- **AsyncNotifierProvider** for data from DB
- **StateProvider / NotifierProvider** for UI state
- **ref.watch** for rebuild, **ref.listen** for side effects, **ref.read** for callbacks
- Use `ref.watch(provider.select(...))` for granular rebuilds during streaming

### Navigation
- **GoRouter** for route definitions
- Named routes: `/`, `/chat/:charId`, `/settings/api`
- **Sub-screens need an explicit back button** — `leading: BackButton(onPressed: () => context.go('/parent'))` — GoRouter `go()` replaces the stack and won't add one automatically

### File Naming
| Type | Convention | Example |
|------|-----------|---------|
| Screens | snake_case + `_screen.dart` | `character_list_screen.dart` |
| Widgets | snake_case | `chat_bubble.dart` |
| Models | snake_case | `character.dart`, `chat_message.dart` |
| Providers | snake_case + `_provider.dart` | `character_provider.dart` |
| Repositories | snake_case + `_repo.dart` | `character_repo.dart` |
| Services | snake_case + `_service.dart` | `prompt_builder_service.dart` |

### Theme
- Material 3 with `colorSchemeSeed`
- Dark theme only for MVP
- Colors in `lib/shared/theme/app_colors.dart`
- Theme in `lib/shared/theme/app_theme.dart`

## Storage

| Data | Backend | Pattern |
|------|---------|---------|
| Characters | Drift `Characters` table | Repository |
| Chat sessions | Drift `ChatSessions` table | Repository |
| Presets | Drift `Presets` table | Repository |
| API config | Drift `ApiConfigs` table | Repository |
| Personas | Drift `Personas` table | Repository |
| Images | File system (`dart:io` Platform) | Image storage service |

## Architecture Layers

```
UI (screens/widgets)
  → Riverpod providers (state + business logic)
    → Repositories (DB abstraction)
      → Drift / SQLite (persistence)
    → Services (LLM, prompt builder, macro engine)
      → Dio (HTTP/SSE)
```

## Context-Sensitive Rules

When editing files matching a pattern below, READ the corresponding rule file FIRST:

| When editing... | Read this |
|----------------|-----------|
| Generation, transport, streaming, abort | `docs/rules/generation.md` |
| Any async boundary, DB writes | `docs/rules/race-conditions.md` |
| Drift reads/writes, repositories | `docs/rules/database.md` |
| Architecture details, full flow | `docs/ARCHITECTURE.md` |
| Formal invariants with code references | `docs/INVARIANTS.md` |
| Custom `==...==` markdown markers, message rendering | `docs/markdown-markers.md` |
| Windows/build failures, dependency overrides | `docs/BUILD_NOTES.md` |
| Class/file organization, decomposition | `docs/CODE_STYLE.md` |
| JS extension bridge (`glaze.*`), panel iframe, headless engine, capability permissions, periodic/afterUser triggers, `executeCommand`, audio, connection profiles | `docs/ARCHITECTURE.md` § 9 + `docs/INVARIANTS.md` (INV-EG1–8, INV-JS1–6) |
| Variable storage (`chat` / `character` / `global` / `message` scopes) | `docs/rules/database.md` (atomic repo methods) |
| Build channels, dev-mode / watermark defaults, `--dart-define` wiring | `docs/RELEASE_CHANNELS.md` |

## Workflow

- Branch (`feat/xxx`) off `nightly`, push to `origin`, open a PR — see `docs/WORKFLOW.md` for branching, Trello, and cleanup checklists.
- Open PRs only against upstream repository `hydall/Glaze` (base: `hydall/Glaze:nightly`), not against fork repos.
- PR title and body are **in English**, and the body lists the changes as bullets (one bullet per change, `##` headings when a PR carries several independent fixes) plus how it was verified. Full rules: `docs/WORKFLOW.md` § PR title and body.
- PRs are squash-merged and gated on CI (`.github/workflows/ci.yml` — `flutter analyze` + `flutter test`); a red check blocks the merge.
- Release branches are `nightly` → `staging` → `stable`, one per build channel; features enter at `nightly` and are promoted by merge. Channel semantics: `docs/RELEASE_CHANNELS.md`.
- Run `dart run build_runner build` after changing any freezed/drift model.
- Single responsibility: split a class before it grows past ~200-250 lines (thin orchestrators, fat specialists, constructor injection). Details: `docs/CODE_STYLE.md`.

## Do NOT

- Add Provider/BLoC/GetX — Riverpod only
- Use WebSocket for LLM streaming (SSE only)
- Break SillyTavern V2 format compatibility for character cards
- Store API keys in plain text in Drift
- Mutate state directly — use immutable patterns with freezed
- Forget `ref.watch` select for streaming UI (causes full rebuild per chunk)
- Commit directly to `nightly`, `staging` or `stable` — always use a feature branch
- Use the `gh` CLI — GitHub operations go through GitHub MCP tools
- Bypass `_requireCapability` in the JS bridge — every `glaze.*` method must enforce the matching capability (default-deny)
- Run user JS in a same-origin iframe — panel/sandbox scripts go in `sandbox="allow-scripts"` (no `allow-same-origin`)
- Read-modify-write a `ChatSession` / `Character` from outside the dedicated atomic repo methods (chat/character variable scopes)
