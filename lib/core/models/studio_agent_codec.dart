import 'dart:convert';

import '../llm/studio_controller_ontology.dart';
import 'studio_config.dart';

/// Compatibility boundary for legacy persisted Studio agents.
abstract final class StudioAgentCodec {
  static final Set<String> _controllerIds = {
    for (final spec in StudioControllerOntology.specs) spec.id,
  };

  static List<StudioAgent> decodeAgentsJson(String source) {
    final canonical = canonicalizeAgentsJson(source);
    final decoded = jsonDecode(canonical) as List<dynamic>;
    return [
      for (final value in decoded)
        StudioAgent.fromJson(Map<String, dynamic>.from(value as Map)),
    ];
  }

  static StudioConfig decodeConfig(Map<String, dynamic> source) {
    final agents = source['agents'];
    final canonical = Map<String, dynamic>.from(source);
    if (agents is List) {
      canonical['agents'] = jsonDecode(
        canonicalizeAgentsJson(jsonEncode(agents)),
      );
    }
    _migrateRunApiConfigId(canonical);
    return StudioConfig.fromJson(canonical);
  }

  /// Moves the pre-3-slot API selection into each still-empty explicit slot.
  static Map<String, dynamic> canonicalizeConfigRow(
    Map<String, dynamic> source,
  ) {
    final canonical = Map<String, dynamic>.from(source);
    _migrateRunApiConfigId(canonical, snakeCase: true);
    canonical
      ..remove('final_preset_id')
      ..remove('run_api_config_id')
      ..remove('run_model_override');
    return canonical;
  }

  static void _migrateRunApiConfigId(
    Map<String, dynamic> target, {
    bool snakeCase = false,
  }) {
    String key(String camel, String snake) => snakeCase ? snake : camel;
    final legacyKey = key('runApiConfigId', 'run_api_config_id');
    final legacy = target[legacyKey];
    if (legacy is String && legacy.isNotEmpty) {
      for (final slot in [
        key('expensiveApiConfigId', 'expensive_api_config_id'),
        key('cheapApiConfigId', 'cheap_api_config_id'),
        key('cleanerApiConfigId', 'cleaner_api_config_id'),
      ]) {
        final current = target[slot];
        if (current is! String || current.isEmpty) target[slot] = legacy;
      }
    }
    target
      ..remove(key('finalPresetId', 'final_preset_id'))
      ..remove(legacyKey)
      ..remove(key('runModelOverride', 'run_model_override'));
  }

  /// Canonicalizes once without discarding fields unknown to this app version.
  static String canonicalizeAgentsJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! List) {
      throw const FormatException('Studio agents JSON must be a list.');
    }
    final agents = <Map<String, dynamic>>[
      for (final value in decoded)
        if (value is Map)
          Map<String, dynamic>.from(value)
        else
          throw const FormatException('Studio agent must be an object.'),
    ];
    final deterministicOrderFallback = _hasDeterministicCanonicalOrder(agents);
    final resolutions = [
      for (final agent in agents)
        _resolveControllerId(
          agent,
          allowOrderFallback: deterministicOrderFallback,
        ),
    ];
    final accepted = List<String?>.filled(agents.length, null);
    for (final controllerId in _controllerIds) {
      final candidates = resolutions.indexed
          .where((entry) => entry.$2?.controllerId == controllerId)
          .toList();
      if (candidates.isEmpty) continue;
      final bestPriority = candidates
          .map((entry) => entry.$2!.priority)
          .reduce((a, b) => a < b ? a : b);
      final winners = candidates
          .where((entry) => entry.$2!.priority == bestPriority)
          .toList();
      if (winners.length == 1) {
        accepted[winners.single.$1] = controllerId;
      }
    }

    return jsonEncode([
      for (var index = 0; index < agents.length; index++)
        _canonicalAgent(agents[index], accepted[index]),
    ]);
  }

  static Map<String, dynamic> _canonicalAgent(
    Map<String, dynamic> agent,
    String? controllerId,
  ) {
    final canonical = Map<String, dynamic>.from(agent)
      ..remove('sourceBlockNames');
    if (controllerId == null) {
      canonical['controllerId'] = '';
      canonical['enabled'] = false;
    } else {
      canonical['controllerId'] = controllerId;
    }
    return canonical;
  }

  static String encodeAgents(List<StudioAgent> agents) =>
      jsonEncode([for (final agent in agents) agent.toJson()]);

  static _ControllerResolution? _resolveControllerId(
    Map<String, dynamic> agent, {
    required bool allowOrderFallback,
  }) {
    final existing = agent['controllerId'];
    if (existing is String && _controllerIds.contains(existing)) {
      return _ControllerResolution(existing, 0);
    }

    final id = agent['id'];
    if (id is String) {
      if (_controllerIds.contains(id)) return _ControllerResolution(id, 1);
      for (final spec in StudioControllerOntology.specs) {
        if (RegExp(
          '^agent_.+_${RegExp.escape(spec.id)}_[0-9]+\$',
        ).hasMatch(id)) {
          return _ControllerResolution(spec.id, 2);
        }
      }
    }

    final name = agent['name'];
    if (name is String) {
      final matches = StudioControllerOntology.specs.where(
        (spec) => spec.name == name,
      );
      if (matches.length == 1) {
        return _ControllerResolution(matches.single.id, 3);
      }
    }

    if (allowOrderFallback) {
      final order = agent['order'];
      if (order is num) {
        return _ControllerResolution(
          StudioControllerOntology.specs[order.toInt()].id,
          4,
        );
      }
    }
    return null;
  }

  static bool _hasDeterministicCanonicalOrder(
    List<Map<String, dynamic>> agents,
  ) {
    if (agents.length != StudioControllerOntology.specs.length) return false;
    final orders = agents.map((agent) => agent['order']).toList();
    if (orders.any((order) => order is! num)) return false;
    final normalized = orders.cast<num>().map((order) => order.toInt()).toSet();
    return normalized.length == StudioControllerOntology.specs.length &&
        normalized.every(
          (order) =>
              order >= 0 && order < StudioControllerOntology.specs.length,
        );
  }
}

final class _ControllerResolution {
  final String controllerId;
  final int priority;

  const _ControllerResolution(this.controllerId, this.priority);
}
