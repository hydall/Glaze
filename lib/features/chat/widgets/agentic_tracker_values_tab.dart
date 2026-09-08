import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/tracker.dart';
import '../../../core/state/memory_agent_providers.dart';
import '../../../shared/theme/app_colors.dart';
import '../services/agentic_tracker_values_service.dart';
import 'agentic_operations_log_dialog.dart' show AgenticSessionScope;

class AgenticTrackerValuesTab extends ConsumerStatefulWidget {
  const AgenticTrackerValuesTab({super.key});

  @override
  ConsumerState<AgenticTrackerValuesTab> createState() =>
      _AgenticTrackerValuesTabState();
}

class _AgenticTrackerValuesTabState
    extends ConsumerState<AgenticTrackerValuesTab> {
  List<Tracker>? _trackers;
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
    // Load the EFFECTIVE ledger state — exactly what the prompt sees. This
    // merges the latest committed snapshot with live canon_override/canon_lock
    // rows, so the user always edits what actually feeds the next generation.
    final trackers = await ref
        .read(ledgerTrackerLoaderProvider)
        .loadEffectiveLedgerTrackers(sessionId);
    if (!mounted) return;
    setState(() {
      _trackers = trackers;
      _loaded = true;
    });
  }

  Future<void> _reload() => _load();

  String? _sessionIdOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AgenticSessionScope>();
    return scope?.sessionId;
  }

  Future<void> _purgeTrackers() async {
    final sessionId = _sessionIdOf(context);
    if (sessionId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Purge tracker values?'),
        content: const Text(
          'This permanently deletes all tracker rows and snapshots for this '
          'session. Use this to clear orphaned trackers left by deleted '
          'messages or a Clear chat. The action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Purge'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(agenticTrackerValuesServiceProvider).purgeSession(sessionId);
    if (!mounted) return;
    setState(() {
      _trackers = const <Tracker>[];
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: CircularProgressIndicator());
    }
    final trackers = _trackers ?? const <Tracker>[];
    // Precompute lock/override key sets so tiles can show badges and decide
    // whether the matching canon_lock/canon_override row already exists.
    final lockNames = <String>{};
    final overrideNames = <String>{};
    for (final t in trackers) {
      if (t.name.startsWith('canon_lock:')) {
        lockNames.add(t.name.substring('canon_lock:'.length));
      } else if (t.name.startsWith('canon_override:')) {
        overrideNames.add(t.name.substring('canon_override:'.length));
      }
    }
    return Column(
      children: [
        if (trackers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Text(
                  '${trackers.length} tracker${trackers.length == 1 ? '' : 's'}',
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
                TextButton.icon(
                  onPressed: _purgeTrackers,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                  label: const Text('Purge'),
                  style: TextButton.styleFrom(
                    foregroundColor: context.cs.error,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: trackers.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No tracker values recorded yet for this session.\n\n'
                      'Studio Ledger records accepted session state such as '
                      'scene, world, relationships, and character context. '
                      'Manual canon overrides and locks can also appear here.',
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
                  itemCount: trackers.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 12, endIndent: 12),
                  itemBuilder: (context, i) => _TrackerTile(
                    tracker: trackers[i],
                    sessionId: _sessionIdOf(context) ?? '',
                    lockNames: lockNames,
                    overrideNames: overrideNames,
                    onChanged: _reload,
                  ),
                ),
        ),
      ],
    );
  }
}

class _TrackerTile extends ConsumerWidget {
  final Tracker tracker;
  final String sessionId;
  final Set<String> lockNames;
  final Set<String> overrideNames;
  final VoidCallback onChanged;

  const _TrackerTile({
    required this.tracker,
    required this.sessionId,
    required this.lockNames,
    required this.overrideNames,
    required this.onChanged,
  });

  bool get _isControlRow =>
      tracker.name.startsWith('canon_lock:') ||
      tracker.name.startsWith('canon_override:');

  bool get _isLocked =>
      !tracker.name.startsWith('canon_lock:') &&
      lockNames.contains(tracker.name);

  bool get _isOverridden =>
      !tracker.name.startsWith('canon_override:') &&
      overrideNames.contains(tracker.name);

  Future<String?> _promptEditValue(
    BuildContext context, {
    required String title,
    required String initial,
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 8,
            minLines: 3,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Tracker value',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _editValue(BuildContext context, WidgetRef ref) async {
    final newValue = await _promptEditValue(
      context,
      title: 'Edit: ${tracker.name}',
      initial: tracker.value,
    );
    if (newValue == null) return;
    await ref
        .read(agenticTrackerValuesServiceProvider)
        .editValue(sessionId: sessionId, tracker: tracker, value: newValue);
    onChanged();
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete tracker?'),
        content: Text(
          'Delete "${tracker.name}"? This removes the row from the live '
          'tracker state. The action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(agenticTrackerValuesServiceProvider)
        .deleteTracker(sessionId: sessionId, trackerName: tracker.name);
    onChanged();
  }

  Future<void> _toggleLock(WidgetRef ref) async {
    await ref
        .read(agenticTrackerValuesServiceProvider)
        .toggleCanonLock(
          sessionId: sessionId,
          trackerName: tracker.name,
          isLocked: _isLocked,
        );
    onChanged();
  }

  Future<void> _setOverride(BuildContext context, WidgetRef ref) async {
    final newValue = await _promptEditValue(
      context,
      title: 'Override: ${tracker.name}',
      initial: tracker.value,
    );
    if (newValue == null) return;
    await ref
        .read(agenticTrackerValuesServiceProvider)
        .setCanonOverride(
          sessionId: sessionId,
          trackerName: tracker.name,
          value: newValue,
        );
    onChanged();
  }

  Future<void> _removeOverride(WidgetRef ref) async {
    await ref
        .read(agenticTrackerValuesServiceProvider)
        .removeCanonOverride(sessionId: sessionId, trackerName: tracker.name);
    onChanged();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = context.cs;
    final tt = Theme.of(context).textTheme;
    final value = tracker.value.trim();
    final hasValue = value.isNotEmpty;
    final menuItems = <PopupMenuEntry<String>>[];
    if (_isControlRow) {
      // A canon_override/canon_lock row itself — edit or delete the control.
      menuItems.add(
        PopupMenuItem(value: 'edit', child: const Text('Edit value')),
      );
      menuItems.add(
        PopupMenuItem(value: 'delete', child: const Text('Delete')),
      );
    } else {
      // Regular ledger key — value comes from the snapshot. To change what
      // the prompt sees, set a canon_override (Edit value does this). Lock
      // prevents the ledger from overwriting the key. Remove override clears
      // a previously set manual override.
      menuItems.add(
        PopupMenuItem(
          value: 'override',
          child: Text(
            _isOverridden ? 'Edit override' : 'Edit value (set override)',
          ),
        ),
      );
      menuItems.add(
        PopupMenuItem(
          value: 'lock',
          child: Text(_isLocked ? 'Unlock' : 'Lock (canon_lock)'),
        ),
      );
      if (_isOverridden) {
        menuItems.add(
          PopupMenuItem(
            value: 'remove_override',
            child: const Text('Remove override'),
          ),
        );
      }
    }
    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(Icons.track_changes_outlined, color: cs.primary, size: 20),
      title: Row(
        children: [
          Flexible(
            child: Text(
              tracker.name,
              style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_isLocked) ...[
            const SizedBox(width: 6),
            Icon(Icons.lock_outline, size: 14, color: cs.tertiary),
          ],
          if (_isOverridden) ...[
            const SizedBox(width: 6),
            Icon(Icons.edit_note, size: 14, color: cs.secondary),
          ],
        ],
      ),
      subtitle: Text(
        '${tracker.scope} · ${tracker.provenance.isEmpty ? "no provenance" : tracker.provenance}',
        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontSize: 11),
      ),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert, size: 18),
        padding: EdgeInsets.zero,
        itemBuilder: (_) => menuItems,
        onSelected: (action) {
          switch (action) {
            case 'edit':
              _editValue(context, ref);
            case 'delete':
              _delete(context, ref);
            case 'lock':
              _toggleLock(ref);
            case 'override':
              _setOverride(context, ref);
            case 'remove_override':
              _removeOverride(ref);
          }
        },
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasValue)
                SelectableText(
                  value,
                  style: tt.bodySmall?.copyWith(color: cs.onSurface),
                )
              else
                Text(
                  '(empty — the tracker exists but has no value yet)',
                  style: tt.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'updatedAt: ${DateTime.fromMillisecondsSinceEpoch(tracker.updatedAt * 1000).toIso8601String()}',
                style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
