import 'dart:convert';

import '../../models/character.dart';
import '../../models/chat_message.dart';
import '../../models/persona.dart';
import '../shared/message_range_formatter.dart';

class AuditResult {
  final List<String>? issues;
  final Map<String, dynamic>? beauty;

  const AuditResult({this.issues, this.beauty});

  bool get ok => issues != null;
}

/// Builds the POST-cleaner character/world auditor prompt and parses its JSON
/// response.
///
/// The auditor is a diagnostic sidecar pass that checks the assistant response
/// against the full generation context and returns a compact JSON list of
/// contradictions. It does NOT rewrite text — the cleaner does that separately
/// using the audit issues as fix instructions.
///
/// When [auditBlockContent] is provided (from the `cleaner_audit` preset
/// block), it replaces the hardcoded instructions section. This lets the user
/// iterate on audit + Beauty Shard instructions via the preset without
/// rebuilding the app.
class AuditPromptBuilder {
  /// Builds the auditor prompt. The auditor checks the assistant response
  /// against all provided context and returns a compact JSON list of
  /// contradictions.
  ///
  /// When [auditBlockContent] is non-empty, it is placed after the context
  /// sections and before the assistant response, replacing the hardcoded
  /// "You are a continuity auditor..." preamble and "Instructions:" section.
  static String buildAuditPrompt({
    required String assistantText,
    required Character character,
    Persona? persona,
    String? lorebooksContent,
    String? memoryContent,
    String? summaryContent,
    String? arcContent,
    String? entitiesContent,
    List<ChatMessage> recentMessages = const [],
    int maxCharsPerMessage = kDefaultMaxMessageChars,
    String? beautyState,
    String auditBlockContent = '',
  }) {
    final buffer = StringBuffer();

    // Preset-driven instructions (may contain Beauty Shard + audit rules).
    if (auditBlockContent.trim().isNotEmpty) {
      buffer.writeln(auditBlockContent.trim());
      buffer.writeln();
    } else {
      buffer
        ..writeln(
          'You are a continuity auditor for a roleplay story. Your job is to '
          'find contradictions between the assistant response and the provided '
          'context.',
        )
        ..writeln();
    }

    // Current beauty state (for Beauty Shard instructions in the preset block).
    if (beautyState != null && beautyState.trim().isNotEmpty) {
      buffer
        ..writeln('CURRENT BEAUTY STATE:')
        ..writeln(beautyState)
        ..writeln();
    }

    // Character profile.
    buffer.writeln('CHARACTER PROFILE:');
    buffer.writeln('Name: ${character.name}');
    final desc = character.description?.trim() ?? '';
    if (desc.isNotEmpty) buffer.writeln('Description: $desc');
    final pers = character.personality?.trim() ?? '';
    if (pers.isNotEmpty) buffer.writeln('Personality: $pers');
    final scen = character.scenario?.trim() ?? '';
    if (scen.isNotEmpty) buffer.writeln('Scenario: $scen');
    final phi = character.postHistoryInstructions?.trim() ?? '';
    if (phi.isNotEmpty) buffer.writeln('Post-history instructions: $phi');
    buffer.writeln();

    // User persona.
    if (persona != null) {
      buffer.writeln('USER PERSONA:');
      buffer.writeln('Name: ${persona.name}');
      final pp = persona.prompt?.trim() ?? '';
      if (pp.isNotEmpty) buffer.writeln('Description: $pp');
      buffer.writeln();
    }

    // Lorebooks / world context.
    final lore = lorebooksContent?.trim() ?? '';
    if (lore.isNotEmpty) {
      buffer
        ..writeln('INJECTED WORLD/LORE CONTEXT:')
        ..writeln(lore)
        ..writeln();
    }

    // Memory context.
    final mem = memoryContent?.trim() ?? '';
    if (mem.isNotEmpty) {
      buffer
        ..writeln('INJECTED MEMORY CONTEXT:')
        ..writeln(mem)
        ..writeln();
    }

    // Summary.
    final sum = summaryContent?.trim() ?? '';
    if (sum.isNotEmpty) {
      buffer
        ..writeln('SUMMARY:')
        ..writeln(sum)
        ..writeln();
    }

    // Arcs.
    final arcs = arcContent?.trim() ?? '';
    if (arcs.isNotEmpty) {
      buffer
        ..writeln('ARCS:')
        ..writeln(arcs)
        ..writeln();
    }

    // Entities.
    final ents = entitiesContent?.trim() ?? '';
    if (ents.isNotEmpty) {
      buffer
        ..writeln('ENTITIES:')
        ..writeln(ents)
        ..writeln();
    }

    // Recent chat history.
    if (recentMessages.isNotEmpty) {
      final history = formatRecentMessages(recentMessages, maxCharsPerMessage);
      if (history.isNotEmpty) {
        buffer
          ..writeln('RECENT CHAT HISTORY:')
          ..writeln(history)
          ..writeln();
      }
    }

    buffer
      ..writeln('ASSISTANT RESPONSE TO AUDIT:')
      ..writeln(assistantText)
      ..writeln();

    // Response format instructions.
    if (auditBlockContent.trim().isEmpty) {
      buffer
        ..writeln('Instructions:')
        ..writeln('- Check the response against ALL provided context.')
        ..writeln(
          '- Report ONLY direct contradictions: wrong names, wrong '
          'relationships, wrong locations, personality conflicts, world-fact '
          'errors, persona identity errors.',
        )
        ..writeln('- Do NOT report style issues, cliches, or prose quality.')
        ..writeln(
          '- Do NOT suggest fixes or rewrites. Only describe the contradiction.',
        )
        ..writeln('- If no contradictions found, return: {"ok": true}')
        ..writeln(
          '- If contradictions found, return: {"ok": false, "issues": ["...", "..."]}',
        )
        ..writeln()
        ..writeln('Return ONLY the JSON, no other text.');
    } else {
      buffer
        ..writeln(
          'Return ONLY JSON in this format: {"ok": true|false, "issues": ["..."], "beauty": {"speakers": {"Name": "#hex"}, "thoughts": {"Name": "#hex"}}}',
        )
        ..writeln('The "beauty" field is optional but recommended when speaker colors are assigned.');
    }

    return buffer.toString();
  }

  /// Parses the auditor JSON response.
  ///
  /// - `{"ok": true}` → `AuditResult(issues: [])`
  /// - `{"ok": false, "issues": [...]}` → `AuditResult(issues: [...])`
  /// - with `beauty` field → `AuditResult(issues: [...], beauty: {...})`
  /// - malformed / unparseable → `AuditResult(issues: null)` (skip audit)
  static AuditResult parseAuditResult(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return const AuditResult(issues: null);

    // Some models wrap JSON in ``` fences or prose. Extract the first
    // balanced `{...}` block.
    final start = text.indexOf('{');
    if (start < 0) return const AuditResult(issues: null);
    final end = text.lastIndexOf('}');
    if (end <= start) return const AuditResult(issues: null);
    text = text.substring(start, end + 1);

    try {
      final parsed = jsonDecode(text);
      if (parsed is! Map<String, dynamic>) {
        return const AuditResult(issues: null);
      }
      final ok = parsed['ok'];
      final beautyRaw = parsed['beauty'];
      final beauty = beautyRaw is Map<String, dynamic>
          ? Map<String, dynamic>.from(beautyRaw)
          : null;
      if (ok == true) return AuditResult(issues: const [], beauty: beauty);
      if (ok == false) {
        final issues = parsed['issues'];
        if (issues is List) {
          return AuditResult(
            issues: issues
                .whereType<String>()
                .where((s) => s.trim().isNotEmpty)
                .toList(),
            beauty: beauty,
          );
        }
        return AuditResult(issues: null, beauty: beauty);
      }
      return const AuditResult(issues: null);
    } catch (_) {
      return const AuditResult(issues: null);
    }
  }

  /// Backward-compat: returns only issues list (beauty is ignored).
  static List<String>? parseAuditJson(String raw) {
    return parseAuditResult(raw).issues;
  }
}
