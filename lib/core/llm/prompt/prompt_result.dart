import '../../models/chat_message.dart' show TriggeredEntry;
import '../history_assembler.dart' show PromptMessage;
import '../context_calculator.dart' show TokenBreakdown;

class PromptResult {
  final List<PromptMessage> messages;
  final TokenBreakdown breakdown;
  final Map<String, String> sessionVars;
  final Map<String, String> globalVars;
  final List<TriggeredEntry> triggeredLorebooks;
  final List<TriggeredEntry> triggeredMemories;
  final Map<String, dynamic> memoryCoverage;

  const PromptResult({
    required this.messages,
    required this.breakdown,
    required this.sessionVars,
    required this.globalVars,
    this.triggeredLorebooks = const [],
    this.triggeredMemories = const [],
    this.memoryCoverage = const {},
  });

  Map<String, dynamic> toJson() => {
    'messages': messages.map((m) => m.toJson()).toList(),
    'breakdown': breakdown.toJson(),
    'sessionVars': sessionVars,
    'globalVars': globalVars,
    'triggeredLorebooks': triggeredLorebooks.map((t) => t.toJson()).toList(),
    'triggeredMemories': triggeredMemories.map((t) => t.toJson()).toList(),
    'memoryCoverage': memoryCoverage,
  };

  factory PromptResult.fromJson(Map<String, dynamic> json) => PromptResult(
    messages: (json['messages'] as List)
        .map((m) => PromptMessage.fromJson(m as Map<String, dynamic>))
        .toList(),
    breakdown: TokenBreakdown.fromJson(
      json['breakdown'] as Map<String, dynamic>,
    ),
    sessionVars: Map<String, String>.from(json['sessionVars'] as Map),
    globalVars: Map<String, String>.from(json['globalVars'] as Map),
    triggeredLorebooks: (json['triggeredLorebooks'] as List? ?? [])
        .map((t) => TriggeredEntry.fromJson(t as Map<String, dynamic>))
        .toList(),
    triggeredMemories: (json['triggeredMemories'] as List? ?? [])
        .map((t) => TriggeredEntry.fromJson(t as Map<String, dynamic>))
        .toList(),
    memoryCoverage: Map<String, dynamic>.from(
      json['memoryCoverage'] as Map? ?? {},
    ),
  );
}
