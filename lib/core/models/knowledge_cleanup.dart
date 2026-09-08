enum KnowledgeCleanupOpType { retract, renameEntity }

class KnowledgeCleanupOp {
  final KnowledgeCleanupOpType type;
  final String factId;
  final String fromKey;
  final String toKey;
  final String canonicalName;

  const KnowledgeCleanupOp._({
    required this.type,
    this.factId = '',
    this.fromKey = '',
    this.toKey = '',
    this.canonicalName = '',
  });

  const KnowledgeCleanupOp.retract(String factId)
    : this._(type: KnowledgeCleanupOpType.retract, factId: factId);

  const KnowledgeCleanupOp.renameEntity({
    required String fromKey,
    required String toKey,
    required String canonicalName,
  }) : this._(
         type: KnowledgeCleanupOpType.renameEntity,
         fromKey: fromKey,
         toKey: toKey,
         canonicalName: canonicalName,
       );
}
