import '../../../extensions/services/generation_dispatcher.dart';
import '../../../extensions/models/trigger_result.dart';
import '../../models/plugin_manifest.dart';
import '../plugin_api.dart';

/// `glaze.commands.run('/cmd args | /cmd2 {{pipe}}')`: a small set of
/// SillyTavern-style slash commands. Each command's output is available to
/// the next one as `{{pipe}}`; the last output is returned.
///
/// `/send text` (user message, no reply), `/sendas text` (character message),
/// `/trigger` (generate a reply), `/echo text` (toast), `/gen prompt`,
/// `/setvar key=name value`, `/getvar name`, `/flushvar name`.
Map<String, PluginMethod> commandsApi() => {
  'commands.run': const PluginMethod(_run),
};

typedef _Command = Future<String> Function(PluginCall c, String args);

final Map<String, ({String? permission, _Command run})> _commands = {
  'send': (permission: PluginPermission.messages, run: _messageAs('user')),
  'sendas': (
    permission: PluginPermission.messages,
    run: _messageAs('assistant'),
  ),
  'trigger': (permission: PluginPermission.generate, run: _trigger),
  'echo': (
    permission: null,
    run: (c, args) async {
      c.host.ui.toast(c.pluginName, args);
      return args;
    },
  ),
  'gen': (
    permission: PluginPermission.generate,
    run: (c, args) async => '${await c.invoke('generate', [args])}',
  ),
  'setvar': (permission: PluginPermission.variables, run: _setVar),
  'getvar': (
    permission: PluginPermission.variables,
    run: (c, args) async =>
        '${await c.invoke('variables.get', [args.trim()]) ?? ''}',
  ),
  'flushvar': (
    permission: PluginPermission.variables,
    run: (c, args) async {
      await c.invoke('variables.delete', [args.trim()]);
      return '';
    },
  ),
};

_Command _messageAs(String role) => (c, args) async {
  final id = await c.invoke('messages.add', [
    {'content': args, 'role': role},
  ]);
  return '$id';
};

Future<String> _trigger(PluginCall c, String args) async {
  final result = await c.ref
      .read(generationDispatcherProvider)
      .dispatch(charId: c.host.charId, rawMode: 'auto', reason: 'plugin');
  if (result is! TriggerAccepted) {
    throw const PluginApiError('busy', 'A reply cannot be started now');
  }
  return '';
}

Future<String> _setVar(PluginCall c, String args) async {
  final match = RegExp(r'^key=(\S+)\s*([\s\S]*)$').firstMatch(args.trim());
  if (match == null) {
    throw const PluginApiError(
      'invalid_arguments',
      'Use /setvar key=name value',
    );
  }
  await c.invoke('variables.set', [match.group(1), match.group(2)]);
  return match.group(2)!;
}

Future<Object?> _run(PluginCall c) async {
  final script = c.requireString(0, 'command');
  var pipe = '';
  for (final raw in script.split(RegExp(r'\s\|\s'))) {
    final text = raw.trim().replaceAll('{{pipe}}', pipe);
    if (text.isEmpty) continue;
    final match = RegExp(r'^/(\w+)\s*([\s\S]*)$').firstMatch(text);
    final command = match == null ? null : _commands[match.group(1)!];
    if (command == null) {
      throw PluginApiError('unknown_command', 'Unknown command: $text');
    }
    if (command.permission case final p?) await c.require(p);
    pipe = await command.run(c, match!.group(2)!);
  }
  return pipe;
}
