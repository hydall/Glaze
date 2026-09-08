/// Generic concurrency-limited gather, extracted from `TrackerBatcher` (plan
/// §4). Runs at most [limit] jobs in flight at once. Port of Marinara
/// `settleAgentJobsWithConcurrencyLimit`.
///
/// Pure, stateless, reusable (the tracker phase uses it for batch + individual
/// jobs; `MemoryStudioService` uses it for its retry path). Behavior preserved
/// verbatim.
class ConcurrencyLimiter {
  const ConcurrencyLimiter._();

  /// Run [run] over [items] with at most [limit] concurrent invocations.
  /// Results are returned in input order. [I] = input item type, [R] = result
  /// type.
  static Future<List<R>> settle<I, R>({
    required List<I> items,
    required int limit,
    required Future<R> Function(I item) run,
  }) async {
    if (items.length <= limit) {
      return Future.wait(items.map(run));
    }
    final results = <R>[];
    for (var i = 0; i < items.length; i += limit) {
      final chunk = items.sublist(
        i,
        (i + limit).clamp(0, items.length),
      );
      results.addAll(await Future.wait(chunk.map(run)));
    }
    return results;
  }
}
