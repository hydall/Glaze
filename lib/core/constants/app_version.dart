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

/// Full git SHA the build was produced from. Injected by the CI workflow
/// (`--dart-define=BUILD_COMMIT=<sha>`). Empty for local/dev builds, in which
/// case the update checker cannot diff against the latest CI build.
const buildCommit = String.fromEnvironment('BUILD_COMMIT');

/// Whether the app still presents itself as a beta: the badge in About and the
/// build watermark on by default, `stable` included.
///
/// This used to be derived from a `0.x` version. Calendar versions carry no
/// such signal, so it is a plain switch now — set it to `false` when the app
/// leaves beta.
const isBetaVersion = true;
