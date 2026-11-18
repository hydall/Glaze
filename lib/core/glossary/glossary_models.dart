class GlossaryTerm {
  final String id;
  final String name;
  final String? alt;
  final String desc;

  const GlossaryTerm({
    required this.id,
    required this.name,
    this.alt,
    required this.desc,
  });

  factory GlossaryTerm.fromJson(Map<String, dynamic> json) => GlossaryTerm(
        id: json['id'] as String,
        name: json['name'] as String,
        alt: json['alt'] as String?,
        desc: (json['desc'] as String?) ?? '',
      );
}

class GlossaryCategory {
  final String id;
  final String label;
  final List<GlossaryTerm> terms;

  const GlossaryCategory({
    required this.id,
    required this.label,
    required this.terms,
  });

  factory GlossaryCategory.fromJson(Map<String, dynamic> json) =>
      GlossaryCategory(
        id: json['id'] as String,
        label: json['label'] as String,
        terms: ((json['terms'] as List?) ?? const [])
            .cast<Map<String, dynamic>>()
            .map(GlossaryTerm.fromJson)
            .toList(growable: false),
      );
}
