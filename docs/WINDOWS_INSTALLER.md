# Windows setup and in-app updates

The Windows build ships two ways: the portable zip it always had, and one
`GlazeSetup.exe` that installs it. The setup is what lets Glaze update itself.

## How the file is made

`GlazeSetup.exe` is three things in one file:

```
[launcher] [setup window, packed] [Glaze build, zip] [64-byte footer]
```

- **Launcher** (`windows/installer/launcher/launcher.cpp`) — a small C++
  program with no UI of its own. It unpacks the setup window into a folder
  under `%TEMP%`, copies the Glaze zip next to it, runs the window with its own
  arguments plus `--package <itself>` and `--payload <zip>`, waits, and deletes
  the folder. The window's files are compressed with the Windows Compression
  API (LZMS), so neither side needs a library. A manifest keeps Windows from
  asking for administrator rights because of the word "Setup" in the name.
- **Setup window** (`windows/installer/app`) — a Flutter app with the app's
  colours, font, spinner and buttons. It does the install, update and
  uninstall itself (`lib/src/engine.dart`) and talks to Windows through
  `reg.exe`, PowerShell and `cmd.exe` (`lib/src/system.dart`), which every
  Windows 10 and 11 has.
- **Glaze build** — the `Release` folder of `flutter build windows`, zipped,
  without any `Glaze.exe.WebView2` profile a local run left in it.

The footer layout is shared by `launcher.cpp` (`Footer`) and
`lib/src/package.dart` (`PackageFooter`); change both together.

## Building it

After `flutter build windows --release`:

```powershell
./windows/installer/build_setup.ps1 -Channel nightly
```

It needs what the Glaze build already needs (Flutter, CMake, Visual Studio C++
tools). `-Channel` must match the `BUILD_CHANNEL` Glaze was built with; the
version comes from `pubspec.yaml`. Output goes to `build/windows/setup/`: the
setup and a `.sha256` next to it. The script checks the result unpacks
(`GlazeSetup.exe --selftest <dir>`) before it is done.

To look at the window without installing anything, run the setup window with
`--demo` (add `--demo-previous 0.9.0`, `--demo-app-open` or `--demo-fail` for
the other pages). It runs on Linux too, for previews: `flutter create
--platforms linux .` in `windows/installer/app` (the folder is gitignored),
copy `assets/fonts/InterVariable.ttf` from the app into its `assets/fonts/`,
then `flutter run -d linux -a --demo`.

In CI:

- `build-release.yml` builds it when **Windows installer** is ticked (on by
  default) and attaches `<tag>-windows-setup.exe` and its `.sha256` to the
  release.
- `build-branch.yml` builds it when **Windows setup** is ticked (on by
  default). On the `nightly` branch, with **Publish as the rolling nightly
  pre-release** ticked, the build replaces the `nightly-build` pre-release —
  see below.
- `ci.yml` analyzes and tests the setup window and compiles the launcher with
  MinGW on every PR.

## What it does

- Installs per user, no administrator rights, into
  `%LOCALAPPDATA%\Programs\com.glaze\<name>` (`Glaze`, `Glaze Nightly`). Not
  `%LOCALAPPDATA%\Programs\Glaze`: the legacy Electron build already lives
  there and its uninstaller deletes that whole folder.
- Each channel is a separate app — own entry in Settings → Apps, own shortcut,
  own folder — matching the per-channel data folders in
  [`RELEASE_CHANNELS.md`](./RELEASE_CHANNELS.md).
- Start menu shortcut always, desktop shortcut as an option (remembered).
- An update installs into the folder the earlier install has, clears `data\`
  (pure build output) first so removed assets do not linger, and waits for a
  running Glaze to close — offering to close it.
- The uninstaller is a copy of the setup without the Glaze build, in
  `uninstall\GlazeSetup.exe`; the Apps entry runs it with `--uninstall`.

Arguments (`lib/src/args.dart`): none for the wizard; `--update` from the
in-app updater (no questions, closes Glaze after 20 s if it has not quit,
starts it again); `--uninstall`, with `--silent` for no window at all (the
data is kept).

## User data

Nothing the user owns is in the files the setup manages:

| What | Where |
|------|-------|
| Database, images, logs | `%APPDATA%\Glaze` or `%APPDATA%\Glaze-nightly` |
| Preferences | `%APPDATA%\com.glaze\Glaze` (shared by all channels) |
| WebView2 profile (catalog logins, cookies) | `<install folder>\Glaze.exe.WebView2` |

Install and update never touch them. Uninstall deletes them only when "Also
delete my data" is ticked (off by default; a silent uninstall never deletes).
The preferences folder goes only when no other channel's data folder is left.
On `stable`, while the legacy Electron app is still installed (its uninstall
key is checked), the data folder is kept and the box is not offered, because
that app uses `%APPDATA%\Glaze` too.

## In-app updates

The update sheet on Windows offers **Install** when the update carries a setup:

- `stable` checks `/releases/latest` and compares versions.
- `nightly` checks the `nightly-build` pre-release and compares its commit
  (`target_commitish`) with the build's own. Builds of other branches still
  point at their Actions run, which cannot be downloaded without a token.

Then:

1. The setup is downloaded only from
   `https://github.com/hydall/Glaze/releases/download/…` (GitHub then
   redirects to its asset CDN).
2. It must match the size and SHA-256 the GitHub API reports for the asset
   (`digest`), or, when there is none, the `.sha256` sidecar. A mismatch
   deletes the file; nothing unchecked is ever run.
3. A copy installed by the setup (`uninstall\GlazeSetup.exe` next to the exe)
   runs it with `--update` and closes; the setup starts Glaze again when it is
   done. A zip copy opens the setup on its first page instead, since an update
   would go to the setup's folder and leave the zip copy as it was.

## The rolling nightly pre-release

Every published nightly build deletes the `nightly-build` release and its tag
and makes them again at the new commit, so the release is dated now and never
piles up. It is a pre-release and never `Latest`: `/releases/latest`, which
the README and the site link to and stable's update check reads, never points
at it, and the site's "All releases" link filters pre-releases out. The tag is
not called `nightly` because git would resolve that name to the tag before the
branch.

The setup is not code-signed, so a browser download shows a SmartScreen
warning on first install. In-app updates are not affected (the file the app
downloads carries no mark-of-the-web).
