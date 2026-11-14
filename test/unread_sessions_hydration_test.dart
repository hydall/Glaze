import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/chat/unread_sessions_provider.dart';

/// Regression tests for the unread-dot hydration race: a session opened before
/// the persisted set finished loading used to be flagged unread again the
/// moment `_load` merged the stored ids in — so a reply the user had already
/// read showed a dot in the chat list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  void setUpContainer(List<String> stored) {
    SharedPreferences.setMockInitialValues({'unread_sessions': stored});
    container = ProviderContainer();
    addTearDown(container.dispose);
  }

  test('session read during hydration is not resurrected by the load', () async {
    setUpContainer(['s1', 's2']);

    // Reading the provider starts the async load; mark read before it lands.
    expect(container.read(unreadSessionsProvider), isEmpty);
    container.read(unreadSessionsProvider.notifier).markRead('s1');

    await pumpEventQueue();

    expect(container.read(unreadSessionsProvider), {'s2'});
  });

  test('pruned id is dropped from prefs so it stays read across restarts', () async {
    setUpContainer(['s1', 's2']);

    container.read(unreadSessionsProvider.notifier).markRead('s1');
    await pumpEventQueue();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('unread_sessions'), ['s2']);
  });

  test('mark during hydration survives the merge and does not clobber prefs', () async {
    setUpContainer(['s1']);

    // A reply landing during app start must not flush the still-empty set over
    // the stored one — that used to wipe every other session's dot.
    container.read(unreadSessionsProvider.notifier).markUnread('s2');
    await pumpEventQueue();

    expect(container.read(unreadSessionsProvider), {'s1', 's2'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('unread_sessions')?.toSet(), {'s1', 's2'});
  });

  test('a fresh reply after hydration re-flags a previously read session', () async {
    setUpContainer(['s1']);

    container.read(unreadSessionsProvider.notifier).markRead('s1');
    await pumpEventQueue();
    expect(container.read(unreadSessionsProvider), isEmpty);

    container.read(unreadSessionsProvider.notifier).markUnread('s1');
    expect(container.read(unreadSessionsProvider), {'s1'});
  });

  test('stored set is restored untouched when nothing was read early', () async {
    setUpContainer(['s1', 's2']);

    // The provider is lazy — read it first so `build` kicks off the load.
    expect(container.read(unreadSessionsProvider), isEmpty);
    await pumpEventQueue();

    expect(container.read(unreadSessionsProvider), {'s1', 's2'});
  });
}
