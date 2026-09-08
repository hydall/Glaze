# Dependency Upgrade Plan

Актуально для ветки `feat/freezed-3x-migration` после восстановления Robocopy-corruption и `dart pub cache repair`.
Flutter SDK: `Z:\GlazeProject\flutter`. Dart/Flutter версии см. в локальном SDK и `pubspec.lock`.

## Текущий baseline

Перед дальнейшими dependency upgrades baseline должен оставаться зелёным:

```powershell
& "Z:\GlazeProject\flutter\bin\flutter.bat" pub get
& "Z:\GlazeProject\flutter\bin\dart.bat" run build_runner build
& "Z:\GlazeProject\flutter\bin\flutter.bat" analyze
& "Z:\GlazeProject\flutter\bin\flutter.bat" test
```

Последняя проверка после `dart pub cache repair`:

| Проверка | Статус | Примечание |
|---|---:|---|
| `flutter pub get` | pass | `path_provider` overrides removed after Windows verification |
| `dart run build_runner build` | pass | build_runner не зависает, генерация проходит |
| `flutter analyze` | pass with warnings | errors нет, остаются существующие warnings/info |
| `flutter test` | pass | 712 tests passed |
| `flutter build apk --debug` | pass | Android wrapper restored via `flutter create --platforms=android .`; APK built |
| `flutter build windows` | pass | MSVC 14.51 coroutine deprecation suppressed in `windows/CMakeLists.txt`; release exe built |

Если снова появляются странные ошибки пакетов или codegen, сначала восстановить Pub cache:

```powershell
& "Z:\GlazeProject\flutter\bin\dart.bat" pub cache repair
& "Z:\GlazeProject\flutter\bin\flutter.bat" pub get
```

Жёсткий вариант только при повторной corruption cache:

```powershell
Remove-Item -LiteralPath "Z:\Pub\Cache\hosted" -Recurse -Force
& "Z:\GlazeProject\flutter\bin\flutter.bat" pub get
```

## Текущие ключевые версии

Полный список всегда проверять по `pubspec.lock`. Ниже только пакеты, важные для миграции.

| Пакет | Текущая версия | Статус |
|---|---:|---|
| `build_runner` | 2.15.0 | done |
| `freezed` | 3.2.5 | done |
| `freezed_annotation` | 3.1.0 | done |
| `drift` / `drift_dev` | 2.33.0 | latest stable на момент проверки |
| `flutter_riverpod` / `riverpod` | 3.3.1 / 3.2.1 | done |
| `go_router` | 17.3.0 | done |
| `app_links` | 7.1.1 | done |
| `flutter_dotenv` | 6.0.1 | done |
| `sqlite3_flutter_libs` | 0.6.0+eol | done |
| `share_plus` | 12.0.2 | done |
| `file_picker` | 11.0.2 | latest stable; prerelease 12.0.0-beta.5 deferred |
| `image` | 4.9.1 | done |
| `gpt_markdown` | 1.1.7 | patched, `imageBuilder` API changed |
| `path_provider` | 2.1.6 | done |
| `path_provider_foundation` | 2.6.0 | done; `objective_c 9.4.1` verified on Windows |

## Resolved Override

The exact `path_provider 2.1.5` and `path_provider_foundation 2.4.2` overrides
were removed on 2026-07-16. A Windows release build passes with
`path_provider 2.1.6`, `path_provider_foundation 2.6.0`, and
`objective_c 9.4.1`. See `docs/BUILD_NOTES.md` for the original failure.

## Working Migration Order

Не делать один большой `flutter pub upgrade --major-versions`. Обновлять маленькими партиями и после каждой партии прогонять baseline checks.

### 0. Stabilization Gate

Статус: done в текущей ветке.

Цель этапа:

| Задача | Статус |
|---|---:|
| Восстановить Pub cache | done |
| Подтвердить `build_runner build` | done |
| Починить текущие analyze errors | done |
| Починить WebView/navigation smoke failures | done |
| Подтвердить полный `flutter test` | done |

Новые dependency upgrades начинаются только от этого состояния.

### 1. Safe Minor/Patch Batch

Цель: обновить низкорисковые пакеты без архитектурных миграций.

Кандидаты из `flutter pub outdated` после cache repair:

| Пакет | Current | Resolvable/Latest | Риск |
|---|---:|---:|---|
| `image` | 4.9.1 | 4.9.1 | done; image storage/export tests pass |
| `test_api` | 0.7.11 | 0.7.12 | low, обычно транзитивно |
| `meta` | 1.18.0 | 1.18.3 | low, транзитивно |
| `matcher` | 0.12.19 | 0.12.20 | low, транзитивно |

Команда-кандидат:

```powershell
& "Z:\GlazeProject\flutter\bin\flutter.bat" pub upgrade image
```

Не форсировать транзитивные test/analyzer пакеты вручную без причины.

### 2. `go_router` 14.8.1 -> 17.x

Status: done. Upgraded to `17.3.0`; `flutter analyze`, `test/navigation_smoke_test.dart`, and full `flutter test` pass.

Приоритет: medium. Делать до Riverpod, потому что router scope меньше и navigation tests уже покрывают критичный путь.

Перед правками читать:

| Файл | Причина |
|---|---|
| `docs/ARCHITECTURE.md` | navigation architecture and sub-screen back button invariant |
| `lib/core/navigation/router.dart` | single source of GoRouter setup |
| `test/navigation_smoke_test.dart` | regression coverage |

Проверить changelog `go_router` для 15.x, 16.x, 17.x. Особое внимание:

| Зона | Что проверить |
|---|---|
| `StatefulShellRoute` | API and branch behavior |
| `GoRouter.onException` | signature and redirect behavior |
| `GoRouterState.uri` | API compatibility |
| `context.go` / `context.push` | behavior with shell and standalone routes |
| `routerProvider` tests | fresh `GlobalKey<NavigatorState>` per test |

Verification for this batch:

```powershell
& "Z:\GlazeProject\flutter\bin\flutter.bat" analyze
& "Z:\GlazeProject\flutter\bin\flutter.bat" test test/navigation_smoke_test.dart
& "Z:\GlazeProject\flutter\bin\flutter.bat" test
```

### 3. `flutter_riverpod` 2.6.1 -> 3.x

Status: done. Upgraded to `flutter_riverpod 3.3.1` / `riverpod 3.2.1`; `flutter analyze`, `test/navigation_smoke_test.dart`, `test/trigger_generation_test.dart`, and full `flutter test` pass.

Приоритет: medium/high только после зелёного `go_router` batch.

Важно: не смешивать upgrade to Riverpod 3 с переходом на `@riverpod` code generation. Сначала сохранить ручные providers, если API позволяет.

Основные зоны риска:

| Зона | Примеры |
|---|---|
| `AsyncNotifierProvider` | DB-backed lists, chat state |
| `StateNotifierProvider` | theme/settings/catalog/extensions state |
| `StateProvider.family` | streaming state and UI state |
| `ProviderContainer` tests | overrides and disposal behavior |
| `ref.listen` side effects | chat/webview/build listeners |

Поиск перед миграцией:

```powershell
rg "AsyncNotifierProvider|StateNotifierProvider|StateProvider|FutureProvider|ProviderContainer|ref\.listen|\.notifier" lib test
```

Verification for this batch:

```powershell
& "Z:\GlazeProject\flutter\bin\flutter.bat" analyze
& "Z:\GlazeProject\flutter\bin\flutter.bat" test test/navigation_smoke_test.dart
& "Z:\GlazeProject\flutter\bin\flutter.bat" test test/trigger_generation_test.dart
& "Z:\GlazeProject\flutter\bin\flutter.bat" test
```

### 4. Platform/Runtime Major Packages

Делать только после router/Riverpod или в отдельных ветках, если нужны срочно.

| Пакет | Current | Latest | Notes |
|---|---:|---:|---|
| `app_links` | 7.1.1 | 7.1.1 | done; source-compatible, analyze/test pass |
| `flutter_dotenv` | 6.0.1 | 6.0.1 | done; `.env` load API source-compatible, analyze/test pass |
| `flutter_foreground_task` | 9.2.2 | 9.2.2 | done; Android foreground service compiles, analyze/test/Android debug build pass |
| `flutter_local_notifications` | 22.0.0 | 22.0.0 | done; named-argument API migrated, analyze/test/Android debug build pass |
| `share_plus` | 12.0.2 | 13.1.0 | done to highest stable/resolvable without prerelease dependencies; migrated to `SharePlus.instance.share`, AGP 8.12.1; Android debug build pass after wrapper restore |
| `file_picker` | 11.0.2 | 12.0.0-beta.5 | latest stable; beta only considered together with `share_plus` 13.x |
| `sqlite3_flutter_libs` | 0.6.0+eol | 0.6.0+eol | done; no Dart API usage, analyze/test pass |

Do not batch all of these together. One package or one tightly related group per commit.

### 5. Deferred/Blocked

| Item | Status | Rule |
|---|---|---|
| `path_provider_foundation` override removal | done | Windows release build verified with `objective_c 9.4.1` |
| `share_plus` 13.x | deferred | only resolves with prerelease `file_picker 12.0.0-beta.5` today; wait for stable `file_picker` compatibility with `win32 ^6` or test as a separate beta-risk batch |
| `drift` 3.x | unavailable | revisit when stable release exists |
| Riverpod code generation migration | deferred | separate refactor after Riverpod 3 works manually |

## Commit Strategy

Use small commits with one purpose each:

| Commit | Contents |
|---|---|
| stabilization | analyze/test fixes, WebView guard restoration |
| safe dependency batch | low-risk package updates only |
| go_router migration | router code and tests |
| riverpod migration | provider compatibility updates |
| platform package migration | one platform package group |
| docs | update this file and build notes as needed |

Never commit generated `.freezed.dart` / `.g.dart` files if they are gitignored. Still run `build_runner build` after changing freezed/drift/json models.

## PR Checklist

Before opening or updating the PR:

```powershell
git status --short --branch
& "Z:\GlazeProject\flutter\bin\flutter.bat" pub get
& "Z:\GlazeProject\flutter\bin\dart.bat" run build_runner build
& "Z:\GlazeProject\flutter\bin\flutter.bat" analyze
& "Z:\GlazeProject\flutter\bin\flutter.bat" test
& "Z:\GlazeProject\flutter\bin\flutter.bat" build windows
& "Z:\GlazeProject\flutter\bin\flutter.bat" pub outdated
```
