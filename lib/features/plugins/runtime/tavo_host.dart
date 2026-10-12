import '../../../core/models/character.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/persona.dart';
import '../../chat/composer_text_bridge.dart';
import 'tavo_file_store.dart';
import 'tavo_variable_store.dart';

/// One selectable option for `tavo.utils.select` / `ask`.
typedef TavoOption = ({String value, String label, String? description});

/// Everything `tavo.*` needs from the app, for one open chat. Implemented by
/// the plugin runtime with Riverpod; the dispatcher stays free of it.
abstract interface class TavoHost {
  String get charId;
  String? get sessionId;

  ChatSession? currentSession();
  Character? currentCharacter();
  Future<List<Character>> characters();
  Persona? currentPersona();
  Future<List<Persona>> personas();

  ComposerTextAccess? composer();

  void toast(String text);
  Future<void> openUrl(String url);
  Future<String?> select(
    List<TavoOption> options, {
    String? title,
    String? defaultValue,
  });
  Future<Map<String, Object?>> ask({
    required String question,
    required List<TavoOption> options,
    required bool allowOther,
    String? placeholder,
    String? defaultValue,
  });

  Future<String> generate(String prompt, Map<String, dynamic> options);

  TavoVariableStore get variables;
  TavoFileStore files(String pluginId);

  /// Called after a variable write so every frame's sync cache follows.
  void variablesChanged(String scope, Map<String, dynamic> root);
}

/// Tavo's message object. Glaze ids are strings; plugins treat them as
/// opaque handles.
Map<String, Object?> tavoMessageJson(
  ChatMessage m, {
  required int index,
  required String charId,
}) => {
  'id': m.id,
  'index': index,
  'role': m.role,
  'content': m.content,
  'hidden': m.isHidden,
  if (m.role == 'assistant') 'characterId': charId,
  if (m.reasoning != null && m.reasoning!.isNotEmpty) 'reasoning': m.reasoning,
  if (m.timestamp != null) 'timestamp': m.timestamp,
};

Map<String, Object?> tavoCharacterJson(Character c) => {
  'id': c.id,
  'name': c.displayName?.isNotEmpty == true ? c.displayName : c.name,
  'description': c.description ?? '',
  'personality': c.personality ?? '',
  'scenario': c.scenario ?? '',
  'firstMes': c.firstMes ?? '',
  'mesExample': c.mesExample ?? '',
  'creatorNotes': c.creatorNotes ?? '',
  'systemPrompt': c.systemPrompt ?? '',
  'postHistoryInstructions': c.postHistoryInstructions ?? '',
  'alternateGreetings': c.alternateGreetings,
  'tags': c.tags,
  'creator': c.creator ?? '',
  'characterVersion': c.characterVersion,
  'nickname': c.macroName,
};

Map<String, Object?> tavoPersonaJson(Persona p, {required bool active}) => {
  'id': p.id,
  'name': p.displayName?.isNotEmpty == true ? p.displayName : p.name,
  'description': p.prompt ?? '',
  'active': active,
};
