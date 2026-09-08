import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/controllers/chat_session_controller.dart';

class _StateBox {
  _StateBox(this.value);

  AsyncValue<ChatState> value;
  var writes = 0;
}

final _stateBoxProvider = Provider<_StateBox>(
  (ref) => throw UnimplementedError(),
);

final _controllerProvider = Provider.family<ChatSessionController, String>((
  ref,
  charId,
) {
  final box = ref.watch(_stateBoxProvider);
  return ChatSessionController(
    ref: ref,
    charId: charId,
    setState: (value) {
      box.value = value;
      box.writes++;
    },
    getState: () => box.value,
    invalidateHistory: () {},
    fixupSwipesWithImageResults: (session) => session,
  );
});

void main() {
  test('same-session switch preserves active generation state', () async {
    final state = ChatState(
      session: const ChatSession(id: 's1', characterId: 'c1', sessionIndex: 1),
      isGenerating: true,
      generationStartTime: DateTime(2026),
    );
    final box = _StateBox(AsyncData(state));
    final container = ProviderContainer(
      overrides: [_stateBoxProvider.overrideWithValue(box)],
    );
    addTearDown(container.dispose);

    await container.read(_controllerProvider('c1')).switchSession(1);

    expect(box.value.value, same(state));
    expect(box.writes, 0);
  });
}
