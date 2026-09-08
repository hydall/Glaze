import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/tracker.dart';
import '../../../core/models/tracker_snapshot.dart';
import '../../../shared/theme/app_colors.dart';
import '../services/agentic_snapshots_service.dart';
import 'agentic_operations_log_dialog.dart' show AgenticSessionScope;

class AgenticSnapshotsTab extends ConsumerStatefulWidget {
  const AgenticSnapshotsTab({super.key});

  @override
  ConsumerState<AgenticSnapshotsTab> createState() =>
      _AgenticSnapshotsTabState();
}

class _AgenticSnapshotsTabState extends ConsumerState<AgenticSnapshotsTab> {
  List<TrackerSnapshot>? _snapshots;
  bool _loaded = false;
  bool _didLoad = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didLoad) return;
    _didLoad = true;
    _load();
  }

  Future<void> _load() async {
    final sessionId = _sessionIdOf(context);
    if (sessionId == null) {
      if (mounted) setState(() => _loaded = true);
      return;
    }
    final snapshots = await ref
        .read(agenticSnapshotsServiceProvider)
        .loadSnapshots(sessionId);
    if (!mounted) return;
    setState(() {
      _snapshots = snapshots;
      _loaded = true;
    });
  }

  Future<void> _reload() => _load();

  String? _sessionIdOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AgenticSessionScope>();
    return scope?.sessionId;
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final snapshots = _snapshots ?? const <TrackerSnapshot>[];
    return Column(
      children: [
        if (snapshots.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Text(
                  '${snapshots.length} snapshot${snapshots.length == 1 ? '' : 's'}',
                  style: TextStyle(
                    color: context.cs.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: 'Reload',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        Expanded(
          child: snapshots.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No snapshots recorded yet for this session.\n\n'
                      'Each ledger run writes a per-message snapshot of the '
                      'tracker state. Committed snapshots are the accepted '
                      'base for the next generation; tentative ones are '
                      'pending the next user turn.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: context.cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  itemCount: snapshots.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 12, endIndent: 12),
                  itemBuilder: (context, i) => _SnapshotTile(
                    snapshot: snapshots[i],
                    sessionId: _sessionIdOf(context) ?? '',
                    onChanged: _reload,
                  ),
                ),
        ),
      ],
    );
  }
}

class _SnapshotTile extends ConsumerWidget {
  final TrackerSnapshot snapshot;
  final String sessionId;
  final VoidCallback onChanged;

  const _SnapshotTile({
    required this.snapshot,
    required this.sessionId,
    required this.onChanged,
  });

  Future<void> _rollback(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rollback to here?'),
        content: Text(
          'This deletes snapshots for message "${snapshot.messageId}" and '
          'restores the live tracker rows from the previous committed '
          'snapshot. The read path falls back to that snapshot as the '
          'accepted base for the next generation.\n\n'
          'The action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Rollback'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await ref
        .read(agenticSnapshotsServiceProvider)
        .rollback(sessionId: sessionId, messageId: snapshot.messageId);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.fallbackMessageId != null
                ? 'Rolled back to ${result.fallbackMessageId}.'
                : 'Deleted snapshot for ${result.deletedMessageId}. No earlier committed snapshot remains.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    onChanged();
  }

  Future<void> _commit(WidgetRef ref) async {
    await ref
        .read(agenticSnapshotsServiceProvider)
        .commitSnapshot(sessionId: sessionId, snapshot: snapshot);
    onChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final tt = Theme.of(context).textTheme;
    final trackers = snapshot.trackers;
    final menuItems = <PopupMenuEntry<String>>[
      PopupMenuItem(value: 'rollback', child: const Text('Rollback to here')),
      if (!snapshot.committed)
        PopupMenuItem(value: 'commit', child: const Text('Commit')),
    ];
    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(
        Icons.history_edu_outlined,
        size: 20,
        color: snapshot.committed ? cs.primary : cs.onSurfaceVariant,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              snapshot.messageId,
              style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            snapshot.committed ? 'committed' : 'tentative',
            style: tt.labelSmall?.copyWith(
              color: snapshot.committed ? cs.primary : cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
      subtitle: Text(
        'swipe ${snapshot.swipeId} · agent ${snapshot.agentSwipeId} · '
        '${trackers.length} trackers · '
        '${DateTime.fromMillisecondsSinceEpoch(snapshot.createdAt * 1000).toIso8601String()}',
        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11),
      ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 18),
        padding: EdgeInsets.zero,
        itemBuilder: (_) => menuItems,
        onSelected: (action) {
          switch (action) {
            case 'rollback':
              _rollback(context, ref);
            case 'commit':
              _commit(ref);
          }
        },
      ),
      children: [
        if (trackers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              '(no trackers in this snapshot)',
              style: tt.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final t in trackers) _SnapshotTrackerRow(tracker: t),
              ],
            ),
          ),
      ],
    );
  }
}

class _SnapshotTrackerRow extends StatelessWidget {
  final Tracker tracker;
  const _SnapshotTrackerRow({required this.tracker});

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    final tt = Theme.of(context).textTheme;
    final value = tracker.value.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              tracker.name,
              style: tt.bodySmall?.copyWith(fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(
              tracker.scope,
              style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 7,
            child: SelectableText(
              value.isEmpty ? '(empty)' : value,
              maxLines: 3,
              style: tt.bodySmall?.copyWith(color: cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
