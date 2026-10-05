import 'dart:math' as math;
import 'dart:typed_data';

/// Duration and waveform of a clip, as drawn by the chat's voice pill.
class TtsClipInfo {
  final int durationMs;

  /// Bucketed amplitudes, 0..1, normalised against the loudest bucket.
  final List<double> peaks;

  const TtsClipInfo({required this.durationMs, required this.peaks});

  Map<String, dynamic> toJson() => {
    'durationMs': durationMs,
    'peaks': [for (final p in peaks) (p * 100).round() / 100],
  };

  static TtsClipInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final duration = raw['durationMs'];
    final peaks = raw['peaks'];
    if (duration is! num) return null;
    return TtsClipInfo(
      durationMs: duration.toInt(),
      peaks: peaks is List
          ? [
              for (final p in peaks)
                if (p is num) p.toDouble().clamp(0.0, 1.0),
            ]
          : const [],
    );
  }
}

/// Number of waveform bars kept per clip.
const int ttsPeakCount = 64;

/// Pure audio helpers: WAV parsing, PCM wrapping and peak extraction.
class TtsAudioAnalysis {
  const TtsAudioAnalysis._();

  /// Reads a WAV file. Returns null for anything this cannot decode
  /// (compressed WAV, truncated header) — the caller then falls back to the
  /// WebView decoder.
  static TtsClipInfo? analyzeWav(Uint8List bytes, {int buckets = ttsPeakCount}) {
    final wav = _parseWav(bytes);
    if (wav == null) return null;
    final frames = wav.frameCount;
    if (frames <= 0 || wav.sampleRate <= 0) return null;
    final durationMs = (frames * 1000 / wav.sampleRate).round();
    final peaks = List<double>.filled(buckets, 0);
    final perBucket = math.max(1, (frames / buckets).ceil());
    // Sampling every frame of a long clip is wasted work for 64 bars.
    final stride = math.max(1, perBucket ~/ 256);
    for (var frame = 0; frame < frames; frame += stride) {
      final bucket = math.min(buckets - 1, frame ~/ perBucket);
      var amp = 0.0;
      for (var ch = 0; ch < wav.channels; ch++) {
        final v = wav.sample(frame, ch).abs();
        if (v > amp) amp = v;
      }
      if (amp > peaks[bucket]) peaks[bucket] = amp;
    }
    return TtsClipInfo(durationMs: durationMs, peaks: normalizePeaks(peaks));
  }

  /// Scales peaks so the loudest is 1, which keeps a quiet clip from drawing
  /// a flat line. A floor keeps silent bars visible.
  static List<double> normalizePeaks(List<double> peaks) {
    var max = 0.0;
    for (final p in peaks) {
      if (p > max) max = p;
    }
    if (max <= 0) return List<double>.filled(peaks.length, 0.08);
    return [for (final p in peaks) math.max(0.08, p / max)];
  }

  /// Joins several clips' peaks into one waveform of [buckets] bars, each
  /// clip taking room proportional to its duration.
  static List<double> mergePeaks(
    List<TtsClipInfo> clips, {
    int buckets = ttsPeakCount,
  }) {
    if (clips.isEmpty) return const [];
    if (clips.length == 1) return clips.first.peaks;
    final total = clips.fold<int>(0, (s, c) => s + c.durationMs);
    if (total <= 0) return const [];
    final out = <double>[];
    for (var i = 0; i < buckets; i++) {
      final t = (i + 0.5) / buckets * total;
      var start = 0;
      for (final clip in clips) {
        final end = start + clip.durationMs;
        if (t < end || identical(clip, clips.last)) {
          if (clip.peaks.isEmpty || clip.durationMs <= 0) {
            out.add(0.08);
          } else {
            final local = ((t - start) / clip.durationMs).clamp(0.0, 0.999);
            out.add(clip.peaks[(local * clip.peaks.length).floor()]);
          }
          break;
        }
        start = end;
      }
    }
    return out;
  }

  /// Wraps raw little-endian 16-bit PCM in a WAV header so it can be played
  /// and analysed like any other clip.
  static Uint8List pcm16ToWav(
    Uint8List pcm, {
    required int sampleRate,
    int channels = 1,
  }) {
    final dataLength = pcm.length - pcm.length % 2;
    final out = Uint8List(44 + dataLength);
    final view = ByteData.view(out.buffer);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        out[offset + i] = s.codeUnitAt(i);
      }
    }

    ascii(0, 'RIFF');
    view.setUint32(4, 36 + dataLength, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    view.setUint32(16, 16, Endian.little);
    view.setUint16(20, 1, Endian.little);
    view.setUint16(22, channels, Endian.little);
    view.setUint32(24, sampleRate, Endian.little);
    view.setUint32(28, sampleRate * channels * 2, Endian.little);
    view.setUint16(32, channels * 2, Endian.little);
    view.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    view.setUint32(40, dataLength, Endian.little);
    out.setRange(44, 44 + dataLength, pcm);
    return out;
  }

  static _Wav? _parseWav(Uint8List b) {
    if (b.length < 44) return null;
    String tag(int o) => String.fromCharCodes(b.sublist(o, o + 4));
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
    final view = ByteData.sublistView(b);
    int? format;
    var channels = 0;
    var sampleRate = 0;
    var bits = 0;
    var offset = 12;
    while (offset + 8 <= b.length) {
      final id = tag(offset);
      var size = view.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ' && body + 16 <= b.length) {
        format = view.getUint16(body, Endian.little);
        channels = view.getUint16(body + 2, Endian.little);
        sampleRate = view.getUint32(body + 4, Endian.little);
        bits = view.getUint16(body + 14, Endian.little);
        // WAVE_FORMAT_EXTENSIBLE carries the real format in its sub-GUID.
        if (format == 0xFFFE && size >= 26 && body + 26 <= b.length) {
          format = view.getUint16(body + 24, Endian.little);
        }
      } else if (id == 'data') {
        if (format == null || channels <= 0) return null;
        // Streaming encoders write 0 or 0xFFFFFFFF when the length is unknown.
        if (size == 0 || size == 0xFFFFFFFF || body + size > b.length) {
          size = b.length - body;
        }
        final bytesPerSample = bits ~/ 8;
        final supported =
            (format == 1 && (bits == 8 || bits == 16 || bits == 24 || bits == 32)) ||
            (format == 3 && bits == 32);
        if (!supported || bytesPerSample == 0) return null;
        return _Wav(
          view: ByteData.sublistView(b, body, body + size),
          channels: channels,
          sampleRate: sampleRate,
          bytesPerSample: bytesPerSample,
          isFloat: format == 3,
        );
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }
}

class _Wav {
  final ByteData view;
  final int channels;
  final int sampleRate;
  final int bytesPerSample;
  final bool isFloat;

  _Wav({
    required this.view,
    required this.channels,
    required this.sampleRate,
    required this.bytesPerSample,
    required this.isFloat,
  });

  int get frameCount => view.lengthInBytes ~/ (bytesPerSample * channels);

  /// Sample in -1..1.
  double sample(int frame, int channel) {
    final o = (frame * channels + channel) * bytesPerSample;
    if (isFloat) return view.getFloat32(o, Endian.little);
    switch (bytesPerSample) {
      case 1:
        return (view.getUint8(o) - 128) / 128;
      case 2:
        return view.getInt16(o, Endian.little) / 32768;
      case 3:
        var v =
            view.getUint8(o) |
            (view.getUint8(o + 1) << 8) |
            (view.getUint8(o + 2) << 16);
        if (v & 0x800000 != 0) v -= 0x1000000;
        return v / 8388608;
      default:
        return view.getInt32(o, Endian.little) / 2147483648;
    }
  }
}
