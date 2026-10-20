/// The Windows installer attached to a GitHub Release, as the in-app updater
/// needs it: where to fetch it, how big it is, and what its SHA-256 must be.
///
/// Built only from the release the update check already read from
/// `api.github.com` over HTTPS, so the size and digest come from GitHub, not
/// from the download itself. CI names the asset `<tag>-windows-setup.exe` and
/// uploads `<tag>-windows-setup.exe.sha256` next to it
/// (`windows/installer/build_installer.ps1`).
class InstallerAsset {
  final String name;

  /// `browser_download_url` — always under [releaseDownloadPrefix].
  final Uri url;

  /// Size in bytes GitHub reports; the download must match it exactly.
  final int size;

  /// Lower-case hex SHA-256 from the asset's `digest`, or null when GitHub
  /// did not report one and [checksumUrl] has to be read instead.
  final String? sha256;

  /// The `.sha256` sidecar asset, same release.
  final Uri? checksumUrl;

  const InstallerAsset({
    required this.name,
    required this.url,
    required this.size,
    this.sha256,
    this.checksumUrl,
  });

  static const assetSuffix = '-windows-setup.exe';

  /// Everything the updater downloads must start with this. GitHub answers
  /// with a redirect to its asset CDN, which is fine: the file is checked
  /// against [size] and the SHA-256 from the API before it is run.
  static String releaseDownloadPrefix(String owner, String repo) =>
      'https://github.com/$owner/$repo/releases/download/';

  static bool isTrustedDownloadUrl(Uri url, String owner, String repo) {
    if (url.scheme != 'https' || url.host != 'github.com') return false;
    if (url.hasPort && url.port != 443) return false;
    if (url.userInfo.isNotEmpty) return false;
    // Compared on the normalized path, so `..` cannot step out of the
    // release's own download folder.
    final normalized = url.normalizePath();
    return normalized.toString().startsWith(releaseDownloadPrefix(owner, repo));
  }

  /// Picks the installer out of a `/releases/...` response, or null when the
  /// release carries none (older releases, a platform toggled off in CI) or
  /// its entry is malformed or points anywhere unexpected.
  static InstallerAsset? fromRelease(
    Map<String, dynamic> release, {
    required String owner,
    required String repo,
  }) {
    final assets = release['assets'];
    if (assets is! List) return null;

    Map<dynamic, dynamic>? installer;
    Map<dynamic, dynamic>? checksum;
    for (final a in assets) {
      if (a is! Map) continue;
      final name = a['name'];
      if (name is! String) continue;
      final lower = name.toLowerCase();
      if (lower.endsWith(assetSuffix)) installer ??= a;
    }
    if (installer == null) return null;

    final name = installer['name'] as String;
    for (final a in assets) {
      if (a is Map && a['name'] == '$name.sha256') checksum = a;
    }

    final url = Uri.tryParse(
      installer['browser_download_url'] as String? ?? '',
    );
    final size = installer['size'];
    if (url == null || !isTrustedDownloadUrl(url, owner, repo)) return null;
    if (size is! int || size <= 0) return null;

    Uri? checksumUrl;
    final rawChecksumUrl = checksum?['browser_download_url'];
    if (rawChecksumUrl is String) {
      final parsed = Uri.tryParse(rawChecksumUrl);
      if (parsed != null && isTrustedDownloadUrl(parsed, owner, repo)) {
        checksumUrl = parsed;
      }
    }

    final sha = parseDigest(installer['digest']);
    // Without either there is nothing to check the download against, and an
    // unchecked file is never run.
    if (sha == null && checksumUrl == null) return null;

    return InstallerAsset(
      name: name,
      url: url,
      size: size,
      sha256: sha,
      checksumUrl: checksumUrl,
    );
  }

  /// `sha256:<64 hex>` (GitHub's asset `digest`) → the hex, lower case.
  static String? parseDigest(Object? digest) {
    if (digest is! String) return null;
    const prefix = 'sha256:';
    if (!digest.toLowerCase().startsWith(prefix)) return null;
    return normalizeSha256(digest.substring(prefix.length));
  }

  /// First field of a `sha256sum`-style line (`<hex>  <file>`), lower case.
  static String? parseChecksumFile(String content) {
    final first = content.trim().split(RegExp(r'\s+')).first;
    return normalizeSha256(first);
  }

  static String? normalizeSha256(String raw) {
    final hex = raw.trim().toLowerCase();
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(hex) ? hex : null;
  }
}
