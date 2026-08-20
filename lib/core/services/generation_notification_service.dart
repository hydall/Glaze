import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart'
    hide NotificationVisibility;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/haptics.dart';
import '../utils/platform_paths.dart';

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

class GenerationNotificationService {
  GenerationNotificationService._();
  static final GenerationNotificationService instance =
      GenerationNotificationService._();

  static const _generationChannelId = 'glaze_generation';
  static const _generationChannelName = 'Generation';
  static const _messageChannelId = 'glaze_message';
  static const _messageChannelName = 'New Messages';
  static const _iosAudioChannel = MethodChannel(
    'com.hydall.glaze/background_audio',
  );

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final StreamController<NotificationNavigationData> _navigationController =
      StreamController<NotificationNavigationData>.broadcast();
  final StreamController<void> _activeContextChanges =
      StreamController<void>.broadcast();

  bool _initialized = false;
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
    if (!_isMobile) return;

    // Resource name only — flutter_local_notifications resolves it via
    // Resources.getIdentifier(name, "drawable", pkg), which rejects the
    // "@drawable/" XML-reference prefix (returns 0 → init throws and aborts
    // channel setup, leaving _initialized=false).
    const androidSettings = AndroidInitializationSettings(
      'ic_stat_icon_config_sample',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    try {
      await _notifications.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _onNotificationTapped,
      );
      _initialized = true;
    } catch (e, st) {
      // Local notifications (message alerts) failed to init, but keep going:
      // the foreground generation channel is owned by flutter_foreground_task
      // and must still be configured below regardless.
      debugPrint('NOTIF: initialize failed: $e\n$st');
    }

    try {
      if (!kIsWeb && Platform.isAndroid) {
        final androidPlugin = _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        if (androidPlugin != null) {
          await androidPlugin.createNotificationChannel(
            const AndroidNotificationChannel(
              _messageChannelId,
              _messageChannelName,
              description: 'Notifications for new chat messages',
              // Mirror Vue sc_message_channel: importance High (sound + heads-up)
              // with vibration enabled.
              importance: Importance.high,
              enableVibration: true,
            ),
          );
          await androidPlugin.requestNotificationsPermission();
        }
      } else if (!kIsWeb && Platform.isIOS) {
        final iosPlugin = _notifications
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        await iosPlugin?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      }

      if (_isMobile) {
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
      }

      // Restore pending data when app is cold-launched from a notification tap.
      final launchDetails = await _notifications
          .getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp == true) {
        final payload = launchDetails!.notificationResponse?.payload;
        if (payload != null) _pendingNotificationData = _parsePayload(payload);
      }

      await _maybeRequestBatteryExemption();
    } catch (e, st) {
      debugPrint('NOTIF: platform init failed: $e\n$st');
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
  void setActiveContext(String? charId, String? sessionId) {
    if (_activeCharId == charId && _activeSessionId == sessionId) return;
    _activeCharId = charId;
    _activeSessionId = sessionId;
    _activeContextRevision++;
    _activeContextChanges.add(null);
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

    if (_isMobile && _lifecycleState != AppLifecycleState.resumed) {
      await sendMessageNotification(
        charName,
        messagePreview ?? 'New message received',
        avatarPath,
        charId,
        sessionId: sessionId,
        msgId: msgId,
      );
    }
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

  /// Shows a message notification. Suppressed while the app is foregrounded
  /// and the user is viewing the same charId+sessionId (mirrors Vue.js
  /// visibility + activeContext check).
  Future<void> sendMessageNotification(
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
        return;
      }
    }

    if (!_isMobile || !_initialized) return;

    try {
      final notifId = _stableId(charId);
      final payload = _buildPayload(charId, sessionId, msgId);
      final resolvedAvatar = resolveGlazeFilePath(avatarPath);

      final NotificationDetails details;
      if (Platform.isAndroid) {
        final personIcon =
            resolvedAvatar != null && File(resolvedAvatar).existsSync()
            ? BitmapFilePathAndroidIcon(resolvedAvatar)
            : null;
        final person = Person(name: title, icon: personIcon);
        final messagingStyle = MessagingStyleInformation(
          person,
          messages: [Message(body, DateTime.now(), person)],
          conversationTitle: title,
        );
        details = NotificationDetails(
          android: AndroidNotificationDetails(
            _messageChannelId,
            _messageChannelName,
            channelDescription: 'Notifications for new chat messages',
            importance: Importance.high,
            priority: Priority.high,
            styleInformation: messagingStyle,
            icon: 'new_message',
            autoCancel: true,
            groupKey: charId,
            // Mirror Vue: messaging content type + public lock-screen
            // visibility + vibration.
            category: AndroidNotificationCategory.message,
            visibility: NotificationVisibility.public,
            enableVibration: true,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        );
      } else {
        final attachments =
            resolvedAvatar != null && File(resolvedAvatar).existsSync()
            ? [DarwinNotificationAttachment(resolvedAvatar)]
            : <DarwinNotificationAttachment>[];
        details = NotificationDetails(
          iOS: DarwinNotificationDetails(
            attachments: attachments,
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        );
      }

      await _notifications.show(
        id: notifId,
        title: title,
        body: body,
        notificationDetails: details,
        payload: payload,
      );
    } catch (e) {
      debugPrint('NOTIF: sendMessageNotification failed: $e');
    }
  }

  /// Cancels delivered notifications for a character (e.g. when the user
  /// opens that chat). Mirrors Vue.js clearMessageNotifications.
  Future<void> clearMessageNotifications(String charId) async {
    if (!_isMobile) return;
    try {
      await _notifications.cancel(id: _stableId(charId));
    } catch (e) {
      debugPrint('NOTIF: clearMessageNotifications failed: $e');
    }
  }

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
