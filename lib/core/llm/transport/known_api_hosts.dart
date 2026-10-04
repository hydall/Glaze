/// Canonical base paths for providers we know the URL shape of.
///
/// The endpoint field is free text, so users paste anything: a bare host, a
/// full `…/v1/chat/completions`, a typo. For a host in this table we know the
/// real base path, so [KnownApiHosts.basePathFor] can rewrite whatever was
/// typed into the shape the provider actually serves — including providers
/// whose OpenAI-compatible surface is *not* `/v1`
/// (Perplexity serves it at the root, Groq under `/openai/v1`).
///
/// Only hosts whose path shape is stable belong here. Everything else falls
/// back to the generic rules in `EndpointNormalizer` plus the runtime
/// candidate retry.
class KnownApiHosts {
  KnownApiHosts._();

  /// Host (lowercase, no port) → base path without leading/trailing slash.
  /// An empty value means "the API lives at the root" — no version segment.
  static const Map<String, String> openAiCompatible = {
    'api.openai.com': 'v1',
    'api.deepseek.com': 'v1',
    'api.mistral.ai': 'v1',
    'api.x.ai': 'v1',
    'api.together.xyz': 'v1',
    'api.together.ai': 'v1',
    'api.cerebras.ai': 'v1',
    'api.moonshot.ai': 'v1',
    'api.moonshot.cn': 'v1',
    'api.lambdalabs.com': 'v1',
    'integrate.api.nvidia.com': 'v1',
    'api.anthropic.com': 'v1',
    'openrouter.ai': 'api/v1',
    'api.groq.com': 'openai/v1',
    'api.fireworks.ai': 'inference/v1',
    'api.deepinfra.com': 'v1/openai',
    'api.novita.ai': 'v3/openai',
    'generativelanguage.googleapis.com': 'v1beta/openai',
    // Perplexity serves chat completions at the root — appending /v1 404s.
    'api.perplexity.ai': '',
  };

  /// Hosts that speak the Gemini native API (`/v1beta/models/…`). The version
  /// segment is added by the transport, so the base path is empty.
  static const Set<String> geminiNative = {
    'generativelanguage.googleapis.com',
  };

  /// Returns the canonical base path for [host], or `null` when the host is
  /// unknown. [host] is matched case-insensitively, with any port stripped.
  static String? basePathFor(String host, {bool gemini = false}) {
    final key = host.toLowerCase();
    if (gemini) return geminiNative.contains(key) ? '' : null;
    return openAiCompatible[key];
  }
}
