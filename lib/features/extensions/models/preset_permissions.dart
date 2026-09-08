import 'package:freezed_annotation/freezed_annotation.dart';

part 'preset_permissions.freezed.dart';
part 'preset_permissions.g.dart';

/// What an extension preset is allowed to do.
///
/// Defaults are `false` (default-deny) for every capability. Users opt in
/// per-preset via the preset editor. The bridge service consults this
/// set before dispatching any side-effectful or potentially dangerous
/// method.
@freezed
abstract class PresetPermissions with _$PresetPermissions {
  const factory PresetPermissions({
    /// `glaze.getVariables` / `setVariables` / `deleteVariable` for
    /// the `chat` scope. Read-only scopes (character read) are
    /// always allowed.
    @Default(false) bool readChatVars,
    @Default(false) bool writeChatVars,
    @Default(false) bool deleteChatVars,

    /// `character` scope. Read/write/delete character-scoped
    /// variables.
    @Default(false) bool readCharacterVars,
    @Default(false) bool writeCharacterVars,
    @Default(false) bool deleteCharacterVars,

    /// `global` scope. Global variables are visible across
    /// characters and sessions, so this is the most dangerous
    /// scope.
    @Default(false) bool readGlobalVars,
    @Default(false) bool writeGlobalVars,
    @Default(false) bool deleteGlobalVars,

    /// `message` scope. Per-message variables; still default-deny
    /// because they may persist forever (no TTL by default).
    @Default(false) bool readMessageVars,
    @Default(false) bool writeMessageVars,
    @Default(false) bool deleteMessageVars,

    /// `glaze.generateText` — secondary LLM call.
    @Default(false) bool generateText,

    /// `glaze.triggerGeneration` — start a new chat generation.
    @Default(false) bool triggerGeneration,

    /// `glaze.injectPrompt` / `uninjectPrompt` — runtime prompt
    /// injection. Treated as separate capabilities because the
    /// risk profile is different from `setVariables`.
    @Default(false) bool injectPrompt,
    @Default(false) bool uninjectPrompt,

    /// `glaze.playAudio` — play sound. Default-deny so a
    /// silent extension cannot surprise the user.
    @Default(false) bool playAudio,

    /// `glaze.executeCommand` — slash-command execution. Always
    /// audited (logged with reason if provided).
    @Default(false) bool executeCommand,

    /// `glaze.showToast` — show a toast message. Default ALLOW
    /// (toasts are non-destructive).
    @Default(true) bool showToast,
  }) = _PresetPermissions;

  factory PresetPermissions.fromJson(Map<String, dynamic> json) =>
      _$PresetPermissionsFromJson(json);
}

/// All capabilities exposed by `window.glaze.*`. Used for
/// permission-checking and for the editor UI.
enum GlazeCapability {
  readChatVars('read_chat_vars', 'Read chat variables'),
  writeChatVars('write_chat_vars', 'Write chat variables'),
  deleteChatVars('delete_chat_vars', 'Delete chat variables'),
  readCharacterVars('read_character_vars', 'Read character variables'),
  writeCharacterVars('write_character_vars', 'Write character variables'),
  deleteCharacterVars('delete_character_vars', 'Delete character variables'),
  readGlobalVars('read_global_vars', 'Read global variables'),
  writeGlobalVars('write_global_vars', 'Write global variables'),
  deleteGlobalVars('delete_global_vars', 'Delete global variables'),
  readMessageVars('read_message_vars', 'Read message variables'),
  writeMessageVars('write_message_vars', 'Write message variables'),
  deleteMessageVars('delete_message_vars', 'Delete message variables'),
  generateText('generate_text', 'Call LLM (glaze.generateText)'),
  triggerGeneration('trigger_generation', 'Trigger a chat generation'),
  injectPrompt('inject_prompt', 'Inject a runtime prompt block'),
  uninjectPrompt('uninject_prompt', 'Remove an injected prompt block'),
  playAudio('play_audio', 'Play audio'),
  executeCommand('execute_command', 'Run a slash command'),
  showToast('show_toast', 'Show a toast');

  const GlazeCapability(this.id, this.label);
  final String id;
  final String label;
}

/// Map a [GlazeCapability] to the boolean field on [PresetPermissions].
extension PresetPermissionsCapability on PresetPermissions {
  bool isGranted(GlazeCapability capability) {
    switch (capability) {
      case GlazeCapability.readChatVars:
        return readChatVars;
      case GlazeCapability.writeChatVars:
        return writeChatVars;
      case GlazeCapability.deleteChatVars:
        return deleteChatVars;
      case GlazeCapability.readCharacterVars:
        return readCharacterVars;
      case GlazeCapability.writeCharacterVars:
        return writeCharacterVars;
      case GlazeCapability.deleteCharacterVars:
        return deleteCharacterVars;
      case GlazeCapability.readGlobalVars:
        return readGlobalVars;
      case GlazeCapability.writeGlobalVars:
        return writeGlobalVars;
      case GlazeCapability.deleteGlobalVars:
        return deleteGlobalVars;
      case GlazeCapability.readMessageVars:
        return readMessageVars;
      case GlazeCapability.writeMessageVars:
        return writeMessageVars;
      case GlazeCapability.deleteMessageVars:
        return deleteMessageVars;
      case GlazeCapability.generateText:
        return generateText;
      case GlazeCapability.triggerGeneration:
        return triggerGeneration;
      case GlazeCapability.injectPrompt:
        return injectPrompt;
      case GlazeCapability.uninjectPrompt:
        return uninjectPrompt;
      case GlazeCapability.playAudio:
        return playAudio;
      case GlazeCapability.executeCommand:
        return executeCommand;
      case GlazeCapability.showToast:
        return showToast;
    }
  }

  /// Lookup by raw string id (matches [GlazeCapability.id]). Used by the
  /// bridge service which receives the id from JS.
  bool isGrantedById(String capabilityId) {
    for (final c in GlazeCapability.values) {
      if (c.id == capabilityId) return isGranted(c);
    }
    return false;
  }
}

/// Mutation helper: returns a copy with the boolean field matching
/// [capability] set to [value]. Used by the editor UI.
extension PresetPermissionsMutator on PresetPermissions {
  PresetPermissions copyWithField(GlazeCapability capability, bool value) {
    switch (capability) {
      case GlazeCapability.readChatVars:
        return copyWith(readChatVars: value);
      case GlazeCapability.writeChatVars:
        return copyWith(writeChatVars: value);
      case GlazeCapability.deleteChatVars:
        return copyWith(deleteChatVars: value);
      case GlazeCapability.readCharacterVars:
        return copyWith(readCharacterVars: value);
      case GlazeCapability.writeCharacterVars:
        return copyWith(writeCharacterVars: value);
      case GlazeCapability.deleteCharacterVars:
        return copyWith(deleteCharacterVars: value);
      case GlazeCapability.readGlobalVars:
        return copyWith(readGlobalVars: value);
      case GlazeCapability.writeGlobalVars:
        return copyWith(writeGlobalVars: value);
      case GlazeCapability.deleteGlobalVars:
        return copyWith(deleteGlobalVars: value);
      case GlazeCapability.readMessageVars:
        return copyWith(readMessageVars: value);
      case GlazeCapability.writeMessageVars:
        return copyWith(writeMessageVars: value);
      case GlazeCapability.deleteMessageVars:
        return copyWith(deleteMessageVars: value);
      case GlazeCapability.generateText:
        return copyWith(generateText: value);
      case GlazeCapability.triggerGeneration:
        return copyWith(triggerGeneration: value);
      case GlazeCapability.injectPrompt:
        return copyWith(injectPrompt: value);
      case GlazeCapability.uninjectPrompt:
        return copyWith(uninjectPrompt: value);
      case GlazeCapability.playAudio:
        return copyWith(playAudio: value);
      case GlazeCapability.executeCommand:
        return copyWith(executeCommand: value);
      case GlazeCapability.showToast:
        return copyWith(showToast: value);
    }
  }
}
