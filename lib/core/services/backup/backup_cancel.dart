/// Cancellation token shared by [BackupService] and importers.
class ImportCancellationToken {
  final bool Function() _isCancelled;
  final void Function() _check;

  const ImportCancellationToken._(this._isCancelled, this._check);

  /// Public constructor used by [BackupService] to wrap its own flag.
  /// Importers receive a token constructed by the service.
  factory ImportCancellationToken.wrap({
    required bool Function() isCancelled,
    required void Function() check,
  }) =>
      ImportCancellationToken._(isCancelled, check);

  bool get isCancelled => _isCancelled();

  /// Throws [ImportCancelledException] if cancellation was requested.
  void check() => _check();
}

/// Thrown by [ImportCancellationToken.check] when the user has
/// cancelled an in-flight import.
class ImportCancelledException implements Exception {
  const ImportCancelledException();
  @override
  String toString() => 'ImportCancelledException';
}

/// Sentinel token used by importers that don't support cancellation.
const ImportCancellationToken noCancel = ImportCancellationToken._(
  _neverCancelled,
  _neverCheck,
);

bool _neverCancelled() => false;
void _neverCheck() {}
