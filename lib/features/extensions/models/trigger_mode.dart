/// How a JS `glaze.triggerGeneration(...)` call should be resolved into a
/// real `ChatNotifier` action.
enum TriggerMode {
  /// Append to the last assistant message. Maps to
  /// `ChatNotifier.continueMessage()`.
  continueGeneration,

  /// Replace the last assistant message. Maps to
  /// `ChatNotifier.regenerateLastAssistant()`. Aborts any in-flight
  /// generation first (INV-A3).
  regenerate,

  /// Pick the most appropriate mode for the current tail of the chat:
  ///   - last message is `assistant` → `continue`
  ///   - last message is `user` (or empty) → `regenerate`-like send
  ///     (`regenerateLastAssistant` covers the user-tail case as well —
  ///     see its body for the "last user → new generation" branch).
  ///
  /// This mirrors what most users expect when they press "regenerate" in a
  /// chat app.
  auto;

  /// Parses a JS-supplied mode string. Unknown / null values fall back to
  /// [auto]. Comparison is case-insensitive.
  static TriggerMode parse(String? raw) {
    if (raw == null) return TriggerMode.auto;
    switch (raw.trim().toLowerCase()) {
      case 'continue':
        return TriggerMode.continueGeneration;
      case 'regenerate':
        return TriggerMode.regenerate;
      case 'auto':
        return TriggerMode.auto;
      default:
        return TriggerMode.auto;
    }
  }

  /// Stable name used for logging / diagnostics.
  String get name {
    switch (this) {
      case TriggerMode.continueGeneration:
        return 'continue';
      case TriggerMode.regenerate:
        return 'regenerate';
      case TriggerMode.auto:
        return 'auto';
    }
  }
}
