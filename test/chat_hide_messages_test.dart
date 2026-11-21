import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';

final _messageServiceProvider = Provider(ChatMessageService.new);

ChatMessage _m(String id, {bool hidden = false}) => ChatMessage(
  id: id,
  role: 'user',
  content: id,
  timestamp: 1,
  isHidden: hidden,
);

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [appDbProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  final session = ChatSession(
    id: 's1',
    characterId: 'c1',
    sessionIndex: 0,
    messages: [_m('a'), _m('b', hidden: true), _m('c'), _m('d')],
  );

  test('hiding a mixed selection hides all of it instead of flipping', () {
    final svc = container.read(_messageServiceProvider);
    final out = svc.setMessagesHidden(session, {'a', 'b', 'c'}, true);
    expect(out.messages.map((m) => m.isHidden), [true, true, true, false]);
  });

  test('a selection already in the asked state leaves the session alone', () {
    final svc = container.read(_messageServiceProvider);
    expect(
      identical(svc.setMessagesHidden(session, {'b'}, true), session),
      isTrue,
    );
    expect(
      identical(svc.setMessagesHidden(session, {'x'}, true), session),
      isTrue,
    );
  });

  test('the whole selection reaches the database in one write', () async {
    await container.read(chatRepoProvider).put(session);
    final svc = container.read(_messageServiceProvider);
    final durable = await svc.commitMessagesMutation(
      session,
      (latest) => svc.setMessagesHidden(latest, {'a', 'c', 'd'}, true),
    );
    expect(durable.messages.every((m) => m.isHidden), isTrue);
    final stored = await container.read(chatRepoProvider).getById('s1');
    expect(stored!.messages.every((m) => m.isHidden), isTrue);
  });
}
