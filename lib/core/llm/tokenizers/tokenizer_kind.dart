import '../transport/llm_protocol.dart';

/// A token counting scheme a connection can count with.
///
/// Every downloadable kind is a HuggingFace `tokenizer.json`, published on npm
/// by the `@lenml/tokenizer-*` packages and fetched from a CDN on first use —
/// nothing ships inside the app. [approx] needs no download at all.
enum TokenizerKind {
  o200k(
    id: 'o200k',
    label: 'OpenAI o200k',
    models: 'GPT-4o, GPT-4.1, GPT-5, o-series',
    package: 'gpt4o',
  ),
  cl100k(
    id: 'cl100k',
    label: 'OpenAI cl100k',
    models: 'GPT-4, GPT-3.5',
    package: 'gpt4',
  ),
  claude(id: 'claude', label: 'Claude', models: 'Claude', package: 'claude'),
  gemini(
    id: 'gemini',
    label: 'Gemini / Gemma',
    models: 'Gemini, Gemma',
    package: 'gemini',
  ),
  llama3(
    id: 'llama3',
    label: 'Llama 3',
    models: 'Llama 3, Llama 4',
    package: 'llama3_1',
  ),
  llama2(id: 'llama2', label: 'Llama 2', models: 'Llama 2', package: 'llama2'),
  qwen(
    id: 'qwen',
    label: 'Qwen',
    models: 'Qwen 2.5, Qwen 3, QwQ',
    package: 'qwen3',
  ),
  deepseek(
    id: 'deepseek',
    label: 'DeepSeek',
    models: 'DeepSeek V3, R1, V4',
    package: 'deepseek_v3',
  ),
  mistral(
    id: 'mistral',
    label: 'Mistral (Tekken)',
    models: 'Mistral, Mixtral, Nemo, Magistral',
    package: 'mistral_nemo',
  ),
  commandR(
    id: 'command_r',
    label: 'Command R',
    models: 'Command R, R+, A',
    package: 'command_r_plus',
  ),
  approx(id: 'approx', label: 'Estimate', models: '', package: null);

  const TokenizerKind({
    required this.id,
    required this.label,
    required this.models,
    required this.package,
  });

  /// Stored in `ApiConfig.tokenizer`; never rename.
  final String id;
  final String label;

  /// Which models this tokenizer belongs to, for the picker's hint line —
  /// product names only, so it needs no translation.
  final String models;

  /// `@lenml/tokenizer-<package>` on npm, or null when nothing is downloaded.
  final String? package;

  bool get needsDownload => package != null;

  static TokenizerKind? fromId(String? id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// `ApiConfig.tokenizer` value that means "pick from the model name".
const String kTokenizerAuto = 'auto';

/// Pinned so a republished package can never change counts under a user.
const String _packageVersion = '3.7.2';

/// Where a kind's `tokenizer.json` is fetched from, in order of preference.
List<String> tokenizerSourceUrls(TokenizerKind kind) {
  final package = kind.package;
  if (package == null) return const [];
  final path =
      '@lenml/tokenizer-$package@$_packageVersion/models/tokenizer.json';
  return ['https://cdn.jsdelivr.net/npm/$path', 'https://unpkg.com/$path'];
}

/// The tokenizer [setting] selects for [model] on a [protocol] connection:
/// an explicit choice wins; `auto` (or anything unknown) matches the model
/// name the way SillyTavern's `getTokenizerModel` does, then falls back to
/// the provider, then to o200k.
TokenizerKind resolveTokenizerKind({
  required String setting,
  required String model,
  required String protocol,
}) {
  final explicit = setting == kTokenizerAuto
      ? null
      : TokenizerKind.fromId(setting);
  if (explicit != null) return explicit;
  return tokenizerForModel(model) ?? _tokenizerForProtocol(protocol);
}

/// The tokenizer family a model id belongs to, or null when the name says
/// nothing. Handles router prefixes (`anthropic/claude-…`, `meta-llama/…`).
TokenizerKind? tokenizerForModel(String model) {
  final m = model.toLowerCase();
  if (m.isEmpty) return null;
  bool has(String s) => m.contains(s);

  if (has('claude')) return TokenizerKind.claude;
  if (has('gemini') || has('gemma') || has('learnlm')) {
    return TokenizerKind.gemini;
  }
  if (has('deepseek')) return TokenizerKind.deepseek;
  if (has('qwen') || has('qwq')) return TokenizerKind.qwen;
  if (has('command-r') || has('command-a') || has('cohere') || has('aya-')) {
    return TokenizerKind.commandR;
  }
  if (RegExp(
    r'mi[sx]tral|ministral|magistral|codestral|devstral|pixtral|'
    r'(^|[/_-])nemo',
  ).hasMatch(m)) {
    return TokenizerKind.mistral;
  }
  if (RegExp(r'llama[-_ ]?2').hasMatch(m)) return TokenizerKind.llama2;
  if (has('llama')) return TokenizerKind.llama3;
  if (RegExp(
    r'gpt-?4o|gpt-?4\.[15]|gpt-?5|gpt-oss|chatgpt|codex|'
    r'(^|[/:_ -])o[1-9](\b|-)',
  ).hasMatch(m)) {
    return TokenizerKind.o200k;
  }
  if (RegExp(r'gpt-?4|gpt-?3\.5|gpt-?35').hasMatch(m)) {
    return TokenizerKind.cl100k;
  }
  return null;
}

TokenizerKind _tokenizerForProtocol(String protocol) => switch (protocol) {
  LlmProtocol.anthropic => TokenizerKind.claude,
  LlmProtocol.gemini => TokenizerKind.gemini,
  _ => TokenizerKind.o200k,
};
