import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/navigation/router.dart';
import 'package:glaze_flutter/core/services/generation_notification_service.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

import 'helpers/pump_glaze_app.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  Uri? matchedUri;

  setUpAll(initLocalizationOnce);

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const SizedBox()),
        GoRoute(
          path: '/chat/:charId',
          builder: (_, state) {
            matchedUri = state.uri;
            return const SizedBox();
          },
        ),
      ],
    );
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        routerProvider.overrideWithValue(router),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  testWidgets('notification opens its session and target message', (
    tester,
  ) async {
    await container
        .read(chatRepoProvider)
        .put(
          const ChatSession(
            id: 'notification-session',
            characterId: 'notification-character',
            sessionIndex: 7,
          ),
        );

    await pumpGlazeApp(
      tester,
      container: container,
      notificationForTesting: const NotificationNavigationData(
        charId: 'notification-character',
        sessionId: 'notification-session',
        msgId: 'notification-message',
      ),
    );
    await pumpNavigation(tester);

    final location = matchedUri;
    expect(location, isNotNull);
    expect(location!.path, '/chat/notification-character');
    expect(location.queryParameters['session'], '7');
    expect(location.queryParameters['msg'], 'notification-message');
    expect(tester.takeException(), isNull);
  });
}
