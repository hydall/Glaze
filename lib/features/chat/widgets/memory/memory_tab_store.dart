import 'package:shared_preferences/shared_preferences.dart';

/// Remembers which tab of a memory surface was open when it was last closed,
/// so reopening lands on the same tab instead of always resetting to the first.
///
/// Deliberately global rather than per session: the tab is a workflow
/// preference — someone curating memory books wants the books tab next time
/// too, whichever chat they open the sheet from.
class MemoryTabStore {
  /// Summary / Books tabs of the Memory sheet.
  static const MemoryTabStore memorySheet = MemoryTabStore(
    'memory_sheet_last_tab',
  );

  /// Approved / Scan-drafts tabs inside the Memory Books tab.
  static const MemoryTabStore memoryBooks = MemoryTabStore(
    'memory_books_last_tab',
  );

  final String key;

  const MemoryTabStore(this.key);

  /// Last stored tab index, clamped to `[0, tabCount)` so an index written by
  /// an older build with more tabs can never select a tab that no longer
  /// exists.
  Future<int> load(int tabCount) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getInt(key) ?? 0;
    if (stored < 0 || stored >= tabCount) return 0;
    return stored;
  }

  Future<void> save(int index) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, index);
  }
}
