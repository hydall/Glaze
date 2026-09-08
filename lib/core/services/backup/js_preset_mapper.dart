import 'dart:convert';
import 'dart:math';

import '../../models/preset.dart';
import '../../utils/id_generator.dart';
import '../preset_defaults.dart';
import 'type_converters.dart';

mixin JsPresetMapper on TypeConverters {
  void extractPresetsFromRaw(
      dynamic raw, List<Map<String, dynamic>> presets) {
    if (raw is List) {
      for (final p in raw) {
        if (p is Map<String, dynamic>) presets.add(p);
      }
    } else if (raw is Map<String, dynamic>) {
      if (raw.containsKey('id') && raw.containsKey('endpoint')) {
        presets.add(raw);
      } else {
        for (final p in raw.values) {
          if (p is Map<String, dynamic>) presets.add(p);
        }
      }
    } else if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        extractPresetsFromRaw(decoded, presets);
      } catch (_) {}
    }
  }

  Preset mapJsPreset(Map<String, dynamic> json) {
    final blocks = <PresetBlock>[];
    final rawBlocks = json['blocks'] ?? json['prompt_order'];
    if (rawBlocks is List) {
      for (final b in rawBlocks) {
        if (b is! Map<String, dynamic>) continue;
        final normalized = Map<String, dynamic>.from(b);
        if (!normalized.containsKey('id')) normalized['id'] = generateBackupId();
        if (!normalized.containsKey('insertionMode')) {
          normalized['insertionMode'] = b['insertion_mode'] ?? 'relative';
        }
        blocks.add(PresetBlock.fromJson(normalized));
      }
    }

    final regexes = <PresetRegex>[];
    final rawRegexes = json['regexes'] ?? json['regex_scripts'];
    if (rawRegexes is List) {
      for (final r in rawRegexes) {
        if (r is! Map<String, dynamic>) continue;
        final normalized = Map<String, dynamic>.from(r);
        if (!normalized.containsKey('id')) normalized['id'] = generateBackupId();
        if (!normalized.containsKey('name')) normalized['name'] = r['scriptName'] ?? '';
        if (!normalized.containsKey('regex')) normalized['regex'] = r['findRegex'] ?? '';
        if (!normalized.containsKey('replacement')) normalized['replacement'] = r['replaceString'] ?? '';
        if (!normalized.containsKey('trimOut')) normalized['trimOut'] = joinTrimStrings(r['trimStrings']);
        if (r['isEnabled'] is bool) {
          normalized['disabled'] = !(r['isEnabled'] as bool);
        }
        // ST compatibility flags (accept both camelCase and snake_case variants)
        if (!normalized.containsKey('markdownOnly')) {
          normalized['markdownOnly'] = r['markdownOnly'] ?? r['markdown_only'] ?? false;
        }
        if (!normalized.containsKey('promptOnly')) {
          normalized['promptOnly'] = r['promptOnly'] ?? r['prompt_only'] ?? false;
        }
        if (!normalized.containsKey('runOnEdit')) {
          normalized['runOnEdit'] = r['runOnEdit'] ?? false;
        }
        if (!normalized.containsKey('substituteRegex')) {
          normalized['substituteRegex'] = r['substituteRegex'] ?? r['substitute_regex'] ?? 0;
        }
        if (!normalized.containsKey('minDepth') && r.containsKey('minDepth')) {
          normalized['minDepth'] = r['minDepth'];
        }
        if (!normalized.containsKey('maxDepth') && r.containsKey('maxDepth')) {
          normalized['maxDepth'] = r['maxDepth'];
        }
        regexes.add(PresetRegex.fromJson(normalized));
      }
    }

    return finalizeImportedPreset(Preset(
      id: json['id'] as String? ?? generateBackupId(),
      name: json['name'] as String? ?? 'Imported',
      author: json['author'] as String?,
      blocks: blocks,
      regexes: regexes,
      reasoningEnabled: json['reasoningEnabled'] as bool? ?? false,
      reasoningStart: json['reasoningStart'] as String?,
      reasoningEnd: json['reasoningEnd'] as String?,
      guidedGenerationPrompt: json['guidedGenerationPrompt'] as String?,
      guidedImpersonationPrompt: json['guidedImpersonationPrompt'] as String?,
      impersonationPrompt:
          json['impersonationPrompt'] as String? ??
          json['impersonation_prompt'] as String?,
      summaryPrompt: json['summaryPrompt'] as String?,
      mergePrompts: json['mergePrompts'] as bool? ?? false,
      mergeRole: json['mergeRole'] as String? ?? 'system',
      createdAt: toInt(json['createdAt']) ?? 0,
    ));
  }

  String extractReasoningEffort(Map<String, dynamic> preset) {
    final tags = preset['reasoningTags'] as Map<String, dynamic>?;
    if (tags != null) {
      final effort = tags['effort'] as String?;
      if (effort != null) return effort;
    }
    return 'medium';
  }

  String generateBackupId() {
    return generateId() + Random().nextInt(9999).toRadixString(36);
  }
}
