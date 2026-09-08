int _counter = 0;

/// Generates a short unique id that is guaranteed unique within a single
/// process run even when called multiple times within the same millisecond.
String generateId() {
  final ms = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final seq = (_counter++).toRadixString(36).padLeft(4, '0');
  return '$ms$seq';
}
