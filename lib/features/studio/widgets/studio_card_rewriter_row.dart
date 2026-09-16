import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/card_rewriter_settings.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_switch.dart';
import '../../../shared/widgets/menu_group.dart';

/// The Card Rewriter lane, rendered in the preset's pipeline list under the
/// Studio Ledger it feeds off.
///
/// Same row geometry as the agent rows so the section reads as one list, but
/// the lane is not a Studio controller: it has no prompt blocks and no spec in
/// the ontology. It runs after a reconciliation commits, on that commit's
/// evidence, which is why it sits last and why the switch is dead while the
/// Ledger is off.
///
/// Settings are per preset. The switch writes [CardRewriterSettings.enabled];
/// tapping the row opens the rest of the lane's own settings. Its API
/// connection and model are not here — those live with every other stage's
/// connection, in the Agents tab of the API sheet.
class StudioCardRewriterRow extends StatelessWidget {
  /// The settings of the preset being edited, already resolved against the
  /// globals — never the active preset's when a different one is open.
  final CardRewriterSettings settings;

  /// Whether the Ledger agent runs for this preset. The lane needs the Ledger
  /// and its reconciliation runs, so without it there is nothing to enable.
  final bool ledgerEnabled;

  final ValueChanged<CardRewriterSettings> onChanged;

  /// Last row of its section — drops the bottom rule.
  final bool isLast;

  const StudioCardRewriterRow({
    super.key,
    required this.settings,
    required this.ledgerEnabled,
    required this.onChanged,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = ledgerEnabled && settings.enabled;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: const Color(0x33808080),
            width: isLast ? 0 : 1,
          ),
        ),
      ),
      child: Opacity(
        opacity: enabled ? 1.0 : 0.5,
        child: InkWell(
          onTap: () => showCardRewriterLaneSettings(
            context,
            settings: settings,
            ledgerEnabled: ledgerEnabled,
            onChanged: onChanged,
          ),
          child: Row(
            children: [
              const SizedBox(width: 30, height: 44),
              Icon(
                Icons.auto_fix_high_outlined,
                size: 16,
                color: context.cs.onSurface.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'card_rewriter_studio_title'.tr(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: context.cs.onSurface,
                        ),
                      ),
                      Text(
                        ledgerEnabled
                            ? 'card_rewriter_studio_enabled_description'.tr()
                            : 'card_rewriter_studio_ledger_required'.tr(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Transform.scale(
                  scale: 0.8,
                  alignment: Alignment.centerRight,
                  child: GlazeSwitch(
                    value: settings.enabled,
                    onChanged: ledgerEnabled
                        ? (value) => onChanged(settings.copyWith(enabled: value))
                        : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The lane's own settings: what it rewrites and how long a writer call may
/// run. Enablement is the row's switch, repeated here so the sheet can be used
/// on its own.
void showCardRewriterLaneSettings(
  BuildContext context, {
  required CardRewriterSettings settings,
  required bool ledgerEnabled,
  required ValueChanged<CardRewriterSettings> onChanged,
}) {
  GlazeBottomSheet.show<void>(
    context,
    title: 'card_rewriter_studio_title'.tr(),
    child: _CardRewriterLaneSettings(
      settings: settings,
      ledgerEnabled: ledgerEnabled,
      onChanged: onChanged,
    ),
  );
}

class _CardRewriterLaneSettings extends StatefulWidget {
  const _CardRewriterLaneSettings({
    required this.settings,
    required this.ledgerEnabled,
    required this.onChanged,
  });

  final CardRewriterSettings settings;
  final bool ledgerEnabled;
  final ValueChanged<CardRewriterSettings> onChanged;

  @override
  State<_CardRewriterLaneSettings> createState() =>
      _CardRewriterLaneSettingsState();
}

class _CardRewriterLaneSettingsState extends State<_CardRewriterLaneSettings> {
  late CardRewriterSettings _settings = widget.settings;
  late final TextEditingController _timeout = TextEditingController(
    text: '${_settings.timeoutMs ~/ 1000}',
  );

  @override
  void dispose() {
    _timeout.dispose();
    super.dispose();
  }

  void _apply(CardRewriterSettings next) {
    setState(() => _settings = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return MenuGroup(
      items: [
        MenuSwitchItem(
          label: 'card_rewriter_studio_enabled'.tr(),
          description: widget.ledgerEnabled
              ? 'card_rewriter_studio_enabled_description'.tr()
              : 'card_rewriter_studio_ledger_required'.tr(),
          value: _settings.enabled,
          onChanged: widget.ledgerEnabled
              ? (value) => _apply(_settings.copyWith(enabled: value))
              : (_) {},
        ),
        MenuSwitchItem(
          label: 'card_rewriter_studio_rewrite_lorebook'.tr(),
          description: 'card_rewriter_studio_rewrite_lorebook_description'.tr(),
          value: _settings.lorebookEvolutionEnabled,
          onChanged: (value) =>
              _apply(_settings.copyWith(lorebookEvolutionEnabled: value)),
        ),
        MenuFieldItem(
          label: 'card_rewriter_studio_timeout'.tr(),
          description: 'card_rewriter_studio_timeout_description'.tr(),
          controller: _timeout,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (value) {
            final seconds = int.tryParse(value.trim()) ?? 0;
            // An empty or zero field means "leave it at the default" rather
            // than a timeout of zero, which would abort every writer call.
            _apply(
              _settings.copyWith(
                timeoutMs: seconds <= 0 ? 180000 : seconds * 1000,
              ),
            );
          },
        ),
      ],
    );
  }
}
