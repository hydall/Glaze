import 'package:flutter/material.dart';

import '../../../../shared/state/preset_sort.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/widgets/glass_surface.dart';

/// The one list body every Memory Books collection is rendered through.
///
/// The approved entries, the scan drafts and the cross-tab search results used
/// to be three separately written list builders — a `Column` of mapped rows for
/// the first two and a `ListView` for the search hits. They now share this
/// widget, and with it one order: newest first by creation, so the freshest
/// memory always leads. There is no sort control — freshness is the only order
/// that makes sense in a book that grows at the end.
class MemoryListBody<T> extends StatelessWidget {
  final List<T> items;
  final String Function(T) idOf;
  final String Function(T) nameOf;
  final int Function(T) createdAtOf;
  final Widget Function(BuildContext context, T item) rowBuilder;

  /// Shown in place of the rows when [items] is empty.
  final String emptyMessage;

  /// Whether the body owns the scroll view (`true`, for the search results) or
  /// is a plain column inside the tab's own list (`false`).
  final bool scrollable;

  /// Extra bottom padding, e.g. to clear the nav bar and the FAB.
  final EdgeInsets padding;

  const MemoryListBody({
    super.key,
    required this.items,
    required this.idOf,
    required this.nameOf,
    required this.createdAtOf,
    required this.rowBuilder,
    required this.emptyMessage,
    this.scrollable = false,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final sorted = items.isEmpty
        ? items
        : sortPresetItems(
            items,
            const PresetSortState(mode: PresetSortMode.dateAdded),
            idOf: idOf,
            nameOf: nameOf,
            createdAtOf: createdAtOf,
          );

    if (sorted.isEmpty) {
      return Padding(
        padding: padding,
        child: MemoryEmptyState(message: emptyMessage),
      );
    }

    if (scrollable) {
      return ListView.builder(
        padding: padding,
        itemCount: sorted.length,
        itemBuilder: (context, i) => rowBuilder(context, sorted[i]),
      );
    }

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final item in sorted) rowBuilder(context, item)],
      ),
    );
  }
}

/// The shared empty placeholder of a Memory Books list.
class MemoryEmptyState extends StatelessWidget {
  final String message;

  const MemoryEmptyState({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: context.cs.outlineVariant),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: context.cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
