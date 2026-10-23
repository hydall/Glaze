# Windows installer and in-app updates

The Windows build ships two ways: the portable zip it always had, and an
Inno Setup installer (`windows/installer/glaze.iss`). The installer is what
lets Glaze update itself.

## Building it

After `flutter build windows --release`:

```powershell
./windows/installer/build_installer.ps1 -Channel nightly
```

It needs Inno Setup 6 (`winget install JRSoftware.InnoSetup`). The version
comes from `pubspec.yaml`; `-Channel` must match the `BUILD_CHANNEL` the app
was built with. Output goes to `build/windows/installer/`: the setup `.exe`
and a `.sha256` next to it.

In CI, `build-release.yml` builds it when the **Windows installer** input is
ticked (off by default) and attaches both files to the release as
`<tag>-windows-setup.exe` and `<tag>-windows-setup.exe.sha256`.

## What it does

- Installs per user, no administrator rights, into
  `%LOCALAPPDATA%\Programs\com.glaze\<name>` (`Glaze`, `Glaze Nightly`). Not
  `%LOCALAPPDATA%\Programs\Glaze`: the legacy Electron build already lives
  there and its uninstaller deletes that whole folder.
- Each channel is a separate app — own entry in Settings → Apps, own shortcut,
  own folder — matching the per-channel data folders in
  [`RELEASE_CHANNELS.md`](./RELEASE_CHANNELS.md).
- Start menu shortcut always, desktop shortcut as a (pre-ticked) option.
- An update replaces the files and wipes `data\` (pure build output) first, so
  removed assets do not linger.

## User data

Nothing the user owns is inside the files the installer manages:

| What | Where |
|------|-------|
| Database, images, logs | `%APPDATA%\Glaze` or `%APPDATA%\Glaze-nightly` |
| Preferences | `%APPDATA%\com.glaze\Glaze` (shared by all channels) |
| WebView2 profile (catalog logins, cookies) | `<install folder>\Glaze.exe.WebView2` |

Install and update never touch them. Uninstall asks whether to delete them,
defaulting to **No**; a silent uninstall never deletes. The preferences folder
goes only when no other channel's data folder is left. On `stable`, when the
legacy Electron app is still installed (its uninstall key is checked), the
data folder is kept without asking, because that app uses `%APPDATA%\Glaze`
too.

## In-app updates

`stable` builds check `/releases/latest` (`UpdateCheckService`). When the
release carries an asset ending in `-windows-setup.exe`, the update sheet on
Windows offers **Install**:

1. The installer is downloaded only from
   `https://github.com/hydall/Glaze/releases/download/…` (GitHub then
   redirects to its asset CDN).
2. It must match the size and SHA-256 the GitHub API reports for the asset
   (`digest`), or, when there is none, the `.sha256` sidecar. A mismatch
   deletes the file; nothing unchecked is ever run.
3. A copy that was installed by the installer (`unins000.exe` next to the exe)
   runs it with `/VERYSILENT /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS /NORESTART
   /RELAUNCH=1` and closes; setup starts Glaze again when it is done. A zip
   copy opens the normal wizard instead, since a silent install would go
   elsewhere and leave the zip copy as it was.

The nightly channel still points at the Actions run: Actions artifacts cannot
be downloaded without a GitHub token, so there is nothing for the app to fetch.
Publishing nightly builds as pre-releases with the installer attached would
change that.

The installer is not code-signed, so a browser download of it shows a
SmartScreen warning on first install. In-app updates are not affected (the
file the app downloads carries no mark-of-the-web).
