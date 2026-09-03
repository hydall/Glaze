# Glaze

Native LLM frontend for AI roleplay. Flutter rewrite of the original Vue + Capacitor
app, which is archived on the `legacy-vue` branch.
**Stack:** Flutter 3.44 + Riverpod 3 + Drift (SQLite) + GoRouter. **Language:** Dart only. **License:** AGPL-3.0.

Architecture: `docs/ARCHITECTURE.md`. Workflow (git, PRs, Trello): `docs/WORKFLOW.md`.

## Commands

Flutter and Dart must be available on `PATH`. Alternatively, set
`FLUTTER_ROOT` to the local Flutter SDK directory.

```powershell
# Preferred — try PATH first:
flutter analyze

# Optional PowerShell fallback when FLUTTER_ROOT is set:
& "$env:FLUTTER_ROOT\bin\flutter.bat" <subcommand>
```

Full examples:

```powershell
flutter analyze                          # Lint + typecheck
flutter analyze lib/foo.dart             # Analyze single file
flutter test                             # Run all tests
flutter test test/bar_test.dart          # Run single test file
flutter build windows                    # Production build
dart run build_runner build              # Regenerate after editing freezed/drift models

# Same commands via FLUTTER_ROOT (fallback if Flutter is not on PATH):
& "$env:FLUTTER_ROOT\bin\flutter.bat" analyze
& "$env:FLUTTER_ROOT\bin\flutter.bat" test
& "$env:FLUTTER_ROOT\bin\flutter.bat" test test/bar_test.dart
& "$env:FLUTTER_ROOT\bin\flutter.bat" build windows
& "$env:FLUTTER_ROOT\bin\dart.bat" run build_runner build
```

For `flutter run` (dev server), see below — the agent cannot run it.

**`flutter run` is unavailable to the agent because it is long-running and
interactive.** Use only one-shot commands such as:

- `flutter analyze`
- `flutter test`
- `dart run build_runner build --delete-conflicting-outputs`
- `dart run easy_localization:generate -S assets/translations -s en.json -f keys -o locale_keys.g.dart`

Fall back to `& "$env:FLUTTER_ROOT\bin\flutter.bat"` if `flutter` is not on
`PATH`. If runtime or hot-reload verification is required, ask the user to run
`flutter run -d <platform>` in a separate terminal and report the result.

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
- **Build on the Glaze UI kit** (`lib/shared/widgets/`) — `GlazeScaffold`, `SheetView` / `GlazeBottomSheet`, `GlazeTabBar`, `GlassSurface`, `MenuGroup`, `GlazeToast`… Reach for bare Material only when the kit has no equivalent. What-instead-of-what table: `docs/UI_KIT.md`
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
- Light, dark, and system theme modes are supported; each theme preset can also select its preferred mode
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
| Message rendering — `assets/chat_webview/formatter/`, `renderer/` | `docs/rules/message-rendering.md` + `docs/INVARIANTS.md` (INV-MR1–8) |
| Custom `==...==` markdown markers | `docs/markdown-markers.md` |
| Windows/build failures, dependency overrides | `docs/BUILD_NOTES.md` |
| Class/file organization, decomposition | `docs/CODE_STYLE.md` |
| Any screen, sheet or dialog — which widget to reach for | `docs/UI_KIT.md` |
| JS extension bridge (`glaze.*`), panel iframe, headless engine, capability permissions, periodic/afterUser triggers, `executeCommand`, audio, connection profiles | `docs/ARCHITECTURE.md` § 9 + `docs/INVARIANTS.md` (INV-EG1–8, INV-JS1–6) |
| Variable storage (`chat` / `character` / `global` / `message` scopes) | `docs/rules/database.md` (atomic repo methods) |
| Build channels, dev-mode / watermark defaults, `--dart-define` wiring | `docs/RELEASE_CHANNELS.md` |

## Workflow

- Branch (`feat/xxx`) off `nightly`, push to `origin`, open a PR — see `docs/WORKFLOW.md` for branching, Trello, and cleanup checklists.
- **Feature branches are always based on `nightly`** — `stable` is the default branch, so a fresh clone starts there; check the base first, and `git rebase origin/nightly` a branch that was cut from the wrong one before opening the PR.
- Open PRs only against upstream repository `hydall/Glaze` (base: `hydall/Glaze:nightly`), not against fork repos.
- PR title and body are **in English**, and the body lists the changes as bullets (one bullet per change, `##` headings when a PR carries several independent fixes) plus how it was verified. Full rules: `docs/WORKFLOW.md` § PR title and body.
- PRs are squash-merged and gated on CI (`.github/workflows/ci.yml` — `flutter analyze` + `flutter test` + the WebView render suite in `test/webview_js`); a red check blocks the merge.
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
- Build a screen or sheet on bare Material (`TabBar`, `Card`, `OutlinedButton`, `Chip`, `SnackBar`, `AlertDialog`…) when `lib/shared/widgets/` has the Glaze equivalent — check `docs/UI_KIT.md` first
- Commit directly to `nightly`, `staging` or `stable` — always use a feature branch
- Bypass `_requireCapability` in the JS bridge — every `glaze.*` method must enforce the matching capability (default-deny)
- Run user JS in a same-origin iframe — panel/sandbox scripts go in `sandbox="allow-scripts"` (no `allow-same-origin`)
- Read-modify-write a `ChatSession` / `Character` from outside the dedicated atomic repo methods (chat/character variable scopes)
