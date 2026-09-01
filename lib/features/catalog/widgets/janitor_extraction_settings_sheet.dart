import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/fullscreen_editor.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../settings/app_settings_provider.dart';
import '../janitor_account_provider.dart';
import '../services/janitor_lorebook_rebuilder.dart';
import 'janitor_login_sheet.dart';
import 'janitor_source_settings.dart';

/// Settings for the JanitorAI extraction flow, opened from the gear in the
/// lorebook capture sheet's header.
///
/// Everything that decides *how* a closed lorebook is recovered lives here: the
/// account the capture runs through, the local-extraction opt-in it needs, and
/// the system prompts the build LLM is given. Keeping them one tap from the
/// flow means a failed build can be corrected where it failed, instead of in
/// the app's settings screen two navigations away.
Future<void> showJanitorExtractionSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (_) => const _JanitorExtractionSettingsSheet(),
  );
}

class _JanitorExtractionSettingsSheet extends ConsumerStatefulWidget {
  const _JanitorExtractionSettingsSheet();

  @override
  ConsumerState<_JanitorExtractionSettingsSheet> createState() =>
      _JanitorExtractionSettingsSheetState();
}

class _JanitorExtractionSettingsSheetState
    extends ConsumerState<_JanitorExtractionSettingsSheet> {
  /// The prompt fields carry the prompt that is actually in use — the user's
  /// own when they edited it, the built-in default otherwise — so editing
  /// starts from the real text instead of an empty box.
  final _promptController = TextEditingController();
  final _promptJsController = TextEditingController();

  /// Typing writes to SharedPreferences, so the save is debounced rather than
  /// run per keystroke.
  Timer? _debounce;
  bool _seeded = false;

  /// The notifier and the settings as of the last build, held so the
  /// dispose-time flush can still write: both outlive this sheet, `ref` does
  /// not.
  AppSettingsNotifier? _notifier;
  AppSettings? _latest;

  @override
  void dispose() {
    // Flush a pending edit before the fields go away: closing the sheet right
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

  /// Persists both prompt fields. A field left exactly at the built-in default
  /// is stored as empty: the setting then keeps tracking the default instead of
  /// pinning today's wording forever.
  void _savePrompts({bool immediate = false}) {
    _debounce?.cancel();
    if (immediate) {
      _writePrompts();
    } else {
      _debounce = Timer(const Duration(milliseconds: 600), _writePrompts);
    }
  }

  /// The write itself, against the settings as of the last build — so a toggle
  /// flipped between the keystroke and the debounce firing is carried along
  /// rather than written back over.
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
    final account = ref.watch(janitorAccountProvider);
    _notifier = ref.read(appSettingsProvider.notifier);
    _latest = settings;
    if (settings != null) _seed(settings);

    return SheetView(
      title: 'catalog_extraction_settings_title'.tr(),
      startExpanded: true,
      body: Builder(
        builder: (inner) => ListView(
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(inner).top + 12,
            bottom: MediaQuery.paddingOf(inner).bottom + 24,
          ),
          children: [
            MenuGroup(
              header: 'catalog_extraction_settings_capture'.tr(),
              helpTerm: 'janitor-extraction',
              description: 'catalog_extraction_settings_capture_hint'.tr(),
              items: [
                MenuItem(
                  icon: Icons.person_outline_rounded,
                  label: 'janitor_login_menu'.tr(),
                  subtitle: account.isLoggedIn
                      ? 'janitor_login_menu_logged_in'.tr(
                          namedArgs: {'name': account.userName ?? ''},
                        )
                      : 'janitor_login_menu_logged_out'.tr(),
                  onTap: () => openJanitorAccountSheet(context, ref),
                ),
                if (settings != null)
                  ...janitorSourceMenuItems(context, ref, settings),
              ],
            ),
            MenuGroup(
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
            ),
          ],
        ),
      ),
    );
  }
}
