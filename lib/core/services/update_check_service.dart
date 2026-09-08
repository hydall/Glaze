import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../constants/app_version.dart';
import '../constants/build_channel.dart';

/// Where an available update was found.
///
/// The channel decides which one is consulted: `stable` builds track published
/// releases, every pre-release channel tracks its own branch's CI builds.
enum UpdateSource {
  /// A published GitHub Release (`stable` channel).
  release,

  /// A successful GitHub Actions run (`staging` / `nightly` / feature branches).
  ciBuild,
}

/// Result of a successful update check that found something newer than the
/// installed build.
class UpdateInfo {
  /// Which feed this came from — drives the dialog's wording.
  final UpdateSource source;

  /// Stable identity of the update, used as the "don't remind me" key: the
  /// run's head SHA for a CI build, the tag name for a release.
  final String dismissId;

  /// Human-readable build id — `#123` for a CI run, `v0.7.1` for a release.
  final String label;

  /// When the run was created / the release was published (UTC).
  final DateTime createdAt;

  /// Page to open — the Actions run, or the release page where assets live.
  final String url;

  /// What changed, newest first: commit subjects since the installed build, or
  /// the release notes. Empty when it could not be determined.
  final List<String> notes;

  /// Total notes available; may exceed [notes].length when the list was capped.
  final int totalNotes;

  const UpdateInfo({
    required this.source,
    required this.dismissId,
    required this.label,
    required this.createdAt,
    required this.url,
    required this.notes,
    required this.totalNotes,
  });

  /// How many notes were dropped from [notes] because of the cap.
  int get extraNotes =>
      totalNotes > notes.length ? totalNotes - notes.length : 0;
}

/// Outcome of [UpdateCheckService.check].
enum UpdateStatus {
  /// Something newer exists; [UpdateCheckResult.info] is populated.
  available,

  /// Installed build matches the latest release / CI build.
  upToDate,

  /// Cannot tell — local build with no embedded SHA or version, or API failure.
  unknown,
}

class UpdateCheckResult {
  final UpdateStatus status;
  final UpdateInfo? info;

  const UpdateCheckResult(this.status, [this.info]);
}

/// Checks GitHub for a build newer than the installed one.
///
/// Which feed is consulted depends on the build channel
/// (see `lib/core/constants/build_channel.dart`):
///
/// - **`stable`** — the latest published release. `/releases/latest` already
///   excludes drafts and pre-releases, so a public build never offers an RC.
///   Compared by version, since release tags are the only ordering that exists.
/// - **`staging` / `nightly` / feature branches** — the latest successful run of
///   the release workflow *on the branch this build came from*. Compared by
///   commit SHA, because consecutive CI builds share a version number.
///
/// The repo is public, so the REST API is reachable unauthenticated (60 req/h
/// per IP — ample for an occasional check). No token is sent.
class UpdateCheckService {
  static const _owner = 'hydall';
  static const _repo = 'Glaze';
  static const _workflowFile = 'build-branch.yml';

  /// Cap on notes shown in the dialog — matches the release bot's `head -10`.
  static const _noteCap = 10;

  /// Branch whose CI runs are checked on the pre-release channels.
  ///
  /// Uses the branch CI actually built so a tester on `feat/xxx` is told about
  /// newer `feat/xxx` builds rather than unrelated ones. Falls back to the
  /// channel name for local builds, where `BUILD_BRANCH` was never injected.
  static String get _branch =>
      buildBranch.isNotEmpty ? buildBranch : buildChannel;

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
      return isStableChannel ? await _checkRelease() : await _checkCiBuild();
    } on DioException {
      return const UpdateCheckResult(UpdateStatus.unknown);
    } catch (_) {
      return const UpdateCheckResult(UpdateStatus.unknown);
    }
  }

  // ── stable: published releases ─────────────────────────────────────────────

  Future<UpdateCheckResult> _checkRelease() async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/repos/$_owner/$_repo/releases/latest',
    );
    // 404 simply means nothing has been released yet.
    if (res.statusCode != 200 || res.data == null) {
      return const UpdateCheckResult(UpdateStatus.unknown);
    }
    final data = res.data!;

    final tag = (data['tag_name'] as String?)?.trim() ?? '';
    if (tag.isEmpty) return const UpdateCheckResult(UpdateStatus.unknown);

    final latest = parseVersion(tag);
    final installed = parseVersion(appVersion);
    if (latest == null || installed == null) {
      return const UpdateCheckResult(UpdateStatus.unknown);
    }
    if (compareVersions(latest, installed) <= 0) {
      return const UpdateCheckResult(UpdateStatus.upToDate);
    }

    final notes = releaseNotes(data['body']);
    return UpdateCheckResult(
      UpdateStatus.available,
      UpdateInfo(
        source: UpdateSource.release,
        dismissId: tag,
        label: tag,
        createdAt:
            DateTime.tryParse(data['published_at'] as String? ?? '')?.toUtc() ??
            DateTime.now().toUtc(),
        url:
            data['html_url'] as String? ??
            'https://github.com/$_owner/$_repo/releases',
        notes: notes.take(_noteCap).toList(),
        totalNotes: notes.length,
      ),
    );
  }

  // ── pre-release channels: CI builds on this branch ─────────────────────────

  Future<UpdateCheckResult> _checkCiBuild() async {
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
    final runNumber = (run['run_number'] as num?)?.toInt() ?? 0;

    return UpdateCheckResult(
      UpdateStatus.available,
      UpdateInfo(
        source: UpdateSource.ciBuild,
        dismissId: headSha,
        label: runNumber > 0 ? '#$runNumber' : _branch,
        createdAt:
            DateTime.tryParse(run['created_at'] as String? ?? '')?.toUtc() ??
            DateTime.now().toUtc(),
        url:
            run['html_url'] as String? ??
            'https://github.com/$_owner/$_repo/actions',
        notes: commits.take(_noteCap).toList(),
        totalNotes: commits.length,
      ),
    );
  }

  /// Latest successful run of the release workflow on [_branch], or null.
  Future<Map<String, dynamic>?> _latestSuccessfulRun() async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/repos/$_owner/$_repo/actions/workflows/$_workflowFile/runs',
      queryParameters: <String, dynamic>{
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

  // ── version helpers ────────────────────────────────────────────────────────

  /// Parses `v0.7.1`, `0.7.1`, `0.7.1-alpha`, `0.7.1+3` into `[0, 7, 1]`.
  ///
  /// Pre-release and build metadata are dropped rather than ordered: releases
  /// are compared on their numeric version only, and `/releases/latest` never
  /// returns a pre-release in the first place. Returns null when the tag isn't
  /// numeric-dotted, which the caller treats as "can't tell".
  @visibleForTesting
  static List<int>? parseVersion(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final cut = s.indexOf(RegExp(r'[-+ ]'));
    if (cut != -1) s = s.substring(0, cut);
    if (s.isEmpty) return null;

    final out = <int>[];
    for (final part in s.split('.')) {
      final n = int.tryParse(part);
      if (n == null) return null;
      out.add(n);
    }
    return out.isEmpty ? null : out;
  }

  /// Component-wise compare, zero-padding the shorter side so `0.7` == `0.7.0`
  /// and `0.10.0` > `0.9.0`. Returns <0, 0 or >0.
  @visibleForTesting
  static int compareVersions(List<int> a, List<int> b) {
    final len = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x < y ? -1 : 1;
    }
    return 0;
  }

  /// Flattens a release body into displayable lines: drops markdown headings
  /// and blank lines, strips leading bullet markers. GitHub's generated notes
  /// are a `## What's Changed` heading over a `* subject by @user in <url>`
  /// list, which reduces to one line per change.
  ///
  /// The trailing `**Full Changelog**: <compare url>` footer is dropped too —
  /// it carries no per-change information and would eat one of the capped
  /// slots in the dialog.
  @visibleForTesting
  static List<String> releaseNotes(Object? body) {
    if (body is! String) return const [];

    final out = <String>[];
    for (final line in body.split('\n')) {
      var t = line.trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      t = t.replaceFirst(RegExp(r'^[-*•]\s+'), '').trim();
      if (t.isEmpty) continue;
      if (t.toLowerCase().startsWith('**full changelog**')) continue;
      out.add(t);
    }
    return out;
  }
}
