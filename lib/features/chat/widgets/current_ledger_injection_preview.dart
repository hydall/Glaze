import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/ledger_prompt_injection_mode.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_filter_chip_bar.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../services/current_ledger_injection_preview_service.dart';

class CurrentLedgerInjectionPreviewCard extends ConsumerStatefulWidget {
  const CurrentLedgerInjectionPreviewCard({
    super.key,
    required this.sessionId,
    this.characterId,
  });

  final String sessionId;
  final String? characterId;

  @override
  ConsumerState<CurrentLedgerInjectionPreviewCard> createState() =>
      _CurrentLedgerInjectionPreviewCardState();
}

class _CurrentLedgerInjectionPreviewCardState
    extends ConsumerState<CurrentLedgerInjectionPreviewCard> {
  LedgerPromptInjectionMode _mode = LedgerPromptInjectionMode.legacy;

  CurrentLedgerInjectionPreviewKey get _key =>
      (sessionId: widget.sessionId, characterId: widget.characterId);

  @override
  Widget build(BuildContext context) {
    final preview = ref.watch(currentLedgerInjectionPreviewProvider(_key));
    return GlassSurface(
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Current Ledger injection',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => ref.invalidate(
                    currentLedgerInjectionPreviewProvider(_key),
                  ),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            Text(
              'Live read-only projection from current canon and the current '
              'Studio final-writer window. This is not a captured request.',
              style: TextStyle(
                color: context.cs.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            preview.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: GlazeSpinner()),
              ),
              error: (error, _) => Text(
                'Preview unavailable: $error',
                style: TextStyle(color: context.cs.error, fontSize: 12),
              ),
              data: _buildPreview,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(CurrentLedgerInjectionPreview preview) {
    final selected = _mode == LedgerPromptInjectionMode.legacy
        ? preview.legacy.value
        : preview.gapFiller.value;
    final selectedCount = selected.diagnostics
        .where((item) => item.selected)
        .length;
    final suppressedCount = selected.diagnostics.length - selectedCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GlazeFilterChipBar<LedgerPromptInjectionMode>(
          current: _mode,
          options: const [
            LedgerPromptInjectionMode.legacy,
            LedgerPromptInjectionMode.gapFiller,
          ],
          labelBuilder: (mode) => switch (mode) {
            LedgerPromptInjectionMode.legacy => 'Legacy',
            LedgerPromptInjectionMode.gapFiller => 'Gap Filler',
            _ => mode.name,
          },
          onSelected: (mode) => setState(() => _mode = mode),
        ),
        Text(
          'Configured: ${preview.configuredMode.name} · '
          '${preview.visibleMessageIds.length} visible messages · '
          '$selectedCount selected · $suppressedCount suppressed',
          style: TextStyle(color: context.cs.onSurfaceVariant, fontSize: 11),
        ),
        const SizedBox(height: 8),
        _InjectionSection(
          title: 'Character knowledge',
          content: selected.characterKnowledgeContent,
        ),
        _InjectionSection(
          title: 'Studio session state',
          content: selected.studioSessionStateContent,
        ),
        _InjectionSection(title: 'Arc', content: selected.arcContent),
        ExpansionTile(
          dense: true,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 4),
          title: const Text('Selection diagnostics'),
          subtitle: Text(
            'Revision ${preview.revisionNumber} · ${preview.revisionHash}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          children: [
            if (selected.diagnostics.isEmpty)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('No projection groups.'),
              )
            else
              for (final diagnostic in selected.diagnostics)
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    '${diagnostic.selected ? 'IN' : 'OUT'} · '
                    '${diagnostic.groupId} · ${diagnostic.tier.name} · '
                    '${diagnostic.reason.name}'
                    '${diagnostic.matchingSourceIds.isEmpty ? '' : ' · ${diagnostic.matchingSourceIds.join(', ')}'}',
                    style: TextStyle(
                      color: context.cs.onSurfaceVariant,
                      fontFamily: 'monospace',
                      fontSize: 10,
                    ),
                  ),
                ),
          ],
        ),
      ],
    );
  }
}

class _InjectionSection extends StatelessWidget {
  const _InjectionSection({required this.title, required this.content});

  final String title;
  final String? content;

  @override
  Widget build(BuildContext context) {
    final text = content?.trim();
    return ExpansionTile(
      dense: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Text(title),
      subtitle: Text(
        text == null || text.isEmpty ? 'Empty' : '${text.length} chars',
      ),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(
            text == null || text.isEmpty ? 'Nothing injected.' : text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ],
    );
  }
}
