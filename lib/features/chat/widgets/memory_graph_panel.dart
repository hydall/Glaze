import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/memory_graph.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../../shared/widgets/tab_slide_switcher.dart';

class MemoryGraphPanel extends ConsumerStatefulWidget {
  final String sessionId;

  const MemoryGraphPanel({super.key, required this.sessionId});

  @override
  ConsumerState<MemoryGraphPanel> createState() => _MemoryGraphPanelState();
}

class _MemoryGraphPanelState extends ConsumerState<MemoryGraphPanel> {
  int _tabIndex = 0;
  bool _rebuilding = false;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 600,
        height: 500,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Text(
                    'Memory Graph',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  GlazeActionButton(
                    icon: Icons.refresh,
                    label: 'Rebuild',
                    tone: GlazeActionTone.primary,
                    busy: _rebuilding,
                    onTap: _rebuildGraph,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: GlazeTabBar(
                tabs: const [
                  GlazeTabItem(
                    label: 'Entities',
                    icon: Icons.account_tree_outlined,
                  ),
                ],
                activeIndex: _tabIndex,
                onChanged: (index) => setState(() => _tabIndex = index),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: SwipeTabSwitcher(
                index: _tabIndex,
                length: 1,
                onChanged: (index) => setState(() => _tabIndex = index),
                child: TabSlideSwitcher(
                  index: _tabIndex,
                  child: _entitiesTab(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entitiesTab() {
    return FutureBuilder(
      future: ref
          .read(memoryEntityRepoProvider)
          .getBySessionId(widget.sessionId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: GlazeSpinner());
        }
        final entities = _mergeEntities(snapshot.data!);
        if (entities.isEmpty) {
          return const Center(
            child: Text('No entities extracted yet. Run Rebuild to populate.'),
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
          children: [
            MenuGroup(
              items: [
                for (final e in entities)
                  MenuItem(
                    iconWidget: Icon(
                      e.entityType == 'character'
                          ? Icons.person_outline
                          : Icons.place_outlined,
                      size: 20,
                      color: context.cs.primary,
                    ),
                    label: e.name,
                    subtitle:
                        '${e.entityType} · salience ${e.salienceAvg.toStringAsFixed(2)} · ${e.mentionCount} mentions'
                        '${e.aliases.isNotEmpty ? " · aliases: ${e.aliases.join(", ")}" : ""}',
                    trailing: e.status == 'active'
                        ? null
                        : Text(
                            e.status,
                            style: TextStyle(
                              fontSize: 11,
                              color: e.status == 'deceased'
                                  ? Colors.red
                                  : context.cs.onSurfaceVariant,
                            ),
                          ),
                    onTap: () {},
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  List<MemoryEntity> _mergeEntities(List<MemoryEntity> rows) {
    final byName = <String, MemoryEntity>{};
    for (final row in rows) {
      final key = '${row.entityType}:${row.name.trim().toLowerCase()}';
      final existing = byName[key];
      if (existing == null) {
        byName[key] = row;
        continue;
      }

      final aliases = <String>{...existing.aliases, ...row.aliases}.toList()
        ..sort();
      byName[key] = existing.copyWith(
        aliases: aliases,
        mentionCount: existing.mentionCount + row.mentionCount,
        salienceAvg: existing.salienceAvg > row.salienceAvg
            ? existing.salienceAvg
            : row.salienceAvg,
        saliencePeak: existing.saliencePeak > row.saliencePeak
            ? existing.saliencePeak
            : row.saliencePeak,
        lastSeenMessageIndex:
            existing.lastSeenMessageIndex > row.lastSeenMessageIndex
            ? existing.lastSeenMessageIndex
            : row.lastSeenMessageIndex,
        updatedAt: existing.updatedAt > row.updatedAt
            ? existing.updatedAt
            : row.updatedAt,
      );
    }
    return byName.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<void> _rebuildGraph() async {
    setState(() => _rebuilding = true);
    try {
      final bookRepo = ref.read(memoryBookRepoProvider);
      final book = await bookRepo.getBySessionId(widget.sessionId);
      if (book == null) return;
      final builder = ref.read(memoryGraphBuilderProvider);
      await builder.rebuildSession(widget.sessionId, book.entries);
    } finally {
      if (mounted) setState(() => _rebuilding = false);
    }
  }
}
