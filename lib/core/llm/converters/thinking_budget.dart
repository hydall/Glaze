/// Reasoning effort → provider budget calculators.
///
/// Ported from SillyTavern `src/prompt-converters.js`:
/// - `calculateClaudeBudgetTokens`
/// - `calculateGoogleBudgetTokens`
///
/// Both return one of:
/// - `int` — explicit token budget (Claude pre-Opus-4.6, Gemini 2.x).
/// - `String` — symbolic effort (`'low'`, `'medium'`, `'high'`, `'max'`,
///   `'minimal'`) for adaptive-thinking models (Opus 4.6+, Gemini 3.x).
/// - `null` — caller should omit the thinking config entirely (effort: auto).
///
/// Caller is responsible for picking adaptive vs explicit by model id.
library;

/// Canonical reasoning effort identifiers (mirrors SillyTavern strings).
class ReasoningEffort {
  ReasoningEffort._();
  static const String auto = 'auto';
  static const String min = 'min';
  static const String low = 'low';
  static const String medium = 'medium';
  static const String high = 'high';
  static const String max = 'max';
}

/// Claude budget. Returns:
/// - `String` (`'low'/'medium'/'high'/'max'`) when [isAdaptiveModel] is true
///   (Opus 4.6+).
/// - `int` token budget for traditional thinking models, clamped to [1024,
///   21333] when [stream] is false (non-stream budget cap).
/// - `null` for `'auto'`.
Object? calculateClaudeBudgetTokens({
  required int maxTokens,
  required String reasoningEffort,
  required bool stream,
  required bool isAdaptiveModel,
}) {
  if (isAdaptiveModel) {
    switch (reasoningEffort) {
      case ReasoningEffort.auto:
        return null;
      case ReasoningEffort.min:
      case ReasoningEffort.low:
        return 'low';
      case ReasoningEffort.medium:
        return 'medium';
      case ReasoningEffort.high:
        return 'high';
      case ReasoningEffort.max:
        return 'max';
    }
    return null;
  }

  int budget;
  switch (reasoningEffort) {
    case ReasoningEffort.auto:
      return null;
    case ReasoningEffort.min:
      budget = 1024;
      break;
    case ReasoningEffort.low:
      budget = (maxTokens * 0.1).floor();
      break;
    case ReasoningEffort.medium:
      budget = (maxTokens * 0.25).floor();
      break;
    case ReasoningEffort.high:
      budget = (maxTokens * 0.5).floor();
      break;
    case ReasoningEffort.max:
      budget = (maxTokens * 0.95).floor();
      break;
    default:
      return null;
  }

  if (budget < 1024) budget = 1024;
  if (!stream && budget > 21333) budget = 21333;
  return budget;
}

/// Gemini budget. Caller selects sub-formula by model name; falls back to
/// `null` for unrecognised models. Returns `int` (explicit budget),
/// `String` symbolic effort (Gemini 3), or `null`.
///
/// Gemini-specific quirk: returning `-1` token budget means "auto" in
/// Gemini's API (different from `null` which omits the config). Keep
/// `int`-returning paths using `-1` for that.
Object? calculateGoogleBudgetTokens({
  required int maxTokens,
  required String reasoningEffort,
  required String model,
}) {
  if (RegExp(r'gemini-3[.\d]*-pro').hasMatch(model)) {
    return _gemini3Symbolic(
      reasoningEffort,
      lowForMedium: true,
    );
  }
  if (RegExp(r'gemini-3[.\d]*-flash').hasMatch(model)) {
    return _gemini3Symbolic(
      reasoningEffort,
      lowForMedium: false,
    );
  }
  if (model.contains('flash-lite')) {
    return _flashLikeBudget(
      maxTokens: maxTokens,
      effort: reasoningEffort,
      minBudget: 512,
      cap: 24576,
    );
  }
  if (model.contains('flash')) {
    return _flashLikeBudget(
      maxTokens: maxTokens,
      effort: reasoningEffort,
      minBudget: 0,
      cap: 24576,
    );
  }
  if (model.contains('pro')) {
    return _proBudget(maxTokens: maxTokens, effort: reasoningEffort);
  }
  return null;
}

Object? _gemini3Symbolic(
  String effort, {
  required bool lowForMedium,
}) {
  switch (effort) {
    case ReasoningEffort.auto:
      return null;
    case ReasoningEffort.min:
      return lowForMedium ? 'low' : 'minimal';
    case ReasoningEffort.low:
      return 'low';
    case ReasoningEffort.medium:
      return lowForMedium ? 'low' : 'medium';
    case ReasoningEffort.high:
    case ReasoningEffort.max:
      return 'high';
  }
  return null;
}

Object _flashLikeBudget({
  required int maxTokens,
  required String effort,
  required int minBudget,
  required int cap,
}) {
  int budget;
  switch (effort) {
    case ReasoningEffort.auto:
      return -1;
    case ReasoningEffort.min:
      return 0;
    case ReasoningEffort.low:
      budget = (maxTokens * 0.1).floor();
      break;
    case ReasoningEffort.medium:
      budget = (maxTokens * 0.25).floor();
      break;
    case ReasoningEffort.high:
      budget = (maxTokens * 0.5).floor();
      break;
    case ReasoningEffort.max:
      budget = maxTokens;
      break;
    default:
      return -1;
  }
  if (budget > cap) budget = cap;
  if (budget < minBudget) budget = minBudget;
  return budget;
}

Object _proBudget({required int maxTokens, required String effort}) {
  int budget;
  switch (effort) {
    case ReasoningEffort.auto:
      return -1;
    case ReasoningEffort.min:
      budget = 128;
      break;
    case ReasoningEffort.low:
      budget = (maxTokens * 0.1).floor();
      break;
    case ReasoningEffort.medium:
      budget = (maxTokens * 0.25).floor();
      break;
    case ReasoningEffort.high:
      budget = (maxTokens * 0.5).floor();
      break;
    case ReasoningEffort.max:
      budget = maxTokens;
      break;
    default:
      return -1;
  }
  if (budget > 32768) budget = 32768;
  if (budget < 128) budget = 128;
  return budget;
}

/// Heuristic: Opus 4.6+ uses adaptive thinking (symbolic effort instead of
/// integer budget). Mirrors SillyTavern's isAdaptiveModel flag.
bool isAdaptiveClaudeModel(String model) {
  final m = model.toLowerCase();
  return RegExp(r'claude-opus-4[\-\.]?[67]').hasMatch(m) ||
      RegExp(r'claude-opus-[5-9]').hasMatch(m) ||
      RegExp(r'claude-opus-4-[6-9]').hasMatch(m);
}
