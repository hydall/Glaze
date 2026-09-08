import 'memory_agentic_policy.dart';

/// Tool definitions for the agentic memory system.
///
/// Read-only tools (`searchMemory`) are available when agentic mode is on.
///
/// Extracted from `memory_agentic_tools.dart` (plan §7.3 cosmetic split).
class MemoryAgenticToolDefinition {
  /// OpenAI-format tool definition for `searchMemory`.
  static Map<String, dynamic> searchMemory() {
    return {
      'type': 'function',
      'function': {
        'name': 'searchMemory',
        'description':
            'Search the Memory Book for relevant past memories. '
            'Returns candidate memory titles and scores. '
            'Use this when you need to recall specific past events, '
            'promises, relationships, or details.',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description':
                  'Search query describing what you want to remember',
            },
            'maxResults': {
              'type': 'integer',
              'description': 'Maximum number of results (default 5, max 10)',
              'default': 5,
            },
          },
          'required': ['query'],
        },
      },
    };
  }

  /// All available read-only tool definitions.
  static List<Map<String, dynamic>> readOnlyTools() => [searchMemory()];

  /// All available tool definitions for the given policy.
  static List<Map<String, dynamic>> forPolicy(MemoryAgenticPolicy policy) {
    if (!policy.settings.enabled) return const [];
    return readOnlyTools();
  }
}
