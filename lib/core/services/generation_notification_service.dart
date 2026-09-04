import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show NotificationResponse;
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/haptics.dart';
import 'notifications/message_notification_presenter.dart';

class NotificationNavigationData {
  final String charId;
  final String? sessionId;
  final String? msgId;

  const NotificationNavigationData({
    required this.charId,
    this.sessionId,
    this.msgId,
  });
}

/// Immutable authority for work that may only target the chat currently
/// visible to the user. [revision] invalidates snapshots on context changes.
class ActiveChatContext {
  const ActiveChatContext({
    required this.charId,
    required this.sessionId,
    required this.revision,
  });

  final String charId;
  final String sessionId;
  final int revision;
}

class GenerationForegroundLease {
  GenerationForegroundLease._(this._service, this._foregroundAcquired);

  final GenerationNotificationService _service;
  final bool _foregroundAcquired;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _service._releaseGenerationLease(_foregroundAcquired);
  }
}

class PostGenerationForegroundLease {
  PostGenerationForegroundLease._(this._service, this._foregroundAcquired);

  final GenerationNotificationService _service;
  final bool _foregroundAcquired;
  bool _released = false;

  Future<void> release() async {
    if (_released) return;
    _released = true;
    if (_foregroundAcquired) await _service._releaseForeground();
  }
}

/// Decides when the user should be told a reply landed, and keeps the Android
/// foreground service alive while one is being generated.
///
/// Presentation lives in [MessageNotificationPresenter]; this class owns the
/// policy around it — app lifecycle, which chat is on screen, and the
/// foreground/wake-lock leases the generation pipeline takes out.
class GenerationNotificationService {
  GenerationNotificationService._();
  static final GenerationNotificationService instance =
      GenerationNotificationService._();

  static const _generationChannelId = 'glaze_generation';
  static const _generationChannelName = 'Generation';
  static const _iosAudioChannel = MethodChannel(
    'com.hydall.glaze/background_audio',
  );

  MessageNotificationPresenter _presenter = MessageNotificationPresenter();
  final StreamController<NotificationNavigationData> _navigationController =
      StreamController<NotificationNavigationData>.broadcast();
  final StreamController<void> _activeContextChanges =
      StreamController<void>.broadcast();

  int _foregroundHoldCount = 0;
  int _generationLeaseCount = 0;
  Future<void> _foregroundTransition = Future<void>.value();
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  NotificationNavigationData? _pendingNotificationData;
  String? _activeCharId;
  String? _activeSessionId;
  int _activeContextRevision = 0;

  Stream<NotificationNavigationData> get navigationStream =>
      _navigationController.stream;

  /// Emits whenever an active-chat authority snapshot becomes stale.
  Stream<void> get activeChatContextChanges => _activeContextChanges.stream;

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Why the last message notification failed to reach the OS, if it did.
  String? get lastNotificationError => _presenter.lastError;

  /// Which form of the notification the OS accepted last — "plain" means this
  /// device refused the messaging style or the sender avatar.
  String? get lastDeliveredNotificationForm => _presenter.lastDeliveredForm;

  /// Whether this platform has a notification backend at all.
  bool get notificationsSupported => _presenter.isSupported;

  /// Swaps in a fake presenter so the notification *policy* — which reply
  /// warrants telling the user — can be tested without a platform channel.
  @visibleForTesting
  void debugSetPresenter(MessageNotificationPresenter presenter) {
    _presenter = presenter;
  }

  /// Stable notification ID in range 1..2147483646, mirrors Vue stableIdFromString.
  int _stableId(String str) {
    int hash = 0;
    for (int i = 0; i < str.length; i++) {
      hash = ((hash << 5) - hash) + str.codeUnitAt(i);
      hash = hash.toSigned(32);
    }
    return (hash.abs() % 2147483646) + 1;
  }

  Future<void> init() async {
    // Message notifications run everywhere Glaze ships, desktop included; the
    // foreground service below is Android/iOS only.
    if (_presenter.isSupported) {
      await _presenter.ensureInitialized(onTap: _onNotificationTapped);

      // Restore pending data when app is cold-launched from a notification tap.
      final payload = await _presenter.consumeLaunchPayload();
      if (payload != null) _pendingNotificationData = _parsePayload(payload);
    }

    if (!_isMobile) return;

    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: _generationChannelId,
          channelName: _generationChannelName,
          channelDescription: 'Shows when the app is generating text',
          // Mirror Vue: Importance.Min + silent so the ongoing generation
          // notice never makes a sound or heads-up popup.
          channelImportance: NotificationChannelImportance.MIN,
          priority: NotificationPriority.MIN,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );

      await _maybeRequestBatteryExemption();
    } catch (e, st) {
      debugPrint('NOTIF: foreground task init failed: $e\n$st');
    }
  }

  /// Asks the user (once) to exempt Glaze from battery optimization / Doze.
  /// Without the exemption Android may freeze the process while the screen is
  /// off, stalling a background generation even though a foreground service +
  /// wake lock are held. Gated by a SharedPreferences flag so the system
  /// dialog is offered a single time.
  Future<void> _maybeRequestBatteryExemption() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      const promptedKey = 'battery_optimization_prompted';
      if (prefs.getBool(promptedKey) ?? false) return;

      final alreadyIgnoring =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (alreadyIgnoring) {
        await prefs.setBool(promptedKey, true);
        return;
      }

      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      // Mark prompted regardless of the user's choice — the dialog is only
      // meant to appear once; the user can still change it in system settings.
      await prefs.setBool(promptedKey, true);
    } catch (e) {
      debugPrint('NOTIF: battery optimization request failed: $e');
    }
  }

  void updateLifecycleState(AppLifecycleState state) {
    if (_lifecycleState == state) return;
    _lifecycleState = state;
    _activeContextRevision++;
    _activeContextChanges.add(null);
  }

  /// Read-only authority snapshot for user-visible chat work.
  ActiveChatContext? get activeChatContext {
    final charId = _activeCharId;
    final sessionId = _activeSessionId;
    if (_lifecycleState != AppLifecycleState.resumed ||
        charId == null ||
        charId.isEmpty ||
        sessionId == null ||
        sessionId.isEmpty) {
      return null;
    }
    return ActiveChatContext(
      charId: charId,
      sessionId: sessionId,
      revision: _activeContextRevision,
    );
  }

  bool isCurrentActiveChatContext(ActiveChatContext context) {
    final current = activeChatContext;
    return current != null &&
        current.charId == context.charId &&
        current.sessionId == context.sessionId &&
        current.revision == context.revision;
  }

  /// True when the given character+session is the one the user currently has
  /// open and focused (app resumed). Mirrors the suppression check used for
  /// message notifications — used to decide whether a completed reply should be
  /// flagged unread in the chat list.
  bool isActiveSession(String charId, String? sessionId) {
    if (_lifecycleState != AppLifecycleState.resumed) return false;
    if (_activeCharId != charId) return false;
    return sessionId == null || _activeSessionId == sessionId;
  }

  /// Call when the user opens / focuses a chat screen to suppress redundant
  /// notifications for that character+session. Pass nulls when leaving.
  ///
  /// Focusing a chat also dismisses whatever notification that character has
  /// already posted: the user is looking at the message it points to, so
  /// leaving it in the shade would send them back to a chat they are in.
  void setActiveContext(String? charId, String? sessionId) {
    if (_activeCharId == charId && _activeSessionId == sessionId) return;
    _activeCharId = charId;
    _activeSessionId = sessionId;
    _activeContextRevision++;
    _activeContextChanges.add(null);
    if (charId != null && charId.isNotEmpty) {
      unawaited(clearMessageNotifications(charId));
    }
  }

  Future<GenerationForegroundLease> acquireGenerationLease(
    String charName,
  ) async {
    _generationLeaseCount++;
    final acquired = await _acquireForeground(
      notificationTitle: charName,
      notificationText: 'notification_generating'.tr(),
    );
    return GenerationForegroundLease._(this, acquired);
  }

  Future<void> _releaseGenerationLease(bool foregroundAcquired) async {
    if (_generationLeaseCount > 0) _generationLeaseCount--;
    if (foregroundAcquired) await _releaseForeground();
  }

  Future<void> onGenerationCompleted(
    String charName,
    String charId, {
    String? messagePreview,
    String? sessionId,
    String? msgId,
    String? avatarPath,
  }) async {
    // Buzz the moment the bot's reply lands, whether the app is foregrounded
    // (user watching the chat) or backgrounded (paired with the notification
    // below). Gated by the user's incoming-message vibration toggle.
    await Haptics.messageReceived();

    // No lifecycle gate here: a reply is worth a notification whenever the user
    // is not looking at the chat it landed in, and being in *another* chat (or
    // on the character list) counts. [sendMessageNotification] owns that check
    // — it compares the target chat against the one on screen, which is the
    // only comparison that distinguishes "already read it" from "did not see
    // it". Gating on `AppLifecycleState.resumed` here made that check dead code
    // and dropped every notification while Glaze was open.
    await sendMessageNotification(
      charName,
      messagePreview ?? 'New message received',
      avatarPath,
      charId,
      sessionId: sessionId,
      msgId: msgId,
    );
  }

  /// Acquire an additional foreground hold for detached post-generation work.
  /// The main pipeline keeps its original hold through awaited post-gen phases.
  Future<PostGenerationForegroundLease> acquirePostGenerationLease() async {
    final acquired = await _acquireForeground(
      notificationTitle: 'Glaze',
      notificationText: 'Processing response...',
    );
    return PostGenerationForegroundLease._(this, acquired);
  }

  Future<void> onSyncStarted() async {
    await _acquireForeground(
      notificationTitle: 'Glaze',
      notificationText: 'Syncing with cloud...',
    );
  }

  Future<void> onSyncFinished() async {
    await _releaseForeground();
  }

  bool get isGenerating => _generationLeaseCount > 0;

  /// Shows a message notification. Suppressed only while the user is actually
  /// looking at that chat — the app is resumed *and* the same charId+sessionId
  /// is the one on screen (mirrors Vue.js visibility + activeContext check).
  Future<bool> sendMessageNotification(
    String title,
    String body,
    String? avatarPath,
    String charId, {
    String? sessionId,
    String? msgId,
  }) async {
    if (_lifecycleState == AppLifecycleState.resumed) {
      if (_activeCharId == charId &&
          (sessionId == null || _activeSessionId == sessionId)) {
        return false;
      }
    }
    return _post(
      title: title,
      body: body,
      avatarPath: avatarPath,
      charId: charId,
      sessionId: sessionId,
      msgId: msgId,
    );
  }

  /// Posts a notification for the user's own "test notification" action,
  /// bypassing the on-screen-chat suppression. Returns whether it reached the
  /// OS; on failure [lastNotificationError] says why.
  Future<bool> sendTestNotification(String title, String body) => _post(
    title: title,
    body: body,
    avatarPath: null,
    charId: '__glaze_notification_self_test__',
    sessionId: null,
    msgId: null,
    // No chat behind this one, so give the tap nothing to navigate to.
    payloadOverride: '',
  );

  Future<bool> _post({
    required String title,
    required String body,
    required String? avatarPath,
    required String charId,
    required String? sessionId,
    required String? msgId,
    String? payloadOverride,
  }) async {
    if (!_presenter.isSupported) return false;
    // Retry initialization rather than staying dead for the process: a failure
    // during startup (missing drawable, permission not yet granted) must not
    // cost every notification afterwards.
    if (!await _presenter.ensureInitialized(onTap: _onNotificationTapped)) {
      return false;
    }
    return _presenter.show(
      id: _stableId(charId),
      title: title,
      body: body,
      payload: payloadOverride ?? _buildPayload(charId, sessionId, msgId),
      groupKey: charId,
      avatarPath: avatarPath,
    );
  }

  /// Whether the OS currently lets Glaze post notifications (`null` where the
  /// platform cannot answer). Used by the settings self-test to tell a blocked
  /// app apart from a broken notification.
  Future<bool?> areNotificationsEnabled() =>
      _presenter.areNotificationsEnabled();

  /// Cancels delivered notifications for a character (e.g. when the user
  /// opens that chat). Mirrors Vue.js clearMessageNotifications.
  Future<void> clearMessageNotifications(String charId) =>
      _presenter.cancel(_stableId(charId));

  /// Returns and clears the notification data from the last tap — used to
  /// navigate on app launch from a background/terminated notification.
  NotificationNavigationData? consumePendingNotificationData() {
    final data = _pendingNotificationData;
    _pendingNotificationData = null;
    return data;
  }

  Future<bool> _acquireForeground({
    required String notificationTitle,
    required String notificationText,
  }) async {
    return _serializeForegroundTransition(() async {
      if (!_isMobile) return true;
      _foregroundHoldCount++;
      if (_foregroundHoldCount > 1) return true;
      try {
        if (!await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.startService(
            // Must match android:foregroundServiceType="dataSync" in the manifest
            // (mirrors Vue's dataSync foreground service for background generation).
            serviceTypes: const [ForegroundServiceTypes.dataSync],
            notificationTitle: notificationTitle,
            notificationText: notificationText,
            notificationIcon: const NotificationIcon(
              metaDataName: 'com.hydall.glaze.ic_generation',
            ),
            callback: _foregroundTaskCallback,
          );
        }
      } catch (e) {
        _foregroundHoldCount--;
        debugPrint('NOTIF: foreground task start failed: $e');
        return false;
      }
      await _startSilentAudio();
      return true;
    });
  }

  Future<void> _releaseForeground() async {
    await _serializeForegroundTransition(() async {
      if (!_isMobile) return;
      if (_foregroundHoldCount <= 0) return;
      _foregroundHoldCount--;
      if (_foregroundHoldCount > 0) return;
      await _stopForegroundTask();
    });
  }

  Future<T> _serializeForegroundTransition<T>(
    Future<T> Function() action,
  ) async {
    final previous = _foregroundTransition;
    final completer = Completer<void>();
    _foregroundTransition = completer.future;
    await previous;
    try {
      return await action();
    } finally {
      completer.complete();
    }
  }

  Future<void> _stopForegroundTask() async {
    if (_isMobile) {
      try {
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.stopService();
        }
      } catch (e) {
        debugPrint('NOTIF: foreground task stop failed: $e');
      }
      await _stopSilentAudio();
    }
  }

  Future<void> _startSilentAudio() async {
    if (kIsWeb || !Platform.isIOS) return;
    try {
      await _iosAudioChannel.invokeMethod<void>('start');
    } catch (e) {
      debugPrint('NOTIF: silent audio start failed: $e');
    }
  }

  Future<void> _stopSilentAudio() async {
    if (kIsWeb || !Platform.isIOS) return;
    try {
      await _iosAudioChannel.invokeMethod<void>('stop');
    } catch (e) {
      debugPrint('NOTIF: silent audio stop failed: $e');
    }
  }

  void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;
    final data = _parsePayload(payload);
    if (data != null) {
      _pendingNotificationData = data;
      _navigationController.add(data);
    }
  }

  NotificationNavigationData? _parsePayload(String payload) {
    if (!payload.startsWith('chat:')) return null;
    final parts = payload.substring(5).split(':');
    if (parts.isEmpty || parts[0].isEmpty) return null;
    return NotificationNavigationData(
      charId: parts[0],
      sessionId: parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null,
      msgId: parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null,
    );
  }

  String _buildPayload(String charId, String? sessionId, String? msgId) =>
      'chat:$charId:${sessionId ?? ''}:${msgId ?? ''}';

  void dispose() {
    _navigationController.close();
    _activeContextChanges.close();
  }
}

@pragma('vm:entry-point')
void _foregroundTaskCallback() {}
