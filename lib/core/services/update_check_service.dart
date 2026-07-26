import 'package:dio/dio.dart';

import '../constants/app_version.dart';

/// Result of a successful update check that found a newer CI build than the
/// one currently installed. Mirrors the data the Telegram release bot posts:
/// the new build's date plus the list of commit subjects since the installed
/// build (see `.github/workflows/build-branch.yml`).
class UpdateInfo {
  /// Full git SHA of the latest successful `stable` build.
  final String headSha;

  /// When the CI run was created (UTC).
  final DateTime createdAt;

  /// GitHub Actions run page URL — opened by the "Open Actions" button.
  final String runUrl;

  /// Sequential CI run number (`#123`), used as a human-readable build id.
  final int runNumber;

  /// Commit subjects since the installed build, newest first, merges removed.
  /// Empty when the range could not be computed (e.g. installed SHA unknown).
  final List<String> commits;

  /// Total non-merge commits in the range; may exceed [commits].length when
  /// the list was capped.
  final int totalCommits;

  const UpdateInfo({
    required this.headSha,
    required this.createdAt,
    required this.runUrl,
    required this.runNumber,
    required this.commits,
    required this.totalCommits,
  });

  /// How many commits were dropped from [commits] because of the cap.
  int get extraCommits =>
      totalCommits > commits.length ? totalCommits - commits.length : 0;
}

/// Outcome of [UpdateCheckService.check].
enum UpdateStatus {
  /// A newer build exists; [UpdateCheckResult.info] is populated.
  available,

  /// Installed build matches the latest CI build.
  upToDate,

  /// Cannot tell — local/dev build with no embedded SHA, or the API failed.
  unknown,
}

class UpdateCheckResult {
  final UpdateStatus status;
  final UpdateInfo? info;

  const UpdateCheckResult(this.status, [this.info]);
}

/// Checks GitHub Actions for a `stable` build newer than the installed one.
///
/// The repo is public, so the Actions REST API is reachable unauthenticated
/// (60 req/h per IP — ample for an occasional check). No token is sent.
class UpdateCheckService {
  static const _owner = 'hydall';
  static const _repo = 'Glaze';
  static const _workflowFile = 'build-branch.yml';
  static const _branch = 'stable';

  /// Cap on commit subjects shown in the dialog — matches the bot's `head -10`.
  static const _commitCap = 10;

  final Dio _dio;

  UpdateCheckService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.github.com',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              headers: {
                'Accept': 'application/vnd.github+json',
                'X-GitHub-Api-Version': '2022-11-28',
                // GitHub rejects requests without a User-Agent.
                'User-Agent': 'Glaze-UpdateCheck',
              },
              // We branch on status codes ourselves; never throw on 4xx/5xx.
              validateStatus: (_) => true,
            ),
          );

  Future<UpdateCheckResult> check() async {
    try {
      final run = await _latestSuccessfulRun();
      if (run == null) return const UpdateCheckResult(UpdateStatus.unknown);

      final headSha = run['head_sha'] as String?;
      if (headSha == null || headSha.isEmpty) {
        return const UpdateCheckResult(UpdateStatus.unknown);
      }

      // Local/dev build with no embedded SHA — can't compare meaningfully.
      if (buildCommit.isEmpty) {
        return const UpdateCheckResult(UpdateStatus.unknown);
      }

      if (headSha == buildCommit) {
        return const UpdateCheckResult(UpdateStatus.upToDate);
      }

      final commits = await _commitsBetween(buildCommit, headSha);
      final capped = commits.take(_commitCap).toList();

      final info = UpdateInfo(
        headSha: headSha,
        createdAt:
            DateTime.tryParse(run['created_at'] as String? ?? '')?.toUtc() ??
            DateTime.now().toUtc(),
        runUrl:
            run['html_url'] as String? ??
            'https://github.com/$_owner/$_repo/actions',
        runNumber: (run['run_number'] as num?)?.toInt() ?? 0,
        commits: capped,
        totalCommits: commits.length,
      );
      return UpdateCheckResult(UpdateStatus.available, info);
    } on DioException {
      return const UpdateCheckResult(UpdateStatus.unknown);
    } catch (_) {
      return const UpdateCheckResult(UpdateStatus.unknown);
    }
  }

  /// Latest successful run of the release workflow on `stable`, or null.
  Future<Map<String, dynamic>?> _latestSuccessfulRun() async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/repos/$_owner/$_repo/actions/workflows/$_workflowFile/runs',
      queryParameters: const {
        'branch': _branch,
        'status': 'success',
        'per_page': 1,
      },
    );
    if (res.statusCode != 200 || res.data == null) return null;
    final runs = res.data!['workflow_runs'];
    if (runs is! List || runs.isEmpty) return null;
    final first = runs.first;
    return first is Map<String, dynamic> ? first : null;
  }

  /// Non-merge commit subjects in `base..head`, newest first. The GitHub
  /// compare endpoint returns commits oldest-first, so we reverse. Returns an
  /// empty list if the range can't be resolved (force-push, unknown SHA, etc.).
  Future<List<String>> _commitsBetween(String base, String head) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/repos/$_owner/$_repo/compare/$base...$head',
    );
    if (res.statusCode != 200 || res.data == null) return const [];

    final raw = res.data!['commits'];
    if (raw is! List) return const [];

    final subjects = <String>[];
    for (final entry in raw.reversed) {
      if (entry is! Map) continue;
      final parents = entry['parents'];
      // Skip merge commits (>1 parent), matching the workflow's --no-merges.
      if (parents is List && parents.length > 1) continue;
      final commit = entry['commit'];
      if (commit is! Map) continue;
      final message = commit['message'];
      if (message is! String || message.trim().isEmpty) continue;
      // Subject line only.
      subjects.add(message.split('\n').first.trim());
    }
    return subjects;
  }
}
