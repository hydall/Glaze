import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/llm/generation_phase.dart';

/// Live phase of the chat generation for one character, keyed by `charId`.
///
/// Written by the generation path (`ChatNotifier` → `StreamGenerationService`
/// → `GenerationPipeline` → `AbortHandler`) and watched by the chat WebView,
/// which pushes the label into the typing bubble. Purely a UI signal — no
/// pipeline decision reads it, so a missed transition can only mean a
/// slightly stale label, never a stuck generation.
final generationPhaseProvider = StateProvider.family<GenerationPhase, String>(
  (ref, _) => GenerationPhase.idle,
);

/// Sets the live phase for [charId], skipping the write when it is already
/// there (the streaming path calls this on every chunk).
void setGenerationPhase(Ref ref, String charId, GenerationPhase phase) {
  if (!ref.mounted) return;
  final notifier = ref.read(generationPhaseProvider(charId).notifier);
  if (notifier.state == phase) return;
  notifier.state = phase;
}

/// Localized label for the typing bubble. Empty for [GenerationPhase.idle] —
/// the page falls back to its own default text, so a bubble left on screen by
/// a settled run never shows the last phase of that run.
String generationPhaseLabel(GenerationPhase phase) =>
    phase == GenerationPhase.idle ? '' : phase.translationKey.tr();
