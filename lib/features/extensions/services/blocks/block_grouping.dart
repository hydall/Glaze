import '../../models/block_config.dart';
import '../../models/block_modes.dart';
import '../macro_expander.dart';

/// The original's `groupBlocksByContext`: generated blocks that share their
/// context list (by item names) and their background flag go to the model as
/// one request, and each takes its own tag out of the reply.
///
/// Only blocks that carry a context list take part — the original's own
/// kind of block. A block without one is built from this app's context policy,
/// which the original has no notion of, so it keeps its own request. A block
/// chained to the one before it, or one that carries its content, never asks
/// the model alongside others. Blocks on different connections or generation
/// profiles are not merged either: the original would quietly run them all
/// on the first one's.
///
/// Returns `null` for a block that is not grouped at all.
String? blockGroupKey(BlockConfig block) {
  if (block.type != BlockType.generated) return null;
  if (block.source != BlockSource.model) return null;
  if (block.dependsOnPrevious) return null;
  final items = block.context.where((item) => !item.disabled).toList();
  if (items.isEmpty) return null;
  final names = items.map((item) => item.name).join('_');
  return '${block.background ? 'bg_' : ''}$names'
      '|${block.apiPreset.name}|${block.apiConfigId}|${block.model}';
}

/// The group of every block in [blocks] that runs alongside at least one
/// other, by block id and in [blocks]' order. A block missing from the map
/// runs alone.
Map<String, List<BlockConfig>> blockGroups(Iterable<BlockConfig> blocks) {
  final byKey = <String, List<BlockConfig>>{};
  for (final block in blocks) {
    final key = blockGroupKey(block);
    if (key != null) (byKey[key] ??= []).add(block);
  }
  return {
    for (final group in byKey.values)
      if (group.length > 1)
        for (final block in group) block.id: group,
  };
}

/// The instruction the original puts ahead of a request's context
/// (`getBlocksFullPrompt`): every block's prompt, then every block's template,
/// each list skipping the empty ones. `''` when all of them are empty.
String upstreamBlocksHeader(List<BlockConfig> blocks, MacroContext macros) {
  String resolve(String text, BlockConfig block) =>
      expand(text.replaceAll('{{name}}', block.name), macros).trim();
  final prompts = [
    for (final b in blocks) resolve(b.prompt, b),
  ].where((p) => p.isNotEmpty);
  final templates = [
    for (final b in blocks) resolve(b.template, b),
  ].where((t) => t.isNotEmpty);
  return [
    if (prompts.isNotEmpty) 'Block(s) prompt:\n${prompts.join('\n')}',
    if (templates.isNotEmpty) 'Block(s) template:\n${templates.join('\n')}',
  ].join('\n\n');
}
