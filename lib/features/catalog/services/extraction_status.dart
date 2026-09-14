/// Reading DataCat's `/api/extraction/status` for one request Glaze started.
///
/// Pulled out of the polling loop so the decision can be tested without a
/// server, and so the loop can say what it is waiting for. The loop used to ask
/// one question — "is there a character id yet?" — which made a run that had
/// already finished empty-handed look exactly like one still working: the
/// import sat on its spinner for the full three minutes before giving up with
/// "Extraction timed out", which is not what happened.
library;

enum ExtractionRunState {
  /// Still working, or nothing about this request has surfaced yet.
  running,

  /// Finished, and a character came out of it.
  produced,

  /// Finished, and no character came out of it. Only concluded for a run this
  /// request can claim as its own.
  finishedEmpty,
}

typedef ExtractionStatusReading = ({
  ExtractionRunState state,
  String? characterId,
  String phase,
});

/// What to tell a reader whose extraction finished without a character.
///
/// The status endpoint does not say *why* a run came back empty, so this says
/// what is known — it finished, there is nothing to import — and for Saucepan
/// adds the one reason that accounts for it: the remote extractor is asked for
/// public definitions only, so a companion whose definition is restricted to
/// vetted providers produces a run that completes with nothing in it.
String extractionFinishedEmptyMessage({required bool isSaucepan}) => isSaucepan
    ? 'The extraction finished without a character. Saucepan companions whose '
          'definition is only readable by vetted providers cannot be imported '
          'yet — only open-definition companions work.'
    : 'The extraction finished without a character.';

String? _asString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

Map<String, dynamic>? _asMap(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : null;

List<Map<String, dynamic>> _asList(Object? value) => value is List
    ? value
          .whereType<Map<Object?, Object?>>()
          .map((e) => e.cast<String, dynamic>())
          .toList()
    : const [];

/// What [status] says about the request identified by [requestId].
///
/// [previousRunId] is the run that was current before this request started, and
/// [targetUuid] the character id in the submitted URL: both are how a run is
/// recognised when the server does not echo the request id back, and both are
/// only ever used to *claim a character*, never to declare a failure — a run
/// Glaze cannot prove is its own must not fail this import.
ExtractionStatusReading readExtractionStatus(
  Map<String, dynamic> status, {
  String? requestId,
  String? previousRunId,
  String? targetUuid,
}) {
  final run = _asMap(status['run']);
  final phase =
      _asString(_asMap(status['inProgress'])?['phase']) ??
      _asString(run?['phase']) ??
      '';

  String? characterId;
  var finished = false;

  if (requestId != null) {
    if (run?['requestId'] == requestId) {
      if (run?['lifecycle'] == 'terminal') {
        finished = true;
        characterId = _asString(run?['characterId'] ?? run?['targetId']);
      }
    }

    if (characterId == null) {
      for (final entry in _asList(status['taskHistory'])) {
        if (entry['id'] != requestId) continue;
        if (entry['status'] == 'terminal') {
          finished = true;
          characterId = _asString(_asMap(entry['target'])?['id']);
        }
        break;
      }
    }

    if (characterId == null) {
      for (final entry in _asList(status['history'])) {
        if (entry['requestId'] == requestId) {
          characterId = _asString(entry['characterId']);
          break;
        }
      }
    }
  }

  // A terminal run that started after ours and matches the character we asked
  // for. The server does not always echo the request id, so this is how most
  // successful imports are actually recognised.
  if (characterId == null &&
      run?['lifecycle'] == 'terminal' &&
      run?['requestId'] != previousRunId &&
      (targetUuid == null || run?['targetId'] == targetUuid)) {
    characterId = _asString(run?['characterId'] ?? run?['targetId']);
  }

  if (characterId == null && targetUuid != null) {
    for (final entry in _asList(status['history'])) {
      final url = _asString(entry['url']);
      final id = _asString(entry['characterId']);
      if (url != null && id != null && url.contains(targetUuid)) {
        characterId = id;
        break;
      }
    }
  }

  if (characterId != null) {
    return (
      state: ExtractionRunState.produced,
      characterId: characterId,
      phase: phase,
    );
  }
  return (
    state: finished
        ? ExtractionRunState.finishedEmpty
        : ExtractionRunState.running,
    characterId: null,
    phase: phase,
  );
}
