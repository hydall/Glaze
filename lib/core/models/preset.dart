import 'package:freezed_annotation/freezed_annotation.dart';

part 'preset.freezed.dart';
part 'preset.g.dart';

@freezed
abstract class PresetBlock with _$PresetBlock {
  const factory PresetBlock({
    required String id,
    required String name,
    required String role,
    required String content,
    @Default(true) bool enabled,
    @Default(false) bool isStatic,
    @Default('relative') String insertionMode,
    int? depth,
    String? prefix,
    @Default(false) bool isStashed,
    /// When true, this block's content is appended (after macro expansion) to
    /// the last user-role message in the chat history at prompt-assembly time.
    /// The block's own `role` is ignored in this mode — content is always
    /// merged into the last user message. If no user message exists in
    /// history, the block is silently dropped. See docs/INVARIANTS.md.
    @Default(false) bool appendToLastMessage,
  }) = _PresetBlock;

  factory PresetBlock.fromJson(Map<String, dynamic> json) =>
      _$PresetBlockFromJson(_normalizeBlock(json));
}

@freezed
abstract class PresetRegex with _$PresetRegex {
  const factory PresetRegex({
    required String id,
    required String name,
    required String regex,
    @Default('') String replacement,
    @Default('') String trimOut,
    @Default([1, 2]) List<int> placement,
    @Default([1, 2]) List<int> ephemerality,
    @Default(false) bool disabled,
    @Default('0') String macroRules,
    int? minDepth,
    int? maxDepth,
    @Default(false) bool markdownOnly,
    @Default(false) bool promptOnly,
    @Default(false) bool runOnEdit,
    @Default(0) int substituteRegex,
  }) = _PresetRegex;

  factory PresetRegex.fromJson(Map<String, dynamic> json) =>
      _$PresetRegexFromJson(_normalizeRegex(json));
}

@freezed
abstract class Preset with _$Preset {
  const factory Preset({
    required String id,
    required String name,
    String? author,
    @Default([]) List<PresetBlock> blocks,
    @Default([]) List<PresetRegex> regexes,
    @Default(false) bool reasoningEnabled,
    String? reasoningStart,
    String? reasoningEnd,
    String? guidedGenerationPrompt,
    String? guidedImpersonationPrompt,
    String? impersonationPrompt,
    String? summaryPrompt,
    @Default(false) bool mergePrompts,
    @Default('system') String mergeRole,
    @Default(0) int createdAt,
  }) = _Preset;

  factory Preset.fromJson(Map<String, dynamic> json) =>
      _$PresetFromJson(_normalizePreset(json));
}

/// Canonical ids that always represent system (non-editable) blocks.
const _staticBlockIds = <String>{
  'worldInfoBefore',
  'worldInfoAfter',
  'char_card',
  'char_personality',
  'user_persona',
  'scenario',
  'example_dialogue',
  'chat_history',
  'summary',
  'authors_note',
  'guided_generation',
  'memory',
};

Map<String, dynamic> _normalizeBlock(Map<String, dynamic> json) {
  final n = Map<String, dynamic>.from(json);
  n['enabled'] = _coerceBool(n['enabled'], true);
  // Auto-promote known system block ids to isStatic=true so existing presets
  // created before this field was introduced are handled correctly.
  final id = n['id'] as String?;
  final alreadyStatic = _coerceBool(n['isStatic'], false);
  n['isStatic'] = alreadyStatic || (id != null && _staticBlockIds.contains(id));
  n['isStashed'] = _coerceBool(n['isStashed'], false);
  n['appendToLastMessage'] = _coerceBool(n['appendToLastMessage'], false);
  n['depth'] = _coerceInt(n['depth']);
  // Bring the guided-generation wrapper to parity with hydall/Glaze. Presets
  // still carrying the legacy '[System Note: {{guidance}}]' default (i.e.
  // never customized) are upgraded to the Glaze wording so guided
  // generation/swipe reads identically. Customized content is left untouched.
  if (id == 'guided_generation' &&
      (n['content'] as String?) == '[System Note: {{guidance}}]') {
    n['content'] =
        '[Generate your next reply according to these instructions: {{guidance}}]';
  }
  return n;
}

Map<String, dynamic> _normalizeRegex(Map<String, dynamic> json) {
  final n = Map<String, dynamic>.from(json);

  // ST key mappings → canonical Glaze keys (defensive for direct fromJson calls)
  if (!n.containsKey('name') || (n['name'] is String && (n['name'] as String).isEmpty)) {
    final stName = n['scriptName'];
    if (stName is String && stName.isNotEmpty) n['name'] = stName;
  }
  if (!n.containsKey('regex') || (n['regex'] is String && (n['regex'] as String).isEmpty)) {
    final stRegex = n['findRegex'];
    if (stRegex is String && stRegex.isNotEmpty) n['regex'] = stRegex;
  }
  if (!n.containsKey('replacement') || (n['replacement'] is String && (n['replacement'] as String).isEmpty)) {
    final stRepl = n['replaceString'];
    if (stRepl is String) n['replacement'] = stRepl;
  }
  if (!n.containsKey('trimOut') || (n['trimOut'] is String && (n['trimOut'] as String).isEmpty)) {
    n['trimOut'] = _joinTrimForNormalize(n['trimStrings']);
  }

  n['disabled'] = _coerceBool(n['disabled'], false);
  n['minDepth'] = _coerceInt(n['minDepth']);
  n['maxDepth'] = _coerceInt(n['maxDepth']);
  n['macroRules'] = _coerceString(n['macroRules'], '0');
  n['markdownOnly'] = _coerceBool(n['markdownOnly'], false);
  n['promptOnly'] = _coerceBool(n['promptOnly'], false);
  n['runOnEdit'] = _coerceBool(n['runOnEdit'], false);
  n['substituteRegex'] = _coerceInt(n['substituteRegex']) ?? 0;
  if (n['placement'] is List) {
    n['placement'] = _migrateGlazePlacementIds(
      (n['placement'] as List).map((e) => e is int ? e : int.tryParse(e.toString()) ?? 1).toList(),
    );
  }
  return n;
}

/// Maps legacy Glaze WI placement (4) to SillyTavern World Info (5).
/// Does not remap 5→6 so ST-imported WI scripts (placement 5) stay valid.
List<int> _migrateGlazePlacementIds(List<int> placement) {
  return placement.map((p) => p == 4 ? 5 : p).toList();
}

String _joinTrimForNormalize(dynamic trim) {
  if (trim is List) {
    return trim.whereType<String>().join('\n');
  }
  if (trim is String) return trim;
  return '';
}

Map<String, dynamic> _normalizePreset(Map<String, dynamic> json) {
  final n = Map<String, dynamic>.from(json);
  n['reasoningEnabled'] = _coerceBool(n['reasoningEnabled'], false);
  n['mergePrompts'] = _coerceBool(n['mergePrompts'], false);
  n['createdAt'] = _coerceInt(n['createdAt']) ?? 0;
  return n;
}

int? _coerceInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

bool _coerceBool(dynamic v, bool fallback) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  return fallback;
}

String _coerceString(dynamic v, String fallback) {
  if (v is String) return v;
  return fallback;
}

/// Per-character and per-chat preset bindings.
///
/// Shape mirrors [PersonaConnections]:
///   `character`: charId → presetId  (one preset per character)
///   `chat`:      sessionId → presetId  (one preset per chat session)
@freezed
abstract class PresetConnections with _$PresetConnections {
  const factory PresetConnections({
    @Default({}) Map<String, String> character,
    @Default({}) Map<String, String> chat,
  }) = _PresetConnections;

  factory PresetConnections.fromJson(Map<String, dynamic> json) =>
      _$PresetConnectionsFromJson(json);
}
