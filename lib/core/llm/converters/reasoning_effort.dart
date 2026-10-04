/// Pure mapping from Glaze's six-step reasoning-effort scale onto the value a
/// given protocol actually accepts.
///
/// Ported from SillyTavern `public/scripts/openai.js::getReasoningEffort` +
/// `src/constants.js::OPENAI_REASONING_EFFORT_MAP`. The UI offers the same six
/// steps for every protocol — `auto | min | low | medium | high | max` — and
/// the translation happens here, at send time, instead of by shrinking the
/// dropdown per protocol:
///
/// - `auto` → `null`: the field is omitted and the provider default wins.
/// - Official OpenAI and OpenRouter accept up to `high`, so `max` becomes
///   `high`. Custom Chat Completion endpoints receive `max` unchanged.
/// - The UI's `min` step becomes `minimal` on the GPT-5 family or `low` on
///   older models.
/// - Anthropic and Gemini read the raw step as a share of the thinking budget
///   (`thinking_budget.dart`), so all six pass through untouched.
library;

import '../transport/llm_protocol.dart';

/// The steps offered in the UI, coarsest first.
const List<String> reasoningEffortSteps = [
  'auto',
  'min',
  'low',
  'medium',
  'high',
  'max',
];

bool isValidReasoningEffort(String value) =>
    reasoningEffortSteps.contains(value);

/// GPT-5 and newer accept `minimal`; earlier reasoning models do not. Matched
/// loosely because proxies prefix the model (`openai/gpt-5.1`, `azure/gpt-5`).
final RegExp _minimalEffortModels = RegExp(r'gpt-5', caseSensitive: false);

/// Resolves the value to put in `reasoning_effort` (Chat Completions) or
/// `reasoning.effort` (Responses). Returns null when nothing should be sent.
String? resolveReasoningEffort({
  required String protocol,
  required String? effort,
  required String model,
}) {
  if (effort == null || effort.isEmpty || effort == 'auto') return null;

  switch (protocol) {
    case LlmProtocol.anthropic:
    case LlmProtocol.gemini:
      // Budget fractions — the full scale is meaningful, pass it through.
      return effort;
    case LlmProtocol.customChatCompletion:
      switch (effort) {
        case 'min':
          return _minimalEffortModels.hasMatch(model) ? 'minimal' : 'low';
        case 'low':
        case 'medium':
        case 'high':
        case 'max':
          return effort;
        default:
          return null;
      }
    default:
      switch (effort) {
        case 'min':
          return _minimalEffortModels.hasMatch(model) ? 'minimal' : 'low';
        case 'max':
          return 'high';
        case 'low':
        case 'medium':
        case 'high':
          return effort;
        default:
          // Unknown step: send nothing rather than a value the API rejects.
          return null;
      }
  }
}
