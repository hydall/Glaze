import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/extensions/services/command_registry.dart';
import 'helpers/js_bridge_test_support.dart';

void main() {
  group('CommandRegistry', () {
    test('rejects command names without leading slash', () {
      final r = CommandRegistry();
      expect(
        () => r.register(
          GlazeCommand(
            name: 'trigger',
            summary: '',
            handler: (_, _) async => const CommandResult.ok(),
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('runs a registered command and returns its result', () async {
      final r = CommandRegistry().register(
        GlazeCommand(
          name: '/echo',
          summary: '',
          handler: (args, context) async => CommandResult.ok(
            message: 'echoed ${args['text']}',
            data: {'charId': context.charId},
          ),
        ),
      );
      final result = await r.run('/echo', {
        'text': 'hi',
      }, context: const CommandContext(charId: 'c1'));
      expect(result.ok, isTrue);
      expect(result.message, 'echoed hi');
      expect(result.data, {'charId': 'c1'});
    });

    test('returns an error for unknown commands', () async {
      final r = CommandRegistry();
      final result = await r.run('/unknown', const {});
      expect(result.ok, isFalse);
      expect(result.message, contains('Unknown command "/unknown"'));
    });

    test('catches handler exceptions and returns an error result', () async {
      final r = CommandRegistry().register(
        GlazeCommand(
          name: '/boom',
          summary: '',
          handler: (_, _) async => throw StateError('kaboom'),
        ),
      );
      final result = await r.run('/boom', const {});
      expect(result.ok, isFalse);
      expect(result.message, contains('kaboom'));
    });

    test('list() exposes every registered command', () {
      final r = buildDefaultCommandRegistry();
      final names = r.list().map((c) => c.name).toSet();
      expect(names, {'/trigger', '/getvar', '/setvar', '/inject', '/toast'});
    });
  });

  group('JsBridgeService executeCommand', () {
    test(
      'delegates command + args + context to the injected handler',
      () async {
        String? seenCommand;
        Map<String, dynamic>? seenArgs;
        final bridge = TestJsBridge.create(
          permissionCheck: (_) => true,
          executeCommand: (command, args, context) async {
            seenCommand = command;
            seenArgs = args;
            return {'ok': true, 'message': 'done'};
          },
        );
        final result = await bridge.dispatch({
          'method': 'executeCommand',
          'params': {
            'command': '/toast',
            'args': {'message': 'hi'},
          },
        });
        expect(result['ok'], isTrue);
        expect(seenCommand, '/toast');
        expect(seenArgs, {'message': 'hi'});
      },
    );

    test('rejects empty command with invalid_request', () async {
      final bridge = TestJsBridge.create(
        permissionCheck: (_) => true,
        executeCommand: (_, _, _) async => const {'ok': true},
      );
      final result = await bridge.dispatch({
        'method': 'executeCommand',
        'params': {'command': ''},
      });
      expect(result['ok'], isFalse);
      expect(result['error']['code'], 'invalid_request');
    });

    test('denies when execute_command capability is not granted', () async {
      final bridge = TestJsBridge.create(
        permissionCheck: (_) => false,
        executeCommand: (_, _, _) async => const {'ok': true},
      );
      final result = await bridge.dispatch({
        'method': 'executeCommand',
        'params': {'command': '/toast'},
      });
      expect(result['ok'], isFalse);
      expect(
        (result['error']['message'] as String),
        contains('execute_command'),
      );
    });

    test('returns unsupported_method when no handler is registered', () async {
      final bridge = TestJsBridge.create(permissionCheck: (_) => true);
      final result = await bridge.dispatch({
        'method': 'executeCommand',
        'params': {'command': '/toast'},
      });
      expect(result['ok'], isFalse);
      expect(result['error']['code'], 'unsupported_method');
    });
  });
}
