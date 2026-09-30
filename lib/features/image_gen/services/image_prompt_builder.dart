/// Style resolution and final-prompt assembly.
///
/// Ported from https://github.com/0xl0cal/sillyimages (`src/parser.js`):
/// the `[STYLE: ...]` block, the reference-description blocks and the per-image
/// labels sent alongside reference images.
library;

import '../image_gen_models.dart';

final _styleBlockRegex = RegExp(
  r'\[\s*style\s*:\s*[^\]]*\]',
  caseSensitive: false,
);

/// Puts `[STYLE: value]` in front of the prompt, replacing a style block the
/// model may have written itself (extra ones are dropped). An empty style
/// leaves the prompt untouched.
String injectStyleBlock(String prompt, String styleValue) {
  final normalizedPrompt = prompt.trim();
  final normalizedStyle = styleValue.trim();
  if (normalizedStyle.isEmpty) return normalizedPrompt;

  final styleBlock = '[STYLE: $normalizedStyle]';
  if (normalizedPrompt.isEmpty) return styleBlock;

  if (_styleBlockRegex.hasMatch(normalizedPrompt)) {
    var replacedFirst = false;
    return normalizedPrompt.replaceAllMapped(_styleBlockRegex, (_) {
      if (replacedFirst) return '';
      replacedFirst = true;
      return styleBlock;
    }).trim();
  }

  return '$styleBlock\n\n$normalizedPrompt'.trim();
}

/// Puts the style in front of the prompt as plain text, with no `[STYLE: ...]`
/// wrapper, and drops any style block the model wrote itself.
///
/// NovelAI reads the whole prompt as tags, so the wrapper would reach the
/// sampler as literal tokens (`[STYLE:`, `]`) instead of steering the image.
String injectPlainStyle(String prompt, String styleValue) {
  final normalizedPrompt = prompt.replaceAll(_styleBlockRegex, '').trim();
  final normalizedStyle = styleValue.trim();
  if (normalizedStyle.isEmpty) return normalizedPrompt;
  if (normalizedPrompt.isEmpty) return normalizedStyle;
  return '$normalizedStyle\n\n$normalizedPrompt';
}

/// The style library wins over the style the model wrote into the tag; with
/// "no style" selected ([ImageGenSettings.activeStyleId] empty) the tag's own
/// style is used.
String resolveEffectiveStyle(String? tagStyle, ImageGenSettings settings) {
  final libraryStyle = settings.activeStyle?.value.trim() ?? '';
  if (libraryStyle.isNotEmpty) return libraryStyle;
  return (tagStyle ?? '').trim();
}

/// The active style's negative prompt appended to [base] — the provider's own
/// negative stays as the base and the style adds to it. Returns [base]
/// unchanged when no style is active or it carries no negative prompt.
String resolveEffectiveNegativePrompt(String base, ImageGenSettings settings) {
  final styleNegative = settings.activeStyle?.negativePrompt.trim() ?? '';
  if (styleNegative.isEmpty) return base;
  final trimmedBase = base.trim();
  if (trimmedBase.isEmpty) return styleNegative;
  return '$trimmedBase, $styleNegative';
}

/// Text block describing every matched library reference, so the model can
/// keep characters and items visually consistent.
String buildReferenceDescriptionsBlock(List<Map<String, String>> references) {
  final items = <String>[];
  for (final ref in references) {
    if (ref['source'] != 'additional') continue;
    final name = (ref['name'] ?? '').trim();
    final description = (ref['description'] ?? '').trim();
    final line = name.isNotEmpty && description.isNotEmpty
        ? '$name: $description'
        : (description.isNotEmpty ? description : name);
    if (line.isNotEmpty) items.add('- $line');
  }
  if (items.isEmpty) return '';
  return 'Reference descriptions (use these to keep characters and items '
      'visually consistent):\n${items.join('\n')}';
}

/// Text block describing the character / persona avatars that are being sent.
String buildAvatarDescriptionsBlock(List<Map<String, String>> references) {
  final lines = <String>[];
  for (var i = 0; i < references.length; i++) {
    final source = references[i]['source'];
    if (source != 'char' && source != 'user') continue;
    final description = (references[i]['description'] ?? '').trim();
    if (description.isEmpty) continue;
    final label = source == 'char' ? '{{char}} avatar' : '{{user}} avatar';
    lines.add('- Reference ${i + 1} ($label): $description');
  }
  if (lines.isEmpty) return '';
  return 'Character reference descriptions:\n${lines.join('\n')}';
}

/// Appearance descriptions of {{char}} / {{user}} as a prompt block.
///
/// Ported from https://github.com/0xl0cal/sillyimages
/// (`buildCharacterDescriptionPromptBlock`). In [CharacterDescriptionsMode.asIs]
/// only characters whose avatar is *not* among [references] are described —
/// the ones that are sent already carry their description next to the image.
/// [CharacterDescriptionsMode.characterPrompt] describes both regardless and
/// emits NovelAI character-prompt lines, persona first.
String buildCharacterDescriptionPromptBlock({
  required CharacterDescriptionsMode mode,
  required List<Map<String, String>> references,
  String charDescription = '',
  String userDescription = '',
}) {
  if (mode == CharacterDescriptionsMode.none) return '';

  final sentSources = references
      .map((ref) => ref['source'] ?? '')
      .where((source) => source.isNotEmpty)
      .toSet();
  final asCharacterPrompt = mode == CharacterDescriptionsMode.characterPrompt;

  final char = asCharacterPrompt || !sentSources.contains('char')
      ? charDescription.trim()
      : '';
  final user = asCharacterPrompt || !sentSources.contains('user')
      ? userDescription.trim()
      : '';

  if (asCharacterPrompt) {
    final lines = [
      user,
      char,
    ].where((line) => line.isNotEmpty).map((line) => '\\| $line');
    return lines.join('\n');
  }

  final lines = <String>[
    if (char.isNotEmpty) '- {{char}}: $char',
    if (user.isNotEmpty) '- {{user}}: $user',
  ];
  return lines.isEmpty ? '' : 'Character descriptions:\n${lines.join('\n')}';
}

String appendPromptBlock(String prompt, String block) {
  final text = block.trim();
  if (text.isEmpty) return prompt;
  return '$prompt\n\n$text'.trim();
}

/// Assembles style block + prompt + reference descriptions.
/// [wrapStyle] false keeps the style as a plain prefix — see
/// [injectPlainStyle].
String buildFinalGenerationPrompt({
  required String prompt,
  required String? tagStyle,
  required ImageGenSettings settings,
  List<Map<String, String>> references = const [],
  bool wrapStyle = true,
}) {
  final style = resolveEffectiveStyle(tagStyle, settings);
  var fullPrompt = wrapStyle
      ? injectStyleBlock(prompt, style)
      : injectPlainStyle(prompt, style);
  if (settings.sendRefDescriptions) {
    fullPrompt = appendPromptBlock(
      fullPrompt,
      buildReferenceDescriptionsBlock(references),
    );
    fullPrompt = appendPromptBlock(
      fullPrompt,
      buildAvatarDescriptionsBlock(references),
    );
  }
  return fullPrompt;
}

/// Prefixes the critical "copy these appearances" instruction when at least
/// one reference image is attached and the instruction is enabled.
String withReferenceInstruction(
  String prompt,
  ImageGenSettings settings, {
  required bool hasReferences,
}) {
  if (!hasReferences) return prompt;
  final instruction = settings.effectiveRefInstruction;
  if (instruction.isEmpty) return prompt;
  return '$instruction\n\n$prompt';
}

/// Positional reference labels for rout.my, which sends every reference as a
/// bare image without a per-image caption: the prompt has to state which
/// picture is whom before the scene description.
String imagePromptWithReferenceLabels(
  String prompt,
  List<Map<String, String>> references,
) {
  if (references.isEmpty) return prompt;
  final labels = <String>[];
  for (var i = 0; i < references.length; i++) {
    final rawName = references[i]['name']?.trim() ?? '';
    if (rawName.isEmpty || rawName == 'context') continue;
    final name = rawName
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .replaceAll('"', "'");
    labels.add('Reference image ${i + 1} shows "$name".');
  }
  if (labels.isEmpty) return prompt;
  return '${labels.join(' ')} Preserve these exact identities and assign each '
      'person the role and position stated in the prompt.\n\n$prompt';
}

/// `Reference 1: red-haired mage` — inline label for chat-completion providers.
String referenceTextLabel(int index, String? description) {
  final text = (description ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.isEmpty ? '' : 'Reference $index: $text';
}

/// `IMAGE_1: red-haired mage` — inline label for Gemini `generateContent`.
String geminiImageLabel(int index, String? description) {
  final text = (description ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.isEmpty ? '' : 'IMAGE_$index: $text';
}
