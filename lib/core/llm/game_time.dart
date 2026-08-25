import '../models/tracker.dart';

/// Game clock state kept in the Studio Ledger under `world:` tracker keys.
///
/// The ledger maintains three keys:
/// - `world:time` — current in-game time of day, `HH:MM` (24h);
/// - `world:date` — optional in-game date, `DD.MM.YYYY`;
/// - `world:day` — zero-based in-game day counter (day 0 = the day the
///   story starts).
///
/// The clock only ever moves forward: when the narrative advances time, the
/// ledger bumps `world:time`, rolls it past midnight into `world:date` /
/// `world:day` as needed, and never rewinds it (flashbacks stay prose, not
/// clock changes).
class GameTimeState {
  const GameTimeState({this.time, this.date, this.day});

  static const String timeKey = 'world:time';
  static const String dateKey = 'world:date';
  static const String dayKey = 'world:day';

  /// `HH:MM` in-game time of day, or null when the ledger has none yet.
  final String? time;

  /// `DD.MM.YYYY` in-game date, or null when the story has no calendar.
  final String? date;

  /// Zero-based in-game day number, or null when unset.
  final int? day;

  bool get isEmpty => time == null && date == null && day == null;

  static GameTimeState fromTrackers(Iterable<Tracker> trackers) {
    String? time;
    String? date;
    int? day;
    for (final tracker in trackers) {
      final value = tracker.value.trim();
      if (value.isEmpty) continue;
      switch (tracker.name) {
        case timeKey:
          time = _normalizeTime(value);
        case dateKey:
          date = _normalizeDate(value);
        case dayKey:
          day = int.tryParse(value);
      }
    }
    return GameTimeState(time: time, date: date, day: day);
  }

  /// Compact display string: `DD.MM.YYYY · День N · HH:MM` with the parts
  /// that exist. Returns null when no clock part is known at all.
  String? format() {
    if (time == null && date == null && day == null) return null;
    final parts = <String>[?date, if (day != null) 'День $day', ?time];
    return parts.join(' · ');
  }

  /// English display variant used where localization is not available.
  String? formatEnglish() {
    if (time == null && date == null && day == null) return null;
    final parts = <String>[?date, if (day != null) 'Day $day', ?time];
    return parts.join(' · ');
  }

  static String? _normalizeTime(String raw) {
    final match = RegExp(r'(\d{1,2}):(\d{1,2})').firstMatch(raw);
    if (match == null) return null;
    final hour = int.parse(match.group(1)!);
    final minute = int.parse(match.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  static String? _normalizeDate(String raw) {
    final match = RegExp(r'(\d{2})\.(\d{2})\.(\d{4})').firstMatch(raw);
    if (match == null) return null;
    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    if (day < 1 || day > 31 || month < 1 || month > 12) return null;
    return '${match.group(1)}.${match.group(2)}.${match.group(3)}';
  }

  /// Expands `{{gametime}}` / `{{gamedate}}` / `{{gameday}}` in user-authored
  /// injection content (memory book entries, summary templates). Only the
  /// game-clock macros are touched — the full macro engine is deliberately
  /// not run over memory content.
  String expandMacros(String text) {
    var result = text;
    if (result.isEmpty) return result;
    result = result.replaceAllMapped(
      RegExp(r'\{\{gametime\}\}', caseSensitive: false),
      (_) => time ?? '',
    );
    result = result.replaceAllMapped(
      RegExp(r'\{\{gamedate\}\}', caseSensitive: false),
      (_) => date ?? '',
    );
    result = result.replaceAllMapped(
      RegExp(r'\{\{gameday\}\}', caseSensitive: false),
      (_) => day?.toString() ?? '',
    );
    return result;
  }
}
