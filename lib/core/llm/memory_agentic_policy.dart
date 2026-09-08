enum MemoryAgenticTool { inspectContext, proposeMemory, proposeTracker }

class MemoryAgenticSettings {
  final bool enabled;
  final bool readOnly;
  final bool writeToolsEnabled;
  final bool requireExplicitDiffApproval;

  const MemoryAgenticSettings({
    this.enabled = false,
    this.readOnly = true,
    this.writeToolsEnabled = false,
    this.requireExplicitDiffApproval = true,
  });
}

class MemoryAgenticToolDecision {
  final bool allowed;
  final String reason;

  const MemoryAgenticToolDecision.allow() : allowed = true, reason = '';

  const MemoryAgenticToolDecision.deny(this.reason) : allowed = false;
}

class MemoryAgenticPolicy {
  final MemoryAgenticSettings settings;

  const MemoryAgenticPolicy(this.settings);

  MemoryAgenticToolDecision canUse(
    MemoryAgenticTool tool, {
    bool explicitDiffApproved = false,
  }) {
    if (!settings.enabled) {
      return const MemoryAgenticToolDecision.deny('agentic_disabled');
    }
    if (!_isWriteTool(tool)) return const MemoryAgenticToolDecision.allow();
    if (settings.readOnly) {
      return const MemoryAgenticToolDecision.deny('agentic_read_only');
    }
    if (!settings.writeToolsEnabled) {
      return const MemoryAgenticToolDecision.deny('write_tools_disabled');
    }
    if (settings.requireExplicitDiffApproval && !explicitDiffApproved) {
      return const MemoryAgenticToolDecision.deny('diff_approval_required');
    }
    return const MemoryAgenticToolDecision.allow();
  }

  static bool _isWriteTool(MemoryAgenticTool tool) => false;
}
