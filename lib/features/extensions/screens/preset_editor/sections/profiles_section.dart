import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../shared/widgets/glaze_action_button.dart';
import '../../../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../../../shared/widgets/glaze_sheet.dart';
import '../../../../../shared/widgets/menu_group.dart';
import '../../../../../shared/widgets/sheet_view.dart';
import '../../../../settings/widgets/api_slot_group.dart';
import '../../../models/connection_profiles.dart';
import '../../../models/extension_preset.dart';
import '../../../models/profile_params.dart';
import '../../../providers/extension_presets_provider.dart';

/// The connection every LLM call this preset makes runs on.
///
/// It is the same [ApiSlotGroup] the Agents tab and the memory
/// books sheet bind their auxiliary calls with, so the connection and model
/// rows read and behave identically here. Unlike those two it writes straight
/// through — the panel has no draft to save.
class ProfilesSection extends ConsumerWidget {
  const ProfilesSection({required this.preset, super.key});

  final ExtensionPreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void update(ExtensionPreset next) =>
        ref.read(extensionPresetsProvider.notifier).update(next);

    return ApiSlotGroup(
      header: 'tab_api'.tr(),
      description: 'extblocks_api_section_desc'.tr(),
      apiConfigId: preset.apiConfigId,
      onApiConfigChanged: (id) => update(
        // Endpoint and key always come from the selected connection; a model
        // chosen against the previous one would not resolve.
        preset.copyWith(apiConfigId: id, apiModel: ''),
      ),
      modelRows: [
        ApiSlotModelRow(
          value: preset.apiModel,
          onChanged: (value) => update(preset.copyWith(apiModel: value)),
        ),
      ],
    );
  }
}

/// The generation parameters of the original's three API presets, `big`,
/// `medium` and `small`, which a block picks by its `api_preset`.
///
/// Only in the full preset editor: the quick sheet keeps to the connection.
class GenerationProfilesSection extends ConsumerWidget {
  const GenerationProfilesSection({required this.preset, super.key});

  final ExtensionPreset preset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void update(ExtensionPreset next) =>
        ref.read(extensionPresetsProvider.notifier).update(next);

    Future<void> editProfile(ConnectionProfile profile) async {
      final edited = await showGlazeSheet<ProfileParams>(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _ProfileParamsSheet(
          profile: profile,
          initial: profileParamsFor(preset.profileParams, profile),
        ),
      );
      if (edited == null) return;
      final next = {...preset.profileParams};
      if (edited.isEmpty) {
        next.remove(profile.id);
      } else {
        next[profile.id] = edited;
      }
      update(preset.copyWith(profileParams: next));
    }

    return MenuGroup(
      header: 'extblocks_profiles_header'.tr(),
      items: [
        for (final profile in ConnectionProfile.values)
          MenuItem(
            icon: profileIcon(profile),
            label: profileLabel(profile),
            subtitle: profileParamsSummary(
              profileParamsFor(preset.profileParams, profile),
            ),
            onTap: () => editProfile(profile),
          ),
      ],
    );
  }
}

String profileLabel(ConnectionProfile profile) => switch (profile) {
  ConnectionProfile.big => 'extblocks_profile_big'.tr(),
  ConnectionProfile.medium => 'extblocks_profile_medium'.tr(),
  ConnectionProfile.small => 'extblocks_profile_small'.tr(),
};

/// The original's battery icons: full, half, empty.
IconData profileIcon(ConnectionProfile profile) => switch (profile) {
  ConnectionProfile.big => Icons.battery_full_rounded,
  ConnectionProfile.medium => Icons.battery_4_bar_rounded,
  ConnectionProfile.small => Icons.battery_1_bar_rounded,
};

/// One line saying what a profile changes, or that it changes nothing.
String profileParamsSummary(ProfileParams params) {
  if (params.isEmpty) return 'extblocks_profile_inherits'.tr();
  return [
    if (params.temperature != null) 'T ${params.temperature}',
    if (params.topP != null) 'top_p ${params.topP}',
    if (params.maxTokens != null) '${params.maxTokens} tok',
    if (params.reasoningEffort != null)
      '${'extblocks_profile_reasoning'.tr()}: ${params.reasoningEffort}',
    if (params.confirmationJb) 'confirm',
  ].join(' · ');
}

const _reasoningSteps = ['auto', 'min', 'low', 'medium', 'high', 'max'];

class _ProfileParamsSheet extends StatefulWidget {
  const _ProfileParamsSheet({required this.profile, required this.initial});

  final ConnectionProfile profile;
  final ProfileParams initial;

  @override
  State<_ProfileParamsSheet> createState() => _ProfileParamsSheetState();
}

class _ProfileParamsSheetState extends State<_ProfileParamsSheet> {
  late final _temperature = TextEditingController(
    text: widget.initial.temperature?.toString() ?? '',
  );
  late final _topP = TextEditingController(
    text: widget.initial.topP?.toString() ?? '',
  );
  late final _maxTokens = TextEditingController(
    text: widget.initial.maxTokens?.toString() ?? '',
  );
  late String? _reasoningEffort = widget.initial.reasoningEffort;
  late bool _confirmationJb = widget.initial.confirmationJb;

  @override
  void dispose() {
    _temperature.dispose();
    _topP.dispose();
    _maxTokens.dispose();
    super.dispose();
  }

  double? _double(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  void _save() {
    final maxTokens = int.tryParse(_maxTokens.text.trim());
    Navigator.of(context).pop(
      ProfileParams(
        temperature: _double(_temperature),
        topP: _double(_topP),
        maxTokens: maxTokens != null && maxTokens > 0 ? maxTokens : null,
        reasoningEffort: _reasoningEffort,
        confirmationJb: _confirmationJb,
      ),
    );
  }

  Future<void> _pickReasoning() async {
    String label(String? step) => step ?? 'extblocks_profile_inherit'.tr();
    await GlazeBottomSheet.show<void>(
      context,
      title: 'extblocks_profile_reasoning'.tr(),
      items: [
        for (final step in <String?>[null, ..._reasoningSteps])
          BottomSheetItem(
            label: label(step),
            icon: _reasoningEffort == step
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            onTap: () {
              Navigator.of(context, rootNavigator: true).pop();
              setState(() => _reasoningEffort = step);
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const number = TextInputType.numberWithOptions(decimal: true);
    return SheetView(
      title: profileLabel(widget.profile),
      showHandle: true,
      bodyPadding: const EdgeInsets.fromLTRB(0, 0, 0, 24),
      body: ListView(
        children: [
          MenuGroup(
            description: 'extblocks_profile_desc'.tr(),
            items: [
              MenuFieldItem(
                label: 'extblocks_profile_temperature'.tr(),
                controller: _temperature,
                placeholder: 'extblocks_profile_inherit'.tr(),
                keyboardType: number,
              ),
              MenuFieldItem(
                label: 'Top P',
                controller: _topP,
                placeholder: 'extblocks_profile_inherit'.tr(),
                keyboardType: number,
              ),
              MenuFieldItem(
                label: 'extblocks_profile_max_tokens'.tr(),
                controller: _maxTokens,
                placeholder: 'extblocks_profile_inherit'.tr(),
                keyboardType: TextInputType.number,
              ),
              MenuSelectorItem(
                label: 'extblocks_profile_reasoning'.tr(),
                currentValue:
                    _reasoningEffort ?? 'extblocks_profile_inherit'.tr(),
                onTap: _pickReasoning,
              ),
              MenuSwitchItem(
                label: 'extblocks_profile_confirmation'.tr(),
                description: 'extblocks_profile_confirmation_desc'.tr(),
                value: _confirmationJb,
                onChanged: (v) => setState(() => _confirmationJb = v),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlazeActionButton(
              icon: Icons.check_rounded,
              label: 'btn_save'.tr(),
              tone: GlazeActionTone.primary,
              expand: true,
              onTap: _save,
            ),
          ),
        ],
      ),
    );
  }
}
