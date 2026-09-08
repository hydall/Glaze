import 'dart:convert';

import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../../core/models/preset.dart';
import 'chat_bridge_controller.dart';

/// Outgoing identity / persona / layout commands. The host stores
/// the active character + persona + avatar URLs + layout; this group
/// pushes them to the WebView so already-rendered messages refresh
/// their user name / avatar when the active persona resolves late.
class IdentityBridgeCommands {
  final ChatBridgeController _host;

  IdentityBridgeCommands(this._host);

  Future<void> setIdentity({
    String? charName,
    String? charColor,
    String? personaName,
    String? layout,
    String? charAvatarPath,
    String? personaAvatarPath,
    int? greetingTotal,
  }) async {
    _host.currentCharName = charName;
    _host.currentCharColor = charColor;
    _host.currentPersonaName = personaName;
    _host.currentChatLayout = layout;
    if (greetingTotal != null) _host.currentGreetingTotal = greetingTotal;
    _host.setAvatarUrl(charAvatarPath, isChar: true);
    _host.setAvatarUrl(personaAvatarPath, isChar: false);
    final payload = jsonEncode({
      'charName': _host.currentCharName,
      'personaName': _host.currentPersonaName,
      'charAvatarUrl': _host.charAvatarUrl,
      'personaAvatarUrl': _host.personaAvatarUrl,
    });
    await _host.evalJs('window.bridge?.setIdentity($payload)');
  }

  Future<void> applyLayout(String layout) {
    final normalized = _host.normalizeLayout(layout);
    _host.currentChatLayout = normalized;
    return _host.evalJs(
      'window.bridge?.applyLayout?.("${_host.escape(normalized)}")',
    );
  }

  void setRegexContext(
    List<PresetRegex> regexes,
    Character? char,
    Persona? persona,
  ) {
    _host.setRegexContext(regexes, char, persona);
  }
}
