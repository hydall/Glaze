import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/memory_graph.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../../../shared/theme/app_colors.dart';

class MemoryGraphPanel extends ConsumerStatefulWidget {
  final String sessionId;

  const MemoryGraphPanel({super.key, required this.sessionId});

  @override
  ConsumerState<MemoryGraphPanel> createState() => _MemoryGraphPanelState();
}

class _MemoryGraphPanelState extends ConsumerState<MemoryGraphPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _rebuilding = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 1, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

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
                  if (_rebuilding)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  FilledButton.tonalIcon(
                    onPressed: _rebuilding ? null : _rebuildGraph,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Rebuild'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tabController,
              tabs: const [Tab(text: 'Entities')],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [_entitiesTab()],
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
          return const Center(child: CircularProgressIndicator());
        }
        final entities = _mergeEntities(snapshot.data!);
        if (entities.isEmpty) {
          return const Center(
            child: Text('No entities extracted yet. Run Rebuild to populate.'),
          );
        }
        return ListView.builder(
          itemCount: entities.length,
          itemBuilder: (context, index) {
            final e = entities[index];
            return ListTile(
              leading: Icon(
                e.entityType == 'character'
                    ? Icons.person_outline
                    : Icons.place_outlined,
                size: 20,
                color: context.cs.primary,
              ),
              title: Text(e.name),
              subtitle: Text(
                '${e.entityType} · salience ${e.salienceAvg.toStringAsFixed(2)} · ${e.mentionCount} mentions'
                '${e.aliases.isNotEmpty ? " · aliases: ${e.aliases.join(", ")}" : ""}',
                style: const TextStyle(fontSize: 12),
              ),
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
            );
          },
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
