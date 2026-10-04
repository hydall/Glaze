/// The `state` parameter of an OAuth authorization request, and the one rule
/// every Glaze OAuth flow checks it by.
///
/// Three flows compare it — Dropbox and Google Drive on mobile, where the
/// answer arrives as a deep link, and the loopback server on desktop — and
/// they used to disagree: Dropbox reported both values, Google Drive reported
/// neither, and the desktop server never looked. One function, so a reader who
/// hits this on one platform reads the same sentence on the next.
library;

/// Why [returned] is not the answer to the attempt that sent [expected], or
/// null when it is.
///
/// A null [expected] means the caller sent no state and has nothing to compare
/// against; that is not a mismatch, just an unverified callback.
String? oauthStateMismatchMessage(String? expected, String? returned) {
  if (expected == null || expected.isEmpty) return null;
  if (returned == expected) return null;
  return 'OAuth state mismatch (expected=$expected got=$returned)';
}
