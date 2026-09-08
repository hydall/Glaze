import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/generation_notification_service.dart';
import '../../../core/state/shared_prefs_provider.dart';
import '../../extensions/services/periodic_trigger_scheduler.dart';
import '../chat_provider.dart';
import '../unread_sessions_provider.dart';

class SessionLifecycleTracker extends ConsumerStatefulWidget {
  final String charId;
  final Widget child;
  const SessionLifecycleTracker({super.key, required this.charId, required this.child});

  @override
  ConsumerState<SessionLifecycleTracker> createState() => _SessionLifecycleTrackerState();
}

class _SessionLifecycleTrackerState extends ConsumerState<SessionLifecycleTracker> with WidgetsBindingObserver {
  DateTime? _enteredAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enteredAt = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncActiveContext());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    GenerationNotificationService.instance.setActiveContext(null, null);
    _flushTime();
    super.dispose();
  }

  void _syncActiveContext() {
    if (!mounted) return;
    final session = ref.read(chatProvider(widget.charId)).value?.session;
    GenerationNotificationService.instance.setActiveContext(
      widget.charId,
      session?.id,
    );
    ref.read(periodicTriggerSchedulerProvider);
    // Opening / focusing a session clears its unread dot in the chat list.
    final sessionId = session?.id;
    if (sessionId != null) {
      ref.read(unreadSessionsProvider.notifier).markRead(sessionId);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _enteredAt = DateTime.now();
      // `isActiveSession` is false while the app is backgrounded, so a reply
      // that landed then was flagged unread even though this chat stayed open.
      // Coming back to it is reading it — clear the dot (and restore the active
      // context, which suppresses redundant notifications).
      _syncActiveContext();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _flushTime();
    }
  }

  Future<void> _flushTime() async {
    if (_enteredAt == null) return;
    final elapsed = DateTime.now().difference(_enteredAt!).inSeconds;
    _enteredAt = null;
    if (elapsed <= 0) return;
    try {
      final prefs = await ref.read(sharedPreferencesProvider.future);
      final key = 'chat_time_${widget.charId}';
      final prev = prefs.getInt(key) ?? 0;
      await prefs.setInt(key, prev + elapsed);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatProvider(widget.charId), (_, _) => _syncActiveContext());
    return widget.child;
  }
}
