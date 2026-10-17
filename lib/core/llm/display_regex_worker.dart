import 'dart:async';
import 'dart:isolate';

import '../models/chat_message.dart' show TriggeredEntry;
import '../models/preset.dart';
import 'regex_service.dart';

/// One message's text on its way through the display regexes, and the
/// placement it is filtered by (1 user, 2 AI output).
class DisplayRegexJob {
  final String text;
  final int placement;

  const DisplayRegexJob({required this.text, required this.placement});
}

/// A message's text after the display regexes, and the scripts that changed
/// it.
class DisplayRegexResult {
  final String text;
  final List<TriggeredEntry> triggered;

  const DisplayRegexResult({required this.text, required this.triggered});
}

/// The results of one batch, in job order, and the scripts that had to be
/// stopped to get them.
class DisplayRegexRun {
  final List<DisplayRegexResult> results;
  final List<PresetRegex> stopped;

  const DisplayRegexRun({required this.results, required this.stopped});
}

/// Runs the chat's display regexes off the main isolate, under a deadline.
///
/// A user's pattern can backtrack catastrophically on one message: a tracker
/// regex with a field too few spent minutes on a single reply, and since the
/// display pass ran on the main isolate — where a running regex cannot be
/// interrupted — the chat froze on every open until Android killed the app.
///
/// Here each batch runs in its own isolate, which reports every script it
/// starts. A script that runs longer than [stepTimeout] on one message gets
/// the isolate killed (that does interrupt a match), is marked stopped for the
/// app session (see [markRegexScriptStopped]) and the batch reruns without
/// it. Batches run one at a time, so results come back in the order they
/// were asked for, as the bridge's commands expect.
class DisplayRegexWorker {
  DisplayRegexWorker._();

  /// How long one script may spend on one message.
  static Duration stepTimeout = const Duration(seconds: 3);

  /// How long the isolate may take to start and report its first script.
  /// Missing it means the worker is broken, not that a script is slow.
  static Duration startTimeout = const Duration(seconds: 15);

  static Future<void> _tail = Future.value();

  /// Applies [scripts] to every job, in the display pass. Throws when the
  /// worker itself cannot run; callers fall back to the inline pass.
  static Future<DisplayRegexRun> apply(
    List<DisplayRegexJob> jobs,
    List<PresetRegex> scripts,
    RegexApplyContext ctx,
  ) {
    final run = _tail.then((_) => _applyNow(jobs, scripts, ctx));
    _tail = run.then((_) {}, onError: (_) {});
    return run;
  }

  static Future<DisplayRegexRun> _applyNow(
    List<DisplayRegexJob> jobs,
    List<PresetRegex> scripts,
    RegexApplyContext ctx,
  ) async {
    final stopped = <PresetRegex>[];
    while (true) {
      final live = [
        for (final s in scripts)
          if (!s.disabled && !isRegexScriptStopped(s)) s,
      ];
      if (live.isEmpty) {
        return DisplayRegexRun(
          results: [
            for (final job in jobs)
              DisplayRegexResult(text: job.text, triggered: const []),
          ],
          stopped: stopped,
        );
      }
      final attempt = await _attempt(jobs, live, ctx);
      final results = attempt.results;
      if (results != null) {
        return DisplayRegexRun(results: results, stopped: stopped);
      }
      final culprit = attempt.culprit;
      if (culprit == null) {
        throw StateError('display regex worker did not run');
      }
      markRegexScriptStopped(culprit);
      stopped.add(culprit);
    }
  }

  static Future<_Attempt> _attempt(
    List<DisplayRegexJob> jobs,
    List<PresetRegex> live,
    RegexApplyContext ctx,
  ) async {
    final port = ReceivePort();
    final done = Completer<_Attempt>();
    Isolate? isolate;
    Timer? watchdog;

    void finish(_Attempt attempt) {
      if (done.isCompleted) return;
      watchdog?.cancel();
      port.close();
      if (attempt.results == null) {
        isolate?.kill(priority: Isolate.immediate);
      }
      done.complete(attempt);
    }

    void arm(Duration timeout, PresetRegex? culprit) {
      watchdog?.cancel();
      watchdog = Timer(timeout, () => finish(_Attempt.timedOut(culprit)));
    }

    port.listen((message) {
      if (message is int) {
        arm(stepTimeout, live[message]);
      } else if (message is _Done) {
        finish(_Attempt.done(message.results));
      } else if (message == null) {
        // The isolate exited without a result: it threw.
        finish(const _Attempt.timedOut(null));
      }
    });

    arm(startTimeout, null);
    try {
      isolate = await Isolate.spawn(
        _run,
        _Request(port.sendPort, jobs, live, ctx),
        onExit: port.sendPort,
      );
      // A timeout that fired during the spawn could not kill it yet.
      if (done.isCompleted) isolate.kill(priority: Isolate.immediate);
    } catch (_) {
      finish(const _Attempt.timedOut(null));
    }
    return done.future;
  }
}

class _Request {
  final SendPort port;
  final List<DisplayRegexJob> jobs;
  final List<PresetRegex> scripts;
  final RegexApplyContext ctx;

  const _Request(this.port, this.jobs, this.scripts, this.ctx);
}

class _Done {
  final List<DisplayRegexResult> results;

  const _Done(this.results);
}

class _Attempt {
  final List<DisplayRegexResult>? results;
  final PresetRegex? culprit;

  const _Attempt.done(List<DisplayRegexResult> this.results) : culprit = null;
  const _Attempt.timedOut(this.culprit) : results = null;
}

void _run(_Request request) {
  final results = <DisplayRegexResult>[];
  for (final job in request.jobs) {
    final triggered = <TriggeredEntry>[];
    final text = applyRegexes(
      job.text,
      job.placement,
      1,
      request.scripts,
      request.ctx,
      isMarkdown: true,
      triggered: triggered,
      onScript: (script) => request.port.send(request.scripts.indexOf(script)),
    );
    results.add(DisplayRegexResult(text: text, triggered: triggered));
  }
  Isolate.exit(request.port, _Done(results));
}
