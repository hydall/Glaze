import '../models/lorebook.dart';

/// The range the lorebook settings screens allow for the global entry cap.
const int minLorebookEntryCap = 1;
const int maxLorebookEntryCap = 100;

/// The global "max injected entries" budget.
///
/// Held to the range the settings UI enforces: a value outside it can still
/// reach the settings object through a backup restore or a cloud-sync payload,
/// and the prompt build and the coverage preview have to agree on what such a
/// value means. Read the cap through here, never straight off the settings
/// object.
int resolveGlobalEntryCap(LorebookGlobalSettings settings) {
  final raw = settings.maxInjectedEntries;
  if (raw < minLorebookEntryCap) return minLorebookEntryCap;
  if (raw > maxLorebookEntryCap) return maxLorebookEntryCap;
  return raw;
}

/// A lorebook's own entry cap, or null when the book defers to the global one.
///
/// Zero and below mean "unset" — that is what the per-book settings screen
/// stores for an empty field, and what an import can carry when the source
/// wrote a default 0. It must never be read as "inject nothing from this book".
int? resolvePerBookEntryCap(int? raw) => (raw != null && raw > 0) ? raw : null;
