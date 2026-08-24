import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/tracker.dart';
import '../../../core/models/tracker_snapshot.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_spinner.dart';
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
      return const Center(child: GlazeSpinner());
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
                      'Studio Ledger state. Committed snapshots are the '
                      'accepted base for the next generation; tentative ones '
                      'are pending the next user turn. This view is read-only; '
                      'reconciliation commits and regeneration live in the '
                      'Reconciler tab.',
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
                  itemBuilder: (context, i) =>
                      _SnapshotTile(snapshot: snapshots[i]),
                ),
        ),
      ],
    );
  }
}

class _SnapshotTile extends ConsumerWidget {
  final TrackerSnapshot snapshot;

  const _SnapshotTile({required this.snapshot});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final tt = Theme.of(context).textTheme;
    final trackers = snapshot.trackers;
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
        '${trackers.length} ledger values · '
        '${DateTime.fromMillisecondsSinceEpoch(snapshot.createdAt * 1000).toIso8601String()}',
        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11),
      ),
      children: [
        if (trackers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              '(no ledger values in this snapshot)',
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
