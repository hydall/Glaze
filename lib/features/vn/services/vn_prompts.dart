/// The requests for each pass of a novel and the checks on what comes back.
///
/// Every request is the script-language spec as the system message and one
/// user message ordered from what never changes to what changes most: the
/// idea, the written setup, the story so far, where the player is, the task.
library;

import '../models/vn_document.dart';
import 'vn_script.dart';

String _section(String title, String? body) {
  final text = body?.trim() ?? '';
  return text.isEmpty ? '' : '$title\n$text\n\n';
}

String _task(VnPass pass, VnDocument doc) => switch (pass) {
  VnPass.scenario =>
    'TASK: write the SCENARIO of a long, open-ended story from the idea. '
        'Plain text, no script commands. First line: `title: <short title>`. '
        'Then: genre and tone; the setting; who the player is (THE PLAYER '
        'above when given; seen in first person, never shown); the central '
        'conflict or mystery; 4 to 6 arcs '
        'the story can grow through; 3 threads to pull on early. The story '
        'must be able to go on for many parts and branch on the player\'s '
        'choices.',
  VnPass.characters =>
    'TASK: write the CHARACTERS of the scenario: 3 to 6 people. For each, '
        'two lines: `cast ID "Name" #haircolor`, then `about ID: role, '
        'personality, look, what they want, a secret`. Nothing else.',
  VnPass.locations =>
    'TASK: write the LOCATIONS the first arcs need: 3 to 5 `location` '
        'blocks with room, light, spawn and props, each with something to '
        'tap. No @scene links: scenes add their own doors. Give floors and '
        'walls texture ids (e.g. `floor oak_boards wall cream_plaster`); '
        'they are defined in the next step.',
  VnPass.textures => () {
    final ids = doc.referencedTextures;
    final list = ids.isEmpty ? '(none yet)' : ids.join(', ');
    return 'TASK: write the TEXTURES. One `texture` line for each id the '
        'locations use: $list. You may add a few more the story will need '
        'later. Nothing else.';
  }(),
  VnPass.chapter =>
    doc.chapters.isEmpty
        ? 'TASK: write PART 1, the opening: 2 to 4 scenes. First line: '
              '`summary: <one or two sentences on what this part covers>`. '
              'Then, if the part needs them, new cast, about, texture or '
              'location lines. Then the scenes (`# id < location`) with '
              'doors (`prop door x,z,deg @scene`) between them. Introduce the '
              'setting and pull on a thread. Choices set flags that matter '
              'later; give the player an item worth carrying. Characters '
              'know the player as THE PLAYER describes them. Every path ends '
              'at `next <where the story goes>`.'
        : 'TASK: write PART ${doc.nextChapterNumber}, continuing exactly '
              'from where the player stopped: 2 to 4 new scenes, the first '
              'one where the player arrives now. First line: `summary: <one '
              'or two sentences>`. Then any new cast, about, texture or '
              'location lines the part needs, and `item` lines for new '
              'items. Follow from the choices, flags and inventory above, '
              'keep characters consistent, move an arc forward and do not '
              'repeat what already happened. Every path ends at `next <where '
              'the story goes>`.',
};

/// The request for [pass] of [doc].
///
/// [state] is the engine's snapshot when a chapter is asked for: at a `next`,
/// or ahead of it with the scene's `exits`. [persona] is who the player is.
List<Map<String, String>> buildVnPassMessages({
  required String spec,
  required VnDocument doc,
  required VnPass pass,
  required String language,
  VnPlayState? state,
  VnPersona? persona,
}) {
  final buffer = StringBuffer()
    ..write(
      _section(
        'IDEA',
        doc.premise.isEmpty ? 'Free choice: surprise the player.' : doc.premise,
      ),
    )
    ..write(
      _section(
        'THE PLAYER',
        persona == null
            ? null
            : [
                'Name: ${persona.name}',
                if (persona.description.isNotEmpty)
                  persona.description.replaceAll(
                    RegExp(r'\{\{user\}\}', caseSensitive: false),
                    persona.name,
                  ),
              ].join('\n'),
      ),
    )
    ..write(_section('SCENARIO', doc.setup[VnPass.scenario]));

  if (pass == VnPass.chapter && doc.chapters.isNotEmpty) {
    // Old parts shrink to their summaries; definitions from every part are
    // kept whole so no one and nothing is forgotten.
    buffer
      ..write(_section('DEFINED SO FAR', doc.definitions))
      ..write(
        _section(
          'STORY SO FAR',
          [
            for (final c in doc.chapters)
              'Part ${c.number}: ${c.summary.isEmpty ? '…' : c.summary}',
          ].join('\n'),
        ),
      )
      ..write(
        _section(
          'LAST PART (${doc.chapters.last.number})',
          doc.chapters.last.body,
        ),
      )
      ..write(_section('SCENE IDS ALREADY USED', doc.sceneIds.join(' ')));
    final next = state?.pendingNext;
    final exits = state?.exits ?? const <String>[];
    final items = doc.items;
    final carried = [
      for (final id in state?.inventory ?? const <String>[])
        items[id] == null ? id : '$id (${items[id]!.name})',
    ];
    final lines = <String>[
      if (next != null) 'The player is in scene ${next.scene}.',
      if (next != null && next.hint.isNotEmpty)
        'The last part ended with: ${next.hint}',
      if (next == null && state?.scene != null)
        'The player is in scene ${state!.scene}, where the last part ends.',
      if (next == null && exits.any((e) => e.isNotEmpty))
        'It ends at one of: ${exits.where((e) => e.isNotEmpty).join(' / ')}',
      'Flags set: ${(state?.flags ?? const []).join(' ').ifEmpty('none')}',
      'Inventory: ${carried.join(', ').ifEmpty('empty')}',
      if ((state?.choices ?? const []).isNotEmpty)
        'Choices made, oldest first:',
      ...?state?.choices.map((c) => '- $c'),
    ];
    // The last lines read keep the voice and the moment continuous.
    final journal = state?.journal ?? const <VnJournalEntry>[];
    buffer
      ..write(
        _section(
          'LAST LINES THE PLAYER READ',
          [
            for (final e in journal.skip(
              journal.length > 25 ? journal.length - 25 : 0,
            ))
              switch (e.kind) {
                'say' => '${e.who}: ${e.text}',
                'choice' => '(chose) ${e.text}',
                'scene' => '[${e.text}]',
                _ => e.text,
              },
          ].join('\n'),
        ),
      )
      ..write(_section('WHERE THE PLAYER IS', lines.join('\n')));
  } else {
    if (pass.index > VnPass.characters.index) {
      buffer.write(_section('CHARACTERS', doc.setup[VnPass.characters]));
    }
    if (pass.index > VnPass.locations.index) {
      buffer.write(_section('LOCATIONS', doc.setup[VnPass.locations]));
    }
    if (pass.index > VnPass.textures.index) {
      buffer.write(_section('TEXTURES', doc.setup[VnPass.textures]));
    }
  }

  buffer
    ..write(_task(pass, doc))
    ..write(
      '\nAll titles, names, lines, narration and notes in $language. '
      'Commands, KIND and TYPE words and colors stay as in the spec.',
    );
  return [
    {'role': 'system', 'content': spec.trim()},
    {'role': 'user', 'content': buffer.toString()},
  ];
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

final RegExp _castLine = RegExp(r'^\s*cast\s+\S+\s+"', multiLine: true);
final RegExp _locationLine = RegExp(r'^\s*location\s+\S+', multiLine: true);
final RegExp _textureLine = RegExp(r'^\s*texture\s+\S+', multiLine: true);
final RegExp _sceneLine = RegExp(r'^\s*#\s*\S', multiLine: true);
final RegExp _endLine = RegExp(r'^(\s*)end\s*$', multiLine: true);
final RegExp _nextLine = RegExp(r'^\s*next\b', multiLine: true);

/// The body of [pass] inside a model [reply], or null when the reply does
/// not hold one.
///
/// A chapter is made to continue: an `end` becomes a `next`, and a chapter
/// with no `next` at all gets one after its last line.
String? extractVnPass(VnPass pass, String reply) {
  final text = cleanVnReply(reply);
  if (text.isEmpty) return null;
  switch (pass) {
    case VnPass.scenario:
      return text;
    case VnPass.characters:
      return _castLine.hasMatch(text) ? text : null;
    case VnPass.locations:
      return _locationLine.hasMatch(text) ? text : null;
    case VnPass.textures:
      return _textureLine.hasMatch(text) ? text : null;
    case VnPass.chapter:
      if (!_sceneLine.hasMatch(text)) return null;
      final continued = text.replaceAllMapped(_endLine, (m) => '${m[1]}next');
      return _nextLine.hasMatch(continued) ? continued : '$continued\nnext';
  }
}
