import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/bridge/chat_bridge_controller.dart';
import 'package:glaze_flutter/features/extensions/models/preset_permissions.dart';
import 'package:glaze_flutter/features/extensions/services/js_bridge_service.dart';
import 'helpers/js_bridge_test_support.dart';

void main() {
  group('JsBridgeMethodRegistry', () {
    test('every method has a unique operation and canonical capability', () {
      final capabilityIds = GlazeCapability.values.map((e) => e.id).toSet();
      final names = <String>{};
      final operations = <JsBridgeOperation>{};

      for (final method in JsBridgeMethodRegistry.methods) {
        expect(names.add(method.name), isTrue, reason: method.name);
        expect(operations.add(method.operation), isTrue, reason: method.name);
        expect(
          capabilityIds,
          contains(method.capabilityFor(const {})),
          reason: method.name,
        );
        expect(method.hosts, isNotEmpty, reason: method.name);
      }

      expect(
        () => JsBridgeMethodRegistry.methods.clear(),
        throwsUnsupportedError,
      );
    });

    test('variable methods resolve every scope-specific capability', () {
      const expected = {
        'getVariables': {
          'chat': 'read_chat_vars',
          'character': 'read_character_vars',
          'global': 'read_global_vars',
          'message': 'read_message_vars',
        },
        'setVariables': {
          'chat': 'write_chat_vars',
          'character': 'write_character_vars',
          'global': 'write_global_vars',
          'message': 'write_message_vars',
        },
        'deleteVariable': {
          'chat': 'delete_chat_vars',
          'character': 'delete_character_vars',
          'global': 'delete_global_vars',
          'message': 'delete_message_vars',
        },
      };

      for (final methodEntry in expected.entries) {
        final method = JsBridgeMethodRegistry.lookup(methodEntry.key)!;
        for (final scopeEntry in methodEntry.value.entries) {
          expect(
            method.capabilityFor({'scope': scopeEntry.key}),
            scopeEntry.value,
          );
        }
      }
    });

    test('only the Chat WebView profile exposes the bridge contract', () {
      final canonical = JsBridgeMethodRegistry.methods
          .map((e) => e.name)
          .toSet();

      expect(ChatBridgeController.supportedExtensionMethods, canonical);
      expect(JsBridgeHostProfile.values, [JsBridgeHostProfile.visual]);
    });

    test(
      'unknown methods remain unsupported without a permission lookup',
      () async {
        var permissionChecks = 0;
        final response = await TestJsBridge.create(
          permissionCheck: (_) {
            permissionChecks++;
            return true;
          },
        ).dispatch(const {'method': 'notRegistered'});

        expect(response['ok'], isFalse);
        expect(response['error']['code'], 'unsupported_method');
        expect(permissionChecks, 0);
      },
    );
  });
}
