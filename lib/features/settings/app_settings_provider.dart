import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform/haptics.dart';
import '../../core/state/shared_prefs_provider.dart';

part 'app_settings_provider.freezed.dart';

const supportedAppLanguages = {'en', 'ru'};

bool? _coerceBool(Object? value) {
  if (value is bool) return value;
  if (value is int) return value != 0;
  if (value is String) {
    final normalized = value.toLowerCase();
    if (normalized == '1' || normalized == 'true') return true;
    if (normalized == '0' || normalized == 'false') return false;
  }
  return null;
}

double? _coerceDouble(Object? value) {
  if (value is int) return value.toDouble();
  if (value is double) return value;
  if (value is String) return double.tryParse(value);
  return null;
}

final appSettingsProvider =
    AsyncNotifierProvider<AppSettingsNotifier, AppSettings>(
      AppSettingsNotifier.new,
    );

@freezed
abstract class AppSettings with _$AppSettings {
  const factory AppSettings({
    @Default(true) bool enterToSend,
    @Default(false) bool hideMessageId,
    @Default(false) bool hideGenerationTime,
    @Default(false) bool hideTokenCount,
    @Default(false) bool groupDialogs,
    @Default(true) bool batterySaver,
    @Default(false) bool hideTooltips,
    @Default(false) bool disableSwipeRegeneration,
    @Default(false) bool allowMessageScripts,
    @Default('en') String language,
    @Default(false) bool virtualKeyboardSend,
    @Default(30) double tokenizerHidePercent,
    @Default(85) double tokenizerHistoryFillThreshold,
    @Default(true) bool showOurPicks,
    @Default(true) bool forceMobileLayout,
    @Default(false) bool addBlockAtTop,
    @Default(true) bool openCardAfterImport,
    @Default(true) bool hapticFeedback,
    @Default(true) bool messageVibration,
    @Default(false) bool extractJanitorLocally,

    /// User-edited system prompt for the closed-lorebook build (the JanitorAI
    /// extraction flow). Empty means the built-in default
    /// (`kLorebookSystemPrompt`) is used — that is also what clearing the field
    /// in the extraction settings does.
    @Default('') String lorebookBuildPrompt,

    /// Same, for the scripted ("advanced" / Nine API) lorebook path, which asks
    /// the model to recover entries from JavaScript source instead of splitting
    /// concatenated bodies. Empty → `kLorebookSystemPromptJs`.
    @Default('') String lorebookBuildPromptJs,

    /// When on, the shuffle button opens a random character straight in the
    /// detail sheet (the classic behaviour) instead of the randomizing
    /// (Holocard) discovery overlay. Off by default.
    @Default(false) bool useStandardRandomizer,
  }) = _AppSettings;
}

/// Canonical SharedPreferences schema for [AppSettings]. Cloud sync uses the
/// same codec as the settings provider so newly added fields cannot silently
/// be omitted from one of the two paths.
abstract final class AppSettingsPreferences {
  static const keys = <String>{
    'enterToSend',
    'hideMessageId',
    'hideGenerationTime',
    'hideTokenCount',
    'dialogGrouping',
    'batterySaver',
    'hideTooltips',
    'disableSwipeRegeneration',
    'allowMessageScripts',
    'language',
    'virtualKeyboardSend',
    'tokenizerHidePercent',
    'tokenizerHistoryFillThreshold',
    'showOurPicks',
    'gz_force_mobile_layout',
    'addBlockAtTop',
    'openCardAfterImport',
    'hapticFeedback',
    'messageVibration',
    'extractJanitorLocally',
    'lorebookBuildPrompt',
    'lorebookBuildPromptJs',
    'useStandardRandomizer',
  };

  static AppSettings read(SharedPreferences prefs) {
    const defaults = AppSettings();
    final savedLanguage = prefs.getString('language');
    return AppSettings(
      enterToSend:
          _coerceBool(prefs.get('enterToSend')) ?? defaults.enterToSend,
      hideMessageId:
          _coerceBool(prefs.get('hideMessageId')) ?? defaults.hideMessageId,
      hideGenerationTime:
          _coerceBool(prefs.get('hideGenerationTime')) ??
          defaults.hideGenerationTime,
      hideTokenCount:
          _coerceBool(prefs.get('hideTokenCount')) ?? defaults.hideTokenCount,
      groupDialogs:
          _coerceBool(prefs.get('dialogGrouping')) ?? defaults.groupDialogs,
      batterySaver:
          _coerceBool(prefs.get('batterySaver')) ?? defaults.batterySaver,
      hideTooltips:
          _coerceBool(prefs.get('hideTooltips')) ?? defaults.hideTooltips,
      disableSwipeRegeneration:
          _coerceBool(prefs.get('disableSwipeRegeneration')) ??
          defaults.disableSwipeRegeneration,
      allowMessageScripts:
          _coerceBool(prefs.get('allowMessageScripts')) ??
          defaults.allowMessageScripts,
      language: supportedAppLanguages.contains(savedLanguage)
          ? savedLanguage!
          : defaults.language,
      virtualKeyboardSend:
          _coerceBool(prefs.get('virtualKeyboardSend')) ??
          defaults.virtualKeyboardSend,
      tokenizerHidePercent:
          _coerceDouble(prefs.get('tokenizerHidePercent')) ??
          defaults.tokenizerHidePercent,
      tokenizerHistoryFillThreshold:
          _coerceDouble(prefs.get('tokenizerHistoryFillThreshold')) ??
          defaults.tokenizerHistoryFillThreshold,
      showOurPicks:
          _coerceBool(prefs.get('showOurPicks')) ?? defaults.showOurPicks,
      forceMobileLayout:
          _coerceBool(prefs.get('gz_force_mobile_layout')) ??
          defaults.forceMobileLayout,
      addBlockAtTop:
          _coerceBool(prefs.get('addBlockAtTop')) ?? defaults.addBlockAtTop,
      openCardAfterImport:
          _coerceBool(prefs.get('openCardAfterImport')) ??
          defaults.openCardAfterImport,
      hapticFeedback:
          _coerceBool(prefs.get('hapticFeedback')) ?? defaults.hapticFeedback,
      messageVibration:
          _coerceBool(prefs.get('messageVibration')) ??
          defaults.messageVibration,
      extractJanitorLocally:
          _coerceBool(prefs.get('extractJanitorLocally')) ??
          defaults.extractJanitorLocally,
      lorebookBuildPrompt:
          prefs.getString('lorebookBuildPrompt') ??
          defaults.lorebookBuildPrompt,
      lorebookBuildPromptJs:
          prefs.getString('lorebookBuildPromptJs') ??
          defaults.lorebookBuildPromptJs,
      useStandardRandomizer:
          _coerceBool(prefs.get('useStandardRandomizer')) ??
          defaults.useStandardRandomizer,
    );
  }

  static Map<String, dynamic> encode(AppSettings settings) {
    final normalized = _normalize(settings);
    return {
      'enterToSend': normalized.enterToSend,
      'hideMessageId': normalized.hideMessageId,
      'hideGenerationTime': normalized.hideGenerationTime,
      'hideTokenCount': normalized.hideTokenCount,
      'dialogGrouping': normalized.groupDialogs,
      'batterySaver': normalized.batterySaver,
      'hideTooltips': normalized.hideTooltips,
      'disableSwipeRegeneration': normalized.disableSwipeRegeneration,
      'allowMessageScripts': normalized.allowMessageScripts,
      'language': normalized.language,
      'virtualKeyboardSend': normalized.virtualKeyboardSend,
      'tokenizerHidePercent': normalized.tokenizerHidePercent,
      'tokenizerHistoryFillThreshold': normalized.tokenizerHistoryFillThreshold,
      'showOurPicks': normalized.showOurPicks,
      'gz_force_mobile_layout': normalized.forceMobileLayout,
      'addBlockAtTop': normalized.addBlockAtTop,
      'openCardAfterImport': normalized.openCardAfterImport,
      'hapticFeedback': normalized.hapticFeedback,
      'messageVibration': normalized.messageVibration,
      'extractJanitorLocally': normalized.extractJanitorLocally,
      'lorebookBuildPrompt': normalized.lorebookBuildPrompt,
      'lorebookBuildPromptJs': normalized.lorebookBuildPromptJs,
      'useStandardRandomizer': normalized.useStandardRandomizer,
    };
  }

  static Future<void> write(
    SharedPreferences prefs,
    AppSettings settings,
  ) async {
    final values = encode(settings);
    for (final entry in values.entries) {
      final value = entry.value;
      if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is double) {
        await prefs.setDouble(entry.key, value);
      } else if (value is String) {
        await prefs.setString(entry.key, value);
      }
    }
  }

  /// Applies only recognized, valid fields. Missing fields from older clients
  /// preserve their local values instead of resetting newly introduced prefs.
  static Future<void> applyPartial(
    SharedPreferences prefs,
    Map<String, dynamic> values,
  ) async {
    final merged = encode(read(prefs));
    for (final key in keys) {
      if (!values.containsKey(key)) continue;
      final incoming = values[key];
      final current = merged[key];
      if (current is bool) {
        final parsed = _coerceBool(incoming);
        if (parsed != null) merged[key] = parsed;
      } else if (current is double) {
        final parsed = _coerceDouble(incoming);
        if (parsed != null) merged[key] = parsed;
      } else if (current is String && incoming is String) {
        merged[key] =
            key == 'language' && !supportedAppLanguages.contains(incoming)
            ? 'en'
            : incoming;
      }
    }
    await write(prefs, _fromMap(merged));
  }

  static Future<void> removeAll(SharedPreferences prefs) async {
    for (final key in keys) {
      await prefs.remove(key);
    }
  }

  static AppSettings _normalize(AppSettings settings) =>
      supportedAppLanguages.contains(settings.language)
      ? settings
      : settings.copyWith(language: 'en');

  static AppSettings _fromMap(Map<String, dynamic> values) => AppSettings(
    enterToSend: values['enterToSend'] as bool,
    hideMessageId: values['hideMessageId'] as bool,
    hideGenerationTime: values['hideGenerationTime'] as bool,
    hideTokenCount: values['hideTokenCount'] as bool,
    groupDialogs: values['dialogGrouping'] as bool,
    batterySaver: values['batterySaver'] as bool,
    hideTooltips: values['hideTooltips'] as bool,
    disableSwipeRegeneration: values['disableSwipeRegeneration'] as bool,
    allowMessageScripts: values['allowMessageScripts'] as bool,
    language: values['language'] as String,
    virtualKeyboardSend: values['virtualKeyboardSend'] as bool,
    tokenizerHidePercent: values['tokenizerHidePercent'] as double,
    tokenizerHistoryFillThreshold:
        values['tokenizerHistoryFillThreshold'] as double,
    showOurPicks: values['showOurPicks'] as bool,
    forceMobileLayout: values['gz_force_mobile_layout'] as bool,
    addBlockAtTop: values['addBlockAtTop'] as bool,
    openCardAfterImport: values['openCardAfterImport'] as bool,
    hapticFeedback: values['hapticFeedback'] as bool,
    messageVibration: values['messageVibration'] as bool,
    extractJanitorLocally: values['extractJanitorLocally'] as bool,
    lorebookBuildPrompt: values['lorebookBuildPrompt'] as String,
    lorebookBuildPromptJs: values['lorebookBuildPromptJs'] as String,
    useStandardRandomizer: values['useStandardRandomizer'] as bool,
  );
}

class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final settings = AppSettingsPreferences.read(prefs);
    // Cache the toggles so the central [Haptics] gate can decide synchronously
    // in tap handlers and on message completion.
    Haptics.configure(enabled: settings.hapticFeedback);
    Haptics.configureMessageVibration(enabled: settings.messageVibration);
    return settings;
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final normalized = supportedAppLanguages.contains(settings.language)
        ? settings
        : settings.copyWith(language: 'en');
    await AppSettingsPreferences.write(prefs, normalized);
    Haptics.configure(enabled: normalized.hapticFeedback);
    Haptics.configureMessageVibration(enabled: normalized.messageVibration);
    state = AsyncData(normalized);
  }
}
