import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/translation_settings.dart';
import 'package:glaze_flutter/features/chat/composer_pins_provider.dart';
import 'package:glaze_flutter/features/translation/composer_translator.dart';
import 'package:glaze_flutter/features/translation/message_translation_controller.dart';
import 'package:glaze_flutter/features/translation/translation_languages.dart';
import 'package:glaze_flutter/features/translation/translation_service.dart';

void main() {
  group('TranslationSettings', () {
    test('is off by default, also for settings saved before it existed', () {
      expect(const TranslationSettings().enabled, isFalse);
      final legacy = PipelineSettings.fromJson({
        'studioAgent': <String, dynamic>{},
      });
      expect(legacy.translation, const TranslationSettings());
    });

    test('round-trips through the pipeline JSON', () {
      const settings = PipelineSettings(
        translation: TranslationSettings(
          enabled: true,
          apiConfigId: 'api-2',
          model: 'gpt-x',
          messageLanguage: 'ru',
          inputLanguage: 'en',
        ),
      );
      // Same trip as the provider's save / load through SharedPreferences.
      final stored = jsonDecode(jsonEncode(settings.toJson()));
      expect(
        PipelineSettings.fromJson(stored as Map<String, dynamic>),
        settings,
      );
    });
  });

  group('resolveTranslationConfig', () {
    const chat = ApiConfig(id: 'chat', model: 'chat-model');
    const cheap = ApiConfig(id: 'cheap', model: 'cheap-model');
    const embedding = ApiConfig(id: 'emb', mode: 'embedding');

    test('uses the bound connection, else the active one', () {
      expect(
        resolveTranslationConfig(
          const TranslationSettings(apiConfigId: 'cheap'),
          configs: const [chat, cheap],
          active: chat,
        )?.id,
        'cheap',
      );
      expect(
        resolveTranslationConfig(
          const TranslationSettings(apiConfigId: 'deleted'),
          configs: const [chat, cheap],
          active: chat,
        )?.id,
        'chat',
      );
    });

    test('folds in the model override', () {
      expect(
        resolveTranslationConfig(
          const TranslationSettings(model: ' tiny '),
          configs: const [chat],
          active: chat,
        )?.model,
        'tiny',
      );
    });

    test('refuses an embedding connection and no connection at all', () {
      expect(
        resolveTranslationConfig(
          const TranslationSettings(apiConfigId: 'emb'),
          configs: const [embedding],
          active: null,
        ),
        isNull,
      );
      expect(
        resolveTranslationConfig(
          const TranslationSettings(),
          configs: const [],
          active: null,
        ),
        isNull,
      );
    });
  });

  group('the translation request', () {
    test('carries the text alone — no chat history, no persona, no card', () {
      final messages = buildTranslationMessages(
        'She smiled. *waves*',
        resolveTranslationLanguage('ru'),
      );
      expect(messages, hasLength(2));
      expect(messages[0]['role'], 'system');
      expect(messages[0]['content'], contains('Russian'));
      expect(messages[1], {'role': 'user', 'content': 'She smiled. *waves*'});
    });

    test('an unknown language code falls back to English', () {
      expect(resolveTranslationLanguage('xx').code, 'en');
    });

    test('drops an inline reasoning block from the answer', () {
      expect(
        cleanTranslationOutput('<think>plan</think>\n Привет \n'),
        'Привет',
      );
    });
  });

  group('MessageTranslationController', () {
    late List<String> calls;
    late MessageTranslationController controller;
    late List<Object> errors;
    var acceptPending = true;

    setUp(() {
      calls = [];
      errors = [];
      acceptPending = true;
      controller = MessageTranslationController(
        view: MessageTranslationView(
          showPending: (id, original, label) async {
            calls.add('pending:$id:$original:$label');
            return acceptPending;
          },
          showTranslation: (id, original, text) async =>
              calls.add('show:$id:$original:$text'),
          showOriginal: (id) async => calls.add('original:$id'),
        ),
        onError: errors.add,
      );
    });

    Future<void> tap(
      String action, {
      MessageTranslator? translate,
      String text = 'Hello',
    }) => controller.handle(
      id: 'm1',
      action: action,
      text: text,
      pendingLabel: 'Translating...',
      translate: translate ?? (text, _) async => 'Привет',
    );

    test('shows the pending bubble, then the translation', () async {
      await tap('translate');
      expect(calls, [
        'pending:m1:Hello:Translating...',
        'show:m1:Hello:Привет',
      ]);
      expect(controller.isTranslating('m1'), isFalse);
    });

    test('sends nothing when the bubble no longer shows the text', () async {
      acceptPending = false;
      var sent = false;
      await tap(
        'translate',
        translate: (text, _) async {
          sent = true;
          return '';
        },
      );
      expect(sent, isFalse);
      expect(calls, ['pending:m1:Hello:Translating...']);
    });

    test('a cancel tap stops the request and restores the original', () async {
      final gate = Completer<String>();
      CancelToken? token;
      final running = tap(
        'translate',
        translate: (text, t) {
          token = t;
          return gate.future;
        },
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.isTranslating('m1'), isTrue);
      await tap('cancel');
      expect(token!.isCancelled, isTrue);
      gate.complete('late');
      await running;
      expect(calls, ['pending:m1:Hello:Translating...', 'original:m1']);
    });

    test('a request outliving a chat switch paints nothing', () async {
      final gate = Completer<String>();
      final running = tap('translate', translate: (_, _) => gate.future);
      await Future<void>.delayed(Duration.zero);
      controller.cancelAll();
      gate.complete('late');
      await running;
      expect(calls, ['pending:m1:Hello:Translating...']);
      expect(errors, isEmpty);
    });

    test('a failure restores the original and reports once', () async {
      await tap('translate', translate: (_, _) async => throw Exception('500'));
      expect(calls.last, 'original:m1');
      expect(errors, hasLength(1));
    });

    test('ignores an empty message and a second tap mid-request', () async {
      await tap('translate', text: '   ');
      expect(calls, isEmpty);
      final gate = Completer<String>();
      final first = tap('translate', translate: (_, _) => gate.future);
      await Future<void>.delayed(Duration.zero);
      await tap('translate');
      gate.complete('Привет');
      await first;
      expect(calls.where((c) => c.startsWith('pending')), hasLength(1));
    });
  });

  group('ComposerTranslator', () {
    test('replaces the draft, then a second tap restores it', () async {
      final field = TextEditingController(text: 'Привет');
      final translator = ComposerTranslator(field);
      addTearDown(translator.dispose);
      Future<void> tap() => translator.toggle(
        translate: (text, _) async => 'Hello',
        onEmpty: () => fail('not empty'),
        onError: (e) => fail('$e'),
      );

      await tap();
      expect(field.text, 'Hello');
      expect(translator.canRestore, isTrue);
      await tap();
      expect(field.text, 'Привет');
      expect(translator.canRestore, isFalse);
    });

    test('an edited translation is translated again, not reverted', () async {
      final field = TextEditingController(text: 'Привет');
      final translator = ComposerTranslator(field);
      addTearDown(translator.dispose);
      await translator.toggle(
        translate: (text, _) async => 'Hello',
        onEmpty: () {},
        onError: (_) {},
      );
      field.text = 'Hello!';
      expect(translator.canRestore, isFalse);
    });

    test('a cancelled request leaves the draft alone', () async {
      final field = TextEditingController(text: 'Привет');
      final translator = ComposerTranslator(field);
      addTearDown(translator.dispose);
      final gate = Completer<String>();
      final running = translator.toggle(
        translate: (_, _) => gate.future,
        onEmpty: () {},
        onError: (e) => fail('$e'),
      );
      expect(translator.busy, isTrue);
      await translator.toggle(
        translate: (_, _) async => 'x',
        onEmpty: () {},
        onError: (_) {},
      );
      expect(translator.busy, isFalse);
      gate.complete('Hello');
      await running;
      expect(field.text, 'Привет');
    });

    test('an empty draft is not sent', () async {
      final field = TextEditingController(text: '  ');
      final translator = ComposerTranslator(field);
      addTearDown(translator.dispose);
      var empty = false;
      await translator.toggle(
        translate: (_, _) async => fail('sent'),
        onEmpty: () => empty = true,
        onError: (_) {},
      );
      expect(empty, isTrue);
    });
  });

  test('the composer translate action is not in the shipped row', () {
    expect(
      kDefaultComposerPins,
      isNot(contains(ComposerPin.action(ComposerAction.translate))),
    );
  });
}
