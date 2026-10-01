import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/vn_generator_service.dart';
import 'services/vn_script.dart';

/// What the 3D novel screen is playing.
@immutable
class VnState {
  const VnState({this.script, this.generating = false});

  /// The game script, or null until the sample has loaded.
  final String? script;

  /// A generation request is in flight.
  final bool generating;

  VnState copyWith({String? script, bool? generating}) => VnState(
    script: script ?? this.script,
    generating: generating ?? this.generating,
  );
}

class VnNotifier extends Notifier<VnState> {
  @override
  VnState build() {
    Future.microtask(_loadSampleIfEmpty);
    return const VnState();
  }

  Future<void> _loadSampleIfEmpty() async {
    if (state.script != null) return;
    final sample = await rootBundle.loadString(kVnSampleAsset);
    if (state.script == null) state = state.copyWith(script: sample);
  }

  Future<void> loadSample() async {
    state = state.copyWith(script: await rootBundle.loadString(kVnSampleAsset));
  }

  void setScript(String script) => state = state.copyWith(script: script);

  /// Generates a new game from [premise] and plays it. Throws on failure and
  /// leaves the current game in place.
  Future<void> generate({
    required String premise,
    required String language,
  }) async {
    if (state.generating) return;
    state = state.copyWith(generating: true);
    try {
      final script = await ref
          .read(vnGeneratorServiceProvider)
          .generate(premise: premise, language: language);
      state = state.copyWith(script: script);
    } finally {
      state = state.copyWith(generating: false);
    }
  }
}

final vnProvider = NotifierProvider<VnNotifier, VnState>(VnNotifier.new);
