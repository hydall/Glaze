import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/character_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_spinner.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../personas/persona_list_provider.dart';
import '../models/tts_settings.dart';
import '../models/tts_types.dart';
import '../providers/tts_provider.dart';
import '../services/tts_engine.dart';
import '../services/tts_text_preparer.dart';
import '../services/tts_voice_resolver.dart';
import '../tts_provider.dart';
import 'tts_field_rows.dart';
import 'tts_voice_map_section.dart';

/// TTS settings: the switch, the provider and its fields, the voice map,
/// what gets read and how, and the audio cache. Opened from the chat
/// drawer (with [charId], so the chat's character shows in the voice map)
/// and from the Tools tab.
class TtsSheet extends ConsumerStatefulWidget {
  const TtsSheet({super.key, this.charId});

  final String? charId;

  @override
  ConsumerState<TtsSheet> createState() => _TtsSheetState();
}

class _TtsSheetState extends ConsumerState<TtsSheet> {
  final ScrollController _scroll = ScrollController();
  bool _checking = false;
  Future<int>? _cacheSize;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _save(TtsSettings s) => ref.read(ttsSettingsProvider.notifier).save(s);

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(ttsSettingsProvider).value ?? const TtsSettings();
    final engine = ref.watch(ttsEngineProvider).value;
    return SheetView(
      titleWidget: Row(
        children: [
          Text(
            'tts_title'.tr(),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          Switch(
            value: settings.enabled,
            onChanged: (v) => _save(settings.copyWith(enabled: v)),
          ),
        ],
      ),
      fitContent: false,
      scrollController: _scroll,
      enableHeaderBlur: false,
      body: !settings.enabled
          ? _placeholder(context)
          : engine == null
          ? const Center(child: GlazeSpinner())
          : _body(context, settings, engine),
    );
  }

  Widget _placeholder(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.record_voice_over_outlined,
            size: 56,
            color: context.cs.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'tts_disabled_placeholder'.tr(),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
          ),
        ],
      ),
    ),
  );

  List<TtsSpeaker> _speakers() {
    final speakers = <TtsSpeaker>[];
    final charId = widget.charId;
    if (charId != null) {
      final character = ref.watch(characterByIdProvider(charId));
      if (character != null) {
        speakers.add(TtsSpeaker(ttsCharKey(charId), character.name));
      }
    }
    final personas = ref.watch(personaListProvider).value ?? const [];
    for (final persona in personas) {
      speakers.add(
        TtsSpeaker(
          ttsUserKey(persona.id),
          '${persona.name} (${'tts_persona'.tr()})',
        ),
      );
    }
    return speakers;
  }

  Widget _body(BuildContext context, TtsSettings s, TtsEngine engine) {
    final registry = ref.watch(ttsRegistryProvider);
    final provider = registry.byId(s.providerId) ?? registry.providers.first;
    final config = provider.configFrom(s.settingsFor(provider.id));
    return Builder(
      builder: (context) => SingleChildScrollView(
        controller: _scroll,
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + 16,
          bottom: MediaQuery.paddingOf(context).bottom + 24,
        ),
        child: Column(
          children: [
            MenuGroup(
              header: 'tts_provider'.tr(),
              description: provider.description.isEmpty
                  ? null
                  : provider.description,
              items: [
                MenuSelectorItem(
                  label: 'tts_provider'.tr(),
                  currentValue: provider.displayName,
                  onTap: () => showTtsOptions<TtsProvider>(
                    context,
                    title: 'tts_provider'.tr(),
                    items: registry.providers,
                    labelOf: (p) => p.displayName,
                    hintOf: (p) => p.isLocal ? 'tts_local_server'.tr() : null,
                    isSelected: (p) => p.id == provider.id,
                    onSelected: (p) => _save(s.copyWith(providerId: p.id)),
                  ),
                ),
                ...buildTtsFieldRows(
                  context: context,
                  fields: provider.fields,
                  config: config,
                  onChanged: (key, value) =>
                      _save(s.withProviderValue(provider.id, key, value)),
                ),
                MenuItem(
                  icon: Icons.wifi_tethering,
                  label: 'tts_check'.tr(),
                  trailing: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: GlazeSpinner(),
                        )
                      : null,
                  onTap: () => _check(provider, config),
                ),
              ],
            ),
            TtsVoiceMapSection(
              engine: engine,
              provider: provider,
              settings: s,
              speakers: _speakers(),
              onChanged: _save,
            ),
            _narrationGroup(s),
            _textGroup(s),
            _playbackGroup(s),
            _cacheGroup(context, s, engine),
          ],
        ),
      ),
    );
  }

  Future<void> _check(TtsProvider provider, TtsProviderConfig config) async {
    setState(() => _checking = true);
    try {
      await provider.checkReady(config);
      if (mounted) GlazeToast.show(context, 'tts_check_ok'.tr());
    } catch (e) {
      if (mounted) GlazeToast.show(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Widget _narrationGroup(TtsSettings s) => MenuGroup(
    header: 'tts_narration'.tr(),
    items: [
      MenuSwitchItem(
        label: 'tts_auto'.tr(),
        description: 'tts_auto_desc'.tr(),
        value: s.autoGeneration,
        onChanged: (v) => _save(s.copyWith(autoGeneration: v)),
      ),
      MenuSwitchItem(
        label: 'tts_streaming'.tr(),
        description: 'tts_streaming_desc'.tr(),
        value: s.narrateWhileStreaming,
        onChanged: (v) => _save(s.copyWith(narrateWhileStreaming: v)),
      ),
      MenuSwitchItem(
        label: 'tts_user'.tr(),
        description: 'tts_user_desc'.tr(),
        value: s.narrateUser,
        onChanged: (v) => _save(s.copyWith(narrateUser: v)),
      ),
      MenuSwitchItem(
        label: 'tts_paragraphs'.tr(),
        description: 'tts_paragraphs_desc'.tr(),
        value: s.narrateByParagraphs,
        onChanged: (v) => _save(s.copyWith(narrateByParagraphs: v)),
      ),
      MenuSwitchItem(
        label: 'tts_multi_voice'.tr(),
        description: 'tts_multi_voice_desc'.tr(),
        value: s.multiVoice,
        onChanged: (v) => _save(s.copyWith(multiVoice: v)),
      ),
    ],
  );

  Widget _textGroup(TtsSettings s) {
    final regexInvalid = s.applyRegex &&
        s.regexPattern.trim().isNotEmpty &&
        TtsTextPreparer.parseUserRegex(s.regexPattern) == null;
    return MenuGroup(
      header: 'tts_text'.tr(),
      items: [
        MenuSwitchItem(
          label: 'tts_quotes_only'.tr(),
          description: 'tts_quotes_only_desc'.tr(),
          value: s.narrateQuotedOnly,
          onChanged: (v) => _save(s.copyWith(narrateQuotedOnly: v)),
        ),
        MenuSwitchItem(
          label: 'tts_ignore_asterisks'.tr(),
          description: 'tts_ignore_asterisks_desc'.tr(),
          value: s.ignoreAsterisks,
          onChanged: (v) => _save(s.copyWith(ignoreAsterisks: v)),
        ),
        MenuSwitchItem(
          label: 'tts_pass_asterisks'.tr(),
          description: 'tts_pass_asterisks_desc'.tr(),
          value: s.passAsterisks,
          onChanged: (v) => _save(s.copyWith(passAsterisks: v)),
        ),
        MenuSwitchItem(
          label: 'tts_skip_code'.tr(),
          value: s.skipCodeblocks,
          onChanged: (v) => _save(s.copyWith(skipCodeblocks: v)),
        ),
        MenuSwitchItem(
          label: 'tts_skip_tags'.tr(),
          description: 'tts_skip_tags_desc'.tr(),
          value: s.skipTags,
          onChanged: (v) => _save(s.copyWith(skipTags: v)),
        ),
        MenuSwitchItem(
          label: 'tts_regex'.tr(),
          description: 'tts_regex_desc'.tr(),
          value: s.applyRegex,
          onChanged: (v) => _save(s.copyWith(applyRegex: v)),
        ),
        if (s.applyRegex)
          TtsTextFieldRow(
            label: 'tts_regex_pattern'.tr(),
            value: s.regexPattern,
            hint: r'/\[OOC:.*?\]/gi',
            onChanged: (v) => _save(s.copyWith(regexPattern: v)),
          ),
        if (regexInvalid)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'tts_regex_invalid'.tr(),
              style: TextStyle(color: context.cs.error, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _playbackGroup(TtsSettings s) => MenuGroup(
    header: 'tts_playback'.tr(),
    items: [
      MenuRangeItem(
        label: 'tts_playback_rate'.tr(),
        value: s.playbackRate,
        min: 0.5,
        max: 2,
        divisions: 30,
        unit: '×',
        onChanged: (v) => _save(s.copyWith(playbackRate: v)),
        onReset: s.playbackRate != 1
            ? () => _save(s.copyWith(playbackRate: 1))
            : null,
      ),
    ],
  );

  Widget _cacheGroup(BuildContext context, TtsSettings s, TtsEngine engine) {
    final size = _cacheSize ??= engine.cache.persistentSize();
    return MenuGroup(
      header: 'tts_cache'.tr(),
      items: [
        MenuSwitchItem(
          label: 'tts_cache_enabled'.tr(),
          description: 'tts_cache_enabled_desc'.tr(),
          value: s.cacheEnabled,
          onChanged: (v) => _save(s.copyWith(cacheEnabled: v)),
        ),
        FutureBuilder<int>(
          future: size,
          builder: (context, snap) => MenuItem(
            icon: Icons.delete_outline,
            label: 'tts_cache_clear'.tr(),
            value: snap.hasData ? _formatBytes(snap.data!) : null,
            onTap: () => _confirmClear(engine),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClear(TtsEngine engine) async {
    final confirmed = await GlazeBottomSheet.show<bool>(
      context,
      title: 'tts_cache_clear'.tr(),
      bigInfo: BottomSheetBigInfo(
        icon: Icons.delete_outline,
        description: 'tts_cache_clear_desc'.tr(),
      ),
      items: [
        BottomSheetItem(
          icon: Icons.delete_outline,
          label: 'common_clear'.tr(),
          isDestructive: true,
          onTap: () => Navigator.of(context, rootNavigator: true).pop(true),
        ),
        BottomSheetItem(
          icon: Icons.close,
          label: 'common_cancel'.tr(),
          onTap: () => Navigator.of(context, rootNavigator: true).pop(false),
        ),
      ],
    );
    if (confirmed != true) return;
    await engine.stop();
    await engine.cache.clearAll();
    engine.forgetMessages();
    if (mounted) setState(() => _cacheSize = null);
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
