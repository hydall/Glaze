import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/menu_group.dart';
import '../models/tts_settings.dart';
import '../models/tts_types.dart';
import '../providers/tts_provider.dart';
import '../services/tts_engine.dart';
import '../services/tts_text_preparer.dart';
import '../services/tts_voice_resolver.dart';
import 'tts_field_rows.dart';

/// Someone whose messages can be voiced.
class TtsSpeaker {
  final String key;
  final String name;
  const TtsSpeaker(this.key, this.name);
}

/// The voice map: one row per speaker (three with several voices on), each
/// opening a picker of the provider's voices with a play button per voice.
class TtsVoiceMapSection extends StatefulWidget {
  final TtsEngine engine;
  final TtsProvider provider;
  final TtsSettings settings;
  final List<TtsSpeaker> speakers;
  final ValueChanged<TtsSettings> onChanged;

  const TtsVoiceMapSection({
    super.key,
    required this.engine,
    required this.provider,
    required this.settings,
    required this.speakers,
    required this.onChanged,
  });

  @override
  State<TtsVoiceMapSection> createState() => _TtsVoiceMapSectionState();
}

class _TtsVoiceMapSectionState extends State<TtsVoiceMapSection> {
  Future<List<TtsVoice>>? _voices;
  String? _loadedFor;
  String? _error;

  TtsProviderConfig get _config =>
      widget.provider.configFrom(widget.settings.settingsFor(widget.provider.id));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureVoices();
  }

  @override
  void didUpdateWidget(covariant TtsVoiceMapSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureVoices();
  }

  void _ensureVoices({bool force = false}) {
    final signature = '${widget.provider.id}|${_config.values}';
    if (!force && signature == _loadedFor) return;
    _loadedFor = signature;
    if (force) widget.engine.catalog.invalidate();
    _error = null;
    final future = widget.engine.catalog.voicesFor(widget.provider, _config);
    _voices = future;
    future.then(
      (_) {},
      onError: (Object e) {
        if (mounted && identical(_voices, future)) {
          setState(() => _error = e.toString());
        }
      },
    );
  }

  Map<String, String> get _map => widget.settings.voiceMapFor(widget.provider.id);

  void _assign(String key, String? value) {
    widget.onChanged(widget.settings.withVoice(widget.provider.id, key, value));
  }

  String _label(String? value, {required bool inherits, bool isDefault = false}) {
    if (value == null || value.isEmpty) {
      if (isDefault) return 'tts_voice_first'.tr();
      return inherits ? 'tts_voice_same'.tr() : 'tts_voice_default'.tr();
    }
    if (value == ttsDefaultVoiceMarker) return 'tts_voice_default'.tr();
    if (value == ttsDisabledVoiceMarker) return 'tts_voice_disabled'.tr();
    return value;
  }

  Future<void> _pick(String key, String title, {required bool isDefault, required bool inherits}) async {
    List<TtsVoice> voices;
    try {
      voices = await (_voices ?? Future.value(const <TtsVoice>[]));
    } catch (e) {
      if (mounted) GlazeToast.show(context, e.toString(), isError: true);
      return;
    }
    if (!mounted) return;
    final current = _map[key];
    // (stored value, label, voice for preview)
    final options = <(String?, String, TtsVoice?)>[
      if (inherits) (null, 'tts_voice_same'.tr(), null),
      if (isDefault) (null, 'tts_voice_first'.tr(), null),
      if (!isDefault && !inherits) (null, 'tts_voice_default'.tr(), null),
      if (inherits) (ttsDefaultVoiceMarker, 'tts_voice_default'.tr(), null),
      (ttsDisabledVoiceMarker, 'tts_voice_disabled'.tr(), null),
      for (final v in voices) (v.name, v.name, v),
    ];
    showTtsOptions<(String?, String, TtsVoice?)>(
      context,
      title: title,
      items: options,
      searchable: voices.length > 12,
      labelOf: (o) => o.$2,
      hintOf: (o) => o.$3?.lang,
      isSelected: (o) => (o.$1 ?? '') == (current ?? ''),
      actionsOf: (o) => o.$3 == null
          ? const []
          : [
              BottomSheetAction(
                icon: Icons.play_arrow_rounded,
                onTap: () => _preview(o.$3!),
              ),
            ],
      onSelected: (o) => _assign(key, o.$1),
    );
  }

  Future<void> _preview(TtsVoice voice) async {
    try {
      await widget.engine.preview(voice);
    } catch (e) {
      if (mounted) GlazeToast.show(context, e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final multi = widget.settings.multiVoice;
    final perSpeaker = widget.provider.perSpeakerField;
    final config = _config;
    final rows = <Widget>[
      MenuSelectorItem(
        label: 'tts_voice_default'.tr(),
        description: 'tts_voice_default_desc'.tr(),
        currentValue: _label(
          _map[ttsDefaultVoiceKey],
          inherits: false,
          isDefault: true,
        ),
        onTap: () => _pick(
          ttsDefaultVoiceKey,
          'tts_voice_default'.tr(),
          isDefault: true,
          inherits: false,
        ),
      ),
    ];
    for (final speaker in widget.speakers) {
      rows.add(
        MenuSelectorItem(
          label: speaker.name,
          currentValue: _label(_map[speaker.key], inherits: false),
          onTap: () => _pick(speaker.key, speaker.name, isDefault: false, inherits: false),
        ),
      );
      if (multi) {
        for (final type in TtsSegmentType.values) {
          final key = ttsSegmentKey(speaker.key, type);
          final title = '${speaker.name} · ${'tts_segment_${type.name}'.tr()}';
          rows.add(
            MenuSelectorItem(
              label: '   ${'tts_segment_${type.name}'.tr()}',
              currentValue: _label(_map[key], inherits: true),
              onTap: () => _pick(key, title, isDefault: false, inherits: true),
            ),
          );
        }
      }
      if (perSpeaker != null) {
        rows.add(
          buildTtsFieldRow(
            context: context,
            field: TtsField.multiline(
              perSpeaker.key,
              '${speaker.name} · ${perSpeaker.label}',
              hint: perSpeaker.hint,
            ),
            config: config,
            storageKey: '${perSpeaker.key}:${speaker.key}',
            onChanged: (key, value) => widget.onChanged(
              widget.settings.withProviderValue(widget.provider.id, key, value),
            ),
          ),
        );
      }
    }
    rows.add(
      MenuItem(
        icon: Icons.refresh,
        label: 'tts_reload_voices'.tr(),
        subtitle: _error,
        onTap: () => setState(() => _ensureVoices(force: true)),
      ),
    );
    return MenuGroup(
      header: 'tts_voices'.tr(),
      description: 'tts_voices_desc'.tr(),
      items: rows,
    );
  }
}
