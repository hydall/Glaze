import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'character_tool_proposal.dart';

/// A set of tools switched on or off together on a connection
/// (`ApiConfig.disabledToolGroups`). Reading the library has no group of its
/// own: it is offered whenever a group that changes the library is.
enum ModelToolGroup {
  charactersCreate('characters_create'),
  charactersEdit('characters_edit');

  const ModelToolGroup(this.id);

  final String id;
}

/// A failed call, reported back to the model rather than thrown at the
/// generation. [code] is stable; [message] is for the model to read.
class ModelToolError implements Exception {
  const ModelToolError(this.code, this.message, {this.details});

  final String code;
  final String message;
  final Map<String, Object?>? details;

  static ModelToolError invalid(String path, String expected, Object? actual) =>
      ModelToolError(
        'invalid_arguments',
        '$path must be $expected',
        details: {
          'path': path,
          'expected': expected,
          'actualType': actual == null ? 'null' : actual.runtimeType.toString(),
        },
      );

  @override
  String toString() => 'ModelToolError($code: $message)';
}

/// Asks the user to approve a library write: true only on an explicit yes,
/// false when they decline or dismiss, null when there was no way to ask.
typedef ConfirmCharacterProposal =
    Future<bool?> Function(CharacterToolProposal proposal);

/// What a tool may reach while it runs: the app, the chat that started the
/// reply, and the user — for confirmation only.
class ModelToolContext {
  const ModelToolContext({
    required this.ref,
    required this.charId,
    required this.isAborted,
    required this.confirm,
  });

  final Ref ref;

  /// The character whose chat is generating — "the current character".
  final String charId;
  final bool Function() isAborted;
  final ConfirmCharacterProposal confirm;
}

/// One function the chat model may call.
abstract class ModelTool {
  const ModelTool();

  String get name;

  /// Null for read-only tools, which ride along with any enabled group.
  ModelToolGroup? get group;

  String get description;

  /// JSON Schema of the arguments object.
  Map<String, dynamic> get parameters;

  /// Runs the call. Throws [ModelToolError] for anything the model should be
  /// told about; the returned value is JSON-encoded as the result.
  Future<Object?> run(ModelToolContext context, Map<String, dynamic> arguments);

  /// Chat Completions `tools[]` entry; other protocols convert from this.
  Map<String, dynamic> get definition => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}
