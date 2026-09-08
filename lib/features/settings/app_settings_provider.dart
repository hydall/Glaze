import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform/haptics.dart';
import '../../core/state/shared_prefs_provider.dart';

part 'app_settings_provider.freezed.dart';

const supportedAppLanguages = {'en', 'ru'};

bool _readBoolPref(
  SharedPreferences prefs,
  String key, {
  required bool defaultValue,
}) {
  final value = prefs.get(key);
  if (value is bool) return value;
  if (value is int) return value != 0;
  if (value is String) {
    final normalized = value.toLowerCase();
    return normalized == '1' || normalized == 'true';
  }
  return defaultValue;
}

double _readDoublePref(
  SharedPreferences prefs,
  String key, {
  required double defaultValue,
}) {
  final value = prefs.get(key);
  if (value is int) return value.toDouble();
  if (value is double) return value;
  if (value is String) return double.tryParse(value) ?? defaultValue;
  return defaultValue;
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

    /// When on, the shuffle button opens a random character straight in the
    /// detail sheet (the classic behaviour) instead of the randomizing
    /// (Holocard) discovery overlay. Off by default.
    @Default(false) bool useStandardRandomizer,
  }) = _AppSettings;
}

class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final savedLanguage = prefs.getString('language');
    final hapticFeedback = _readBoolPref(
      prefs,
      'hapticFeedback',
      defaultValue: true,
    );
    final messageVibration = _readBoolPref(
      prefs,
      'messageVibration',
      defaultValue: true,
    );
    // Cache the toggles so the central [Haptics] gate can decide synchronously
    // in tap handlers and on message completion.
    Haptics.configure(enabled: hapticFeedback);
    Haptics.configureMessageVibration(enabled: messageVibration);
    return AppSettings(
      enterToSend: _readBoolPref(prefs, 'enterToSend', defaultValue: true),
      hideMessageId: _readBoolPref(prefs, 'hideMessageId', defaultValue: false),
      hideGenerationTime: _readBoolPref(
        prefs,
        'hideGenerationTime',
        defaultValue: false,
      ),
      hideTokenCount: _readBoolPref(
        prefs,
        'hideTokenCount',
        defaultValue: false,
      ),
      groupDialogs: _readBoolPref(prefs, 'dialogGrouping', defaultValue: false),
      batterySaver: _readBoolPref(prefs, 'batterySaver', defaultValue: true),
      hideTooltips: _readBoolPref(prefs, 'hideTooltips', defaultValue: false),
      disableSwipeRegeneration: _readBoolPref(
        prefs,
        'disableSwipeRegeneration',
        defaultValue: false,
      ),
      allowMessageScripts: _readBoolPref(
        prefs,
        'allowMessageScripts',
        defaultValue: false,
      ),
      language: supportedAppLanguages.contains(savedLanguage)
          ? savedLanguage!
          : 'en',
      virtualKeyboardSend: _readBoolPref(
        prefs,
        'virtualKeyboardSend',
        defaultValue: false,
      ),
      tokenizerHidePercent: _readDoublePref(
        prefs,
        'tokenizerHidePercent',
        defaultValue: 30,
      ),
      tokenizerHistoryFillThreshold: _readDoublePref(
        prefs,
        'tokenizerHistoryFillThreshold',
        defaultValue: 85,
      ),
      showOurPicks: _readBoolPref(prefs, 'showOurPicks', defaultValue: true),
      forceMobileLayout: _readBoolPref(
        prefs,
        'gz_force_mobile_layout',
        defaultValue: true,
      ),
      addBlockAtTop: _readBoolPref(prefs, 'addBlockAtTop', defaultValue: false),
      openCardAfterImport: _readBoolPref(
        prefs,
        'openCardAfterImport',
        defaultValue: true,
      ),
      hapticFeedback: hapticFeedback,
      messageVibration: messageVibration,
      extractJanitorLocally: _readBoolPref(
        prefs,
        'extractJanitorLocally',
        defaultValue: false,
      ),
      useStandardRandomizer: _readBoolPref(
        prefs,
        'useStandardRandomizer',
        defaultValue: false,
      ),
    );
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final normalized = supportedAppLanguages.contains(settings.language)
        ? settings
        : settings.copyWith(language: 'en');
    await prefs.setBool('enterToSend', settings.enterToSend);
    await prefs.setBool('hideMessageId', settings.hideMessageId);
    await prefs.setBool('hideGenerationTime', settings.hideGenerationTime);
    await prefs.setBool('hideTokenCount', settings.hideTokenCount);
    await prefs.setBool('dialogGrouping', settings.groupDialogs);
    await prefs.setBool('batterySaver', settings.batterySaver);
    await prefs.setBool('hideTooltips', settings.hideTooltips);
    await prefs.setBool(
      'disableSwipeRegeneration',
      settings.disableSwipeRegeneration,
    );
    await prefs.setBool('allowMessageScripts', settings.allowMessageScripts);
    await prefs.setString('language', normalized.language);
    await prefs.setBool('virtualKeyboardSend', normalized.virtualKeyboardSend);
    await prefs.setDouble(
      'tokenizerHidePercent',
      normalized.tokenizerHidePercent,
    );
    await prefs.setDouble(
      'tokenizerHistoryFillThreshold',
      normalized.tokenizerHistoryFillThreshold,
    );
    await prefs.setBool('showOurPicks', normalized.showOurPicks);
    await prefs.setBool('gz_force_mobile_layout', normalized.forceMobileLayout);
    await prefs.setBool('addBlockAtTop', normalized.addBlockAtTop);
    await prefs.setBool('openCardAfterImport', normalized.openCardAfterImport);
    await prefs.setBool('hapticFeedback', normalized.hapticFeedback);
    await prefs.setBool('messageVibration', normalized.messageVibration);
    await prefs.setBool(
      'extractJanitorLocally',
      normalized.extractJanitorLocally,
    );
    await prefs.setBool(
      'useStandardRandomizer',
      normalized.useStandardRandomizer,
    );
    Haptics.configure(enabled: normalized.hapticFeedback);
    Haptics.configureMessageVibration(enabled: normalized.messageVibration);
    state = AsyncData(normalized);
  }
}
