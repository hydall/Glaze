/// Reads and writes single blocks in the format used by the original ExtBlocks
/// extension, so a block exported there can be imported here and back again.
///
/// The original writes only the keys that apply to a block's type and leaves
/// the rest out entirely, so [encodeUpstreamBlock] does the same: a script
/// block does not come back carrying injection settings it never had.
library;

import '../../../core/utils/id_generator.dart';
import '../models/block_config.dart';
import '../models/block_context_item.dart';
import '../models/block_injection.dart';
import '../models/block_modes.dart';
import '../models/connection_profiles.dart';
import 'upstream_context_codec.dart';
import 'upstream_json.dart';

const Map<String, BlockType> _typeFromUpstream = {
  'generated': BlockType.infoblock,
  'rewrite': BlockType.rewrite,
  'accumulation': BlockType.accumulation,
  'script': BlockType.jsRunner,
};

const Map<BlockType, String> _typeToUpstream = {
  BlockType.infoblock: 'generated',
  BlockType.rewrite: 'rewrite',
  BlockType.accumulation: 'accumulation',
  BlockType.jsRunner: 'script',
};

const Map<Object, InjectionRole> _injectionRoles = {
  0: InjectionRole.system,
  1: InjectionRole.user,
  2: InjectionRole.assistant,
};

const Map<Object, InjectionPosition> _injectionPositions = {
  0: InjectionPosition.afterMainPrompt,
  1: InjectionPosition.inChat,
  2: InjectionPosition.beforeMainPrompt,
};

const Map<Object, BlockRunOrder> _runOrders = {
  'before': BlockRunOrder.before,
  'after': BlockRunOrder.after,
};

const Map<Object, RewriteMode> _rewriteModes = {
  'full': RewriteMode.full,
  'search_replace': RewriteMode.searchReplace,
};

const Map<Object, ScriptType> _scriptTypes = {
  'stscript': ScriptType.stScript,
  'js': ScriptType.js,
};

const Map<Object, ConnectionProfile> _apiPresets = {
  'big': ConnectionProfile.big,
  'medium': ConnectionProfile.medium,
  'small': ConnectionProfile.small,
};

int _injectionRoleValue(InjectionRole role) => switch (role) {
  InjectionRole.system => 0,
  InjectionRole.user => 1,
  InjectionRole.assistant => 2,
};

int _injectionPositionValue(InjectionPosition position) => switch (position) {
  InjectionPosition.afterMainPrompt => 0,
  InjectionPosition.inChat => 1,
  InjectionPosition.beforeMainPrompt => 2,
};

String _runOrderValue(BlockRunOrder order) =>
    order == BlockRunOrder.before ? 'before' : 'after';

/// Whether [json] looks like a block from the original extension rather than
/// one of ours. Both carry `name` and `id`, so the tell is the snake_case
/// trigger pair, which our own format never writes.
bool looksLikeUpstreamBlock(Map<String, dynamic> json) =>
    json.containsKey('block_type') ||
    json.containsKey('char_message') ||
    json.containsKey('user_message');

/// The trigger enum our own pipeline still selects on. The original has no
/// single-valued equivalent — a block there can answer to both sides — so a
/// user-only block maps to [BlockTrigger.afterUser] and everything else to
/// [BlockTrigger.afterAssistant], which is the chain that runs.
BlockTrigger _legacyTrigger({required bool onUser, required bool onChar}) =>
    onUser && !onChar ? BlockTrigger.afterUser : BlockTrigger.afterAssistant;

/// Builds a [BlockConfig] from one block exported by the original extension.
///
/// [order] places the block in our preset, which the original tracks by array
/// position rather than by a stored field.
BlockConfig decodeUpstreamBlock(Map<String, dynamic> json, {int order = 0}) {
  final type =
      _typeFromUpstream[upstreamString(
        json['block_type'],
        fallback: 'generated',
      )] ??
      BlockType.infoblock;

  final onUser = upstreamBool(json['user_message']);
  final onChar = upstreamBool(json['char_message']);

  final rawContext = json['context'];
  final context = <BlockContextItem>[];
  if (rawContext is List) {
    for (final item in rawContext) {
      if (item is! Map) continue;
      context.add(BlockContextItem.fromJson(Map<String, dynamic>.from(item)));
    }
  }

  final id = upstreamString(json['id']);

  return BlockConfig(
    id: id.isEmpty ? generateId() : id,
    name: upstreamString(json['name']).trim(),
    type: type,
    enabled: !upstreamBool(json['disabled']),
    order: order,
    trigger: _legacyTrigger(onUser: onUser, onChar: onChar),
    triggerOnUser: onUser,
    triggerOnChar: onChar,
    triggerOnSwipe: upstreamBool(json['swipe']),
    generationPause: upstreamBool(json['generation_pause']),
    generationAfterCommands: upstreamBool(json['generation_after_commands']),
    period: upstreamIntNonZero(json['period'], 2),
    keyword: upstreamString(json['keyword']),
    keywordIsRegex: upstreamBool(json['keyword_is_regex']),
    template: upstreamString(json['template']),
    prompt: upstreamString(json['prompt']),
    script: upstreamString(json['script']),
    scriptType: upstreamEnum(
      json['script_type'],
      _scriptTypes,
      ScriptType.stScript,
    ),
    hideDisplay: upstreamBool(json['hide_display']),
    inject: upstreamBool(json['inject_block']),
    background: upstreamBool(json['background']),
    applyRegex: upstreamBool(json['apply_regex']),
    injectionRole: upstreamEnum(
      json['injection_role'],
      _injectionRoles,
      InjectionRole.system,
    ),
    injectionPosition: upstreamEnum(
      json['injection_position'],
      _injectionPositions,
      InjectionPosition.afterMainPrompt,
    ),
    injectionDepth: upstreamInt(json['injection_depth'], 4),
    generationOrder: upstreamEnum(
      json['generation_order'],
      _runOrders,
      BlockRunOrder.before,
    ),
    executionOrder: upstreamEnum(
      json['execution_order'],
      _runOrders,
      BlockRunOrder.before,
    ),
    rewriteMode: upstreamEnum(
      json['rewrite_mode'],
      _rewriteModes,
      RewriteMode.full,
    ),
    updaterName: upstreamString(json['updater_name']).trim(),
    apiPreset: upstreamEnum(
      json['api_preset'],
      _apiPresets,
      ConnectionProfile.big,
    ),
    context: context,
  );
}

/// Writes [block] back out in the original's format.
///
/// Types with no counterpart there — images and interactive panels — are
/// written as generated blocks, which is the closest the format can express.
Map<String, dynamic> encodeUpstreamBlock(BlockConfig block) {
  final type = _typeToUpstream[block.type] ?? 'generated';

  final base = <String, dynamic>{
    'id': block.id,
    'name': block.name,
    'block_type': type,
    'disabled': !block.enabled,
    'user_message': block.triggerOnUser,
    'char_message': block.triggerOnChar,
  };

  final injection = <String, dynamic>{
    'hide_display': block.hideDisplay,
    'inject_block': block.inject,
    'injection_role': _injectionRoleValue(block.injectionRole),
    'injection_position': _injectionPositionValue(block.injectionPosition),
    'injection_depth': block.injectionDepth,
  };

  switch (type) {
    case 'accumulation':
      return {...base, 'updater_name': block.updaterName, ...injection};

    case 'script':
      return {
        ...base,
        'script_type': block.scriptType == ScriptType.js ? 'js' : 'stscript',
        'script': block.script,
        'generation_pause': block.generationPause,
        'generation_after_commands': block.generationAfterCommands,
        'swipe': block.triggerOnSwipe,
        'period': block.period,
        'keyword': block.keyword,
        'keyword_is_regex': block.keywordIsRegex,
        'execution_order': _runOrderValue(block.executionOrder),
      };

    default:
      final generated = <String, dynamic>{
        ...base,
        'template': block.template,
        'prompt': block.prompt,
        'generation_pause': block.generationPause,
        'period': block.period,
        'keyword': block.keyword,
        'keyword_is_regex': block.keywordIsRegex,
        ...injection,
        'generation_order': _runOrderValue(block.generationOrder),
        'background': block.background,
        'apply_regex': block.applyRegex,
        'context': block.context
            .map(encodeUpstreamContextItem)
            .toList(growable: false),
        'api_preset': block.apiPreset.id,
      };
      if (type == 'rewrite') {
        generated['rewrite_mode'] =
            block.rewriteMode == RewriteMode.searchReplace
            ? 'search_replace'
            : 'full';
      }
      return generated;
  }
}
