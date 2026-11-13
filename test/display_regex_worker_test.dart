import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/display_regex_worker.dart';
import 'package:glaze_flutter/core/llm/regex_service.dart';
import 'package:glaze_flutter/core/llm/regex_validator.dart';
import 'package:glaze_flutter/core/models/preset.dart';

/// The tracker-widget pattern from the report: with a field too few in the
/// tracker it backtracks for minutes over the rest of the message.
const _trackerPattern =
    r'/\{\s*(\d{1,2}):(\d{2})\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*'
    r'([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|,]+?)(?:,\s*([^|,]+?))?'
    r'(?:,\s*([^|,]+?))?\s*\|\s*([^|]+?)\s*\|\s*([^|,]+?)(?:,\s*([^|]+?))?'
    r'\s*\|\s*(.*?)\s*\}/gi';

/// Seven fields after the time where the pattern wants eight, then a long
/// reply without a single `|`.
final _brokenTrackerMessage =
    '{12:25 | 17.04.2026 | +9°C, Облачно | Екатеринбург, Подвальная '
    'тату-студия | Черные джинсы, черное худи, кроссовки | Раздраженный, '
    'затем пристыженный, остывший | Случайная связь, 1 день | "Мысли"}\n\n'
    '${'У облупленного бетонного спуска в цокольный этаж стоял гвалт. ' * 80}';

const _tracker = PresetRegex(
  id: 'tracker',
  name: 'fwn: info',
  regex: _trackerPattern,
  replacement: r'<div>$1:$2</div>',
  placement: [2],
  markdownOnly: true,
);

const _bold = PresetRegex(
  id: 'bold',
  name: 'bold',
  regex: r'/Облачно/g',
  replacement: '<b>Облачно</b>',
  placement: [2],
  markdownOnly: true,
);

void main() {
  setUp(() {
    resetStoppedRegexScripts();
    DisplayRegexWorker.stepTimeout = const Duration(seconds: 3);
  });

  tearDown(resetStoppedRegexScripts);

  test('applies the scripts and reports the ones that fired', () async {
    final run = await DisplayRegexWorker.apply(
      const [
        DisplayRegexJob(text: 'Облачно, +9', placement: 2),
        DisplayRegexJob(text: 'Облачно, +9', placement: 1),
      ],
      const [_bold],
      const RegexApplyContext(),
    );

    expect(run.stopped, isEmpty);
    expect(run.results[0].text, '<b>Облачно</b>, +9');
    expect(run.results[0].triggered.map((t) => t.id), ['bold']);
    // A user message is outside the script's placement.
    expect(run.results[1].text, 'Облачно, +9');
    expect(run.results[1].triggered, isEmpty);
  });

  test('stops a script that hangs on a message and keeps the rest', () async {
    DisplayRegexWorker.stepTimeout = const Duration(milliseconds: 300);
    final watch = Stopwatch()..start();

    final run = await DisplayRegexWorker.apply(
      [DisplayRegexJob(text: _brokenTrackerMessage, placement: 2)],
      const [_tracker, _bold],
      const RegexApplyContext(),
    );

    expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    expect(run.stopped.map((s) => s.id), ['tracker']);
    expect(run.results.single.text, contains('<b>Облачно</b>'));
    expect(run.results.single.triggered.map((t) => t.id), ['bold']);
    expect(isRegexScriptStopped(_tracker), isTrue);

    // The inline passes skip it too, so it cannot freeze them either.
    final inline = applyRegexes(
      _brokenTrackerMessage,
      2,
      1,
      const [_tracker],
      const RegexApplyContext(),
      isMarkdown: true,
    );
    expect(inline, _brokenTrackerMessage);
  });

  test(
    'runs a script the ReDoS heuristic flags; the deadline guards it',
    () async {
      // Flagged by the heuristic, yet linear: every iteration must eat a `"`
      // or a char that is not one.
      const attrs = PresetRegex(
        id: 'attrs',
        name: 'header',
        regex: r'''/<h\b((?:[^<>"']|"[^"<>]*")*?)\/?>/gi''',
        replacement: r'<b>$1</b>',
        placement: [2],
        markdownOnly: true,
      );
      expect(classifyRegexSafety(attrs.regex), RegexSafety.pathological);

      final run = await DisplayRegexWorker.apply(
        const [DisplayRegexJob(text: '<h a="1"/>', placement: 2)],
        const [attrs],
        const RegexApplyContext(),
      );

      expect(run.stopped, isEmpty);
      expect(run.results.single.text, '<b> a="1"</b>');
      // The inline passes, which nothing can interrupt, still skip it.
      expect(
        applyRegexes(
          '<h a="1"/>',
          2,
          1,
          const [attrs],
          const RegexApplyContext(),
          isMarkdown: true,
        ),
        '<h a="1"/>',
      );
    },
  );

  test('an edited pattern of a stopped script runs again', () {
    markRegexScriptStopped(_tracker);

    expect(isRegexScriptStopped(_tracker), isTrue);
    expect(
      isRegexScriptStopped(_tracker.copyWith(regex: r'/\{(\d+):(\d+)\}/')),
      isFalse,
    );
  });

  test('batches come back in the order they were asked for', () async {
    final first = DisplayRegexWorker.apply(
      List.filled(50, const DisplayRegexJob(text: 'Облачно', placement: 2)),
      const [_bold],
      const RegexApplyContext(),
    );
    final second = DisplayRegexWorker.apply(
      const [DisplayRegexJob(text: 'Облачно', placement: 2)],
      const [_bold],
      const RegexApplyContext(),
    );

    final order = <int>[];
    await Future.wait([
      first.then((_) => order.add(1)),
      second.then((_) => order.add(2)),
    ]);
    expect(order, [1, 2]);
  });
}
