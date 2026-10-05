/// What the voice pill under a message shows.
enum TtsPillStatus {
  /// Nothing generated yet: play button, no duration.
  idle,
  loading,

  /// Audio available: duration and waveform.
  ready,
  playing,
  error,

  /// Nothing to speak (voice disabled, empty text) — no pill.
  none,
}

class TtsPillState {
  final TtsPillStatus status;
  final int? durationMs;
  final List<double> peaks;
  final String? error;

  const TtsPillState(
    this.status, {
    this.durationMs,
    this.peaks = const [],
    this.error,
  });

  static const idle = TtsPillState(TtsPillStatus.idle);
  static const none = TtsPillState(TtsPillStatus.none);

  TtsPillState withStatus(TtsPillStatus status, {String? error}) =>
      TtsPillState(status, durationMs: durationMs, peaks: peaks, error: error);

  Map<String, dynamic> toJson() => {
    's': status.name,
    if (durationMs != null) 'd': durationMs,
    if (peaks.isNotEmpty) 'p': [for (final v in peaks) (v * 100).round()],
    if (error != null) 'e': error,
  };

  @override
  bool operator ==(Object other) =>
      other is TtsPillState &&
      other.status == status &&
      other.durationMs == durationMs &&
      other.error == error &&
      _samePeaks(other.peaks, peaks);

  @override
  int get hashCode => Object.hash(status, durationMs, error, peaks.length);

  static bool _samePeaks(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
