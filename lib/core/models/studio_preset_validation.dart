import 'studio_config.dart';

enum StudioPresetValidationSeverity { warning, error }

final class StudioPresetValidationIssue {
  final StudioPresetValidationSeverity severity;
  final String message;
  final String? blockId;

  const StudioPresetValidationIssue({
    required this.severity,
    required this.message,
    this.blockId,
  });
}

abstract final class StudioPresetValidator {
  static const supportedSections = <String>{
    'pregen',
    'final',
    'cleaner',
    'ledger',
    'build',
    'brief_parser',
  };

  static const supportedRoles = <String>{'system', 'user', 'assistant'};

  static const supportedInsertionModes = <String>{'relative', 'depth'};

  static const targetAgentIds = <String>{
    'continuity',
    'agency',
    'narrative',
    'dialogue',
    'guard',
    'world',
    'meta',
    'beauty',
    'final',
  };

  static List<StudioPresetValidationIssue> validate(StudioPreset preset) {
    final issues = <StudioPresetValidationIssue>[];
    final ids = <String>{};
    for (final block in preset.blocks) {
      final id = block.id.trim();
      if (id.isEmpty) {
        issues.add(_error(block, 'Block id must not be empty.'));
      } else if (!ids.add(id)) {
        issues.add(_error(block, 'Block id "$id" is duplicated.'));
      }
      if (!supportedSections.contains(block.section)) {
        // A block in an unknown section is never assembled into a prompt, so
        // it is inert rather than broken — and retired sections (`writeloop`)
        // still sit in long-lived DBs, which migrations deliberately preserve
        // as inert data. Erroring here would make a preset the app itself
        // stores and exports impossible to import back.
        issues.add(
          _warning(block, 'Unsupported Studio section "${block.section}".'),
        );
      }

      if (!supportedInsertionModes.contains(block.insertionMode)) {
        issues.add(_warning(block, 'Unsupported insertion mode.'));
      } else if (block.insertionMode == 'depth' && block.depth == null) {
        issues.add(
          _warning(block, 'Depth insertion mode is set without a depth.'),
        );
      } else if (block.insertionMode != 'depth' && block.depth != null) {
        issues.add(
          _warning(block, 'Depth is set but insertion mode is not "depth".'),
        );
      }
      if (block.insertionMode == 'depth' &&
          block.type != StudioBlockType.instruction) {
        // Depth-based interleaving only makes sense for instructions being
        // inserted into the chat-history array. A `history` block is the
        // array being interleaved into, and `context`/`priorBriefs` blocks
        // are spliced individually elsewhere in the pipeline — depth on
        // those types is ignored at runtime, so flag it rather than silently
        // dropping the author's intent.
        issues.add(
          _warning(block, 'Depth insertion only applies to instructions.'),
        );
      }

      switch (block.type) {
        case StudioBlockType.instruction:
          if (!supportedRoles.contains(block.role)) {
            issues.add(_error(block, 'Unsupported instruction role.'));
          }
          if (block.contextSlot != null) {
            issues.add(
              _error(block, 'Instruction blocks cannot select context.'),
            );
          }
          final target = block.targetAgentId;
          if (target != null && !targetAgentIds.contains(target)) {
            issues.add(_error(block, 'Unknown target agent "$target".'));
          }
          if (block.enabled &&
              block.content.trim().isEmpty &&
              !_isGroupBoundary(block.id)) {
            // The editor lets a block carry only a title (headers and
            // separators are built that way), and prompt assembly just emits
            // nothing for it. Contributing nothing is not the same as being
            // malformed, so this stays a warning — as an error it made those
            // presets un-importable after export.
            issues.add(
              _warning(block, 'Instruction content must not be empty.'),
            );
          }
        case StudioBlockType.context:
          if (block.contextSlot == null) {
            issues.add(_error(block, 'Context source is required.'));
          }
          if (block.targetAgentId != null) {
            issues.add(_error(block, 'Context blocks cannot target an agent.'));
          }
          _warnIgnoredContent(block, issues);
        case StudioBlockType.history:
          _validateSourceFreeBlock(block, issues);
          _warnIgnoredContent(block, issues);
        case StudioBlockType.priorBriefs:
          _validateSourceFreeBlock(block, issues);
          _warnIgnoredContent(block, issues);
          if (block.section != 'final') {
            issues.add(
              StudioPresetValidationIssue(
                severity: StudioPresetValidationSeverity.warning,
                blockId: block.id,
                message: 'Prior briefs are normally used in the final section.',
              ),
            );
          }
      }
    }
    return issues;
  }

  static bool hasErrors(Iterable<StudioPresetValidationIssue> issues) => issues
      .any((issue) => issue.severity == StudioPresetValidationSeverity.error);

  static void _validateSourceFreeBlock(
    StudioPresetBlock block,
    List<StudioPresetValidationIssue> issues,
  ) {
    if (block.contextSlot != null) {
      issues.add(_error(block, '${block.type.name} cannot select context.'));
    }
    if (block.targetAgentId != null) {
      issues.add(_error(block, '${block.type.name} cannot target an agent.'));
    }
  }

  static void _warnIgnoredContent(
    StudioPresetBlock block,
    List<StudioPresetValidationIssue> issues,
  ) {
    if (block.content.trim().isEmpty) return;
    issues.add(
      StudioPresetValidationIssue(
        severity: StudioPresetValidationSeverity.warning,
        blockId: block.id,
        message: '${block.type.name} block content is ignored.',
      ),
    );
  }

  static StudioPresetValidationIssue _error(
    StudioPresetBlock block,
    String message,
  ) => StudioPresetValidationIssue(
    severity: StudioPresetValidationSeverity.error,
    blockId: block.id,
    message: message,
  );

  static StudioPresetValidationIssue _warning(
    StudioPresetBlock block,
    String message,
  ) => StudioPresetValidationIssue(
    severity: StudioPresetValidationSeverity.warning,
    blockId: block.id,
    message: message,
  );

  static bool _isGroupBoundary(String id) =>
      id.endsWith('_group_open') ||
      id.endsWith('_group_close') ||
      id.endsWith('_prefix_close');
}

String describeStudioPresetBlock(StudioPresetBlock block) =>
    switch (block.type) {
      StudioBlockType.instruction =>
        'Instruction · ${block.targetAgentId ?? 'all agents'} · ${block.role}',
      StudioBlockType.context =>
        'Context · ${block.contextSlot?.name ?? 'source missing'}',
      StudioBlockType.history => 'History',
      StudioBlockType.priorBriefs => 'Previous agent briefs',
    };
