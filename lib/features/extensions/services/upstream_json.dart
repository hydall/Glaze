/// Tolerant readers for JSON written by the original ExtBlocks extension.
///
/// Hand-edited and older exports turn up with numbers as strings, booleans as
/// 0/1, and keys simply absent. These helpers absorb that without guessing:
/// anything unreadable falls back to the caller's default, which is always the
/// same default the original itself would have applied.
library;

bool upstreamBool(Object? raw, {bool fallback = false}) {
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) {
    final lower = raw.trim().toLowerCase();
    if (lower == 'true') return true;
    if (lower == 'false') return false;
  }
  return fallback;
}

int upstreamInt(Object? raw, int fallback) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
  return fallback;
}

String upstreamString(Object? raw, {String fallback = ''}) =>
    raw is String ? raw : fallback;

/// Mirrors the original's own coercion, where a zero or unparseable value falls
/// through to the default. Used for `period`, which must never reach zero: the
/// trigger check divides by it.
int upstreamIntNonZero(Object? raw, int fallback) {
  final value = upstreamInt(raw, fallback);
  return value == 0 ? fallback : value;
}

/// Looks [raw] up in [byJsonValue], retrying across the int/string divide
/// because the original writes some enums as numbers and some as strings, and
/// exports do not always keep the distinction.
T upstreamEnum<T extends Enum>(
  Object? raw,
  Map<Object, T> byJsonValue,
  T fallback,
) {
  if (raw == null) return fallback;
  final direct = byJsonValue[raw];
  if (direct != null) return direct;
  if (raw is String) {
    final asInt = int.tryParse(raw.trim());
    if (asInt != null) return byJsonValue[asInt] ?? fallback;
  }
  if (raw is num) return byJsonValue[raw.toString()] ?? fallback;
  return fallback;
}
