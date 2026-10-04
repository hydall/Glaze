/// The effective canon changed while prompt inputs were being assembled.
/// Callers must discard the partial result and rebuild from a fresh snapshot.
final class PromptBuildStaleException implements Exception {
  const PromptBuildStaleException(this.message);
  final String message;

  @override
  String toString() => 'PromptBuildStaleException: $message';
}
