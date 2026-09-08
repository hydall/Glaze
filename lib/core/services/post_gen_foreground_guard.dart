/// Runs a bounded post-generation operation while holding the platform
/// foreground service. The release callback is guaranteed to run after a
/// successful acquire, even when [action] throws.
Future<T> runWithPostGenForeground<T>({
  required Future<void> Function() onStarted,
  required Future<T> Function() action,
  required Future<void> Function() onFinished,
}) async {
  await onStarted();
  try {
    return await action();
  } finally {
    await onFinished();
  }
}
