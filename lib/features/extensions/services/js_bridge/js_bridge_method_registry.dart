import 'dart:collection';

import 'capability_resolver.dart';

typedef JsBridgeCapabilityResolver =
    String Function(Map<String, dynamic> params);

/// The Chat WebView is the only bridge host. Sandboxed panels relay through it.
/// `visual` is retained as the public name to avoid a needless API migration.
enum JsBridgeHostProfile { visual }

enum JsBridgeOperation {
  showToast,
  getVariables,
  setVariables,
  deleteVariable,
  executeCommand,
  triggerGeneration,
  playAudio,
  injectPrompt,
  uninjectPrompt,
  generateText,
}

class JsBridgeMethodDefinition {
  const JsBridgeMethodDefinition({
    required this.name,
    required this.operation,
    required this.capabilityResolver,
    required this.hosts,
  });

  final String name;
  final JsBridgeOperation operation;
  final JsBridgeCapabilityResolver capabilityResolver;
  final Set<JsBridgeHostProfile> hosts;

  String capabilityFor(Map<String, dynamic> params) =>
      capabilityResolver(params);
}

/// Canonical public `window.glaze` method contract.
///
/// Dispatch, host contract checks, and parity tests all consume this registry.
/// A method cannot be registered without a capability resolver or an explicit
/// host set.
abstract final class JsBridgeMethodRegistry {
  static const _allHosts = {JsBridgeHostProfile.visual};

  static final List<JsBridgeMethodDefinition> methods = List.unmodifiable([
    JsBridgeMethodDefinition(
      name: 'showToast',
      operation: JsBridgeOperation.showToast,
      capabilityResolver: _showToastCapability,
      hosts: _allHosts,
    ),
    JsBridgeMethodDefinition(
      name: 'getVariables',
      operation: JsBridgeOperation.getVariables,
      capabilityResolver: _readVariablesCapability,
      hosts: _allHosts,
    ),
    JsBridgeMethodDefinition(
      name: 'setVariables',
      operation: JsBridgeOperation.setVariables,
      capabilityResolver: _writeVariablesCapability,
      hosts: _allHosts,
    ),
    JsBridgeMethodDefinition(
      name: 'deleteVariable',
      operation: JsBridgeOperation.deleteVariable,
      capabilityResolver: _deleteVariableCapability,
      hosts: _allHosts,
    ),
    JsBridgeMethodDefinition(
      name: 'executeCommand',
      operation: JsBridgeOperation.executeCommand,
      capabilityResolver: _executeCommandCapability,
      hosts: _allHosts,
    ),
    JsBridgeMethodDefinition(
      name: 'triggerGeneration',
      operation: JsBridgeOperation.triggerGeneration,
      capabilityResolver: _triggerGenerationCapability,
      hosts: _allHosts,
    ),
    JsBridgeMethodDefinition(
      name: 'playAudio',
      operation: JsBridgeOperation.playAudio,
      capabilityResolver: _playAudioCapability,
      hosts: _allHosts,
    ),
    JsBridgeMethodDefinition(
      name: 'injectPrompt',
      operation: JsBridgeOperation.injectPrompt,
      capabilityResolver: _injectPromptCapability,
      hosts: _allHosts,
    ),
    JsBridgeMethodDefinition(
      name: 'uninjectPrompt',
      operation: JsBridgeOperation.uninjectPrompt,
      capabilityResolver: _uninjectPromptCapability,
      hosts: _allHosts,
    ),
    JsBridgeMethodDefinition(
      name: 'generateText',
      operation: JsBridgeOperation.generateText,
      capabilityResolver: _generateTextCapability,
      hosts: _allHosts,
    ),
  ]);

  static final Map<String, JsBridgeMethodDefinition> _byName =
      UnmodifiableMapView({for (final method in methods) method.name: method});

  static JsBridgeMethodDefinition? lookup(String name) => _byName[name];

  static Set<String> methodsFor(JsBridgeHostProfile host) => Set.unmodifiable(
    methods.where((method) => method.hosts.contains(host)).map((e) => e.name),
  );
}

String _scope(Map<String, dynamic> params) {
  final scope = (params['scope'] as String? ?? 'chat').trim().toLowerCase();
  return scope.isEmpty ? 'chat' : scope;
}

String _readVariablesCapability(Map<String, dynamic> params) =>
    readCapabilityForScope(_scope(params));

String _writeVariablesCapability(Map<String, dynamic> params) =>
    writeCapabilityForScope(_scope(params));

String _deleteVariableCapability(Map<String, dynamic> params) =>
    deleteCapabilityForScope(_scope(params));

String _showToastCapability(Map<String, dynamic> _) => 'show_toast';
String _executeCommandCapability(Map<String, dynamic> _) => 'execute_command';
String _triggerGenerationCapability(Map<String, dynamic> _) =>
    'trigger_generation';
String _playAudioCapability(Map<String, dynamic> _) => 'play_audio';
String _injectPromptCapability(Map<String, dynamic> _) => 'inject_prompt';
String _uninjectPromptCapability(Map<String, dynamic> _) => 'uninject_prompt';
String _generateTextCapability(Map<String, dynamic> _) => 'generate_text';
