import 'preset.dart';

const studioRegexStages = <String>[
  'pregen',
  'specificAgent',
  'final',
  'output',
  'cleaner',
  'ledger',
];

final class StudioRegex {
  final PresetRegex script;
  final Set<String> stages;

  const StudioRegex({required this.script, this.stages = const {}});

  StudioRegex copyWith({PresetRegex? script, Set<String>? stages}) {
    return StudioRegex(
      script: script ?? this.script,
      stages: stages ?? this.stages,
    );
  }

  factory StudioRegex.fromJson(Map<String, dynamic> json) {
    final rawStages = json['stages'];
    return StudioRegex(
      script: PresetRegex.fromJson(
        Map<String, dynamic>.from(json['script'] as Map),
      ),
      stages: rawStages is List
          ? rawStages
                .whereType<String>()
                .where(studioRegexStages.contains)
                .toSet()
          : const {},
    );
  }

  Map<String, dynamic> toJson() => {
    'script': script.toJson(),
    'stages': [
      for (final stage in studioRegexStages)
        if (stages.contains(stage)) stage,
    ],
  };
}
