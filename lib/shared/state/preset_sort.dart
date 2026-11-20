import 'dart:convert';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How a preset list is ordered, shared by every list that runs on presets.
///
/// [manual] is the list's own order: rows are dragged into place and the
/// resulting sequence is persisted, so switching to another mode and back
/// restores it unchanged. It is the default, and with nothing dragged yet it
/// leaves the source order — the one the list has always shown — untouched.
enum PresetSortMode { alphabetical, dateAdded, manual }

extension PresetSortModeInfo on PresetSortMode {
  String get wireName => name;

  static PresetSortMode fromWireName(String? value) =>
      PresetSortMode.values.where((m) => m.wireName == value).firstOrNull ??
      PresetSortMode.manual;

  IconData get icon => switch (this) {
    PresetSortMode.alphabetical => Icons.sort_by_alpha_rounded,
    PresetSortMode.dateAdded => Icons.schedule_rounded,
    PresetSortMode.manual => Icons.drag_indicator_rounded,
  };

  String get label => switch (this) {
    PresetSortMode.alphabetical => 'sort_alphabetical'.tr(),
    PresetSortMode.dateAdded => 'sort_date'.tr(),
    PresetSortMode.manual => 'sort_manual'.tr(),
  };

  /// Extra line shown under the option in the sort picker. Only the manual mode
  /// has one — it is the only mode whose behaviour is not obvious from its name.
  String? get hint =>
      this == PresetSortMode.manual ? 'sort_manual_hint'.tr() : null;
}

/// Sort mode plus the manual order, persisted together in SharedPreferences.
class PresetSortState {
  final PresetSortMode mode;

  /// Preset ids in their manual order. Presets absent from the list keep their
  /// incoming order behind the ones listed here.
  final List<String> manualOrder;

  const PresetSortState({
    this.mode = PresetSortMode.manual,
    this.manualOrder = const [],
  });

  PresetSortState copyWith({PresetSortMode? mode, List<String>? manualOrder}) =>
      PresetSortState(
        mode: mode ?? this.mode,
        manualOrder: manualOrder ?? this.manualOrder,
      );
}

/// The stored sort of one preset list. Each list supplies its own pair of
/// preference keys, so the API presets and the External Blocks presets are sorted
/// independently.
class PresetSortNotifier extends AsyncNotifier<PresetSortState> {
  PresetSortNotifier({required this.modeKey, required this.orderKey});

  final String modeKey;
  final String orderKey;

  @override
  Future<PresetSortState> build() async {
    final prefs = await SharedPreferences.getInstance();
    return PresetSortState(
      mode: PresetSortModeInfo.fromWireName(prefs.getString(modeKey)),
      manualOrder: _decodeOrder(prefs.getString(orderKey)),
    );
  }

  static List<String> _decodeOrder(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return const [];
    }
  }

  Future<void> setMode(PresetSortMode mode) async {
    final current = state.value ?? const PresetSortState();
    if (current.mode == mode) return;
    state = AsyncData(current.copyWith(mode: mode));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(modeKey, mode.wireName);
  }

  Future<void> setManualOrder(List<String> order) async {
    final current = state.value ?? const PresetSortState();
    state = AsyncData(current.copyWith(manualOrder: order));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(orderKey, jsonEncode(order));
  }
}

/// Sorts [items] according to [state], leaving the caller's list untouched.
///
/// Every mode is a stable sort over the incoming order, so items that compare
/// equal (same name, same stamp, or both missing from the manual order) stay in
/// the order the source returned them in.
List<T> sortPresetItems<T>(
  List<T> items,
  PresetSortState state, {
  required String Function(T) idOf,
  required String Function(T) nameOf,
  required int Function(T) createdAtOf,
}) {
  final ranks = <String, int>{};
  if (state.mode == PresetSortMode.manual) {
    for (var i = 0; i < state.manualOrder.length; i++) {
      ranks[state.manualOrder[i]] = i;
    }
  }

  // Decorate with the incoming index so the comparator can fall back to it —
  // List.sort is not stable on its own.
  final indexed = [
    for (var i = 0; i < items.length; i++) (index: i, item: items[i]),
  ];

  int compare(({int index, T item}) a, ({int index, T item}) b) {
    final result = switch (state.mode) {
      PresetSortMode.alphabetical => nameOf(
        a.item,
      ).toLowerCase().compareTo(nameOf(b.item).toLowerCase()),
      // Newest first, matching "date added" everywhere else in the app.
      PresetSortMode.dateAdded => createdAtOf(
        b.item,
      ).compareTo(createdAtOf(a.item)),
      PresetSortMode.manual => (ranks[idOf(a.item)] ?? ranks.length).compareTo(
        ranks[idOf(b.item)] ?? ranks.length,
      ),
    };
    return result != 0 ? result : a.index.compareTo(b.index);
  }

  indexed.sort(compare);
  return [for (final e in indexed) e.item];
}

/// The full id order after the row at [oldIndex] of [visible] was dragged to
/// [newIndex] (its final index, as `onReorderItem` reports it).
///
/// [visible] is what the user dragged over — one folder, or the rows a filter
/// left; [full] is the whole list. The moved row lands right after the visible
/// row it now follows, so rows hidden from view keep the places they had.
List<String> reanchorOrder(
  List<String> full,
  List<String> visible,
  int oldIndex,
  int newIndex,
) {
  if (oldIndex == newIndex) return full;
  final shown = List<String>.of(visible);
  final moved = shown.removeAt(oldIndex);
  shown.insert(newIndex, moved);
  final result = List<String>.of(full)..remove(moved);
  if (newIndex == 0) {
    // Lands before the row that now follows it.
    final next = shown.length > 1 ? shown[1] : null;
    final at = next == null ? 0 : result.indexOf(next);
    result.insert(at < 0 ? 0 : at, moved);
    return result;
  }
  final anchor = shown[newIndex - 1];
  result.insert(result.indexOf(anchor) + 1, moved);
  return result;
}

/// The manual order of a sorted list after the row at [oldIndex] of
/// [visible] was dragged to [newIndex].
///
/// [visible] is what the user dragged over (one folder, the rows a filter
/// left); [all] is every item. The full manual order is rebuilt from [all], so
/// items never dragged yet get a place too, and rows hidden from view keep the
/// places they had.
List<String> manualOrderAfterDrag<T>({
  required List<T> all,
  required List<T> visible,
  required int oldIndex,
  required int newIndex,
  required PresetSortState state,
  required String Function(T) idOf,
  required String Function(T) nameOf,
  required int Function(T) createdAtOf,
}) {
  final full = [
    for (final e in sortPresetItems(
      all,
      state.copyWith(mode: PresetSortMode.manual),
      idOf: idOf,
      nameOf: nameOf,
      createdAtOf: createdAtOf,
    ))
      idOf(e),
  ];
  return reanchorOrder(
    full,
    [for (final e in visible) idOf(e)],
    oldIndex,
    newIndex,
  );
}
