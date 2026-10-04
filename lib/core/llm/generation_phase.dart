/// The stage a chat generation is actually in, reported live so the typing
/// bubble can name the work in progress instead of claiming "Generating…"
/// while the prompt is still being assembled.
///
/// The order below is the order a normal turn walks through. Studio turns
/// replace [waiting]/[reasoning]/[streaming] with [agents] until the final
/// writer starts streaming.
enum GenerationPhase {
  /// Nothing is running for this character.
  idle,

  /// Reading character, persona, API config, history and summary.
  preparing,

  /// Memory candidates, lorebook vector search and raw-message recall —
  /// the three retrieval futures `collectGenerationContext` awaits together.
  retrieving,

  /// Compiling the payload into provider messages (`buildPromptInIsolate`).
  prompt,

  /// Studio tracker agents are running before the final writer.
  agents,

  /// Request sent; no token has come back yet.
  waiting,

  /// Reasoning tokens are arriving but the visible reply is still empty.
  reasoning,

  /// Visible reply tokens are streaming.
  streaming,

  /// Post-generation work (cleaner, ledger, extension blocks, image tags).
  finalizing;

  /// Translation key for the label shown in the typing bubble.
  /// [idle] has no label — callers must not render it.
  String get translationKey => switch (this) {
    GenerationPhase.idle => 'gen_phase_streaming',
    GenerationPhase.preparing => 'gen_phase_preparing',
    GenerationPhase.retrieving => 'gen_phase_retrieving',
    GenerationPhase.prompt => 'gen_phase_prompt',
    GenerationPhase.agents => 'gen_phase_agents',
    GenerationPhase.waiting => 'gen_phase_waiting',
    GenerationPhase.reasoning => 'gen_phase_reasoning',
    GenerationPhase.streaming => 'gen_phase_streaming',
    GenerationPhase.finalizing => 'gen_phase_finalizing',
  };
}
