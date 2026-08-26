import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Result of the first-message game time seeding dialog.
class GameTimeSeedResult {
  const GameTimeSeedResult({required this.time, required this.date});

  /// `HH:MM` in-game time of day for message zero.
  final String time;

  /// `DD.MM.YYYY` in-game date.
  final String date;
}

/// Shown before the first message of a Studio chat so the player can anchor
/// the ledger game clock (world:time / world:date / world:day). The in-game
/// day always starts at 0; only the time of day and date are
/// entered here.
class GameTimeSeedDialog extends StatefulWidget {
  const GameTimeSeedDialog({super.key});

  @override
  State<GameTimeSeedDialog> createState() => _GameTimeSeedDialogState();
}

class _GameTimeSeedDialogState extends State<GameTimeSeedDialog> {
  final _dateController = TextEditingController();
  final _timeController = TextEditingController(text: '09:00');

  static final _timeRe = RegExp(r'^(\d{1,2}):(\d{2})$');
  static final _dateRe = RegExp(r'^\d{2}\.\d{2}\.\d{4}$');

  String? _error;

  @override
  void dispose() {
    _dateController.dispose();
    _timeController.dispose();
    super.dispose();
  }

  void _submit() {
    final timeMatch = _timeRe.firstMatch(_timeController.text.trim());
    if (timeMatch == null ||
        int.parse(timeMatch.group(1)!) > 23 ||
        int.parse(timeMatch.group(2)!) > 59) {
      setState(() => _error = 'game_time_seed_invalid_time'.tr());
      return;
    }
    final dateRaw = _dateController.text.trim();
    if (!_dateRe.hasMatch(dateRaw)) {
      setState(() => _error = 'game_time_seed_invalid_date'.tr());
      return;
    }
    final dateParts = dateRaw.split('.').map(int.parse).toList();
    final parsedDate = DateTime.utc(dateParts[2], dateParts[1], dateParts[0]);
    if (parsedDate.year != dateParts[2] ||
        parsedDate.month != dateParts[1] ||
        parsedDate.day != dateParts[0]) {
      setState(() => _error = 'game_time_seed_invalid_date'.tr());
      return;
    }
    final hour = int.parse(timeMatch.group(1)!).toString().padLeft(2, '0');
    final minute = timeMatch.group(2)!;
    Navigator.of(
      context,
    ).pop(GameTimeSeedResult(time: '$hour:$minute', date: dateRaw));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('game_time_seed_title'.tr()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('game_time_seed_description'.tr()),
            const SizedBox(height: 16),
            TextField(
              controller: _timeController,
              decoration: InputDecoration(
                labelText: 'game_time_seed_time_label'.tr(),
                hintText: '09:00',
                errorText: null,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9:]')),
                LengthLimitingTextInputFormatter(5),
              ],
              keyboardType: TextInputType.datetime,
              autofocus: true,
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _dateController,
              decoration: InputDecoration(
                labelText: 'game_time_seed_date_label'.tr(),
                hintText: 'DD.MM.YYYY',
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                LengthLimitingTextInputFormatter(10),
              ],
              keyboardType: TextInputType.datetime,
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: cs.error, fontSize: 13),
                ),
              ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: _submit,
            child: Text('game_time_seed_confirm'.tr()),
          ),
        ],
      ),
    );
  }
}
