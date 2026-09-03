/// When this app process started.
///
/// The Requests tab scopes itself to "since the app started" — request captures
/// live in the database and outlive a restart, so a wall-clock cut is the only
/// thing that separates this run's traffic from the previous one's. Stamped
/// from `main()` so it is the process start, not the first time something
/// happened to read it.
abstract final class AppRuntime {
  static DateTime? _startedAt;

  /// Called once from `main()`. Later calls are ignored, so a hot restart in
  /// development keeps the original stamp rather than resetting the window.
  static void markStarted() => _startedAt ??= DateTime.now();

  static DateTime get startedAt => _startedAt ??= DateTime.now();

  static int get startedAtMs => startedAt.millisecondsSinceEpoch;
}
