/// What the setup was asked to do, from its command line.
///
/// The launcher passes on whatever it was started with and adds `--package`
/// (the setup file itself) and `--payload` (the Glaze zip it unpacked).
///
/// - no mode: the install wizard.
/// - `--update`: started by Glaze's in-app updater, which quits right after.
///   Waits for Glaze to close, installs over it without asking and starts it
///   again.
/// - `--uninstall`: the Apps entry. `--silent` with it removes the program and
///   keeps the data, with no window.
/// - `--import-from <folder>`: the folder of a portable Glaze the in-app
///   updater was started from. Its WebView2 profile (catalog logins) is
///   copied into a fresh install, which would otherwise start logged out.
/// - `--demo`: no changes to the system, for previews and tests.
enum SetupMode { install, update, uninstall }

class SetupArgs {
  final SetupMode mode;
  final bool silent;
  final bool demo;
  final String? package;
  final String? payload;
  final String? importFrom;

  const SetupArgs({
    this.mode = SetupMode.install,
    this.silent = false,
    this.demo = false,
    this.package,
    this.payload,
    this.importFrom,
  });

  factory SetupArgs.parse(List<String> args) {
    var mode = SetupMode.install;
    var silent = false;
    var demo = false;
    String? package;
    String? payload;
    String? importFrom;
    for (var i = 0; i < args.length; i++) {
      String? next() => i + 1 < args.length ? args[++i] : null;
      switch (args[i].toLowerCase()) {
        case '--update':
          mode = SetupMode.update;
        case '--uninstall':
          mode = SetupMode.uninstall;
        case '--silent':
          silent = true;
        case '--demo':
          demo = true;
        case '--package':
          package = next();
        case '--payload':
          payload = next();
        case '--import-from':
          importFrom = next();
      }
    }
    return SetupArgs(
      mode: mode,
      // Only an uninstall may run unseen: an install or an update always
      // shows where it stands.
      silent: silent && mode == SetupMode.uninstall,
      demo: demo,
      package: package,
      payload: payload,
      importFrom: importFrom,
    );
  }
}
