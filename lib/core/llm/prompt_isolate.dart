import 'prompt_builder.dart';
import 'prompt_inputs.dart';
import 'prompt_worker.dart';

/// Runs buildPrompt in a persistent background isolate.
///
/// The isolate maintains its own copy of the active tokenizer and a
/// persistent token cache, so repeated calls are fast (cached history
/// tokens).
Future<PromptResult> buildPromptInIsolate(
  PromptPayload payload, {
  PromptWorkerPriority priority = PromptWorkerPriority.foreground,
}) async {
  final worker = await PromptWorker.ensureInitialized();
  return worker.buildPrompt(payload, priority: priority);
}

/// Builds a complete prompt from raw inputs in the isolate.
/// This runs memory injection, lorebook scanning, prompt assembly,
/// and tokenization all off the main thread.
Future<PromptResult> buildFromInputsInIsolate(
  PromptInputs inputs, {
  PromptWorkerPriority priority = PromptWorkerPriority.background,
}) async {
  final worker = await PromptWorker.ensureInitialized();
  return worker.buildFromInputs(inputs, priority: priority);
}
