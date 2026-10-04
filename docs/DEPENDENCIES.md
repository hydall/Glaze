# Dependency Baseline

This document describes the maintained dependency baseline. It is not an
upgrade plan for a particular branch.

## Sources of truth

- `pubspec.yaml` defines direct dependency constraints and SDK requirements.
- `pubspec.lock` defines the versions resolved for the repository.
- `.github/workflows/ci.yml` defines the required generated artifacts and the
  analyzer/test commands used by CI.
- `docs/BUILD_NOTES.md` records platform-specific constraints and workarounds.

Do not copy version or test-count snapshots into planning documents. Read the
current lockfile and current test output instead.

## Baseline commands

Run these from the repository root after changing dependencies. Code and
localization generation are required because generated files are gitignored
and recreated in CI.

```powershell
flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart run easy_localization:generate -S assets/translations -s en.json -f keys -o locale_keys.g.dart
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test --reporter expanded
```

`-s en.json` is required, not decorative: in `keys` format the generator reads
`files.first` from a bare `Directory.list()` of the source folder
(easy_localization 3.0.8, `bin/generate.dart`), which is filesystem order. The
glossary files live in that folder too, so without naming the source file the
run sometimes generates `LocaleKeys` from `glossary_en.json` — one key — and
the localization contract test fails on a diff that never touched translations.

Build every affected target platform that is available in the verification
environment. Glaze targets Windows, Android, iOS, macOS, and Linux; web is not
supported. Typical one-shot checks include:

```powershell
flutter build windows
flutter build apk --debug
flutter build ios --no-codesign
flutter build macos
flutter build linux
```

Only run builds relevant to the dependency or platform files changed. Apple
builds require macOS, Linux builds require Linux, and Windows builds require
Windows with the configured native toolchain.

## Locked versions

Always verify the full resolved graph in `pubspec.lock`. Selected dependencies
that commonly affect migrations or platform integration currently resolve to:

| Package | Locked version |
|---|---:|
| `build_runner` | 2.15.0 |
| `freezed` | 3.2.5 |
| `freezed_annotation` | 3.1.0 |
| `drift` / `drift_dev` | 2.33.0 |
| `flutter_riverpod` / `riverpod` | 3.3.2 / 3.3.2 |
| `go_router` | 17.3.0 |
| `app_links` | 7.2.1 |
| `flutter_dotenv` | 6.0.1 |
| `flutter_local_notifications` | 22.0.1 |
| `sqlite3_flutter_libs` | 0.6.0+eol |
| `share_plus` | 12.0.2 |
| `file_picker` | 11.0.2 |
| `image` | 4.9.1 |
| `gpt_markdown` | 1.1.8 |
| `path_provider` | 2.1.6 |
| `path_provider_foundation` | 2.6.0 |

## Upgrade policy

- Upgrade one package or one tightly related package group at a time.
- Inspect `flutter pub outdated` and upstream changelogs before changing
  constraints; do not force transitive analyzer/test packages without a reason.
- Run the complete baseline after each dependency batch, plus focused tests and
  affected platform builds.
- Keep dependency upgrades separate from unrelated architecture refactors when
  practical.
- Never commit generated `.freezed.dart`, `.g.dart`, or localization key files
  when they are gitignored, but always regenerate them for verification.

## Historical migration status

The Freezed 3, GoRouter 17, and Riverpod 3 migrations, the Android wrapper
restoration, and removal of the old `path_provider` overrides are historical
completed work. They are not gates or a prescribed migration order for current
branches. See repository history and `docs/BUILD_NOTES.md` when investigating
those changes.

If package resolution or code generation shows evidence of a corrupted Pub
cache, use `dart pub cache repair`, then rerun `flutter pub get`. Destructive
cache deletion is a last resort, not a normal baseline step.
