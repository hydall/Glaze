/// A visual novel as it is stored: one chat session whose messages are the
/// player's idea followed by every pass the model wrote.
///
/// The session's character id carries [kVnCharacterIdPrefix] and points at no
/// character row; that prefix is what tells a novel from a chat everywhere
/// sessions are listed. Each generated message opens with an `@vn <pass>`
/// header, so the passes survive sync, backup and export as plain text.
///
/// Everything here is pure so it can be tested without a database or a model.
library;

import 'dart:convert';

import '../../../core/models/chat_message.dart';
import '../../../core/models/vn_session_id.dart';
import '../../../core/utils/id_generator.dart';

export '../../../core/models/vn_session_id.dart';

/// [ChatSession.sessionVars] key holding the engine's last snapshot (scene,
/// flags, `once` blocks, choices, inventory, journal, position) as JSON.
const String kVnStateVarKey = '__vnState';

/// [ChatSession.sessionVars] key holding the persona the novel was started
/// with, as `{name, description}` JSON. Copied, not referenced, so editing or
/// deleting the persona later does not rewrite the story's hero.
const String kVnPersonaVarKey = '__vnPersona';

/// [ChatSession.sessionVars] key holding a chapter written ahead of the
/// player: `{chapter, key, body}` JSON, see [vnPrefetchKey].
const String kVnPrefetchVarKey = '__vnPrefetch';

/// [ChatSession.sessionVars] key holding the sprites drawn for the cast:
/// `{castId: {emotion: path}}` JSON, paths relative to the app's data folder.
const String kVnSpritesVarKey = '__vnSprites';

/// [ChatSession.sessionVars] key set when the novel draws its cast with the
/// image provider; the value is the sheet size asked for (`2K`, `4K`).
/// Absent: the cast stays cardboard.
const String kVnArtVarKey = '__vnArt';

/// Sprite paths by cast id and emotion, read from the session.
Map<String, Map<String, String>> vnSpritesOf(Map<String, String> vars) {
  final json = vars[kVnSpritesVarKey];
  if (json == null || json.isEmpty) return {};
  try {
    final m = jsonDecode(json);
    if (m is! Map) return {};
    return {
      for (final e in m.entries)
        if (e.value is Map)
          '${e.key}': {
            for (final f in (e.value as Map).entries) '${f.key}': '${f.value}',
          },
    };
  } catch (_) {
    return {};
  }
}

/// A character as the script defines them.
class VnCastMember {
  const VnCastMember({
    required this.id,
    required this.name,
    this.color,
    this.about = '',
  });

  final String id;
  final String name;

  /// Hair color, `#rrggbb`.
  final String? color;

  /// The `about` line: role, personality, look.
  final String about;
}

/// Who the player is in the story.
class VnPersona {
  const VnPersona({required this.name, this.description = ''});

  final String name;
  final String description;

  Map<String, String> toJson() => {
    'name': name,
    if (description.isNotEmpty) 'description': description,
  };

  static VnPersona? fromSessionVars(Map<String, String> vars) {
    final json = vars[kVnPersonaVarKey];
    if (json == null || json.isEmpty) return null;
    try {
      final m = jsonDecode(json);
      if (m is! Map) return null;
      final name = '${m['name'] ?? ''}'.trim();
      if (name.isEmpty) return null;
      return VnPersona(
        name: name,
        description: '${m['description'] ?? ''}'.trim(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A novel is the only session of its pseudo-character.
({String characterId, String sessionId}) newVnIds() {
  final characterId = '$kVnCharacterIdPrefix${generateId()}';
  return (characterId: characterId, sessionId: '${characterId}_0');
}

/// The passes a novel is written in. The first four run once, in this order,
/// from the player's idea; chapters then follow one per `next`.
enum VnPass { scenario, characters, locations, textures, chapter }

const List<VnPass> kVnSetupPasses = [
  VnPass.scenario,
  VnPass.characters,
  VnPass.locations,
  VnPass.textures,
];

final RegExp _header = RegExp(r'^@vn\s+([a-z]+)(?:\s+(\d+))?\s*$');

String formatVnPass(VnPass pass, String body, {int chapter = 0}) {
  final header = pass == VnPass.chapter
      ? '@vn chapter $chapter'
      : '@vn ${pass.name}';
  return '$header\n${body.trim()}';
}

/// One stored pass, or null when [content] is not one.
({VnPass pass, int chapter, String body})? parseVnPass(String content) {
  final newline = content.indexOf('\n');
  final first = (newline < 0 ? content : content.substring(0, newline)).trim();
  final m = _header.firstMatch(first);
  if (m == null) return null;
  final pass = VnPass.values.where((p) => p.name == m.group(1)).firstOrNull;
  if (pass == null) return null;
  return (
    pass: pass,
    chapter: int.tryParse(m.group(2) ?? '') ?? 0,
    body: newline < 0 ? '' : content.substring(newline + 1).trim(),
  );
}

class VnChapter {
  const VnChapter({
    required this.number,
    required this.body,
    required this.summary,
    required this.opensOn,
  });

  final int number;

  /// The script of the chapter, without its summary line.
  final String body;

  /// What the model said the chapter covers; empty when it gave none.
  final String summary;

  /// The first scene of the chapter, where the player is taken when it lands.
  final String? opensOn;
}

final RegExp _summaryLine = RegExp(
  r'^\s*summary\s*:\s*(.*)$',
  caseSensitive: false,
);
final RegExp _sceneHeader = RegExp(r'^\s*#\s*([\p{L}\p{N}_]+)', unicode: true);

VnChapter parseVnChapter(int number, String body) {
  var summary = '';
  String? opensOn;
  final kept = <String>[];
  for (final line in const LineSplitter().convert(body)) {
    final s = _summaryLine.firstMatch(line);
    if (s != null && opensOn == null) {
      summary = s.group(1)!.trim();
      continue;
    }
    opensOn ??= _sceneHeader.firstMatch(line)?.group(1);
    kept.add(line);
  }
  return VnChapter(
    number: number,
    body: kept.join('\n').trim(),
    summary: summary,
    opensOn: opensOn,
  );
}

/// The novel read back from its session's messages.
class VnDocument {
  const VnDocument({
    required this.premise,
    required this.setup,
    required this.chapters,
  });

  factory VnDocument.fromMessages(List<ChatMessage> messages) {
    var premise = '';
    final setup = <VnPass, String>{};
    final chapters = <int, VnChapter>{};
    for (final m in messages) {
      if (m.role == 'user') {
        if (premise.isEmpty) premise = m.content.trim();
        continue;
      }
      final pass = parseVnPass(m.content);
      if (pass == null) continue;
      if (pass.pass == VnPass.chapter) {
        chapters[pass.chapter] = parseVnChapter(pass.chapter, pass.body);
      } else {
        setup[pass.pass] = pass.body;
      }
    }
    final ordered = chapters.values.toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    return VnDocument(premise: premise, setup: setup, chapters: ordered);
  }

  /// The player's idea the novel was started from.
  final String premise;

  /// The bodies of the setup passes written so far.
  final Map<VnPass, String> setup;

  final List<VnChapter> chapters;

  /// The pass to write next before the novel can be played, or null once the
  /// setup and the first chapter exist. Later chapters are asked for by the
  /// engine's `next`.
  VnPass? get pendingPass {
    for (final pass in kVnSetupPasses) {
      if (!setup.containsKey(pass)) return pass;
    }
    return chapters.isEmpty ? VnPass.chapter : null;
  }

  bool get playable => pendingPass == null;

  int get nextChapterNumber => chapters.isEmpty ? 1 : chapters.last.number + 1;

  /// The `title:` line of the scenario, or null before it is written.
  String? get title {
    final scenario = setup[VnPass.scenario];
    if (scenario == null) return null;
    for (final line in const LineSplitter().convert(scenario)) {
      final m = RegExp(
        r'^\s*title\s*:\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(line);
      if (m != null) return m.group(1)!.trim();
    }
    return null;
  }

  /// What the engine plays: definitions, then every chapter. `---` keeps a
  /// stray line at the head of one part from landing in the previous scene.
  String get script => [
    setup[VnPass.characters],
    setup[VnPass.textures],
    setup[VnPass.locations],
    for (final c in chapters) c.body,
  ].whereType<String>().where((s) => s.isNotEmpty).join('\n---\n');

  /// Texture ids the locations name for a floor or a wall, in order of first
  /// use. The textures pass is asked to define exactly these.
  List<String> get referencedTextures {
    final locations = setup[VnPass.locations] ?? '';
    final ids = <String>{};
    for (final m in RegExp(
      r'\b(?:floor|wall)\s+([\p{L}\p{N}_]+)',
      unicode: true,
    ).allMatches(locations)) {
      final id = m.group(1)!;
      if (id.toLowerCase() != 'none') ids.add(id);
    }
    return ids.toList();
  }

  /// Every definition in the whole script, chapters included, in one compact
  /// block: the model sees who and what exists without rereading old parts.
  String get definitions {
    final out = <String>[];
    final lines = const LineSplitter().convert(script);
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i].trim();
      if (l.startsWith('cast ') ||
          l.startsWith('about ') ||
          l.startsWith('item ') ||
          l.startsWith('texture ')) {
        out.add(l);
      } else if (l.startsWith('location ')) {
        out.add(l);
        // The room line says how big the place is and what it is made of.
        for (var j = i + 1; j < lines.length && j < i + 4; j++) {
          final next = lines[j].trim();
          if (next.startsWith('room ')) out.add('  $next');
        }
      }
    }
    return out.join('\n');
  }

  /// Items defined anywhere in the script, by id: their names and what they
  /// are, for the status window.
  Map<String, ({String name, String description})> get items {
    final out = <String, ({String name, String description})>{};
    for (final m in RegExp(
      r'^\s*item\s+([\p{L}\p{N}_]+)\s+"([^"]+)"(?:\s+(.+))?$',
      multiLine: true,
      unicode: true,
    ).allMatches(script)) {
      out[m.group(1)!] = (
        name: m.group(2)!,
        description: (m.group(3) ?? '').trim(),
      );
    }
    return out;
  }

  /// Every character the script defines, by id, in order of definition. A
  /// later `cast` or `about` line for the same id replaces the earlier one.
  Map<String, VnCastMember> get cast {
    final names = <String, ({String name, String? color})>{};
    final about = <String, String>{};
    for (final line in const LineSplitter().convert(script)) {
      final c = RegExp(
        r'^\s*cast\s+([\p{L}\p{N}_]+)\s+"([^"]+)"(?:\s+(#[0-9a-fA-F]{3,6}))?',
        unicode: true,
      ).firstMatch(line);
      if (c != null) {
        names[c.group(1)!] = (name: c.group(2)!, color: c.group(3));
        continue;
      }
      final a = RegExp(
        r'^\s*about\s+([\p{L}\p{N}_]+)\s*:\s*(.+)$',
        unicode: true,
      ).firstMatch(line);
      if (a != null) about[a.group(1)!] = a.group(2)!.trim();
    }
    return {
      for (final e in names.entries)
        e.key: VnCastMember(
          id: e.key,
          name: e.value.name,
          color: e.value.color,
          about: about[e.key] ?? '',
        ),
    };
  }

  /// Scene ids used so far, so a new chapter does not reuse one.
  List<String> get sceneIds => [
    for (final m in RegExp(
      r'^\s*#\s*([\p{L}\p{N}_]+)',
      multiLine: true,
      unicode: true,
    ).allMatches(script))
      m.group(1)!,
  ];
}

/// What the engine reported last: where the player is and what they did.
class VnPlayState {
  const VnPlayState(this.raw);

  /// Null when the session holds no state or it does not decode.
  static VnPlayState? fromSessionVars(Map<String, String> vars) {
    final json = vars[kVnStateVarKey];
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) return VnPlayState(decoded);
    } catch (_) {}
    return null;
  }

  final Map<String, dynamic> raw;

  String? get scene => raw['scene'] as String?;

  List<String> get flags => [
    for (final f in (raw['flags'] as List?) ?? const []) '$f',
  ];

  /// Item ids carried, in the order they were received.
  List<String> get inventory => [
    for (final i in (raw['inv'] as List?) ?? const []) '$i',
  ];

  /// What the player read, oldest first.
  List<VnJournalEntry> get journal => [
    for (final e in (raw['backlog'] as List?) ?? const [])
      if (e is Map)
        VnJournalEntry(
          kind: '${e['k'] ?? ''}',
          who: e['who'] == null ? null : '${e['who']}',
          text: '${e['text'] ?? ''}',
        ),
  ];

  /// The `next` hints of the scene the player is in, when the host asked for
  /// a chapter ahead of them.
  List<String> get exits => [
    for (final e in (raw['exits'] as List?) ?? const []) '$e',
  ];

  /// Choices made, oldest first, as `scene: choice` lines.
  List<String> get choices => [
    for (final e in (raw['log'] as List?) ?? const [])
      if (e is Map) '${e['scene'] ?? '?'}: ${e['choice'] ?? ''}',
  ];

  /// The `next` the player reached, if the engine has not been given the
  /// part that answers it. [part] is how many chapters existed when it was
  /// reached.
  ({String scene, String hint, int part})? get pendingNext {
    final next = raw['next'];
    if (next is! Map) return null;
    return (
      scene: '${next['scene'] ?? ''}',
      hint: '${next['hint'] ?? ''}',
      part: (next['part'] as num?)?.toInt() ?? 0,
    );
  }
}

/// One line of the journal: a scene entered, a line read, a choice, an item.
class VnJournalEntry {
  const VnJournalEntry({required this.kind, this.who, required this.text});

  /// `scene`, `narr`, `say`, `choice` or `item`.
  final String kind;
  final String? who;
  final String text;
}

/// What a chapter written ahead depends on. A chapter is written from the
/// flags, the inventory and the choices; when any of them differs at the
/// `next`, the chapter written ahead no longer follows from the game.
String vnPrefetchKey(VnPlayState play) => jsonEncode({
  'flags': [...play.flags]..sort(),
  'inv': [...play.inventory]..sort(),
  'choices': play.choices,
});

/// The snapshot to reopen [doc] from, or null to start at its first scene.
///
/// A `next` whose chapter was written while the novel was closed is answered
/// here: the player starts that chapter's first scene, intro included.
Map<String, dynamic>? resumeSnapshot(VnDocument doc, VnPlayState? play) {
  if (play == null) return null;
  final raw = Map<String, dynamic>.of(play.raw);
  final next = play.pendingNext;
  if (next != null && next.part < doc.chapters.length) {
    raw
      ..remove('next')
      ..remove('pos')
      ..['scene'] = doc.chapters[next.part].opensOn;
  }
  return raw;
}

/// The chat-list line for a novel's newest message.
({VnPass? pass, int chapter, String summary}) vnPreviewOf(String content) {
  final pass = parseVnPass(content);
  if (pass == null) return (pass: null, chapter: 0, summary: '');
  if (pass.pass != VnPass.chapter) {
    return (pass: pass.pass, chapter: 0, summary: '');
  }
  final chapter = parseVnChapter(pass.chapter, pass.body);
  return (
    pass: VnPass.chapter,
    chapter: pass.chapter,
    summary: chapter.summary,
  );
}
