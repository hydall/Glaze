import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../saucepan_account_provider.dart';

/// Menu entry point for the "Saucepan Account" item. When already logged in it
/// offers a log-out sheet; otherwise it opens the login form.
Future<void> openSaucepanAccountSheet(
    BuildContext context, WidgetRef ref) async {
  if (!ref.read(saucepanAccountProvider).isLoggedIn) {
    await showSaucepanLoginSheet(context);
    return;
  }
  await GlazeBottomSheet.show<void>(
    context,
    title: 'Saucepan account',
    items: [
      BottomSheetItem(
        label: 'Log out',
        icon: Icons.logout_rounded,
        isDestructive: true,
        onTap: () async {
          Navigator.of(context, rootNavigator: true).pop();
          await ref.read(saucepanAccountProvider.notifier).logout();
        },
      ),
      BottomSheetItem(
        label: 'Cancel',
        icon: Icons.close_rounded,
        onTap: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ],
  );
}

/// Opens the Saucepan login form as a modal sheet.
Future<void> showSaucepanLoginSheet(BuildContext context) {
  return GlazeBottomSheet.show<void>(
    context,
    title: 'Log in to Saucepan',
    child: const _SaucepanLoginForm(),
  );
}

/// Handle + password login, with a "paste a bearer token instead" fallback.
/// Once a token is stored, pasting a `saucepan.ai/companion/…` URL into Import
/// extracts the companion locally on-device (see `import_url_dialog`).
class _SaucepanLoginForm extends ConsumerStatefulWidget {
  const _SaucepanLoginForm();

  @override
  ConsumerState<_SaucepanLoginForm> createState() => _SaucepanLoginFormState();
}

class _SaucepanLoginFormState extends ConsumerState<_SaucepanLoginForm> {
  final _handle = TextEditingController();
  final _password = TextEditingController();
  final _token = TextEditingController();
  bool _busy = false;
  bool _useToken = false;
  String? _error;

  @override
  void dispose() {
    _handle.dispose();
    _password.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        GlazeToast.show(context, 'Signed in to Saucepan');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  void _login() {
    final handle = _handle.text.trim();
    final password = _password.text;
    if (handle.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your handle and password.');
      return;
    }
    _run(() =>
        ref.read(saucepanAccountProvider.notifier).login(handle, password));
  }

  void _saveToken() {
    final token = _token.text.trim();
    if (token.isEmpty) {
      setState(() => _error = 'Paste a bearer token.');
      return;
    }
    _run(() => ref.read(saucepanAccountProvider.notifier).setToken(token));
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Extraction pulls the companion definition under your account and '
            'reassembles it on-device. A throwaway account is recommended.',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (!_useToken) ...[
            _field(cs, _handle, 'Handle', enabled: !_busy),
            const SizedBox(height: 10),
            _field(cs, _password, 'Password', obscure: true, enabled: !_busy),
            const SizedBox(height: 16),
            _primaryButton(cs, 'Log in', _busy ? null : _login),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _useToken = true),
              child: const Text('Use a bearer token instead'),
            ),
          ] else ...[
            _field(cs, _token, 'Bearer token', enabled: !_busy),
            const SizedBox(height: 16),
            _primaryButton(cs, 'Save token', _busy ? null : _saveToken),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _useToken = false),
              child: const Text('Log in with handle instead'),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _field(
    ColorScheme cs,
    TextEditingController controller,
    String hint, {
    bool obscure = false,
    bool enabled = true,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      enabled: enabled,
      style: TextStyle(fontSize: 14, color: cs.onSurface),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
        filled: true,
        fillColor: cs.surfaceContainerHighest,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _primaryButton(ColorScheme cs, String label, VoidCallback? onTap) {
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
        ),
        child: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Text(label,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
