import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/platform/haptics.dart';
import 'package:glaze_flutter/core/services/generation_notification_service.dart';
import 'package:glaze_flutter/core/services/notifications/message_notification_presenter.dart';

/// One notification reached the fake presenter.
class _Shown {
  _Shown(this.id, this.title, this.body, this.payload, this.groupKey);

  final int id;
  final String title;
  final String body;
  final String payload;
  final String groupKey;
}

class _FakePresenter extends MessageNotificationPresenter {
  final List<_Shown> shown = [];
  final List<int> cancelled = [];

  @override
  bool get isSupported => true;

  @override
  Future<bool> ensureInitialized({
    required DidReceiveNotificationResponseCallback onTap,
  }) async => true;

  @override
  Future<bool> show({
    required int id,
    required String title,
    required String body,
    required String payload,
    required String groupKey,
    String? avatarPath,
  }) async {
    shown.add(_Shown(id, title, body, payload, groupKey));
    return true;
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

/// The rule these guard: a reply is worth a notification whenever the user is
/// not looking at the chat it landed in. Being in *another* chat counts — the
/// old gate dropped every notification while Glaze was foregrounded, which made
/// the per-session suppression below unreachable.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = GenerationNotificationService.instance;
  late _FakePresenter presenter;

  setUp(() {
    // The incoming-message buzz is a platform channel with no handler here, and
    // it fires before the notification decision this file is about.
    Haptics.configureMessageVibration(enabled: false);
    presenter = _FakePresenter();
    service.debugSetPresenter(presenter);
    service.updateLifecycleState(AppLifecycleState.resumed);
    service.setActiveContext(null, null);
    presenter.shown.clear();
    presenter.cancelled.clear();
  });

  tearDown(() {
    Haptics.configureMessageVibration(enabled: true);
    service.setActiveContext(null, null);
    service.updateLifecycleState(AppLifecycleState.resumed);
  });

  Future<void> replyLands({String charId = 'char-a', String? sessionId}) =>
      service.onGenerationCompleted(
        'Aria',
        charId,
        messagePreview: 'hello',
        sessionId: sessionId ?? 'sess-1',
        msgId: 'msg-1',
      );

  test('suppressed while the user is looking at that very chat', () async {
    service.setActiveContext('char-a', 'sess-1');
    await replyLands();
    expect(presenter.shown, isEmpty);
  });

  test('sent when another session of the same character is open', () async {
    service.setActiveContext('char-a', 'sess-2');
    await replyLands(sessionId: 'sess-1');
    expect(presenter.shown, hasLength(1));
    expect(presenter.shown.single.payload, 'chat:char-a:sess-1:msg-1');
  });

  test('sent when another character is open', () async {
    service.setActiveContext('char-b', 'sess-9');
    await replyLands();
    expect(presenter.shown, hasLength(1));
    expect(presenter.shown.single.groupKey, 'char-a');
  });

  test('sent when no chat is open at all', () async {
    await replyLands();
    expect(presenter.shown, hasLength(1));
  });

  test('sent while the app is backgrounded, same chat or not', () async {
    service.setActiveContext('char-a', 'sess-1');
    service.updateLifecycleState(AppLifecycleState.paused);
    presenter.cancelled.clear();
    await replyLands();
    expect(presenter.shown, hasLength(1));
  });

  test('opening a chat dismisses that character notification', () async {
    await replyLands();
    final postedId = presenter.shown.single.id;

    service.setActiveContext('char-a', 'sess-1');
    await Future<void>.delayed(Duration.zero);
    expect(presenter.cancelled, contains(postedId));
  });

  test('the test notification ignores the on-screen-chat suppression', () async {
    service.setActiveContext('char-a', 'sess-1');
    final sent = await service.sendTestNotification('Glaze', 'ping');
    expect(sent, isTrue);
    expect(presenter.shown, hasLength(1));
  });
}
