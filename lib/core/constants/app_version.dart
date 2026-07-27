const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.7.0');
const buildDate = String.fromEnvironment('BUILD_DATE');
const buildBranch = String.fromEnvironment('BUILD_BRANCH');

/// Full git SHA the build was produced from. Injected by the CI workflow
/// (`--dart-define=BUILD_COMMIT=<sha>`). Empty for local/dev builds, in which
/// case the update checker cannot diff against the latest CI build.
const buildCommit = String.fromEnvironment('BUILD_COMMIT');

bool get isBetaVersion {
  final parts = appVersion.split('.');
  if (parts.isEmpty) return false;
  final major = int.tryParse(parts.first);
  return major != null && major == 0;
}
