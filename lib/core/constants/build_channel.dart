/// Release channel this build was produced for.
///
/// Injected by the CI workflow (`--dart-define=BUILD_CHANNEL=<name>`), which
/// derives it from the branch being built:
///
/// | branch        | channel   |
/// |---------------|-----------|
/// | `stable`      | `stable`  |
/// | `staging`     | `staging` |
/// | `nightly`     | `nightly` |
/// | anything else | `nightly` |
///
/// Defaults to `nightly` so that local developer builds — which never pass the
/// define — behave like an internal build.
///
/// The channel no longer decides whether developer mode is on — that is off by
/// default everywhere and is unlocked through the version-badge easter egg in
/// About. What is left is packaging (data folder, cloud root, update source)
/// and the build-watermark default.
const buildChannel = String.fromEnvironment(
  'BUILD_CHANNEL',
  defaultValue: 'nightly',
);

/// Whether this is a production (`stable`) build.
const isStableChannel = buildChannel == 'stable';

/// Name of the Glaze data folder on desktop (`%APPDATA%\<name>` on Windows,
/// `~/.local/share/<name>` on Linux, `~/Library/Application Support/<name>` on
/// macOS).
///
/// Android and iOS get their separation from the per-channel applicationId /
/// bundle identifier — each package already owns its own sandbox, so the folder
/// inside it stays plain `Glaze`. Desktop builds have no such packaging, so the
/// channel has to be part of the path or two installs would share one database.
///
/// `stable` deliberately keeps the bare `Glaze` name so existing installs are
/// not orphaned by this split.
const glazeDataFolderName = isStableChannel ? 'Glaze' : 'Glaze-$buildChannel';
