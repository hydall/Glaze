import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/beauty_state_parser.dart';

void main() {
  group('parseBeautyState', () {
    test('no marker — returns text untouched, stateJson null', () {
      const text = 'Just a normal roleplay response.\nNo marker here.';
      final result = parseBeautyState(text);
      expect(result.markerFound, isFalse);
      expect(result.stateJson, isNull);
      expect(result.cleanedText, text);
    });

    test('empty string — no marker, empty cleaned text', () {
      final result = parseBeautyState('');
      expect(result.markerFound, isFalse);
      expect(result.stateJson, isNull);
      expect(result.cleanedText, '');
    });

    test('well-formed marker — state extracted, tag stripped', () {
      final state = {
        'speakers': {'Alice': '#abc123'},
        'bg': '#1a1a1a',
      };
      final text =
          'Narrative response here.\n\n'
          '<glaze_beauty_state>${jsonEncode(state)}</glaze_beauty_state>';
      final result = parseBeautyState(text);
      expect(result.markerFound, isTrue);
      expect(result.cleanedText, 'Narrative response here.');
      final decoded = jsonDecode(result.stateJson!) as Map<String, dynamic>;
      expect(decoded['speakers'], {'Alice': '#abc123'});
      expect(decoded['bg'], '#1a1a1a');
    });

    test('multiple markers — LAST one wins', () {
      final first = {
        'speakers': {'Alice': '#aaa'},
      };
      final second = {
        'speakers': {'Alice': '#bbb', 'Bob': '#ccc'},
      };
      final text =
          '<glaze_beauty_state>${jsonEncode(first)}</glaze_beauty_state>'
          ' narrative '
          '<glaze_beauty_state>${jsonEncode(second)}</glaze_beauty_state>';
      final result = parseBeautyState(text);
      expect(result.markerFound, isTrue);
      final decoded = jsonDecode(result.stateJson!) as Map<String, dynamic>;
      expect(decoded['speakers'], {'Alice': '#bbb', 'Bob': '#ccc'});
      expect(result.cleanedText, 'narrative');
    });

    test('marker with whitespace body — stateJson null, tag stripped', () {
      const text = 'narrative\n<glaze_beauty_state>   </glaze_beauty_state>';
      final result = parseBeautyState(text);
      expect(result.markerFound, isTrue);
      expect(result.stateJson, isNull);
      expect(result.cleanedText, 'narrative');
    });

    test('malformed JSON inside marker — stateJson null, tag stripped', () {
      const text =
          'narrative\n<glaze_beauty_state>{not valid json</glaze_beauty_state>';
      final result = parseBeautyState(text);
      expect(result.markerFound, isTrue);
      expect(result.stateJson, isNull);
      expect(result.cleanedText, 'narrative');
    });

    test('JSON with trailing comma — repaired by repairJson, state parsed', () {
      const body = '{"speakers": {"Alice": "#abc",}, "bg": "#111",}';
      const text = 'narrative\n<glaze_beauty_state>$body</glaze_beauty_state>';
      final result = parseBeautyState(text);
      expect(result.markerFound, isTrue);
      expect(result.stateJson, isNotNull);
      final decoded = jsonDecode(result.stateJson!) as Map<String, dynamic>;
      expect(decoded['speakers'], {'Alice': '#abc'});
      expect(decoded['bg'], '#111');
    });

    test('marker is case-insensitive', () {
      const text =
          'narrative\n<GLAZE_BEAUTY_STATE>{"x":1}</GLAZE_BEAUTY_STATE>';
      final result = parseBeautyState(text);
      expect(result.markerFound, isTrue);
      expect(result.stateJson, isNotNull);
      expect(result.cleanedText, 'narrative');
    });

    test('marker preserves surrounding text including HTML artifacts', () {
      const text =
          '<div style="color:red">scene</div>\n'
          '<glaze_beauty_state>{"palette":"dark"}</glaze_beauty_state>';
      final result = parseBeautyState(text);
      expect(result.markerFound, isTrue);
      expect(result.cleanedText, '<div style="color:red">scene</div>');
      final decoded = jsonDecode(result.stateJson!) as Map<String, dynamic>;
      expect(decoded['palette'], 'dark');
    });

    test('nested JSON object with arrays — parsed correctly', () {
      final state = {
        'speakers': {'Alice': '#abc', 'Bob': '#def'},
        'thoughts': <String, String>{},
        'palette': 'dark',
        'font': 'sans-serif',
        'art_style': 'street_art_anime',
        'reserved': {'lumia_ooc': '#9370DB'},
      };
      final text =
          'response\n<glaze_beauty_state>${jsonEncode(state)}</glaze_beauty_state>';
      final result = parseBeautyState(text);
      expect(result.markerFound, isTrue);
      final decoded = jsonDecode(result.stateJson!) as Map<String, dynamic>;
      expect(decoded['speakers'], {'Alice': '#abc', 'Bob': '#def'});
      expect(decoded['reserved'], {'lumia_ooc': '#9370DB'});
      expect(decoded['art_style'], 'street_art_anime');
    });

    test(
      'trimmed output — leading/trailing whitespace removed from cleaned',
      () {
        const text =
            '  narrative  \n<glaze_beauty_state>{"x":1}</glaze_beauty_state>  ';
        final result = parseBeautyState(text);
        expect(result.cleanedText, 'narrative');
      },
    );

    test('JSON array root (not object) — stateJson null', () {
      const text =
          'narrative\n<glaze_beauty_state>["a","b","c"]</glaze_beauty_state>';
      final result = parseBeautyState(text);
      expect(result.markerFound, isTrue);
      expect(result.stateJson, isNull);
    });
  });

  group('beautyStateVarKey', () {
    test('exposes the session-vars key used by {{getvar::}}', () {
      expect(beautyStateVarKey, 'glaze_beauty_state');
    });
  });

  group('lumiaOocColor', () {
    test('is the hardcoded Lumia signature purple', () {
      expect(lumiaOocColor, '#9370DB');
    });
  });

  group('wrapLumiaOocColors', () {
    test(
      'normalizes an explicit bare Lumia OOC line into the canonical tag',
      () {
        const text = 'Основной ответ.\n\nLumia OOC: Не забудь про левую дверь.';
        expect(
          wrapLumiaOocColors(text),
          'Основной ответ.\n\n'
          '<lumiaooc><font color="#9370DB">Не забудь про левую дверь.'
          '</font></lumiaooc>',
        );
      },
    );

    test('closes a malformed Lumia OOC wrapper at the end of the response', () {
      const text = 'Основной ответ.\n<lumiaooc>Люмия здесь.';
      expect(
        wrapLumiaOocColors(text),
        'Основной ответ.\n'
        '<lumiaooc><font color="#9370DB">Люмия здесь.</font></lumiaooc>',
      );
    });

    test('wraps a bare <lumiaooc> block in the signature color', () {
      const text = '<lumiaooc>\n\nHello from Lumia.\n\n</lumiaooc>';
      final wrapped = wrapLumiaOocColors(text);
      expect(
        wrapped,
        '<lumiaooc><font color="#9370DB">\n\nHello from Lumia.\n\n</font></lumiaooc>',
      );
    });

    test('idempotent — already wrapped block is left unchanged', () {
      const text =
          '<lumiaooc><font color="#9370DB">\nLumia note.\n</font></lumiaooc>';
      expect(wrapLumiaOocColors(text), text);
    });

    test('idempotent when a canonical block starts with a Lumia OOC label', () {
      const text = '<lumiaooc>\nLumia OOC: Already canonical.\n</lumiaooc>';
      final once = wrapLumiaOocColors(text);
      expect(wrapLumiaOocColors(once), once);
      expect(
        RegExp('<lumiaooc>', caseSensitive: false).allMatches(once),
        hasLength(1),
      );
    });

    test('does not normalize Lumia OOC labels inside fenced code', () {
      const text = '```text\nLumia OOC: example only\n```';
      expect(wrapLumiaOocColors(text), text);
    });

    test('idempotent — a different existing <font> color is preserved', () {
      const text =
          '<lumiaooc><font color="#FF0000">Red Lumia?</font></lumiaooc>';
      expect(wrapLumiaOocColors(text), text);
    });

    test('wraps multiple blocks independently', () {
      const text = 'intro\n<lumiaooc>A</lumiaooc>\nmid\n<lumiaooc>B</lumiaooc>';
      final wrapped = wrapLumiaOocColors(text);
      expect(
        wrapped,
        'intro\n'
        '<lumiaooc><font color="#9370DB">A</font></lumiaooc>\n'
        'mid\n'
        '<lumiaooc><font color="#9370DB">B</font></lumiaooc>',
      );
    });

    test('case-insensitive — <LumiaOOC> is wrapped', () {
      const text = '<LumiaOOC>note</LumiaOOC>';
      final wrapped = wrapLumiaOocColors(text);
      expect(wrapped, '<LumiaOOC><font color="#9370DB">note</font></LumiaOOC>');
    });

    test('preserves inner newlines and whitespace', () {
      const text = '<lumiaooc>\n  line one\n  line two\n</lumiaooc>';
      final wrapped = wrapLumiaOocColors(text);
      expect(
        wrapped,
        '<lumiaooc><font color="#9370DB">\n  line one\n  line two\n</font></lumiaooc>',
      );
    });

    test('text without any lumiaooc block is returned untouched', () {
      const text = 'Just narrative and "dialogue". No OOC here.';
      expect(wrapLumiaOocColors(text), text);
    });

    test('does not reinterpret an in-world Lumia dialogue label as OOC', () {
      const text = 'Lumia: "Stay behind me."';
      expect(wrapLumiaOocColors(text), text);
    });

    test('does not depend on beauty-state JSON', () {
      // No marker, no state — the wrap still applies.
      const text = 'prose\n<lumiaooc>Lumia speaks.</lumiaooc>';
      final wrapped = wrapLumiaOocColors(text);
      expect(
        wrapped,
        'prose\n<lumiaooc><font color="#9370DB">Lumia speaks.</font></lumiaooc>',
      );
    });

    test('empty inner content is still wrapped (no crash)', () {
      const text = '<lumiaooc></lumiaooc>';
      final wrapped = wrapLumiaOocColors(text);
      expect(wrapped, '<lumiaooc><font color="#9370DB"></font></lumiaooc>');
    });

    test('narrative around the block is preserved verbatim', () {
      const text = 'Before block.\n<lumiaooc>note</lumiaooc>\nAfter block.';
      final wrapped = wrapLumiaOocColors(text);
      expect(
        wrapped,
        'Before block.\n'
        '<lumiaooc><font color="#9370DB">note</font></lumiaooc>\n'
        'After block.',
      );
    });
  });
}
