import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/llm/studio_controller_ontology.dart';
import '../../../core/llm/studio_activation_gate.dart';
import '../../../core/models/studio_config.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';

const _beautyPipelineBlockIds = {
  'beauty_extractor',
  'beauty_task',
  'cleaner_beauty',
};

/// Applies a controller toggle to a preset. Beauty spans build, tracker, and
/// cleaner stages, so its one visible toggle owns all three persisted blocks.
StudioPreset applyStudioAgentToggle(
  StudioPreset preset,
  String specId,
  bool enabled,
) {
  final updated = Map<String, bool>.from(preset.agentEnabled)
    ..[specId] = enabled;
  if (specId != 'beauty') {
    return preset.copyWith(agentEnabled: updated);
  }
  return preset.copyWith(
    agentEnabled: updated,
    blocks: [
      for (final block in preset.blocks)
        _beautyPipelineBlockIds.contains(block.id)
            ? block.copyWith(enabled: enabled)
            : block,
    ],
  );
}

/// Agent on/off toggles for a Studio preset.
///
/// Shows one switch per controller spec (continuity, narrative, final, etc.).
/// State is persisted into `StudioPreset.agentEnabled` so it travels with
/// the preset on import/export.
class StudioAgentsSheet extends ConsumerStatefulWidget {
  final String presetId;

  const StudioAgentsSheet({super.key, required this.presetId});

  static Future<void> show(BuildContext context, {required String presetId}) {
    return GlazeBottomSheet.show<void>(
      context,
      title: 'Agents',
      child: StudioAgentsSheet(presetId: presetId),
    );
  }

  @override
  ConsumerState<StudioAgentsSheet> createState() => _StudioAgentsSheetState();
}

class _StudioAgentsSheetState extends ConsumerState<StudioAgentsSheet> {
  StudioPreset? _preset;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final preset = await ref
        .read(studioPresetRepoProvider)
        .getById(widget.presetId);
    if (!mounted) return;
    setState(() {
      _preset = preset;
      _loading = false;
    });
  }

  Future<void> _toggle(String specId, bool value) async {
    if (_preset == null) return;
    final next = applyStudioAgentToggle(
      _preset!,
      specId,
      value,
    ).copyWith(updatedAt: DateTime.now().millisecondsSinceEpoch);
    await ref.read(studioPresetRepoProvider).upsert(next);
    setState(() => _preset = next);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_preset == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('Preset not found')),
      );
    }
    final enabledMap = _preset!.agentEnabled;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: StudioControllerOntology.specs.length,
        itemBuilder: (context, index) {
          final spec = StudioControllerOntology.specs[index];
          final allowedByTopology = StudioActivationGate.isControllerAllowed(
            spec.id,
            _preset!.executionMode,
          );
          final isOn = spec.id == 'beauty'
              ? _preset!.blocks
                        .where((block) => block.id == 'beauty_extractor')
                        .firstOrNull
                        ?.enabled ??
                    false
              : enabledMap[spec.id] ?? true;
          return SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 0,
            ),
            secondary: Icon(
              spec.isFinal ? Icons.star_outline : Icons.smart_toy_outlined,
              color: spec.isFinal
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: Text(spec.name),
            subtitle: Text(
              spec.purpose,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
            value: isOn,
            onChanged: allowedByTopology ? (v) => _toggle(spec.id, v) : null,
          );
        },
      ),
    );
  }
}
