import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/plugins/models/plugin_manifest.dart';
import 'package:glaze_flutter/features/plugins/providers/plugin_history_provider.dart';

void main() {
  test('a record keeps the permission it was checked against', () {
    final r = PluginRequestRecord.fromJson('a', {
      'permission': 'library.read.personas',
      'allowed': 2,
      'lastAllowed': 5,
    });
    expect(r.permission, 'library.read.personas');
    final back = PluginRequestRecord.fromJson('a', r.toJson());
    expect(back.permission, r.permission);
    expect(back.allowed, 2);
    expect(PluginRequestRecord.fromJson('b', {'denied': 1}).permission, isNull);
  });

  test('permissions fall into the history filter kinds', () {
    expect(
      PluginPermissionCategory.of('library.delete.themes'),
      PluginPermissionCategory.library,
    );
    expect(
      PluginPermissionCategory.of('variables.shared'),
      PluginPermissionCategory.variables,
    );
    expect(
      PluginPermissionCategory.of('chats.read'),
      PluginPermissionCategory.chats,
    );
    expect(
      PluginPermissionCategory.of('network'),
      PluginPermissionCategory.network,
    );
    expect(
      PluginPermissionCategory.of('composer'),
      PluginPermissionCategory.general,
    );
  });
}
