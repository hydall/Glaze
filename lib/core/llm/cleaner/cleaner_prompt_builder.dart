import '../../models/chat_message.dart';
import '../shared/message_range_formatter.dart';

/// Builds the POST-cleaner prompt.
///
/// When [broadcastBlocks] are supplied the user's own language + prose-quality
/// rules (captured verbatim at Studio build time) are injected and take
/// precedence over the built-in defaults, so the rewrite respects the
/// preset's language and anti-cliché/anti-slop rules instead of a hardcoded
/// English-only list. When [recentMessages] are supplied, the cleaner performs
/// a conservative local continuity check against the recent chat history.
class CleanerPromptBuilder {
  /// Builds the cleaner prompt. See class docs.
  static String buildCleanerPrompt({
    required String assistantText,
    List<String> broadcastBlocks = const [],
    List<ChatMessage> recentMessages = const [],
    List<String>? auditIssues,
    int maxCharsPerMessage = kDefaultMaxMessageChars,
    String bannedWords = '',
    String avoidInstructions = '',
    String styleInstructions = '',
    String beautyBrief = '',
    String? beautyState,
  }) {
    final rules = broadcastBlocks
        .map((b) => b.trim())
        .where((b) => b.isNotEmpty)
        .toList();

    final buffer = StringBuffer()
      ..writeln(
        'You are a faithful prose editor for a roleplay story. Your job is to '
        'clean up the following assistant response: remove clichés and common '
        'AI-isms, smooth repetitive phrasings, and fix local continuity '
        'errors — while PRESERVING the original voice, energy, imagery, and '
        'emotional texture. The text you receive was written with intent; '
        'your edits should refine it, not flatten it. Keep what is vivid, '
        'specific, and alive; only strip what is generic, overused, or '
        'contradictory.',
      )
      ..writeln();

    // Recent chat history — authoritative for local scene state.
    if (recentMessages.isNotEmpty) {
      final history = formatRecentMessages(recentMessages, maxCharsPerMessage);
      if (history.isNotEmpty) {
        buffer
          ..writeln('RECENT CHAT HISTORY:')
          ..writeln(history)
          ..writeln();
      }
    }

    // Character consistency notes from the auditor — explicit fix instructions.
    // Only added when the auditor found concrete contradictions.
    if (auditIssues != null && auditIssues.isNotEmpty) {
      buffer
        ..writeln('CHARACTER CONSISTENCY NOTES (from auditor — fix these):')
        ..writeln(auditIssues.map((i) => '- $i').join('\n'))
        ..writeln()
        ..writeln(
          'Apply minimal fixes for these issues while also cleaning style.',
        )
        ..writeln(
          'Do not add new content to resolve them. Prefer rephrasing that '
          'preserves the prose\'s voice; only delete or neutralize when '
          'rephrasing would bloat the text.',
        )
        ..writeln();
    }

    // Authoritative style rules from the active preset.
    if (rules.isNotEmpty) {
      buffer
        ..writeln(
          'AUTHORITATIVE RULES (from the active preset — follow these exactly; '
          'they OVERRIDE the generic guidance below, especially for output '
          'language and formatting):',
        )
        ..writeln()
        ..writeln(rules.join('\n\n---\n\n'))
        ..writeln();
    }

    // Global prose-guardian style overrides (Marinara `banned`/`avoid`/
    // `prefer` port). User-defined cross-chat style rules that supplement
    // the preset's broadcastBlocks. Only added when at least one field is
    // non-empty. The user sets these once globally (e.g. "never use the
    // word 'ozone'", "avoid starting consecutive responses with dialogue",
    // "prefer terse, hardboiled prose") and they apply to every chat.
    final hasBanned = bannedWords.trim().isNotEmpty;
    final hasAvoid = avoidInstructions.trim().isNotEmpty;
    final hasStyle = styleInstructions.trim().isNotEmpty;
    if (hasBanned || hasAvoid || hasStyle) {
      buffer
        ..writeln(
          'GLOBAL STYLE OVERRIDES (user-defined cross-chat rules — apply '
          'ALONGSIDE the authoritative rules above; do not contradict them):',
        )
        ..writeln();
      if (hasBanned) {
        buffer
          ..writeln(
            'BANNED WORDS (never use these, even if the original has them):',
          )
          ..writeln(bannedWords.trim())
          ..writeln();
      }
      if (hasAvoid) {
        buffer
          ..writeln('AVOID (specific patterns to steer away from):')
          ..writeln(avoidInstructions.trim())
          ..writeln();
      }
      if (hasStyle) {
        buffer
          ..writeln('PREFER (style direction to lean into):')
          ..writeln(styleInstructions.trim())
          ..writeln();
      }
    }

    buffer
      ..writeln('Rules:')
      ..writeln('- Keep the same meaning, events, and character voices.')
      ..writeln(
        '- PRESERVE vivid, original imagery and figurative language. '
        'Metaphors, sensory details, and specific textures are NOT filler '
        '— keep them.',
      )
      ..writeln(
        '- Remove or rephrase ONLY overused AI-isms and clichés (e.g. "a '
        'shiver ran down", "a dance of", "symphony of", "tapestry of", '
        '"couldn\'t help but", "a mix of", "sent shivers", "palpable '
        'tension"). Do NOT remove original metaphors or unique phrasings '
        'just because they are figurative.',
      )
      ..writeln(
        '- Remove redundant repetition of the SAME idea within a few '
        'sentences — but do not compress distinct beats into one.',
      )
      ..writeln('- Do NOT add new content, events, or dialogue.')
      ..writeln(
        '- Do NOT change the POV, tense, or the output language. Preserve the '
        'language and formatting required by the authoritative rules above.',
      )
      ..writeln(
        '- Keep the same approximate length. Do not shorten the text by '
        'removing imagery or descriptive passages — only by removing '
        'genuine filler.',
      )
      ..writeln(
        '- PRESERVE all inline HTML / formatting markup VERBATIM. This includes '
        '<font color="...">, <i>, <b>, <em>, <strong>, <mark>, <sub>, <sup>, '
        'and any other inline tags. These tags carry the user\'s styling '
        '(colored thoughts, colored speech, emphasis) and are NOT markdown to '
        'be stripped. Rewrite the prose INSIDE the tags if needed, but never '
        'remove, move, or alter the tags themselves, and never collapse '
        '<font><i>...</i></font> into plain text. If a sentence with colored '
        'markup is rephrased, keep the tags around the rephrased text in the '
        'same nesting order.',
      )
      ..writeln(
        '- PRESERVE OOC (out-of-character) blocks VERBATIM. OOC blocks are '
        'meta-commentary addressed to the user outside the roleplay — they '
        'are NOT prose to be cleaned. They may be wrapped in `((...))`, '
        '`[OOC: ...]`, `(OOC: ...)`, `((OOC: ...))`, or appear as clearly '
        'meta lines (e.g. "((Ghost in the machine: ...))", narrator notes to '
        'the user, system-style asides). Do not remove, rephrase, translate, '
        'reformat, or alter OOC blocks in any way. Clean only the in-roleplay '
        'prose around them. If the entire response is an OOC block, return it '
        'unchanged.',
      )
      ..writeln(
        '- PRESERVE meta-OOC blocks VERBATIM. A meta-OOC block is any tag '
        'whose name contains "ooc" (e.g. `<lumiaooc>`, `<oocnote>`, '
        '`<metaooc>`, `<sisterooc>`). It is meta-commentary from the '
        'meta-persona to the user outside the roleplay — NOT narrative prose. '
        'Do not rewrite, move, rephrase, translate, reformat, or delete it. '
        'Clean only the in-roleplay prose around it. If the response contains '
        'a meta-OOC block, keep it exactly as-is in the same position.',
      )
      ..writeln(
        '- Return ONLY the cleaned text, no explanation. Inline HTML tags '
        'described above are part of the content, not markdown fences — keep '
        'them. OOC blocks are also part of the content — keep them verbatim. '
        'Do not wrap the output in ``` fences.',
      )
      ..writeln();

    // Continuity rules — only when history is available.
    if (recentMessages.isNotEmpty) {
      buffer
        ..writeln('Continuity rules:')
        ..writeln(
          '- Before editing style, silently check the assistant response '
          'against RECENT CHAT HISTORY.',
        )
        ..writeln(
          '- Fix only clear local continuity contradictions that are directly '
          'contradicted by the provided context: who said what, who is '
          'present, current position, clothing, held objects, object '
          'ownership, and recent actions.',
        )
        ..writeln('- If the context is ambiguous, keep the original wording.')
        ..writeln('- Do not invent missing details.')
        ..writeln(
          '- Do not add new events, explanations, dialogue, memories, or '
          'motivations.',
        )
        ..writeln(
          '- Prefer minimal edits: fix the contradiction while keeping the '
          'sentence vivid. Rephrase rather than delete when possible; only '
          'shorten or neutralize when rephrasing would bloat the text.',
        )
        ..writeln(
          '- If correcting a continuity issue requires adding a new '
          'paragraph or scene event, do not fix it — only clean style.',
        )
        ..writeln();
    }

    // Beauty Shard — styling state owned by the cleaner (not the final agent).
    // When a beauty brief is provided, the cleaner is responsible for applying
    // speaker/thought colors and emitting the updated state marker.
    if (beautyBrief.trim().isNotEmpty) {
      buffer
        ..writeln('BEAUTY SHARD (visual styling — you own this):')
        ..writeln()
        ..writeln('Beauty Shard brief:')
        ..writeln(beautyBrief.trim())
        ..writeln();
      if (beautyState != null && beautyState.trim().isNotEmpty) {
        buffer
          ..writeln('Current styling state:')
          ..writeln(beautyState.trim())
          ..writeln();
      }
      buffer
        ..writeln('Styling rules:')
        ..writeln(
          '- Apply the speaker colors from the styling state to ALL character '
          'dialogue using <font color="#HEX">"text"</font> tags.',
        )
        ..writeln(
          '- Apply the thought colors to inner thoughts using '
          '<font color="#HEX"><i>text</i></font> tags.',
        )
        ..writeln(
          '- Reuse existing colors for established speakers. Assign a new '
          'color only for a speaker not yet in the state.',
        )
        ..writeln(
          '- If the assistant text already has <font> color tags, verify they '
          'match the styling state. Fix mismatches; do not remove correct tags.',
        )
        ..writeln(
          '- Do NOT color narrative prose — only dialogue (in quotes) and '
          'inner thoughts (in italics or marked as thought).',
        )
        ..writeln(
          '- At the very END of your cleaned response, after all narrative '
          'and HTML, emit exactly one marker with the updated state:',
        )
        ..writeln()
        ..writeln('<glaze_beauty_state>')
        ..writeln(
          '{"speakers":{"Name":"#hex"},"thoughts":{"Name":"#hex"},'
          '"palette":"dark|light","font":"sans-serif","bg":"#hex",'
          '"art_style":"..."}',
        )
        ..writeln('</glaze_beauty_state>')
        ..writeln()
        ..writeln(
          'The marker is parsed and stripped automatically — the user never '
          'sees it. Do not put it inside an HTML artifact or a code block.',
        )
        ..writeln();
    }

    buffer
      ..writeln()
      ..writeln('Assistant response to clean:')
      ..write(assistantText);

    return buffer.toString();
  }
}
