import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';

MacroResult _run(String text, [Map<String, String> vars = const {}]) =>
    replaceMacros(
      text,
      MacroContext(
        charName: 'Arthur',
        userName: 'Guin',
        charId: 'c',
        sessionId: 's',
        sessionVars: vars,
      ),
    );

void main() {
  group('setvar / getvar (ST macro engine parity)', () {
    test('a value is resolved when it is set', () {
      final r = _run(
        '{{setvar::where::inside <hud>}}'
        '{{setvar::rule::Located {{getvar::where}}, by {{user}}}}'
        '{{getvar::rule}}',
      );
      expect(r.text, 'Located inside <hud>, by Guin');
      expect(r.sessionVars['rule'], 'Located inside <hud>, by Guin');
    });

    test('scoped setvar takes the text up to its closing tag', () {
      final r = _run(
        '{{setvar::fengine}}\n## Feeling Engine\nLocated {{getvar::where}}.'
        '{{/setvar}}after',
        {'where': 'in the HUD'},
      );
      expect(r.text, 'after');
      expect(
        r.sessionVars['fengine'],
        '## Feeling Engine\nLocated in the HUD.',
      );
    });

    test('variables apply in reading order', () {
      final r = _run('[{{getvar::x}}]{{setvar::x::new}}[{{getvar::x}}]', {
        'x': 'old',
      });
      expect(r.text, '[old][new]');
    });

    test('getchatvar / setchatvar are the session scope', () {
      final r = _run('{{setchatvar::mind::Riot}}{{getchatvar::mind}}');
      expect(r.text, 'Riot');
      expect(r.sessionVars['mind'], 'Riot');
    });

    test('scoped payloads count for preset accounting', () {
      expect(
        extractSetvarPayloads(
          '{{setvar::a::one}}{{setvar::b}}\ntwo\n{{/setvar}}',
          'setvar',
        ),
        ['one', 'two'],
      );
    });
  });

  group('{{if}}', () {
    test('picks a branch on a resolved condition', () {
      expect(
        _run('{{if {{getvar::on}}}}yes{{else}}no{{/if}}', {'on': '1'}).text,
        'yes',
      );
      expect(_run('{{if {{getvar::on}}}}yes{{else}}no{{/if}}').text, 'no');
    });

    test('! negates, and "0" / "false" are falsy', () {
      const text = '{{if !{{getvar::no_hud}}}}HUD{{/if}}';
      expect(_run(text).text, 'HUD');
      expect(_run(text, {'no_hud': '1'}).text, '');
      expect(_run(text, {'no_hud': 'false'}).text, 'HUD');
    });

    test('nested blocks pair up', () {
      expect(
        _run('{{if a}}A{{if {{getvar::b}}}}B{{/if}}C{{/if}}', {'b': ''}).text,
        'AC',
      );
    });

    test('a setvar in the branch not taken never runs', () {
      final r = _run('{{if {{getvar::off}}}}{{setvar::x::set}}{{/if}}');
      expect(r.sessionVars.containsKey('x'), isFalse);
    });

    test('a bare name reads the character field', () {
      final ctx = MacroContext(
        charName: 'A',
        charId: 'c',
        sessionId: 's',
        charDescription: '',
      );
      expect(
        replaceMacros('{{if description}}D{{else}}none{{/if}}', ctx).text,
        'none',
      );
    });

    test('Studio build time defers a condition it cannot resolve yet', () {
      final r = expandVariableMacros(
        '{{if {{user}}}}{{setvar::x::1}}{{/if}}{{if {{getvar::y}}}}Y{{/if}}',
      );
      expect(r.text, '{{if {{user}}}}{{setvar::x::1}}{{/if}}');
      expect(r.sessionVars.containsKey('x'), isFalse);
    });
  });
}
