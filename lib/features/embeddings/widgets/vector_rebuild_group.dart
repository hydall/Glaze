import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/embedding_repo.dart';
import '../../../core/llm/vector_rebuild_service.dart';
import '../../../core/state/vector_rebuild_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';

/// Re-embeds stored vectors after the embedding model or its dimensions
/// changed: what is stale, which sources to rebuild, how fast, and the run's
/// progress with its pause and cancel controls.
class VectorRebuildGroup extends ConsumerStatefulWidget {
  const VectorRebuildGroup({super.key});

  @override
  ConsumerState<VectorRebuildGroup> createState() => _VectorRebuildGroupState();
}

class _VectorRebuildGroupState extends ConsumerState<VectorRebuildGroup> {
  final _vectorsPerMinuteCtrl = TextEditingController(text: '30');
  final _batchSizeCtrl = TextEditingController(text: '10');
  bool _memoryBooks = true;
  bool _lorebooks = true;
  bool _rawChat = true;
  bool _force = false;

  @override
  void dispose() {
    _vectorsPerMinuteCtrl.dispose();
    _batchSizeCtrl.dispose();
    super.dispose();
  }

  /// [clearExisting] turns the run into a reindex: the selected sources'
  /// vectors are deleted first, so it asks before starting.
  Future<void> _start({bool clearExisting = false}) async {
    final sources = <VectorRebuildSource>{
      if (_memoryBooks) VectorRebuildSource.memoryBooks,
      if (_lorebooks) VectorRebuildSource.lorebooks,
      if (_rawChat) VectorRebuildSource.rawChat,
    };
    if (sources.isEmpty) {
      GlazeToast.show(context, 'vector_error_select_source'.tr());
      return;
    }
    if (clearExisting && !await _confirmReindex()) return;
    if (!mounted) return;
    await ref
        .read(vectorRebuildControllerProvider.notifier)
        .start(
          VectorRebuildRequest(
            sources: sources,
            vectorsPerMinute: int.tryParse(_vectorsPerMinuteCtrl.text) ?? 30,
            batchSize: int.tryParse(_batchSizeCtrl.text) ?? 10,
            forceReindex: _force,
            clearExisting: clearExisting,
          ),
        );
  }

  Future<bool> _confirmReindex() async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'vector_reindex_start'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_sweep_outlined,
        description: 'vector_reindex_confirm'.tr(),
      ),
      items: [
        BottomSheetItem(
          label: 'vector_reindex_start'.tr(),
          isDestructive: true,
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          label: 'btn_cancel'.tr(),
          centered: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vectorRebuildControllerProvider);
    final stats = ref.watch(embeddingStaleStatsProvider);
    final running = state.isRunning || state.isPaused;
    // Settings are locked while a run uses them.
    ValueChanged<bool> toggle(void Function(bool) apply) =>
        running ? (_) {} : (v) => setState(() => apply(v));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MenuGroup(
          compact: true,
          header: 'vector_rebuild_title'.tr(),
          description: 'vector_rebuild_desc'.tr(),
          items: [
            _buildStatsItem(stats),
            MenuSwitchItem(
              label: 'vector_rebuild_memory_books'.tr(),
              value: _memoryBooks,
              onChanged: toggle((v) => _memoryBooks = v),
            ),
            MenuSwitchItem(
              label: 'vector_rebuild_lorebooks'.tr(),
              value: _lorebooks,
              onChanged: toggle((v) => _lorebooks = v),
            ),
            MenuSwitchItem(
              label: 'vector_rebuild_raw_chat'.tr(),
              value: _rawChat,
              onChanged: toggle((v) => _rawChat = v),
            ),
            MenuSwitchItem(
              label: 'vector_rebuild_force'.tr(),
              description: 'vector_rebuild_force_desc'.tr(),
              value: _force,
              onChanged: toggle((v) => _force = v),
            ),
            _NumberField(
              label: 'vector_rebuild_per_minute'.tr(),
              controller: _vectorsPerMinuteCtrl,
              placeholder: '30',
            ),
            _NumberField(
              label: 'vector_rebuild_batch_size'.tr(),
              controller: _batchSizeCtrl,
              placeholder: '10',
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (running ||
                  state.status == VectorRebuildStatus.completed ||
                  state.status == VectorRebuildStatus.error)
                _buildProgress(state),
              _buildActions(state, running),
            ],
          ),
        ),
      ],
    );
  }

  /// How many stored vectors no longer match the current embedding config.
  /// Tapping re-checks.
  Widget _buildStatsItem(AsyncValue<EmbeddingStaleStats> stats) {
    final value = stats.value;
    final stale = value?.stale ?? 0;
    final total = value?.total ?? 0;
    final subtitle = [
      if (value != null && value.bySource.isNotEmpty)
        value.bySource.entries.map((e) => '${e.key}: ${e.value}').join(' • '),
      if ((value?.missingMetadata ?? 0) > 0)
        'vector_rebuild_missing_metadata'.tr(
          namedArgs: {'count': '${value!.missingMetadata}'},
        ),
    ].join('\n');
    return MenuItem(
      icon: stale > 0
          ? Icons.warning_amber_rounded
          : Icons.check_circle_outline,
      label: stats.isLoading
          ? 'vector_rebuild_checking'.tr()
          : stale > 0
          ? 'vector_rebuild_stale'.tr(
              namedArgs: {'stale': '$stale', 'total': '$total'},
            )
          : 'vector_rebuild_up_to_date'.tr(namedArgs: {'total': '$total'}),
      subtitle: subtitle.isEmpty ? null : subtitle,
      trailing: Icon(
        Icons.refresh_rounded,
        size: 20,
        color: context.cs.onSurfaceVariant,
      ),
      onTap: () => ref.invalidate(embeddingStaleStatsProvider),
    );
  }

  Widget _buildProgress(VectorRebuildState state) {
    final style = TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: state.progress.clamp(0, 1),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'vector_rebuild_progress'.tr(
              namedArgs: {
                'current': '${state.current}',
                'total': '${state.total}',
                'indexed': '${state.indexed}',
                'skipped': '${state.skipped}',
                'failed': '${state.failed}',
              },
            ),
            style: style,
          ),
          if (state.currentLabel.isNotEmpty)
            Text(
              state.currentLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          if (state.message.isNotEmpty) Text(state.message, style: style),
        ],
      ),
    );
  }

  Widget _buildActions(VectorRebuildState state, bool running) {
    final controller = ref.read(vectorRebuildControllerProvider.notifier);
    if (!running) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlazeActionButton(
            icon: Icons.sync_rounded,
            label: 'vector_rebuild_start'.tr(),
            tone: GlazeActionTone.primary,
            expand: true,
            onTap: _start,
          ),
          const SizedBox(height: 8),
          GlazeActionButton(
            icon: Icons.delete_sweep_outlined,
            label: 'vector_reindex_start'.tr(),
            tone: GlazeActionTone.neutral,
            expand: true,
            onTap: () => _start(clearExisting: true),
          ),
          const SizedBox(height: 6),
          Text(
            'vector_reindex_desc'.tr(),
            style: TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: GlazeActionButton(
            icon: state.isPaused
                ? Icons.play_arrow_rounded
                : Icons.pause_rounded,
            label: state.isPaused
                ? 'vector_rebuild_resume'.tr()
                : 'vector_rebuild_pause'.tr(),
            tone: GlazeActionTone.neutral,
            expand: true,
            onTap: state.isPaused ? controller.resume : controller.pause,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: GlazeActionButton(
            icon: Icons.stop_rounded,
            label: 'btn_cancel'.tr(),
            tone: GlazeActionTone.destructive,
            expand: true,
            onTap: controller.cancel,
          ),
        ),
      ],
    );
  }
}

class _NumberField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String placeholder;

  const _NumberField({
    required this.label,
    required this.controller,
    required this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    return MenuFieldItem(
      label: label,
      controller: controller,
      placeholder: placeholder,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    );
  }
}
