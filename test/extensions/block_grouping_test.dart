import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/active_regex_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/extensions/models/block_config.dart';
import 'package:glaze_flutter/features/extensions/models/block_context_item.dart';
import 'package:glaze_flutter/features/extensions/models/block_modes.dart';
import 'package:glaze_flutter/features/extensions/models/connection_profiles.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_grouping.dart';
import 'package:glaze_flutter/features/extensions/services/blocks/block_llm_runner.dart';
import 'package:glaze_flutter/features/extensions/services/info_block_service.dart';
import 'package:glaze_flutter/features/extensions/services/macro_expander.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _context = [
  BlockContextItem(
    id: 'c1',
    name: 'Chat',
    type: ContextItemType.lastMessages,
    messagesCount: 5,
  ),
];

BlockConfig _block(String name, {List<BlockContextItem> context = _context}) =>
    BlockConfig(
      id: name,
      name: name,
      prompt: 'Describe $name',
      template: '<{{name}}>\n\n</{{name}}>',
      context: context,
    );

class _CountingTransport implements ChatTransport {
  _CountingTransport(this.reply);

  final String reply;
  final requests = <ChatTransportRequest>[];

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    requests.add(request);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    onComplete?.call(reply, null);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => const [];
}

class _FixedApiList extends ApiListNotifier {
  @override
  Future<List<ApiConfig>> build() async => const [
    ApiConfig(
      id: 'api',
      name: 'test',
      endpoint: 'https://example.test',
      apiKey: 'k',
      model: 'm',
    ),
  ];
}

void main() {
  group('grouping', () {
    test('blocks sharing context and background run together', () {
      final mood = _block('mood');
      final place = _block('place');
      final bg = _block('bg').copyWith(background: true);
      final bg2 = _block('bg2').copyWith(background: true);
      final alone = _block('alone', context: const []);
      final chained = _block('chained').copyWith(dependsOnPrevious: true);
      final other = _block(
        'other',
      ).copyWith(apiPreset: ConnectionProfile.small);
      final carried = _block('carried').copyWith(source: BlockSource.carried);

      final groups = blockGroups([
        mood,
        place,
        bg,
        bg2,
        alone,
        chained,
        other,
        carried,
      ]);
      expect(groups['mood']!.map((b) => b.id), ['mood', 'place']);
      expect(groups['place'], same(groups['mood']));
      expect(groups['bg']!.map((b) => b.id), ['bg', 'bg2']);
      for (final id in ['alone', 'chained', 'other', 'carried']) {
        expect(groups.containsKey(id), isFalse, reason: id);
      }
    });

    test('disabled context items do not count', () {
      final a = _block('a');
      final b = _block(
        'b',
        context: [
          ..._context,
          const BlockContextItem(id: 'x', name: 'Extra', disabled: true),
        ],
      );
      expect(blockGroupKey(a), blockGroupKey(b));
    });

    test('the header lists prompts, then templates, as the original', () {
      final header = upstreamBlocksHeader([
        _block('mood'),
        _block('place').copyWith(prompt: '  '),
      ], const MacroContext(persona: 'Ann'));
      expect(
        header,
        'Block(s) prompt:\nDescribe mood\n\n'
        'Block(s) template:\n<mood>\n\n</mood>\n<place>\n\n</place>',
      );
      expect(
        upstreamBlocksHeader([
          _block('x').copyWith(prompt: '', template: ''),
        ], MacroContext.empty),
        '',
      );
    });
  });

  test('a group asks the model once and each block takes its tag', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        apiListProvider.overrideWith(_FixedApiList.new),
        activeRegexesProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);

    final transport = _CountingTransport(
      '<mood>\ncalm\n</mood>\n<place>\nthe train\n</place>',
    );
    final service = InfoBlockService(
      _RefHolder.of(container),
      llmRunner: BlockLlmRunner(transportPicker: (_) => transport),
    );
    final group = [_block('mood'), _block('place'), _block('missing')];
    const messages = [
      ChatMessage(id: 'u', role: 'user', content: 'hi'),
      ChatMessage(id: 'm', role: 'assistant', content: 'Reply'),
    ];
    final token = CancelToken();
    Future<({String? content, String? error})> run(BlockConfig block) =>
        service.generateSingleBlockContent(
          sessionId: 's',
          messageId: 'm',
          messages: messages,
          blockConfig: block,
          character: null,
          persona: 'Ann',
          previousOutput: null,
          cancelToken: token,
          group: group,
        );

    final results = await Future.wait(group.map(run));
    expect(transport.requests, hasLength(1));
    final system = transport.requests.single.messages.first;
    expect(system['role'], 'system');
    expect(
      system['content'] as String,
      startsWith('Block(s) prompt:\nDescribe mood\nDescribe place'),
    );
    expect(results[0].content, 'calm');
    expect(results[1].content, 'the train');
    expect(results[2].content, isNull);
    expect(results[2].error, contains('<missing>'));
  });
}

/// The [Ref] a service built outside a provider needs.
class _RefHolder {
  static Ref of(ProviderContainer container) {
    late Ref ref;
    final probe = Provider<int>((r) {
      ref = r;
      return 0;
    });
    container.read(probe);
    return ref;
  }
}
