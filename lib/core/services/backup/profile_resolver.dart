class ServiceProfile {
  final Map<String, dynamic>? profile;
  final bool useSameAsLlm;

  ServiceProfile({this.profile, required this.useSameAsLlm});
}

class ResolvedProfiles {
  final String? llmProfileId;
  final Set<String> skipIds;
  final ServiceProfile embedding;
  final ServiceProfile imageGen;
  final ServiceProfile memoryBooks;

  ResolvedProfiles({
    this.llmProfileId,
    this.skipIds = const {},
    required this.embedding,
    required this.imageGen,
    required this.memoryBooks,
  });
}

ResolvedProfiles resolveProfiles(
  List<Map<String, dynamic>> allProfiles,
  Map<String, dynamic>? serviceProfileMap,
  String? activeLlmProfileId,
) {
  String? llmProfileId = activeLlmProfileId;
  final skipIds = <String>{};
  Map<String, dynamic>? embProfile;
  bool embUseSame = true;
  Map<String, dynamic>? imggenProfile;
  bool imggenUseSame = true;
  Map<String, dynamic>? mbProfile;
  bool mbUseSame = true;

  if (serviceProfileMap != null) {
    final spmLlm = (serviceProfileMap['llm'] as Map<String, dynamic>?)
        ?['profileId'] as String?;
    if (spmLlm != null) llmProfileId = spmLlm;

    for (final svc in ['embedding', 'image_gen', 'memory_books']) {
      final svcConfig = serviceProfileMap[svc] as Map<String, dynamic>?;
      final svcProfileId = svcConfig?['profileId'] as String?;
      if (svcProfileId != null && svcProfileId != llmProfileId) {
        skipIds.add(svcProfileId);
      }
    }

    final embConfig = serviceProfileMap['embedding'] as Map<String, dynamic>?;
    embUseSame = embConfig?['useSameAsLLM'] as bool? ?? true;
    final embProfileId = embConfig?['profileId'] as String?;
    if (embProfileId != null && embProfileId != llmProfileId) {
      embProfile = allProfiles
          .cast<Map<String, dynamic>?>()
          .firstWhere((p) => p?['id'] == embProfileId, orElse: () => null);
    }

    final imggenConfig =
        serviceProfileMap['image_gen'] as Map<String, dynamic>?;
    imggenUseSame = imggenConfig?['useSameAsLLM'] as bool? ?? true;
    final imggenProfileId = imggenConfig?['profileId'] as String?;
    if (imggenProfileId != null && imggenProfileId != llmProfileId) {
      imggenProfile = allProfiles
          .cast<Map<String, dynamic>?>()
          .firstWhere((p) => p?['id'] == imggenProfileId, orElse: () => null);
    }

    final mbConfig =
        serviceProfileMap['memory_books'] as Map<String, dynamic>?;
    mbUseSame = mbConfig?['useSameAsLLM'] as bool? ?? true;
    final mbProfileId = mbConfig?['profileId'] as String?;
    if (mbProfileId != null && mbProfileId != llmProfileId) {
      mbProfile = allProfiles
          .cast<Map<String, dynamic>?>()
          .firstWhere((p) => p?['id'] == mbProfileId, orElse: () => null);
    }
  } else {
    for (final p in allProfiles) {
      final pMode = p['mode'] as String?;
      if (pMode == 'embedding') {
        embProfile = p;
        embUseSame = false;
      } else if (pMode == 'image_gen') {
        imggenProfile = p;
        imggenUseSame = false;
      } else if (pMode == 'memory_books') {
        mbProfile = p;
        mbUseSame = false;
      }
    }
  }

  return ResolvedProfiles(
    llmProfileId: llmProfileId,
    skipIds: skipIds,
    embedding: ServiceProfile(profile: embProfile, useSameAsLlm: embUseSame),
    imageGen: ServiceProfile(profile: imggenProfile, useSameAsLlm: imggenUseSame),
    memoryBooks: ServiceProfile(profile: mbProfile, useSameAsLlm: mbUseSame),
  );
}
