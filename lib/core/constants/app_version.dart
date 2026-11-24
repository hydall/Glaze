import 'build_channel.dart';

/// Release version, `YY.M.N` (year, month, release number in that month).
///
/// CI computes it from the release tags (`.github/scripts/calver.sh`) and
/// passes it in; it is never bumped by hand. The default only shows in local
/// builds.
const appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '26.11.0',
);
const buildDate = String.fromEnvironment('BUILD_DATE');
const buildBranch = String.fromEnvironment('BUILD_BRANCH');

/// Whether the build branch is worth showing (watermark, About). A main-branch
/// build is the public release, where the version alone identifies it; the
/// branch only tells nightly and feature builds apart.
const showBuildBranch = buildBranch != '' && !isStableChannel;

/// Full git SHA the build was produced from. Injected by the CI workflow
/// (`--dart-define=BUILD_COMMIT=<sha>`). Empty for local/dev builds, in which
/// case the update checker cannot diff against the latest CI build.
const buildCommit = String.fromEnvironment('BUILD_COMMIT');
