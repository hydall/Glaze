import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/regex_service.dart';
import 'package:glaze_flutter/core/models/preset.dart';

void main() {
  group('RegexService — ST compatibility (backrefs, flags, substituteRegex)', () {
    RegexApplyContext ctx() => const RegexApplyContext();

    test('Hide html: paired + self-closing tags removed (backrefs + dotAll)', () {
      final script = PresetRegex.fromJson({
        'id': 'hide-html-1',
        'scriptName': 'Hide html',
        'findRegex':
            r'/<([a-zA-Z0-9]+)(?:[^>]*)?>[\s\S]*?<\/\1>|<[a-zA-Z0-9]+(?:[^>]*)?\s*\/?>/g',
        'replaceString': '',
        'placement': [1, 2, 5],
        'isEnabled': true,
      });

      const input = 'See <div class="x">hello <b>world</b></div> and <br/> and <img src="a.png">';
      final out = applyRegexes(input, 2, 2, [script], ctx());

      expect(out, equals('See  and  and '));
    });

    test('Braille blank jb: space -> U+2800 (braille blank)', () {
      final script = PresetRegex.fromJson({
        'id': 'braille-blank',
        'scriptName': '[RM] ┌ braille blank jb',
        'findRegex': r'/ /g',
        'replaceString': '\u2800',
        'placement': [1, 2, 5],
        'isEnabled': true,
      });

      const input = 'hello world';
      final out = applyRegexes(input, 2, 2, [script], ctx());
      expect(out, equals('hello\u2800world'));
    });

    test('Reverse braille: U+2800 -> space', () {
      final script = PresetRegex.fromJson({
        'id': 'braille-reverse',
        'scriptName': 'Reverse braille',
        'findRegex': r'/\u2800/g',
        'replaceString': ' ',
        'placement': [1, 2, 5],
        'isEnabled': true,
      });

      const input = 'hello\u2800world';
      final out = applyRegexes(input, 2, 2, [script], ctx());
      expect(out, equals('hello world'));
    });

    test('ReplaceSpace with substituteRegex:1 — U+3164 (hangul filler) -> space', () {
      final script = PresetRegex.fromJson({
        'id': 'replace-space',
        'scriptName': 'ReplaceSpace',
        'findRegex': r'/ㅤ/g',
        'replaceString': ' ',
        'substituteRegex': 1,
        'placement': [1, 2, 5],
        'isEnabled': true,
      });

      const input = 'helloㅤworld';
      final out = applyRegexes(input, 2, 2, [script], ctx());
      expect(out, equals('hello world'));
    });

    test('markdownOnly applies only when isMarkdown is true', () {
      final script = PresetRegex.fromJson({
        'id': 'md-only',
        'name': 'MD only',
        'regex': r'/X/g',
        'replacement': 'Y',
        'markdownOnly': true,
        'placement': [1, 2],
      });

      const input = 'aXb';
      final prompt = applyRegexes(input, 1, 2, [script], ctx(), isPrompt: true);
      expect(prompt, equals('aXb'));

      final md = applyRegexes(input, 1, 2, [script], ctx(), isMarkdown: true);
      expect(md, equals('aYb'));
    });

    test('promptOnly applies only when isPrompt is true', () {
      final script = PresetRegex.fromJson({
        'id': 'prompt-only',
        'name': 'Prompt only',
        'regex': r'/X/g',
        'replacement': 'Y',
        'promptOnly': true,
        'placement': [1, 2],
      });

      const input = 'aXb';
      final hist = applyRegexes(input, 2, 2, [script], ctx());
      expect(hist, equals('aXb'));

      final prompt = applyRegexes(input, 4, 2, [script], ctx(), isPrompt: true);
      expect(prompt, equals('aYb'));
    });

    test('World Info placement 5 applies to lorebook blocks', () {
      final script = PresetRegex.fromJson({
        'id': 'wi-only',
        'name': 'WI',
        'regex': r'/foo/g',
        'replacement': 'bar',
        'placement': [5],
      });

      const input = 'foo';
      expect(applyRegexes(input, 4, 2, [script], ctx(), isPrompt: true), equals('foo'));
      expect(applyRegexes(input, 5, 2, [script], ctx(), isPrompt: true), equals('bar'));
    });

    test('{{match}} in replacement', () {
      final script = PresetRegex.fromJson({
        'id': 'match-ref',
        'name': 'wrap',
        'regex': r'/(\w+)/g',
        'replacement': '[{{match}}]',
        'placement': [2],
      });

      const input = 'hi';
      final out = applyRegexes(input, 2, 2, [script], ctx());
      expect(out, equals('[hi]'));
    });

    test('legacy placement 4 migrates to ST World Info (5)', () {
      final script = PresetRegex.fromJson({
        'id': 'legacy-wi',
        'name': 'legacy',
        'regex': r'/x/g',
        'replacement': 'Z',
        'placement': [4],
      });

      expect(script.placement, contains(5));
      const input = 'x';
      expect(applyRegexes(input, 5, 2, [script], ctx(), isPrompt: true), equals('Z'));
    });

    test('HEADER-style: multiline capture groups are resolved', () {
      // Simplified version of the real HEADER regex script
      final script = PresetRegex.fromJson({
        'id': 'header-test',
        'name': 'HEADER',
        'regex': r'/\[HEADER\]\s*name:\s*([^\n]+?)\s*status:\s*([^\n]+?)\s*\[\/HEADER\]/g',
        'replacement': r'<div>Name=$1 Status=$2</div>',
        'placement': [2],
      });

      const input = '[HEADER]\nname: Элай Марш\nstatus: idle\n[/HEADER]\nSome text.';
      final out = applyRegexes(input, 2, 2, [script], ctx());
      expect(out, equals('<div>Name=Элай Марш Status=idle</div>\nSome text.'));
    });

    test('BOOTS-style: single capture group resolved for script content', () {
      final script = PresetRegex.fromJson({
        'id': 'boots-test',
        'name': 'BOOTS',
        'regex': r'/\[BOOTS\]([\s\S]*?)\[\/BOOTS\]/g',
        'replacement': r'<div class="boots">$1</div>',
        'placement': [2],
      });

      const input = '[BOOTS]\ntitle: My Title\nreflection: deep thoughts\n[/BOOTS]';
      final out = applyRegexes(input, 2, 2, [script], ctx());
      expect(out, equals('<div class="boots">\ntitle: My Title\nreflection: deep thoughts\n</div>'));
    });

    test('backrefs work even with substituteRegex != 0', () {
      final script = PresetRegex.fromJson({
        'id': 'sub-backref',
        'name': 'sub-backref',
        'regex': r'/(hello) (world)/g',
        'replacement': r'$2 $1',
        'substituteRegex': 1,
        'placement': [2],
      });

      const input = 'hello world';
      final out = applyRegexes(input, 2, 2, [script], ctx());
      expect(out, equals('world hello'));
    });

    test('no replacement without backrefs still works', () {
      final script = PresetRegex.fromJson({
        'id': 'plain',
        'name': 'plain',
        'regex': r'/foo/g',
        'replacement': 'bar',
        'placement': [2],
      });

      const input = 'foo baz foo';
      final out = applyRegexes(input, 2, 2, [script], ctx());
      expect(out, equals('bar baz bar'));
    });

    test('double-digit capture groups 10+ are resolved correctly', () {
      // Ensure $10 is not eaten as $1 + "0"
      final script = PresetRegex.fromJson({
        'id': 'double-digit',
        'name': 'double-digit',
        'regex': r'/(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)/g',
        'replacement': r'$10-$11',
        'placement': [2],
      });

      const input = 'abcdefghijk';
      final out = applyRegexes(input, 2, 2, [script], ctx());
      // $10 = 'j', $11 = 'k'
      expect(out, equals('j-k'));
    });
  });
}
