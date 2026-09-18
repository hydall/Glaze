import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dart:async';

import '../../core/platform/haptics.dart';
import '../../core/platform/system_settings.dart';
import '../../core/state/shared_prefs_provider.dart';

part 'app_settings_provider.freezed.dart';

const supportedAppLanguages = {'en', 'ru'};

/// Where a JanitorAI card, its hidden definition or its lorebooks are read
/// from.
///
/// * [local] — Glaze's own offscreen WebView session on janitorai.com
///   (`JanitorWebViewProxy`). Reads what the logged-in account can see and, for
///   the closed card/lorebook, captures the assembled prompt.
/// * [datacat] — datacat.run's scraped copy. No Janitor.AI account needed, but
///   it only carries what DataCat has already extracted, and its lorebooks come
///   from the character's *public* scripts only (private books are metadata
///   stubs there — see `extractCharacterBookFromScripts` in the
///   SillyTavern-CharacterLibrary reference).
enum ExtractionSource {
  local,
  datacat;

  static ExtractionSource? parse(Object? value) {
    if (value is ExtractionSource) return value;
    if (value is! String) return null;
    final normalized = value.trim().toLowerCase();
    for (final s in ExtractionSource.values) {
      if (s.name == normalized) return s;
    }
    return null;
  }
}

/// What drives the reduced-motion, reduced-blur "Battery Saver UI".
///
/// [system] follows the OS power-save mode, which is the default: a phone that
/// has decided to save power should not be asked to paint blurs and rolling
/// digits. It resolves to off wherever the platform cannot answer — Windows,
/// Linux and macOS have no signal to follow, so nothing is being followed.
/// [on] and [off] pin it regardless of what the OS is doing.
enum BatterySaverMode {
  system,
  on,
  off;

  static BatterySaverMode? parse(Object? value) {
    if (value is BatterySaverMode) return value;
    if (value is! String) return null;
    final normalized = value.trim().toLowerCase();
    for (final m in BatterySaverMode.values) {
      if (m.name == normalized) return m;
    }
    return null;
  }
}

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

/// The pre-split `extractJanitorLocally` opt-in, read as a source so an
/// upgrading install keeps the behaviour it had: the one toggle governed both
/// the closed card and the closed lorebook, so both settings inherit it. Null
/// when the old key was never written, leaving the new defaults in charge.
ExtractionSource? _legacyExtractionSource(SharedPreferences prefs) {
  final legacy = _coerceBool(prefs.get('extractJanitorLocally'));
  if (legacy == null) return null;
  return legacy ? ExtractionSource.local : ExtractionSource.datacat;
}

/// Reads the Battery Saver choice, migrating the install that only ever stored
/// a bool.
///
/// The old setting defaulted to **on**, so a stored `true` is indistinguishable
/// from never having touched it — those installs take the new default,
/// [BatterySaverMode.system]. A stored `false` is a choice the old UI could
/// only reach deliberately, so it is kept as [BatterySaverMode.off]; under
/// `system` it would have flipped itself on the next time the phone started
/// saving power, which is not what that reader asked for.
BatterySaverMode _batterySaverMode(SharedPreferences prefs) {
  final stored = BatterySaverMode.parse(prefs.get('batterySaverMode'));
  if (stored != null) return stored;
  return _coerceBool(prefs.get('batterySaver')) == false
      ? BatterySaverMode.off
      : BatterySaverMode.system;
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

    /// The resolved answer the whole app reads: whether the reduced UI is on
    /// right now. Derived from [batterySaverMode] — under [BatterySaverMode
    /// .system] it tracks the OS, so it changes without anyone touching a
    /// setting. Persisted as the last known value so a cold start paints the
    /// right thing before the platform has answered.
    @Default(false) bool batterySaver,

    /// What the reader actually chose. [batterySaver] is what that choice
    /// currently works out to.
    @Default(BatterySaverMode.system) BatterySaverMode batterySaverMode,
    @Default(false) bool hideTooltips,
    @Default(false) bool disableSwipeRegeneration,
    @Default(false) bool allowMessageScripts,

    /// Whether a message in the middle of a chat may be deleted — in bulk
    /// selection or from its action menu — instead of only a trailing run that
    /// reaches the last message. Off by default: deleting mid-history breaks
    /// the prompt context, so it is an explicit opt-in.
    @Default(false) bool allowMiddleMessageDelete,
    @Default('en') String language,
    @Default(false) bool virtualKeyboardSend,
    @Default(true) bool showOurPicks,

    /// Widest the chat column is allowed to get, in logical pixels. 0 means
    /// "fill the column". Only ever binds on desktop — phones are narrower than
    /// the default — and is dragged directly by the chat column's edge grips.
    @Default(900) double chatMaxWidth,

    /// Desktop (>=768px) three-column layout is the default on wide windows,
    /// matching the legacy Vue app. This switch forces the phone layout back
    /// on for users who prefer it.
    @Default(false) bool forceMobileLayout,
    @Default(false) bool addBlockAtTop,
    @Default(true) bool openCardAfterImport,
    @Default(true) bool hapticFeedback,
    @Default(true) bool messageVibration,

    /// Where a JanitorAI **closed lorebook** is recovered from. [local] runs the
    /// capture + LLM rebuild through the logged-in session; [datacat] takes
    /// whatever book DataCat's copy of the card carries (public scripts only).
    @Default(ExtractionSource.datacat) ExtractionSource janitorLorebookSource,

    /// Where the catalog sheet reads a JanitorAI **character card** from.
    /// [local] goes through the WebView proxy — which is the only way to see a
    /// card the creator restricted to logged-in visitors — and falls back to
    /// [datacat] when the card is hidden from us and no account is signed in.
    @Default(ExtractionSource.local) ExtractionSource janitorCardSource,

    /// Where a JanitorAI **closed character definition** is recovered from.
    /// [local] captures the assembled prompt through the signed-in session;
    /// [datacat] reads DataCat's scraped copy instead.
    @Default(ExtractionSource.datacat) ExtractionSource janitorCharacterSource,

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

    /// Hides the context coverage card that floats under the chat header (the
    /// memory + lorebook panel). Stored as "hide" like the other chat-surface
    /// switches, so an absent preference keeps the card on.
    @Default(false) bool hideContextCard,
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
    'batterySaverMode',
    'hideTooltips',
    'disableSwipeRegeneration',
    'allowMessageScripts',
    'allowMiddleMessageDelete',
    'language',
    'virtualKeyboardSend',
    'showOurPicks',
    'gz_force_mobile_layout',
    'gz_chat_max_width',
    'addBlockAtTop',
    'openCardAfterImport',
    'hapticFeedback',
    'messageVibration',
    'janitorLorebookSource',
    'janitorCardSource',
    'janitorCharacterSource',
    'lorebookBuildPrompt',
    'lorebookBuildPromptJs',
    'useStandardRandomizer',
    'hideContextCard',
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
      batterySaverMode: _batterySaverMode(prefs),
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
      allowMiddleMessageDelete:
          _coerceBool(prefs.get('allowMiddleMessageDelete')) ??
          defaults.allowMiddleMessageDelete,
      language: supportedAppLanguages.contains(savedLanguage)
          ? savedLanguage!
          : defaults.language,
      virtualKeyboardSend:
          _coerceBool(prefs.get('virtualKeyboardSend')) ??
          defaults.virtualKeyboardSend,
      showOurPicks:
          _coerceBool(prefs.get('showOurPicks')) ?? defaults.showOurPicks,
      forceMobileLayout:
          _coerceBool(prefs.get('gz_force_mobile_layout')) ??
          defaults.forceMobileLayout,
      chatMaxWidth:
          _coerceDouble(prefs.get('gz_chat_max_width')) ??
          defaults.chatMaxWidth,
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
      janitorLorebookSource:
          ExtractionSource.parse(prefs.get('janitorLorebookSource')) ??
          _legacyExtractionSource(prefs) ??
          defaults.janitorLorebookSource,
      janitorCardSource:
          ExtractionSource.parse(prefs.get('janitorCardSource')) ??
          defaults.janitorCardSource,
      janitorCharacterSource:
          ExtractionSource.parse(prefs.get('janitorCharacterSource')) ??
          _legacyExtractionSource(prefs) ??
          defaults.janitorCharacterSource,
      lorebookBuildPrompt:
          prefs.getString('lorebookBuildPrompt') ??
          defaults.lorebookBuildPrompt,
      lorebookBuildPromptJs:
          prefs.getString('lorebookBuildPromptJs') ??
          defaults.lorebookBuildPromptJs,
      useStandardRandomizer:
          _coerceBool(prefs.get('useStandardRandomizer')) ??
          defaults.useStandardRandomizer,
      hideContextCard:
          _coerceBool(prefs.get('hideContextCard')) ?? defaults.hideContextCard,
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
      'batterySaverMode': normalized.batterySaverMode.name,
      'hideTooltips': normalized.hideTooltips,
      'disableSwipeRegeneration': normalized.disableSwipeRegeneration,
      'allowMessageScripts': normalized.allowMessageScripts,
      'allowMiddleMessageDelete': normalized.allowMiddleMessageDelete,
      'language': normalized.language,
      'virtualKeyboardSend': normalized.virtualKeyboardSend,
      'showOurPicks': normalized.showOurPicks,
      'gz_force_mobile_layout': normalized.forceMobileLayout,
      'gz_chat_max_width': normalized.chatMaxWidth,
      'addBlockAtTop': normalized.addBlockAtTop,
      'openCardAfterImport': normalized.openCardAfterImport,
      'hapticFeedback': normalized.hapticFeedback,
      'messageVibration': normalized.messageVibration,
      'janitorLorebookSource': normalized.janitorLorebookSource.name,
      'janitorCardSource': normalized.janitorCardSource.name,
      'janitorCharacterSource': normalized.janitorCharacterSource.name,
      'lorebookBuildPrompt': normalized.lorebookBuildPrompt,
      'lorebookBuildPromptJs': normalized.lorebookBuildPromptJs,
      'useStandardRandomizer': normalized.useStandardRandomizer,
      'hideContextCard': normalized.hideContextCard,
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
        if (_extractionSourceKeys.contains(key)) {
          // An unknown source name from a newer (or corrupted) client keeps the
          // local value rather than silently resetting it to the default.
          final parsed = ExtractionSource.parse(incoming);
          if (parsed != null) merged[key] = parsed.name;
        } else if (key == 'batterySaverMode') {
          final parsed = BatterySaverMode.parse(incoming);
          if (parsed != null) merged[key] = parsed.name;
        } else {
          merged[key] =
              key == 'language' && !supportedAppLanguages.contains(incoming)
              ? 'en'
              : incoming;
        }
      }
    }
    await write(prefs, _fromMap(merged));
  }

  /// Keys whose value is an [ExtractionSource] name rather than free text.
  static const _extractionSourceKeys = <String>{
    'janitorLorebookSource',
    'janitorCardSource',
    'janitorCharacterSource',
  };

  /// Keys no longer written but still read once, to carry an upgrading install's
  /// choice over. Cleared alongside the live ones so a reset really resets.
  static const legacyKeys = <String>{'extractJanitorLocally'};

  static Future<void> removeAll(SharedPreferences prefs) async {
    for (final key in {...keys, ...legacyKeys}) {
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
    batterySaverMode:
        BatterySaverMode.parse(values['batterySaverMode']) ??
        const AppSettings().batterySaverMode,
    hideTooltips: values['hideTooltips'] as bool,
    disableSwipeRegeneration: values['disableSwipeRegeneration'] as bool,
    allowMessageScripts: values['allowMessageScripts'] as bool,
    allowMiddleMessageDelete: values['allowMiddleMessageDelete'] as bool,
    language: values['language'] as String,
    virtualKeyboardSend: values['virtualKeyboardSend'] as bool,
    showOurPicks: values['showOurPicks'] as bool,
    forceMobileLayout: values['gz_force_mobile_layout'] as bool,
    chatMaxWidth: values['gz_chat_max_width'] as double,
    addBlockAtTop: values['addBlockAtTop'] as bool,
    openCardAfterImport: values['openCardAfterImport'] as bool,
    hapticFeedback: values['hapticFeedback'] as bool,
    messageVibration: values['messageVibration'] as bool,
    janitorLorebookSource:
        ExtractionSource.parse(values['janitorLorebookSource']) ??
        const AppSettings().janitorLorebookSource,
    janitorCardSource:
        ExtractionSource.parse(values['janitorCardSource']) ??
        const AppSettings().janitorCardSource,
    janitorCharacterSource:
        ExtractionSource.parse(values['janitorCharacterSource']) ??
        const AppSettings().janitorCharacterSource,
    lorebookBuildPrompt: values['lorebookBuildPrompt'] as String,
    lorebookBuildPromptJs: values['lorebookBuildPromptJs'] as String,
    useStandardRandomizer: values['useStandardRandomizer'] as bool,
    hideContextCard: values['hideContextCard'] as bool,
  );
}

class AppSettingsNotifier extends AsyncNotifier<AppSettings> {
  StreamSubscription<bool>? _powerSaveSub;

  @override
  Future<AppSettings> build() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    var settings = AppSettingsPreferences.read(prefs);
    // Cache the toggles so the central [Haptics] gate can decide synchronously
    // in tap handlers and on message completion.
    Haptics.configure(enabled: settings.hapticFeedback);
    Haptics.configureMessageVibration(enabled: settings.messageVibration);

    // Under `system` the persisted flag is only the last known answer; ask the
    // OS for the current one before anything paints from it.
    if (settings.batterySaverMode == BatterySaverMode.system) {
      settings = settings.copyWith(
        batterySaver: await SystemSettings.isPowerSaveMode(),
      );
    }
    _listenForPowerSaveChanges();
    return settings;
  }

  /// Follows the OS while `system` is selected. The subscription is kept open
  /// under the other two modes as well — they are a user's answer, not a
  /// platform one, and switching back to `system` must not need a restart to
  /// start hearing again.
  void _listenForPowerSaveChanges() {
    _powerSaveSub?.cancel();
    _powerSaveSub = SystemSettings.powerSaveModeChanges().listen(
      _onPowerSaveChanged,
    );
    ref.onDispose(() {
      _powerSaveSub?.cancel();
      _powerSaveSub = null;
    });
  }

  Future<void> _onPowerSaveChanged(bool powerSaving) async {
    final current = state.value;
    if (current == null) return;
    if (current.batterySaverMode != BatterySaverMode.system) return;
    if (current.batterySaver == powerSaving) return;
    await save(current.copyWith(batterySaver: powerSaving));
  }

  /// Sets what drives Battery Saver UI and resolves it in the same write, so
  /// the screen never shows a mode and an effect that disagree.
  Future<void> setBatterySaverMode(BatterySaverMode mode) async {
    final current = state.value ?? const AppSettings();
    final resolved = switch (mode) {
      BatterySaverMode.on => true,
      BatterySaverMode.off => false,
      BatterySaverMode.system => await SystemSettings.isPowerSaveMode(),
    };
    await save(
      current.copyWith(batterySaverMode: mode, batterySaver: resolved),
    );
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
