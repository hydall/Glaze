# Build Notes

Platform/toolchain gotchas and their workarounds. Loaded on demand.

## `path_provider_foundation` + `objective_c` on Windows

**Symptom:** `flutter build windows` fails while compiling a native asset hook.

**Cause:** Flutter compiles native asset hooks for *all* platforms when building
for one. Older `objective_c` build hooks used Apple-only configuration while
building on Windows and failed before the application was compiled.

**Bug report:** [dart-lang/native#2480](https://github.com/dart-lang/native/issues/2480) — "[hooks] Exclude a platform from being built by dependency's build hook". Open, milestone: Native Assets v1.x.

**Resolved 2026-07-16:** `objective_c 9.4.1` fixed its misconfigured build hook.
The `path_provider` overrides were removed after successfully building Windows
with `path_provider 2.1.6`, `path_provider_foundation 2.6.0`, and
`objective_c 9.4.1` on Flutter 3.44.0.

The general platform-exclusion request remains open in
[dart-lang/native#2480](https://github.com/dart-lang/native/issues/2480), but it
no longer blocks this dependency combination.

## MSVC 14.51+ rejects `<experimental/coroutine>`

**Symptom:** `flutter build windows` fails while compiling Windows plugins with:

```text
error STL1011: The /await compiler option, <experimental/coroutine>,
<experimental/generator>, and <experimental/resumable> are deprecated by
Microsoft and will be REMOVED SOON.
```

**Cause:** Some plugin/native dependencies still include the deprecated MSVC
experimental coroutine header. Visual Studio 18 / MSVC 14.51 promotes that to a
static assertion failure.

**Workaround (active):** `windows/CMakeLists.txt` defines
`_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` globally for the Windows
build. Remove it once all affected Windows plugins stop depending on
`<experimental/coroutine>`.

## `app_settings` 6.1.x breaks iOS build with Xcode 16

**Symptom:** `flutter build ios` fails with:

```
Swift Compiler Error: Main actor-isolated static method 'register(with:)' cannot
be used to satisfy nonisolated requirement from protocol 'FlutterPlugin'
Swift Compiler Error: Main actor-isolated instance method 'handle(_:result:)'
cannot be used to satisfy nonisolated requirement from protocol 'FlutterPlugin'
```

**Cause:** Xcode 16 enforces Swift Concurrency strictly. `app_settings` 6.1.1
marks its plugin class `@MainActor` but `FlutterPlugin` requires `nonisolated`
implementations. Fixed upstream in `app_settings` 6.3.0.

**Fix (applied 2026-06-11):** bumped constraint to `^6.3.0` in `pubspec.yaml`.

## GitHub Actions `windows-latest` redirects to Windows Server 2025

**Symptom:** the Windows release workflow fails during
`subosito/flutter-action@v2` before `flutter pub get` or `flutter build windows`.
The log shows the runner image as `windows-2025` and the notice:

```text
windows-latest requests are being redirected to windows-2025-vs2026
```

**Cause:** GitHub started redirecting `windows-latest` to the Windows Server 2025
image. The Flutter setup/cache step is not reliable there yet for this workflow.

**Workaround (active):** `.github/workflows/build-branch.yml` pins the Windows
job to `windows-2022`. Revisit after `subosito/flutter-action` and the GitHub
Windows 2025 image settle.

## Android release APK: `Tag number over 30 is not supported`

**Symptom:** `flutter build apk --release` in CI fails at `:app:packageRelease`:

```text
com.android.ide.common.signing.KeytoolException: Failed to read key <alias>
from store ".../android/<name>.keystore": Tag number over 30 is not supported
```

**Cause:** the signing keystore is passed to Gradle as a base64 secret. A secret
that does not exist in the repository (e.g. after moving the project to a new
GitHub repo — secrets do not travel with the code, and the new repo used
different secret names) still reaches the build as an **empty string**, not as an
unset variable. The old `if (ks != null)` check in `android/app/build.gradle.kts`
therefore passed, `Base64.decode("")` produced 0 bytes, and a 0-byte keystore was
written and handed to AGP. Loading an empty file as PKCS12 makes the JDK DER
parser read tag `-1`, and `-1 and 0x1f == 0x1f` is reported as *"Tag number over
30 is not supported"* — the message says nothing about the file being empty.

**Signing secrets (repository → Settings → Secrets and variables → Actions):**

| Secret | Gradle env | Purpose |
|---|---|---|
| `ANDROID_KEYSTORE_BASE64` | `KEYSTORE_BASE64` | keystore file, base64 of the raw bytes |
| `ANDROID_STORE_PASSWORD` | `KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | `KEY_ALIAS` | alias of the signing key |
| `ANDROID_KEY_PASSWORD` | `KEY_PASSWORD` | password of that key |

All four are required together; the decoded keystore is written to
`android/ci-signing.keystore` (gitignored). Without `KEYSTORE_BASE64` the build
falls back to the local debug signing config, which is what local builds use.

**Fix (applied 2026-07-26):**
- `android/app/build.gradle.kts` treats a blank `KEYSTORE_BASE64` as "no CI
  keystore", tolerates wrapped base64, always rewrites the keystore file,
  requires the other three values to be non-blank, and verifies that the decoded
  store loads and contains `KEY_ALIAS` — failing with an explicit message
  otherwise.
- Both Android workflows read the `ANDROID_*` secrets (they previously looked
  for a `DEBUG_KEYSTORE_BASE64` secret that no longer exists, with alias and
  passwords hardcoded to `debug-key`/`android`) and gained a `Verify signing
  keystore` step that runs before the ~8-minute Gradle build and reports a
  missing, non-base64 or unreadable secret immediately.

**To (re-)create the base64 secret** from the keystore file:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-key.keystore")) | Set-Clipboard
```

Do not paste the output of `certutil -encode` or a file that was re-saved as
text — either mangles the bytes. If the keystore itself is gone, generate a new
one (`keytool -genkeypair -keystore upload-key.keystore -storetype PKCS12 -alias
<ANDROID_KEY_ALIAS> -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Glaze"`)
and update all four secrets; note that a new key changes the APK signature, so
existing installs must be uninstalled before updating.
