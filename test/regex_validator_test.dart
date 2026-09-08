import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/regex_validator.dart';

void main() {
  group('regex_validator — ReDoS detection', () {
    test('nested quantifier (.+)* is pathological', () {
      expect(classifyRegexSafety(r'/(.+)*/gi'), RegexSafety.pathological);
    });

    test('nested quantifier (a+)+ is pathological', () {
      expect(classifyRegexSafety(r'/(a+)+/'), RegexSafety.pathological);
    });

    test('nested quantifier (?:\\w*)* is pathological', () {
      expect(classifyRegexSafety(r'/(?:\w*)*/'), RegexSafety.pathological);
    });

    test('Celia Assist - Inside pattern is pathological', () {
      expect(
        classifyRegexSafety(r'/@(do|say|pen|wild):\s*(.+)*/gi'),
        RegexSafety.pathological,
      );
    });

    test('Celia Hidden Block Details pattern is pathological', () {
      expect(
        classifyRegexSafety(
          r'/`([^`]+)` - (「[^」]*」(?:「[^」]*」)*)*/gi',
        ),
        RegexSafety.pathological,
      );
    });

    test('lazy [\\s\\S]*? with \$ anchor is risky', () {
      expect(
        classifyRegexSafety(
          r'/([\s\S]*?)(<progress>[\s\S]*?<\/progress>)([\s\S]*?$)/g',
        ),
        RegexSafety.risky,
      );
    });

    test('0-or-1 outer quantifier (? after group) is safe', () {
      expect(classifyRegexSafety(r'/(\d+)?/'), RegexSafety.safe);
    });

    test('simple tag strip is safe', () {
      expect(
        classifyRegexSafety(r'/<progress>[\s\S]*?<\/progress>/g'),
        RegexSafety.safe,
      );
    });

    test('anchored tag strip without \$ is safe', () {
      expect(
        classifyRegexSafety(
          r'/<master_ledger>\s*<details>[\s\S]*?<\/details>\s*<\/master_ledger>/g',
        ),
        RegexSafety.safe,
      );
    });

    test('plain word replace is safe', () {
      expect(classifyRegexSafety(r'/foo/g'), RegexSafety.safe);
    });

    test('empty pattern is safe', () {
      expect(classifyRegexSafety(''), RegexSafety.safe);
    });

    test('dotAll .*? with \$ is risky', () {
      expect(classifyRegexSafety(r'/.*?$/s'), RegexSafety.risky);
    });

    test('dotAll .*? without \$ is safe', () {
      expect(classifyRegexSafety(r'/.*?/s'), RegexSafety.safe);
    });
  });
}
