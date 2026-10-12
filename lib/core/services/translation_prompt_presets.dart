import 'memory_prompt_presets.dart' show MemoryPromptPreset;

/// Ready-made instructions for the LLM translator, the way Memory Books and
/// Summary ship ready-made prompts.
///
/// The settings store the template itself, not a preset key, so a preset is a
/// text to start from: picking one fills the field and editing it afterwards is
/// expected. [match] is what tells the settings which preset the stored text
/// still is.
///
/// Every prompt carries a `{{language}}` placeholder — the target language, as
/// named in English — which `TranslationService` substitutes. A hand-written
/// prompt that omits it simply never names the language, which is a mistake the
/// writer is free to make; the service does not inject it.
///
/// Reuses [MemoryPromptPreset] as the record type — a key/label/prompt triple
/// with nothing memory-specific in it.
class TranslationPromptPresets {
  const TranslationPromptPresets._();

  static const fallbackKey = 'literary';

  /// The placeholder `TranslationService` replaces with the target language.
  static const languagePlaceholder = '{{language}}';

  static const builtIn = [
    MemoryPromptPreset(
      key: fallbackKey,
      label: 'Literary (recommended)',
      prompt: _literary,
    ),
    MemoryPromptPreset(
      key: 'literal',
      label: 'Literal / faithful',
      prompt: _literal,
    ),
    MemoryPromptPreset(
      key: 'casual',
      label: 'Casual & natural',
      prompt: _casual,
    ),
    MemoryPromptPreset(key: 'minimal', label: 'Minimal', prompt: _minimal),
  ];

  static List<MemoryPromptPreset> all([List<MemoryPromptPreset>? custom]) => [
    ...builtIn,
    ...?custom,
  ];

  /// The preset [template] still is, or null once it has been edited into
  /// something of its own. An empty template is the built-in default.
  static MemoryPromptPreset? match(
    String? template, [
    List<MemoryPromptPreset>? custom,
  ]) {
    final text = template?.trim() ?? '';
    if (text.isEmpty) return builtIn.first;
    return all(custom).where((p) => p.prompt.trim() == text).firstOrNull;
  }

  /// The prompt actually sent for [template], with the target language folded
  /// in. [languageName] is the English name the translator is asked for.
  ///
  /// An empty template means the built-in default; anything else is used as
  /// written, custom or not — [match] is only how the settings label it.
  static String resolve(String? template, String languageName) {
    final text = template?.trim() ?? '';
    final resolved = text.isEmpty ? builtIn.first.prompt : text;
    return resolved.replaceAll(languagePlaceholder, languageName);
  }

  static const _literary = '''
You are a literary translator for roleplay fiction. Translate the user's message into {{language}}.

Translate only the text. Do not explain, summarize, censor, annotate or add anything of your own. Preserve the meaning, tone, character voices, dialogue, profanity, names, paragraph breaks, Markdown, HTML tags and their attributes, and any text in square or curly brackets as structure. Translate idioms by meaning. If the text is already in {{language}}, return it unchanged. Reply with the translation only.''';

  static const _literal = '''
Translate the user's message into {{language}}, as faithfully to the original as possible.

Translate only the text; do not explain or comment. Keep every name, term, number, Markdown and HTML tag exactly as written. Follow the source sentence structure closely, even where a freer rendering would read more naturally. If the text is already in {{language}}, return it unchanged. Reply with the translation only.''';

  static const _casual = '''
Translate the user's message into {{language}} the way a native speaker would say it out loud.

Translate only the text; do not explain or comment. Keep the register, slang and profanity, use natural everyday phrasing, and preserve names, Markdown and HTML tags exactly. If the text is already in {{language}}, return it unchanged. Reply with the translation only.''';

  static const _minimal = '''
Translate the user's message into {{language}}. Translate only the text, do not explain, and reply with nothing but the translation.''';
}
