import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/extraction_status.dart';

Map<String, dynamic> _status({
  Map<String, dynamic>? run,
  List<Map<String, dynamic>>? taskHistory,
  List<Map<String, dynamic>>? history,
  String? inProgressPhase,
}) => {
  'run': ?run,
  'taskHistory': ?taskHistory,
  'history': ?history,
  if (inProgressPhase != null) 'inProgress': {'phase': inProgressPhase},
};

void main() {
  group('a run that is still working', () {
    test('is running, and reports its phase', () {
      final reading = readExtractionStatus(
        _status(
          run: {'requestId': 'mine', 'lifecycle': 'running'},
          inProgressPhase: 'fetching',
        ),
        requestId: 'mine',
      );

      expect(reading.state, ExtractionRunState.running);
      expect(reading.characterId, isNull);
      expect(reading.phase, 'fetching');
    });

    test('falls back to the run phase when nothing is in progress', () {
      final reading = readExtractionStatus(
        _status(run: {'requestId': 'mine', 'phase': 'queued'}),
        requestId: 'mine',
      );

      expect(reading.phase, 'queued');
    });
  });

  group('a run that finished', () {
    test('with a character is produced', () {
      final reading = readExtractionStatus(
        _status(
          run: {
            'requestId': 'mine',
            'lifecycle': 'terminal',
            'characterId': 'abc',
          },
        ),
        requestId: 'mine',
      );

      expect(reading.state, ExtractionRunState.produced);
      expect(reading.characterId, 'abc');
    });

    // The reported bug. A companion whose definition only vetted providers can
    // read produces a run that completes with nothing in it; asking only "is
    // there a character id yet?" made that indistinguishable from a run still
    // working, so the dialog sat on 'Importing…' for the full three minutes and
    // then blamed a timeout.
    test('with no character is finished, not still running', () {
      final reading = readExtractionStatus(
        _status(run: {'requestId': 'mine', 'lifecycle': 'terminal'}),
        requestId: 'mine',
      );

      expect(reading.state, ExtractionRunState.finishedEmpty);
      expect(reading.characterId, isNull);
    });

    test('is read from taskHistory too', () {
      final produced = readExtractionStatus(
        _status(
          taskHistory: [
            {
              'id': 'mine',
              'status': 'terminal',
              'target': {'id': 'abc'},
            },
          ],
        ),
        requestId: 'mine',
      );
      expect(produced.state, ExtractionRunState.produced);
      expect(produced.characterId, 'abc');

      final empty = readExtractionStatus(
        _status(
          taskHistory: [
            {'id': 'mine', 'status': 'terminal'},
          ],
        ),
        requestId: 'mine',
      );
      expect(empty.state, ExtractionRunState.finishedEmpty);
    });

    test('is still running while its taskHistory entry is not terminal', () {
      final reading = readExtractionStatus(
        _status(
          taskHistory: [
            {'id': 'mine', 'status': 'working'},
          ],
        ),
        requestId: 'mine',
      );

      expect(reading.state, ExtractionRunState.running);
    });
  });

  group('a failure is only ever claimed for our own run', () {
    test("someone else's terminal run does not fail our import", () {
      // Whatever else is finishing on the account, this import has not.
      final reading = readExtractionStatus(
        _status(run: {'requestId': 'theirs', 'lifecycle': 'terminal'}),
        requestId: 'mine',
        previousRunId: 'theirs',
      );

      expect(reading.state, ExtractionRunState.running);
    });

    test('no request id means no conclusion', () {
      // Without an id nothing can be claimed as ours, so the old behaviour
      // stands: keep polling until the timeout rather than guess.
      final reading = readExtractionStatus(
        _status(run: {'lifecycle': 'terminal'}),
        requestId: null,
        previousRunId: 'before',
        targetUuid: 'some-other-uuid',
      );

      expect(reading.state, ExtractionRunState.running);
    });
  });

  group('the ways a character is recognised still work', () {
    test('by our request id in history', () {
      final reading = readExtractionStatus(
        _status(
          history: [
            {'requestId': 'mine', 'characterId': 'abc'},
          ],
        ),
        requestId: 'mine',
      );

      expect(reading.characterId, 'abc');
    });

    test('by a new terminal run for the character we asked for', () {
      // The server does not always echo the request id back; this is how most
      // successful imports are actually recognised.
      final reading = readExtractionStatus(
        _status(
          run: {
            'requestId': 'unechoed',
            'lifecycle': 'terminal',
            'targetId': 'uuid-1',
          },
        ),
        requestId: null,
        previousRunId: 'before',
        targetUuid: 'uuid-1',
      );

      expect(reading.state, ExtractionRunState.produced);
      expect(reading.characterId, 'uuid-1');
    });

    test('not by a terminal run for a different character', () {
      final reading = readExtractionStatus(
        _status(
          run: {
            'requestId': 'unechoed',
            'lifecycle': 'terminal',
            'targetId': 'uuid-2',
          },
        ),
        requestId: null,
        previousRunId: 'before',
        targetUuid: 'uuid-1',
      );

      expect(reading.state, ExtractionRunState.running);
    });

    test('by a history url carrying the character we asked for', () {
      final reading = readExtractionStatus(
        _status(
          history: [
            {
              'url': 'https://saucepan.ai/companion/uuid-1',
              'characterId': 'abc',
            },
          ],
        ),
        targetUuid: 'uuid-1',
      );

      expect(reading.characterId, 'abc');
    });
  });

  group('what the reader is told', () {
    test('a Saucepan failure names the reason that accounts for it', () {
      final message = extractionFinishedEmptyMessage(isSaucepan: true);
      expect(message, contains('vetted providers'));
      expect(message, isNot(contains('timed out')));
    });

    test('another host is not told about Saucepan', () {
      expect(
        extractionFinishedEmptyMessage(isSaucepan: false),
        isNot(contains('Saucepan')),
      );
    });
  });

  test('the poll loop acts on a finished-empty run', () {
    // The reading above is only worth having if the loop stops for it.
    final source = File(
      'lib/features/catalog/services/datacat_provider.dart',
    ).readAsStringSync();

    expect(source, contains('ExtractionRunState.finishedEmpty'));
    expect(source, contains('extractionFinishedEmptyMessage('));
  });
}
