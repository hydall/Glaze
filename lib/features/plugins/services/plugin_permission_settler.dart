import '../models/plugin_manifest.dart';
import 'plugin_store.dart';

/// Record fields that say what a plugin may do. They stay with the device:
/// a backup or another device brings a plugin, not what it was allowed.
const kPluginPermissionFields = {
  'grants',
  'revoked',
  'networkHosts',
  'blockedHosts',
  'localNetwork',
};

/// What this device allowed one plugin before its files were replaced.
class PluginLocalPermissions {
  const PluginLocalPermissions({required this.record, this.manifest});

  final Map<String, dynamic> record;

  /// Null when the installed package did not parse.
  final PluginManifest? manifest;
}

/// Gives plugins that arrived from a backup or another device the
/// permissions of this device.
///
/// A plugin this device already had, from the same author, keeps what it
/// was allowed here, and permissions the arriving version newly asks for
/// start switched off, as after an update. Any other plugin starts like a
/// fresh install: everything off, no internet.
class PluginPermissionSettler {
  PluginPermissionSettler(this.store);

  final PluginStore store;

  /// What every installed plugin is allowed now, to call before its files
  /// are replaced.
  Future<Map<String, PluginLocalPermissions>> capture() async {
    final out = <String, PluginLocalPermissions>{};
    for (final record in await store.readRecords()) {
      final id = record['id'] as String;
      PluginManifest? manifest;
      try {
        manifest = await store.readManifest(store.packageDir(id));
      } catch (_) {}
      out[id] = PluginLocalPermissions(record: record, manifest: manifest);
    }
    return out;
  }

  /// [record] with its permission fields settled against [before]; null when
  /// its package is missing or does not parse.
  Future<Map<String, Object?>?> settle(
    Map<String, dynamic> record,
    Map<String, PluginLocalPermissions> before,
  ) async {
    final id = record['id'];
    if (id is! String) return null;
    final PluginManifest manifest;
    try {
      manifest = await store.readManifest(store.packageDir(id));
    } catch (_) {
      return null;
    }
    final out = <String, Object?>{
      for (final e in record.entries)
        if (!kPluginPermissionFields.contains(e.key)) e.key: e.value,
    };
    final local = before[id];
    if (local == null || !isSamePluginAuthor(local.manifest, manifest)) {
      out
        ..['grants'] = const <String>[]
        ..['revoked'] = manifest.permissions.toList()
        ..['networkHosts'] = const <String>[]
        ..['blockedHosts'] = const <String>[]
        ..['localNetwork'] = false;
      return out;
    }
    final had = local.manifest!.permissions;
    final added = manifest.permissions.where((x) => !had.contains(x));
    final old = local.record;
    final oldRevoked = old['revoked'];
    final networkAdded = added.contains(PluginPermission.network);
    out
      ..['grants'] = old['grants'] ?? const <String>[]
      ..['revoked'] = {
        if (oldRevoked is List) ...oldRevoked.map((x) => '$x'),
        ...added,
      }.toList()
      ..['networkHosts'] = networkAdded ? const <String>[] : old['networkHosts']
      ..['blockedHosts'] = networkAdded
          ? const <String>[]
          : old['blockedHosts'] ?? const <String>[]
      ..['localNetwork'] = !networkAdded && old['localNetwork'] == true;
    return out;
  }

  /// Settles every record in the registry against [before] and drops those
  /// whose package is gone.
  Future<void> settleRegistry(Map<String, PluginLocalPermissions> before) =>
      writeSettled(store.readRecords(), before);

  /// Writes [records] as the registry, settled against [before].
  Future<void> writeSettled(
    Future<List<Map<String, dynamic>>> records,
    Map<String, PluginLocalPermissions> before,
  ) async {
    final out = <Map<String, Object?>>[];
    final seen = <String>{};
    for (final record in await records) {
      final settled = await settle(record, before);
      if (settled == null || !seen.add(settled['id'] as String)) continue;
      out.add(settled);
    }
    await store.writeRecords(out);
  }
}
