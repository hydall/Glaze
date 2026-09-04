import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../constants/build_channel.dart';
import '../../utils/platform_paths.dart';

/// Platform half of the "new message from <character>" notification.
///
/// Owns the `flutter_local_notifications` plugin: per-platform initialization,
/// the Android channel, and the construction of one notification. It never
/// decides *whether* a notification is warranted — that is
/// `GenerationNotificationService`'s job (lifecycle, active chat, leases).
///
/// Every step degrades instead of failing. The previous implementation latched
/// a single `_initialized` flag on the first `initialize()` call and dropped
/// every notification for the rest of the process when that call threw, with
/// nothing but a `debugPrint` to show for it — a silent, permanent outage.
/// Here a failed init is retried on the next send, and a notification the
/// platform rejects is re-posted in a simpler form that keeps the same icon.
class MessageNotificationPresenter {
  MessageNotificationPresenter({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const channelId = 'glaze_message';
  static const channelName = 'New Messages';
  static const channelDescription = 'Notifications for new chat messages';

  /// The envelope, carried over from the Vue app. Every notification this
  /// plugin posts in Glaze is a new-message notification, so it is both the
  /// default registered at init and the per-notification override.
  static const _androidMessageIcon = 'new_message';

  /// Android small-icon candidates in preference order, the envelope first.
  ///
  /// `flutter_local_notifications` resolves an icon by *name* through
  /// `Resources.getIdentifier(name, "drawable", context.getPackageName())` and
  /// errors out when the lookup returns 0. That lookup can fail for reasons
  /// this file does not control — release-build resource shrinking, a
  /// per-channel `applicationIdSuffix`, a renamed drawable — and it used to
  /// abort `initialize()` outright. Trying several names means one broken
  /// resource costs the icon, not the notification.
  ///
  /// `ic_stat_icon_config_sample` is the generation spinner the foreground
  /// service uses; it sits here only as a fallback that is known to exist, and
  /// must never be the first choice — a new message showing a refresh arrow is
  /// exactly the confusion this ordering avoids.
  static const _androidIconCandidates = <String>[
    _androidMessageIcon,
    'ic_stat_icon_config_sample',
    'transparent_splash_icon',
    'launch_background',
  ];

  // Windows toasts are addressed by an Application User Model ID; the GUID
  // identifies the COM activation callback. Both are per-install identities, so
  // they carry the build channel — a Nightly toast must not activate Stable.
  static const _windowsAppName = isStableChannel
      ? 'Glaze'
      : 'Glaze ($buildChannel)';
  static const _windowsAppUserModelId = isStableChannel
      ? 'Hydall.Glaze'
      : 'Hydall.Glaze.$buildChannel';
  static const _windowsGuid = '9b1e6a54-3d27-4c8f-2b71-5e0a4d9c8f36';

  final FlutterLocalNotificationsPlugin _plugin;

  bool _initialized = false;
  bool _platformConfigured = false;
  bool _androidMessageIconRejected = false;
  int _initAttempts = 0;
  String? _lastError;
  String? _lastDeliveredForm;

  /// How many times initialization may be re-attempted before it is treated as
  /// permanently broken. Retrying at all is what recovers from a failure that
  /// is really a startup-order problem; capping it keeps a genuinely broken
  /// install from paying several platform round-trips per generated reply.
  static const _maxInitAttempts = 5;

  /// Why the last send failed, or `null` when the last send worked. Surfaced by
  /// the notification self-test in settings so a platform-side refusal is
  /// visible instead of living in `debugPrint`.
  String? get lastError => _lastError;

  /// Which form of the notification the OS actually accepted on the last
  /// successful send — the self-test reports it, because a step-down to
  /// "plain" is the visible sign that this device refuses the messaging style
  /// or the avatar.
  String? get lastDeliveredForm => _lastDeliveredForm;

  /// Platforms with a notification backend in `flutter_local_notifications`.
  /// Web is excluded — Glaze does not target it (see CLAUDE.md).
  bool get isSupported =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS ||
          Platform.isWindows ||
          Platform.isLinux);

  static bool get _isDarwin => !kIsWeb && (Platform.isIOS || Platform.isMacOS);

  /// Initializes the plugin and, on Android, the message channel. Safe to call
  /// repeatedly: it no-ops once initialization has succeeded and retries when
  /// it has not.
  Future<bool> ensureInitialized({
    required DidReceiveNotificationResponseCallback onTap,
  }) async {
    if (_initialized) return true;
    if (!isSupported) return false;
    if (_initAttempts >= _maxInitAttempts) return false;
    _initAttempts++;

    if (!kIsWeb && Platform.isAndroid) {
      // Try each icon in turn: `initialize()` throws `invalid_icon` for a name
      // the Android resource table cannot resolve.
      for (final icon in _androidIconCandidates) {
        if (await _tryInitialize(onTap: onTap, androidIcon: icon)) break;
      }
    } else {
      await _tryInitialize(onTap: onTap, androidIcon: null);
    }

    // The channel and the permission prompt are independent of the plugin's
    // own initialization, so they are configured even when that failed — a
    // channel the user has already tuned must not be lost to an icon problem.
    await _configurePlatform();
    return _initialized;
  }

  Future<bool> _tryInitialize({
    required DidReceiveNotificationResponseCallback onTap,
    required String? androidIcon,
  }) async {
    try {
      await _plugin.initialize(
        settings: InitializationSettings(
          android: androidIcon == null
              ? null
              : AndroidInitializationSettings(androidIcon),
          iOS: const DarwinInitializationSettings(
            requestAlertPermission: true,
            requestBadgePermission: true,
            requestSoundPermission: true,
          ),
          macOS: const DarwinInitializationSettings(
            requestAlertPermission: true,
            requestBadgePermission: true,
            requestSoundPermission: true,
          ),
          linux: const LinuxInitializationSettings(defaultActionName: 'Open'),
          windows: const WindowsInitializationSettings(
            appName: _windowsAppName,
            appUserModelId: _windowsAppUserModelId,
            guid: _windowsGuid,
          ),
        ),
        onDidReceiveNotificationResponse: onTap,
      );
      _initialized = true;
      return true;
    } catch (e) {
      _lastError = 'initialize(${androidIcon ?? 'default'}) failed: $e';
      debugPrint('NOTIF: $_lastError');
      return false;
    }
  }

  Future<void> _configurePlatform() async {
    if (_platformConfigured) return;
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final android = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        if (android == null) return;
        await android.createNotificationChannel(
          const AndroidNotificationChannel(
            channelId,
            channelName,
            description: channelDescription,
            // Mirror Vue sc_message_channel: importance High (sound + heads-up)
            // with vibration enabled.
            importance: Importance.high,
            enableVibration: true,
          ),
        );
        await android.requestNotificationsPermission();
        _platformConfigured = true;
      } else if (!kIsWeb && Platform.isIOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        _platformConfigured = true;
      } else if (!kIsWeb && Platform.isMacOS) {
        await _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        _platformConfigured = true;
      } else {
        // Linux and Windows have nothing to configure up front.
        _platformConfigured = true;
      }
    } catch (e) {
      debugPrint('NOTIF: platform configuration failed: $e');
    }
  }

  /// Whether the OS currently lets Glaze post notifications. `null` where the
  /// platform cannot answer.
  Future<bool?> areNotificationsEnabled() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      return await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.areNotificationsEnabled();
    } catch (_) {
      return null;
    }
  }

  /// Posts one message notification. Returns whether it reached the OS.
  ///
  /// Three attempts, each dropping the part most likely to have been refused:
  /// the full notification, then the same without the sender avatar, then a
  /// plain title+body one. The avatar is a file the platform decodes into a
  /// bitmap and the messaging style is an OEM-sensitive layout, so either can
  /// sink a notification that is otherwise perfectly postable — stepping down
  /// makes a rejected avatar cost the avatar rather than the message.
  ///
  /// Every step keeps the envelope icon: a fallback the user cannot tell apart
  /// from a normal notification is the point.
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required String groupKey,
    String? avatarPath,
  }) async {
    if (!isSupported) return false;

    final avatar = _existingAvatarPath(avatarPath);
    // Built on demand, not up front: an attempt can mark the small icon
    // rejected, and a later step has to be constructed after that to leave the
    // icon out rather than repeat the rejection.
    final attempts = <(String, NotificationDetails Function())>[
      if (avatar != null)
        (
          'rich',
          () => _richDetails(
            title: title,
            body: body,
            groupKey: groupKey,
            avatar: avatar,
          ),
        ),
      (
        avatar == null ? 'rich' : 'rich, no avatar',
        () => _richDetails(
          title: title,
          body: body,
          groupKey: groupKey,
          avatar: null,
        ),
      ),
      ('plain', () => _plainDetails(groupKey: groupKey)),
    ];

    for (final (form, buildDetails) in attempts) {
      if (await _post(
        id: id,
        title: title,
        body: body,
        payload: payload,
        details: buildDetails(),
      )) {
        _lastDeliveredForm = form;
        return true;
      }
      // An unresolvable small icon is the one rejection that repeats for every
      // send, so remember it and stop asking for that icon. Anything else (a
      // bad avatar on this one message) stays a per-send step-down.
      if (!kIsWeb &&
          Platform.isAndroid &&
          (_lastError?.contains('invalid_icon') ?? false)) {
        _androidMessageIconRejected = true;
      }
    }
    return false;
  }

  Future<bool> _post({
    required int id,
    required String title,
    required String body,
    required String payload,
    required NotificationDetails details,
  }) async {
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: details,
        payload: payload,
      );
      _lastError = null;
      return true;
    } catch (e) {
      _lastError = 'show failed: $e';
      debugPrint('NOTIF: $_lastError');
      return false;
    }
  }

  NotificationDetails _richDetails({
    required String title,
    required String body,
    required String groupKey,
    required String? avatar,
  }) {
    AndroidNotificationDetails? android;
    if (!kIsWeb && Platform.isAndroid) {
      final person = Person(
        name: title,
        icon: avatar == null ? null : BitmapFilePathAndroidIcon(avatar),
      );
      android = AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDescription,
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: MessagingStyleInformation(
          person,
          messages: [Message(body, DateTime.now(), person)],
          conversationTitle: title,
        ),
        icon: _androidMessageIconRejected ? null : _androidMessageIcon,
        autoCancel: true,
        groupKey: groupKey,
        // Mirror Vue: messaging content type + public lock-screen visibility
        // + vibration.
        category: AndroidNotificationCategory.message,
        visibility: NotificationVisibility.public,
        enableVibration: true,
      );
    }

    return NotificationDetails(
      android: android,
      iOS: _darwinDetails(avatar),
      macOS: _darwinDetails(avatar),
      linux: LinuxNotificationDetails(
        icon: avatar == null ? null : FilePathLinuxIcon(avatar),
      ),
      windows: WindowsNotificationDetails(
        images: avatar == null
            ? const []
            : [
                WindowsImage(
                  Uri.file(avatar, windows: true),
                  altText: title,
                  placement: WindowsImagePlacement.appLogoOverride,
                  crop: WindowsImageCrop.circle,
                ),
              ],
      ),
    );
  }

  NotificationDetails _plainDetails({required String groupKey}) =>
      NotificationDetails(
        android: (!kIsWeb && Platform.isAndroid)
            ? AndroidNotificationDetails(
                channelId,
                channelName,
                channelDescription: channelDescription,
                importance: Importance.high,
                priority: Priority.high,
                icon: _androidMessageIconRejected ? null : _androidMessageIcon,
                autoCancel: true,
                groupKey: groupKey,
                category: AndroidNotificationCategory.message,
                visibility: NotificationVisibility.public,
                enableVibration: true,
              )
            : null,
        iOS: _darwinDetails(null),
        macOS: _darwinDetails(null),
        linux: const LinuxNotificationDetails(),
        windows: const WindowsNotificationDetails(),
      );

  DarwinNotificationDetails? _darwinDetails(String? avatar) {
    if (!_isDarwin) return null;
    return DarwinNotificationDetails(
      attachments: avatar == null
          ? const []
          : [DarwinNotificationAttachment(avatar)],
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
  }

  String? _existingAvatarPath(String? avatarPath) {
    final resolved = resolveGlazeFilePath(avatarPath);
    if (resolved == null || resolved.isEmpty) return null;
    try {
      return File(resolved).existsSync() ? resolved : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> cancel(int id) async {
    if (!isSupported) return;
    try {
      await _plugin.cancel(id: id);
    } catch (e) {
      debugPrint('NOTIF: cancel($id) failed: $e');
    }
  }

  /// Payload of the notification that cold-launched the app, if any.
  Future<String?> consumeLaunchPayload() async {
    if (!isSupported) return null;
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return null;
      return details!.notificationResponse?.payload;
    } catch (e) {
      debugPrint('NOTIF: launch details failed: $e');
      return null;
    }
  }
}
