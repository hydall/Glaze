import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/game_time.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_text_field.dart';
import '../services/manual_ledger_clock_service.dart';

class ManualLedgerClockSheet extends ConsumerStatefulWidget {
  const ManualLedgerClockSheet({
    super.key,
    required this.sessionId,
    required this.onSaved,
  });

  final String sessionId;
  final Future<void> Function() onSaved;

  @override
  ConsumerState<ManualLedgerClockSheet> createState() =>
      _ManualLedgerClockSheetState();
}

class _ManualLedgerClockSheetState
    extends ConsumerState<ManualLedgerClockSheet> {
  final _count = TextEditingController(text: '5');
  List<_ClockRow>? _rows;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _count.dispose();
    for (final row in _rows ?? const <_ClockRow>[]) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final count = int.tryParse(_count.text.trim());
    if (count == null || count < 1 || count > 50) {
      setState(() => _error = 'agent_ops_clock_count_error'.tr());
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await ref
          .read(manualLedgerClockServiceProvider)
          .loadRecent(widget.sessionId, limit: count);
      if (!mounted) return;
      for (final row in _rows ?? const <_ClockRow>[]) {
        row.dispose();
      }
      setState(() => _rows = entries.map(_ClockRow.new).toList());
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _rows == null) return;
    final corrections = <ManualLedgerClockCorrection>[];
    for (final row in _rows!) {
      final clock = GameTimeState.parse(
        date: row.date.text,
        day: row.day.text,
        time: row.time.text,
      );
      if (clock.format() == null) {
        setState(() => _error = 'agent_ops_clock_value_error'.tr());
        return;
      }
      corrections.add(
        ManualLedgerClockCorrection(entry: row.entry, clock: clock),
      );
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(manualLedgerClockServiceProvider)
          .save(widget.sessionId, corrections);
      await widget.onSaved();
      if (mounted) Navigator.of(context, rootNavigator: true).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return SizedBox(
      width: 720,
      height: 580,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'agent_ops_clock_description'.tr(),
              style: TextStyle(color: context.cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                SizedBox(
                  width: 130,
                  child: GlazeTextField(
                    controller: _count,
                    label: 'agent_ops_clock_count'.tr(),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _loading || _saving ? null : _load,
                  child: Text('agent_ops_clock_load'.tr()),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Expanded(child: Center(child: GlazeSpinner()))
            else if (rows == null || rows.isEmpty)
              Expanded(child: Center(child: Text('agent_ops_clock_empty'.tr())))
            else
              Expanded(
                child: ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) =>
                      _ClockRowCard(row: rows[index]),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: context.cs.error, fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: rows == null || rows.isEmpty || _loading || _saving
                  ? null
                  : _save,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text('agent_ops_clock_save'.tr()),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClockRow {
  _ClockRow(this.entry)
    : date = TextEditingController(text: entry.clock.date),
      day = TextEditingController(text: '${entry.clock.day}'),
      time = TextEditingController(text: entry.clock.time);

  final ManualLedgerClockEntry entry;
  final TextEditingController date;
  final TextEditingController day;
  final TextEditingController time;

  void dispose() {
    date.dispose();
    day.dispose();
    time.dispose();
  }
}

class _ClockRowCard extends StatelessWidget {
  const _ClockRowCard({required this.row});

  final _ClockRow row;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'agent_ops_clock_message'.tr(
                namedArgs: {
                  'number': '${row.entry.messageNumber}',
                  'status': row.entry.committed
                      ? 'agent_ops_snapshot_committed'.tr()
                      : 'agent_ops_snapshot_tentative'.tr(),
                },
              ),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  flex: 4,
                  child: GlazeTextField(
                    controller: row.date,
                    label: 'agent_ops_clock_date'.tr(),
                    keyboardType: TextInputType.datetime,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: GlazeTextField(
                    controller: row.day,
                    label: 'agent_ops_clock_day'.tr(),
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: GlazeTextField(
                    controller: row.time,
                    label: 'agent_ops_clock_time'.tr(),
                    keyboardType: TextInputType.datetime,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
