/// Barrel re-export for the agentic memory tools, split into three files
/// (plan §7.3 cosmetic split):
/// - [memory_agentic_tool_definitions.dart]: OpenAI-format tool schemas.
/// - [memory_agentic_search_handler.dart]: `searchMemory` handler + result
///   types.
///
/// This file re-exports the read-only search facilities so existing importers
/// keep their import path unchanged.
library;

export 'memory_agentic_search_handler.dart'
    show MemorySearchResult, MemorySearchHit, MemoryAgenticToolHandler;
export 'memory_agentic_tool_definitions.dart' show MemoryAgenticToolDefinition;
