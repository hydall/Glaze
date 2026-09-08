/// Release channel this build was produced for.
///
/// Injected by the CI workflow (`--dart-define=BUILD_CHANNEL=<name>`), which
/// derives it from the branch being built:
///
/// | branch    | channel   | dev tooling |
/// |-----------|-----------|-------------|
/// | `stable`  | `stable`  | off         |
/// | `staging` | `staging` | on          |
/// | `nightly` | `nightly` | on          |
/// | anything else       | `nightly` | on |
///
/// Defaults to `nightly` so that local developer builds — which never pass the
/// define — keep the dev tooling switched on.
const buildChannel = String.fromEnvironment(
  'BUILD_CHANNEL',
  defaultValue: 'nightly',
);

/// Whether this is a production (`stable`) build.
const isStableChannel = buildChannel == 'stable';

/// Whether this build ships developer tooling turned on out of the box.
///
/// Drives the *defaults* of `devModeProvider` and `hideBuildWatermarkProvider`
/// only — on every channel the user's own choice, once made, still wins, and
/// the version-badge easter egg can unlock dev mode on a stable build too.
const devToolingEnabledByDefault = !isStableChannel;

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
