import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/fullscreen_editor.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../settings/app_settings_provider.dart';
import '../../settings/widgets/api_slot_group.dart';
import '../services/janitor_lorebook_rebuilder.dart';

/// Which connection and model lorebook builds run on — the closed-lorebook
/// rebuild and the scripted-lorebook conversion alike.
///
/// The same group sits in three places: the Agents tab of the API settings,
/// the lorebook capture sheet's settings and the content providers screen.
/// All three write the same app setting through, so they always agree.
class LorebookBuildLlmGroup extends ConsumerWidget {
  const LorebookBuildLlmGroup({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider).value;
    if (settings == null) return const SizedBox.shrink();
    void save(AppSettings Function(AppSettings) mutate) {
      final latest = ref.read(appSettingsProvider).value ?? settings;
      ref.read(appSettingsProvider.notifier).save(mutate(latest));
    }

    return ApiSlotGroup(
      header: 'lorebook_build_llm_title'.tr(),
      description: 'lorebook_build_llm_desc'.tr(),
      apiConfigId: settings.lorebookBuildApiConfigId,
      onApiConfigChanged: (id) => save(
        // A model picked against the previous connection would not resolve on
        // the new one, so the override goes with it.
        (s) => s.copyWith(lorebookBuildApiConfigId: id, lorebookBuildModel: ''),
      ),
      modelRows: [
        ApiSlotModelRow(
          value: settings.lorebookBuildModel,
          onChanged: (value) =>
              save((s) => s.copyWith(lorebookBuildModel: value)),
        ),
      ],
    );
  }
}

/// The two system prompts the lorebook build LLM is given — for a closed
/// lorebook recovered from the captured prompt, and for a scripted one — plus
/// a reset to the built-in wording.
///
/// The fields carry the prompt actually in use (the user's own, or the default)
/// so editing starts from the real text instead of an empty box.
class LorebookBuildPromptsGroup extends ConsumerStatefulWidget {
  const LorebookBuildPromptsGroup({super.key});

  @override
  ConsumerState<LorebookBuildPromptsGroup> createState() =>
      _LorebookBuildPromptsGroupState();
}

class _LorebookBuildPromptsGroupState
    extends ConsumerState<LorebookBuildPromptsGroup> {
  final _promptController = TextEditingController();
  final _promptJsController = TextEditingController();

  /// Typing writes to SharedPreferences, so the save is debounced rather than
  /// run per keystroke.
  Timer? _debounce;
  bool _seeded = false;

  /// The notifier and the settings as of the last build, held so the
  /// dispose-time flush can still write: both outlive this widget, `ref` does
  /// not.
  AppSettingsNotifier? _notifier;
  AppSettings? _latest;

  @override
  void dispose() {
    // Flush a pending edit before the fields go away: closing the screen right
    // after typing must not drop the last keystrokes.
    if (_debounce?.isActive ?? false) {
      _debounce!.cancel();
      _writePrompts();
    }
    _promptController.dispose();
    _promptJsController.dispose();
    super.dispose();
  }

  void _seed(AppSettings settings) {
    if (_seeded) return;
    _seeded = true;
    _promptController.text = lorebookSystemPrompt(settings);
    _promptJsController.text = lorebookSystemPrompt(settings, fromJs: true);
  }

  void _savePrompts({bool immediate = false}) {
    _debounce?.cancel();
    if (immediate) {
      _writePrompts();
    } else {
      _debounce = Timer(const Duration(milliseconds: 600), _writePrompts);
    }
  }

  /// Persists both fields against the settings as of the last build, so a
  /// change made elsewhere between the keystroke and the debounce is carried
  /// along. A field left exactly at the built-in default is stored as empty:
  /// the setting then keeps tracking the default instead of pinning today's
  /// wording forever.
  void _writePrompts() {
    final notifier = _notifier;
    final settings = _latest;
    if (notifier == null || settings == null) return;
    final main = _promptController.text.trim();
    final js = _promptJsController.text.trim();
    notifier.save(
      settings.copyWith(
        lorebookBuildPrompt: main == kLorebookSystemPrompt ? '' : main,
        lorebookBuildPromptJs: js == kLorebookSystemPromptJs ? '' : js,
      ),
    );
  }

  Future<void> _expand({
    required TextEditingController controller,
    required String title,
  }) async {
    await FullscreenEditorScreen.show(
      context,
      title: title,
      initialValue: controller.text,
      onChanged: (value) {
        if (!mounted) return;
        controller.text = value;
        setState(() {});
        _savePrompts();
      },
    );
  }

  void _resetPrompts() {
    _promptController.text = kLorebookSystemPrompt;
    _promptJsController.text = kLorebookSystemPromptJs;
    setState(() {});
    _savePrompts(immediate: true);
    GlazeToast.show(context, 'catalog_extraction_prompt_reset_done'.tr());
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider).value;
    _notifier = ref.read(appSettingsProvider.notifier);
    _latest = settings;
    if (settings != null) _seed(settings);

    return MenuGroup(
      header: 'catalog_extraction_settings_prompts'.tr(),
      helpTerm: 'lorebook-build-prompt',
      description: 'catalog_extraction_settings_prompts_hint'.tr(),
      items: [
        MenuFieldItem(
          label: 'catalog_extraction_prompt_main'.tr(),
          description: 'catalog_extraction_prompt_main_desc'.tr(),
          controller: _promptController,
          maxLines: 8,
          onChanged: (_) => _savePrompts(),
          onExpand: () => _expand(
            controller: _promptController,
            title: 'catalog_extraction_prompt_main'.tr(),
          ),
        ),
        MenuFieldItem(
          label: 'catalog_extraction_prompt_js'.tr(),
          description: 'catalog_extraction_prompt_js_desc'.tr(),
          controller: _promptJsController,
          maxLines: 8,
          onChanged: (_) => _savePrompts(),
          onExpand: () => _expand(
            controller: _promptJsController,
            title: 'catalog_extraction_prompt_js'.tr(),
          ),
        ),
        MenuItem(
          icon: Icons.restart_alt_rounded,
          label: 'catalog_extraction_prompt_reset'.tr(),
          subtitle: 'catalog_extraction_prompt_reset_sub'.tr(),
          onTap: _resetPrompts,
        ),
      ],
    );
  }
}
