import 'package:flutter/material.dart';

import '../../../core/models/api_config.dart';
import '../../../core/models/character.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/models/persona.dart';
import '../../../core/models/preset.dart';

/// Logical grouping of drawer items. Used only for sectioning the
/// "Add Action" sheet - the grid itself stays freely orderable.
enum MagicDrawerCategory { session, library, config, tools }

class MagicDrawerItemDef {
  final String id;
  final String label;
  final IconData icon;
  final MagicDrawerCategory category;

  const MagicDrawerItemDef({
    required this.id,
    required this.label,
    required this.icon,
    required this.category,
  });
}

class MagicDrawerCardItem {
  final MagicDrawerItemDef def;
  final String? status;
  final bool isAddButton;

  const MagicDrawerCardItem({
    required this.def,
    this.status,
    this.isAddButton = false,
  });
}

class MagicDrawerStats {
  final Character? character;
  final Preset? activePreset;
  final Persona? activePersona;
  final ApiConfig? apiConfig;
  final ChatSession? session;
  final int sessionCount;
  final int messageCount;
  final int lorebookEntryCount;
  final int memoryEntryCount;
  final int regexCount;
  final int summaryChars;
  final int promptTokens;
  final int approximateHistoryTokens;
  final int contextSize;
  final int characterTokens;
  final int presetTokens;
  final int personaTokens;
  final int summaryTokens;
  final int vectorLoreTokens;
  final int keywordLoreTokens;
  final bool imageGenEnabled;
  final List<Lorebook> lorebooks;
  final String? summaryContent;
  final String? memoryContent;
  final String? memoryMacroContent;
  final String memoryInjectionTarget;
  final Map<String, dynamic> memoryCoverage;
  final List<dynamic> triggeredMemories;
  final bool extBlocksEnabled;
  final String? extBlocksActivePresetName;

  const MagicDrawerStats({
    this.character,
    this.activePreset,
    this.activePersona,
    this.apiConfig,
    this.session,
    this.sessionCount = 0,
    this.messageCount = 0,
    this.lorebookEntryCount = 0,
    this.memoryEntryCount = 0,
    this.regexCount = 0,
    this.summaryChars = 0,
    this.promptTokens = 0,
    this.approximateHistoryTokens = 0,
    this.contextSize = 0,
    this.characterTokens = 0,
    this.presetTokens = 0,
    this.personaTokens = 0,
    this.summaryTokens = 0,
    this.vectorLoreTokens = 0,
    this.keywordLoreTokens = 0,
    this.imageGenEnabled = false,
    this.lorebooks = const [],
    this.summaryContent,
    this.memoryContent,
    this.memoryMacroContent,
    this.memoryInjectionTarget = 'hard_block',
    this.memoryCoverage = const {},
    this.triggeredMemories = const [],
    this.extBlocksEnabled = false,
    this.extBlocksActivePresetName,
  });

  MagicDrawerStats copyWith({
    int? promptTokens,
    int? approximateHistoryTokens,
    int? contextSize,
    int? characterTokens,
    int? presetTokens,
    int? personaTokens,
    int? summaryTokens,
    int? vectorLoreTokens,
    int? keywordLoreTokens,
  }) {
    return MagicDrawerStats(
      character: character,
      activePreset: activePreset,
      activePersona: activePersona,
      apiConfig: apiConfig,
      session: session,
      sessionCount: sessionCount,
      messageCount: messageCount,
      lorebookEntryCount: lorebookEntryCount,
      memoryEntryCount: memoryEntryCount,
      regexCount: regexCount,
      summaryChars: summaryChars,
      promptTokens: promptTokens ?? this.promptTokens,
      approximateHistoryTokens: approximateHistoryTokens ?? this.approximateHistoryTokens,
      contextSize: contextSize ?? this.contextSize,
      characterTokens: characterTokens ?? this.characterTokens,
      presetTokens: presetTokens ?? this.presetTokens,
      personaTokens: personaTokens ?? this.personaTokens,
      summaryTokens: summaryTokens ?? this.summaryTokens,
      vectorLoreTokens: vectorLoreTokens ?? this.vectorLoreTokens,
      keywordLoreTokens: keywordLoreTokens ?? this.keywordLoreTokens,
      imageGenEnabled: imageGenEnabled,
      lorebooks: lorebooks,
      summaryContent: summaryContent,
      memoryContent: memoryContent,
      memoryMacroContent: memoryMacroContent,
      memoryInjectionTarget: memoryInjectionTarget,
      memoryCoverage: memoryCoverage,
      triggeredMemories: triggeredMemories,
    );
  }
}
