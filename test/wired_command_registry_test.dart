// Tests for the wired `CommandRegistry` - the production path that
// dispatches `/trigger`, `/getvar`, `/setvar`, `/inject`, and `/toast`
// to the same services the dedicated bridge methods use.
//
// The wired registry replaced the previous echo-only MVP, so the
// contract pinned here is:
//   * Every command routes through `JsBridgeService.dispatch`, so the
//     dedicated capability, validation, scope, and context rules apply.
//   * Each command validates its args and returns `CommandResult.error`
//     for malformed inputs instead of throwing.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/global_variables_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/features/extensions/services/command_registry.dart';
import 'package:glaze_flutter/features/extensions/models/trigger_mode.dart';
import 'package:glaze_flutter/features/extensions/models/trigger_result.dart';
import 'package:glaze_flutter/features/extensions/services/generation_dispatcher.dart';
import 'package:glaze_flutter/features/extensions/services/js_bridge_service.dart';
import 'package:glaze_flutter/features/extensions/services/runtime_prompt_injection_service.dart';
import 'package:glaze_flutter/features/extensions/services/trigger_generation_handler.dart';
import 'helpers/js_bridge_test_support.dart';

AppDatabase _testDb() => AppDatabase.forTesting(NativeDatabase.memory());

/// Noop `GenerationDispatcher` for unit tests. The wired command
/// registry's `/trigger` validation should never reach the dispatcher;
/// when it does, we return `TriggerNoSession` to keep the test
/// deterministic without touching `Ref`.
class _NoopDispatcher extends GenerationDispatcher {
  @override
  Future<TriggerResult> dispatch({
    required String charId,
    String? rawMode,
    String? reason,
  }) async {
    return TriggerNoSession(mode: TriggerMode.parse(rawMode));
  }

  _NoopDispatcher() : super(null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late CharacterRepo characterRepo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = _testDb();
    characterRepo = CharacterRepo(db);
    await characterRepo.put(Character(id: 'c1', name: 'Alice'));
  });

  tearDown(() async {
    await db.close();
  });

  /// Helper to build a wired registry backed by one fully wired bridge.
  CommandRegistry buildRegistry() {
    late final JsBridgeService bridge;
    final registry = buildWiredCommandRegistry(
      WiredCommandDeps(bridgeDispatch: (request) => bridge.dispatch(request)),
    );
    final promptInjection = RuntimePromptInjectionNotifier();
    final triggerHandler = TriggerGenerationHandler(
      dispatcher: _NoopDispatcher(),
    );
    bridge = TestJsBridge.create(
      characterRepo: characterRepo,
      currentSessionId: () => 's1',
      currentCharacterId: () => 'c1',
      permissionCheck: (_) => true,
      injectPrompt: (id, content, options, context) {
        final injected = promptInjection.inject(
          sessionId: context['sessionId'] as String? ?? 's1',
          id: id,
          content: content,
          depth: options['depth'] as int? ?? 0,
          role: options['role'] as String? ?? 'system',
        );
        return {
          'id': injected.id,
          'depth': injected.depth,
          'role': injected.role,
        };
      },
      showToast: (_, _) {},
      triggerGeneration: (charId, params) =>
          triggerHandler.handle(charId: charId ?? 'c1', params: params),
    );
    return registry;
  }

  group('wired registry setup', () {
    test('registers all five MVP commands', () {
      final registry = buildRegistry();
      final names = registry.list().map((c) => c.name).toSet();
      expect(names, {'/trigger', '/getvar', '/setvar', '/inject', '/toast'});
    });

    test('every command dispatches its registered canonical method', () async {
      String? dispatchedMethod;
      final registry = buildWiredCommandRegistry(
        WiredCommandDeps(
          bridgeDispatch: (request) async {
            dispatchedMethod = request['method'] as String?;
            return {'ok': true};
          },
        ),
      );
      final argsByCommand = <String, Map<String, dynamic>>{
        '/trigger': {'mode': 'auto'},
        '/getvar': {'scope': 'chat'},
        '/setvar': {'scope': 'chat', 'path': 'x', 'value': 1},
        '/inject': {'id': 'mood', 'content': 'tense'},
        '/toast': {'message': 'hi'},
      };

      for (final command in registry.list()) {
        expect(command.bridgeMethod, isNotNull, reason: command.name);
        expect(
          JsBridgeMethodRegistry.lookup(command.bridgeMethod!),
          isNotNull,
          reason: '${command.name} -> ${command.bridgeMethod}',
        );

        dispatchedMethod = null;
        await registry.run(
          command.name,
          argsByCommand[command.name]!,
          context: const CommandContext(charId: 'c1'),
        );
        expect(dispatchedMethod, command.bridgeMethod, reason: command.name);
      }
    });
  });

  group('/getvar and /setvar route through the bridge', () {
    test('/getvar returns the stored value', () async {
      final registry = buildRegistry();
      // Pre-populate the character variables.
      await characterRepo.put(
        Character(
          id: 'c1',
          name: 'Alice',
          extensions: {
            'glaze_variables': {'flag': true},
          },
        ),
      );
      final result = await registry.run('/getvar', {
        'scope': 'character',
        'path': 'flag',
      }, context: const CommandContext(charId: 'c1'));
      expect(result.ok, isTrue);
      expect(result.data, isTrue);
    });

    test('/getvar returns an error for unsupported scope', () async {
      final registry = buildRegistry();
      final result = await registry.run('/getvar', {
        'scope': 'unknown',
        'path': 'x',
      }, context: const CommandContext(charId: 'c1'));
      expect(result.ok, isFalse);
      expect(result.message, isNotEmpty);
    });

    test(
      '/setvar writes to the requested scope and /getvar reads it back',
      () async {
        final registry = buildRegistry();
        final setResult = await registry.run('/setvar', {
          'scope': 'character',
          'path': 'greeting',
          'value': 'hi',
        }, context: const CommandContext(charId: 'c1'));
        expect(setResult.ok, isTrue);

        final getResult = await registry.run('/getvar', {
          'scope': 'character',
          'path': 'greeting',
        }, context: const CommandContext(charId: 'c1'));
        expect(getResult.ok, isTrue);
        expect(getResult.data, 'hi');
      },
    );
  });

  group('/inject validation', () {
    test('rejects missing id', () async {
      final registry = buildRegistry();
      final result = await registry.run('/inject', {
        'content': 'hi',
      }, context: const CommandContext(charId: 'c1'));
      expect(result.ok, isFalse);
      expect(result.message, contains('id'));
    });

    test('rejects missing content', () async {
      final registry = buildRegistry();
      final result = await registry.run('/inject', {
        'id': 'mood',
      }, context: const CommandContext(charId: 'c1'));
      expect(result.ok, isFalse);
      expect(result.message, contains('content'));
    });

    test('uses session context without requiring charId', () async {
      final registry = buildRegistry();
      final result = await registry.run('/inject', {
        'id': 'mood',
        'content': 'hi',
      }, context: const CommandContext(bridgeContext: {'sessionId': 's1'}));
      expect(result.ok, isTrue);
    });

    test('successful inject echoes the result payload', () async {
      final registry = buildRegistry();
      final result = await registry.run('/inject', {
        'id': 'mood',
        'content': 'tense',
        'depth': 1,
        'role': 'system',
      }, context: const CommandContext(charId: 'c1'));
      expect(result.ok, isTrue);
      expect(result.message, 'inject ok');
      expect(result.data, isA<Map<String, dynamic>>());
      expect((result.data as Map)['id'], 'mood');
      expect((result.data as Map)['depth'], 1);
      expect((result.data as Map)['role'], 'system');
    });
  });

  group('/toast validation', () {
    test('rejects non-string message', () async {
      final registry = buildRegistry();
      final result = await registry.run('/toast', {
        'message': 7,
      }, context: const CommandContext());
      expect(result.ok, isFalse);
      expect(result.message, contains('message'));
    });

    test('successful toast resolves ok', () async {
      final registry = buildRegistry();
      final result = await registry.run('/toast', {
        'message': 'hi',
        'severity': 'success',
        'action': 'open',
      }, context: const CommandContext());
      expect(result.ok, isTrue);
    });
  });

  group('/trigger validation', () {
    test('rejects missing charId in context', () async {
      final registry = buildRegistry();
      final result = await registry.run('/trigger', const {
        'mode': 'auto',
      }, context: const CommandContext());
      expect(result.ok, isFalse);
      expect(result.message, contains('charId'));
    });

    test('rejects non-string mode', () async {
      final registry = buildRegistry();
      final result = await registry.run('/trigger', {
        'mode': 5,
      }, context: const CommandContext(charId: 'c1'));
      expect(result.ok, isFalse);
    });
  });

  group('executeCommand capability delegation', () {
    test('requires execute_command and the command capability', () async {
      final granted = <String>{'execute_command'};
      var toastCalls = 0;
      late final JsBridgeService bridge;
      final registry = buildWiredCommandRegistry(
        WiredCommandDeps(bridgeDispatch: (request) => bridge.dispatch(request)),
      );
      bridge = TestJsBridge.create(
        permissionCheck: granted.contains,
        showToast: (_, _) => toastCalls++,
        executeCommand: (command, args, context) async {
          final result = await registry.run(
            command,
            args,
            context: CommandContext(bridgeContext: context),
          );
          return result.toMap();
        },
      );

      Future<Map<String, dynamic>> executeToast() => bridge.dispatch({
        'method': 'executeCommand',
        'params': {
          'command': '/toast',
          'args': {'message': 'hello'},
        },
      });

      final denied = await executeToast();
      expect(denied['ok'], isTrue);
      expect((denied['result'] as Map)['ok'], isFalse);
      expect((denied['result'] as Map)['message'], contains('show_toast'));
      expect(toastCalls, 0);

      granted.add('show_toast');
      final allowed = await executeToast();
      expect((allowed['result'] as Map)['ok'], isTrue);
      expect(toastCalls, 1);
    });

    test(
      'forwards the complete bridge context to canonical dispatch',
      () async {
        Map<String, dynamic>? request;
        final registry = buildWiredCommandRegistry(
          WiredCommandDeps(
            bridgeDispatch: (value) async {
              request = value;
              return {'ok': true, 'result': true};
            },
          ),
        );
        const bridgeContext = {
          'sessionId': 'session-2',
          'characterId': 'character-2',
          'messageId': 'message-2',
        };

        final result = await registry.run(
          '/getvar',
          const {'scope': 'message', 'path': 'flag'},
          context: const CommandContext(
            charId: 'character-2',
            bridgeContext: bridgeContext,
          ),
        );

        expect(result.ok, isTrue);
        expect(request!['method'], 'getVariables');
        expect(request!['context'], bridgeContext);
      },
    );

    test('requires the dedicated capability for every wired command', () async {
      final granted = <String>{'execute_command'};
      final globalRepo = GlobalVariablesRepo.withPrefsLoader(
        SharedPreferences.getInstance,
      );
      late final JsBridgeService bridge;
      final registry = buildWiredCommandRegistry(
        WiredCommandDeps(bridgeDispatch: (request) => bridge.dispatch(request)),
      );
      bridge = TestJsBridge.create(
        globalVariablesRepo: globalRepo,
        currentSessionId: () => 's1',
        currentCharacterId: () => 'c1',
        permissionCheck: granted.contains,
        triggerGeneration: (_, _) async => {'status': 'started'},
        injectPrompt: (id, _, _, _) => {'id': id},
        showToast: (_, _) {},
        executeCommand: (command, args, context) async {
          final result = await registry.run(
            command,
            args,
            context: CommandContext(
              charId: context['characterId'] as String?,
              bridgeContext: context,
            ),
          );
          return result.toMap();
        },
      );
      final cases = <({String command, Map<String, dynamic> args, String cap})>[
        (
          command: '/trigger',
          args: {'mode': 'auto'},
          cap: 'trigger_generation',
        ),
        (
          command: '/getvar',
          args: {'scope': 'global'},
          cap: 'read_global_vars',
        ),
        (
          command: '/setvar',
          args: {'scope': 'global', 'path': 'x', 'value': 1},
          cap: 'write_global_vars',
        ),
        (
          command: '/inject',
          args: {'id': 'mood', 'content': 'tense'},
          cap: 'inject_prompt',
        ),
        (command: '/toast', args: {'message': 'hi'}, cap: 'show_toast'),
      ];

      for (final testCase in cases) {
        Future<Map<String, dynamic>> execute() => bridge.dispatch({
          'method': 'executeCommand',
          'params': {'command': testCase.command, 'args': testCase.args},
          'context': {'sessionId': 's1', 'characterId': 'c1'},
        });

        final denied = await execute();
        expect(
          (denied['result'] as Map)['message'],
          contains(testCase.cap),
          reason: testCase.command,
        );

        granted.add(testCase.cap);
        final allowed = await execute();
        expect(
          (allowed['result'] as Map)['ok'],
          isTrue,
          reason: testCase.command,
        );
        granted.remove(testCase.cap);
      }
    });

    test('global variables have dedicated and command path parity', () async {
      final globalRepo = GlobalVariablesRepo.withPrefsLoader(
        SharedPreferences.getInstance,
      );
      late final JsBridgeService bridge;
      final registry = buildWiredCommandRegistry(
        WiredCommandDeps(bridgeDispatch: (request) => bridge.dispatch(request)),
      );
      bridge = TestJsBridge.create(
        globalVariablesRepo: globalRepo,
        permissionCheck: (_) => true,
        executeCommand: (command, args, context) async {
          final result = await registry.run(
            command,
            args,
            context: CommandContext(bridgeContext: context),
          );
          return result.toMap();
        },
      );

      await bridge.dispatch({
        'method': 'setVariables',
        'params': {'scope': 'global', 'path': 'fromDedicated', 'value': 1},
      });
      await bridge.dispatch({
        'method': 'executeCommand',
        'params': {
          'command': '/setvar',
          'args': {'scope': 'global', 'path': 'fromCommand', 'value': 2},
        },
      });

      final commandRead = await bridge.dispatch({
        'method': 'executeCommand',
        'params': {
          'command': '/getvar',
          'args': {'scope': 'global'},
        },
      });
      final dedicatedRead = await bridge.dispatch({
        'method': 'getVariables',
        'params': {'scope': 'global'},
      });

      expect((commandRead['result'] as Map)['data'], dedicatedRead['result']);
      expect(dedicatedRead['result'], {'fromDedicated': 1, 'fromCommand': 2});
    });
  });
}
