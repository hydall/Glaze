/// What this setup carries, stamped in by build_setup.ps1 with the same
/// `--dart-define`s the Glaze build it packs was made with.
library;

const setupChannel = String.fromEnvironment(
  'BUILD_CHANNEL',
  defaultValue: 'nightly',
);
const setupVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.0.0',
);
const setupCommit = String.fromEnvironment('BUILD_COMMIT');

/// One channel of Glaze as Windows sees it: its own folder, Apps entry,
/// shortcut and data — so stable and nightly install side by side, the way
/// they already keep separate data folders.
class Channel {
  final String id;

  const Channel(this.id);

  static const current = Channel(setupChannel);

  bool get isStable => id == 'stable';

  /// Name in Apps, on the shortcut and of the install folder.
  String get appName => switch (id) {
    'stable' => 'Glaze',
    'nightly' => 'Glaze Nightly',
    _ => 'Glaze ($id)',
  };

  /// `%APPDATA%\<this>`: the database, images and logs. The same rule as
  /// `glazeDataFolderName` in the app (lib/core/constants/build_channel.dart).
  String get dataFolder => isStable ? 'Glaze' : 'Glaze-$id';

  /// Key under `HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall`.
  String get uninstallKey => 'com.glaze.$dataFolder';

  /// "0.9.1", or "0.9.1 · a1b2c3d" for a build that is not a release.
  String get versionLabel {
    final short = setupCommit.length >= 7 ? setupCommit.substring(0, 7) : '';
    return isStable || short.isEmpty ? setupVersion : '$setupVersion · $short';
  }
}

/// Program and data folders of the other channels — preferences
/// (`%APPDATA%\com.glaze\Glaze`) are shared by every channel and go only with
/// the last one.
const knownDataFolders = ['Glaze', 'Glaze-nightly'];

/// The legacy Electron build (electron-builder, appId `com.hydall.glaze`)
/// registers this uninstall key — a UUIDv5 of its appId, the same on every
/// machine — and keeps its data in `%APPDATA%\Glaze` too. While it is
/// installed, removing stable never deletes that folder.
const legacyElectronUninstallKey =
    r'Software\Microsoft\Windows\CurrentVersion\Uninstall\6aaa01ad-0320-5b69-a360-2f2e2354fdec';
