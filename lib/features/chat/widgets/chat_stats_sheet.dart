import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/platform_paths.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/services/model_usage_service.dart';
import '../../../core/state/shared_prefs_provider.dart';
import '../../../core/models/character.dart';
import '../../../core/models/chat_message.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/utils/time_formatter.dart';
import '../../../shared/widgets/rolling_number.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../../../shared/widgets/glaze_tab_bar.dart';
import '../../../shared/widgets/swipe_tab_switcher.dart';
import '../../../shared/widgets/tab_slide_switcher.dart';
import '../chat_provider.dart';

class _StatsData {
  final int tokens;
  final int characters;
  final int messages;
  final int regenerations;
  final int deleted;
  final int timeSpent;
  final String firstMessage;

  const _StatsData({
    this.tokens = 0,
    this.characters = 0,
    this.messages = 0,
    this.regenerations = 0,
    this.deleted = 0,
    this.timeSpent = 0,
    this.firstMessage = '-',
  });

  _StatsData copyWith({
    int? tokens,
    int? characters,
    int? messages,
    int? regenerations,
    int? deleted,
    int? timeSpent,
    String? firstMessage,
  }) {
    return _StatsData(
      tokens: tokens ?? this.tokens,
      characters: characters ?? this.characters,
      messages: messages ?? this.messages,
      regenerations: regenerations ?? this.regenerations,
      deleted: deleted ?? this.deleted,
      timeSpent: timeSpent ?? this.timeSpent,
      firstMessage: firstMessage ?? this.firstMessage,
    );
  }
}

class ChatStatsSheet extends ConsumerStatefulWidget {
  final String initialCharId;

  const ChatStatsSheet({super.key, required this.initialCharId});

  @override
  ConsumerState<ChatStatsSheet> createState() => _ChatStatsSheetState();
}

class _ChatStatsSheetState extends ConsumerState<ChatStatsSheet> {
  String _currentTab = 'chat';
  String? _selectedCharId;
  String? _selectedSessionId;
  List<Character> _allCharacters = [];
  List<ChatSession> _allSessions = [];
  bool _showCharDropdown = false;
  bool _showChatDropdown = false;
  bool _loading = true;

  _StatsData _chatStats = const _StatsData();
  _StatsData _charStats = const _StatsData();
  _StatsData _generalStats = const _StatsData();

  /// Top 10 most-used models (global), highest count first.
  List<MapEntry<String, int>> _topModels = const [];

  Timer? _updateInterval;

  @override
  void initState() {
    super.initState();
    _selectedCharId = widget.initialCharId;
    _initData();
    _updateInterval = Timer.periodic(const Duration(seconds: 1), (_) {
      _updateTimeStats();
    });
  }

  @override
  void dispose() {
    _updateInterval?.cancel();
    super.dispose();
  }

  Future<void> _initData() async {
    // Read characters straight from the DB for the same reason as the sessions
    // below: `charactersProvider` is an AsyncNotifier, so a plain `read` on a
    // sheet opened before it was warmed returns `AsyncLoading` (no value) and
    // the list would stay empty for the sheet's whole lifetime — the character
    // picker then shows "—" and the chat picker falls back to raw character ids.
    _allCharacters = await ref.read(characterRepoProvider).getAll();
    if (!mounted) return;
    // Read sessions straight from the DB rather than the cached provider: the
    // cache is not invalidated on message edits/deletions (counts would lag),
    // and a plain repo future reliably completes so the initial compute — and
    // thus the General tab — never gets stuck behind an unresolved provider.
    _allSessions = await ref.read(chatRepoProvider).getAllSessions();
    if (!mounted) return;

    // Order by most-recent interaction (message timestamps, branch/creation and
    // updatedAt all considered — same signal that sorts the session list) so the
    // pickers default to, and list, the last chat/character the user engaged
    // with rather than whatever the DB happened to return first.
    _allSessions.sort((a, b) => b.lastActivityMs.compareTo(a.lastActivityMs));

    // Global entry point (opened from Tools with no character/chat context):
    // seed defaults from the last-interacted chat so every tab shows data
    // immediately instead of waiting for the user to pick a character/chat.
    if (_selectedCharId == null || _selectedCharId!.isEmpty) {
      // Skip sessions whose character no longer exists — seeding the picker with
      // an orphaned id would leave the Character tab without a name or avatar.
      final knownIds = _allCharacters.map((c) => c.id).toSet();
      _selectedCharId = _allSessions
              .where((s) => knownIds.contains(s.characterId))
              .firstOrNull
              ?.characterId ??
          (_allCharacters.isNotEmpty ? _allCharacters.first.id : null);
    }
    String? currentSessionId;
    if (widget.initialCharId.isNotEmpty) {
      currentSessionId = ref
          .read(chatProvider(widget.initialCharId))
          .value
          ?.session
          ?.id;
    }
    _selectedSessionId =
        currentSessionId ??
        (_allSessions.isNotEmpty ? _allSessions.first.id : null);

    await _calculateStats();
    if (mounted) {
      setState(() => _loading = false);
    }
    // Best-effort: never let a slow/failed model-usage read block the stats.
    await _loadTopModels();
  }

  Future<void> _loadTopModels() async {
    final counts = await ref.read(modelUsageServiceProvider).getUsageCounts();
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    if (!mounted) return;
    setState(() => _topModels = sorted.take(10).toList());
  }

  Future<void> _updateTimeStats() async {
    if (!mounted) return;
    final prefs = await ref.read(sharedPreferencesProvider.future);

    // Time is tracked per character (`chat_time_<charId>`), the finest
    // granularity available. The Chat tab shows the time for the character
    // that owns the selected chat.
    final chatCharId = _allSessions
        .where((s) => s.id == _selectedSessionId)
        .firstOrNull
        ?.characterId;

    int chatTime = 0;
    int charTime = 0;
    int generalTime = 0;

    for (final key in prefs.getKeys()) {
      if (key.startsWith('chat_time_')) {
        final t = prefs.getInt(key) ?? 0;
        generalTime += t;
        final cid = key.replaceFirst('chat_time_', '');
        if (cid == _selectedCharId) charTime += t;
        if (cid == chatCharId) chatTime += t;
      }
    }

    if (!mounted) return;
    setState(() {
      _generalStats = _generalStats.copyWith(timeSpent: generalTime);
      _charStats = _charStats.copyWith(timeSpent: charTime);
      _chatStats = _chatStats.copyWith(timeSpent: chatTime);
    });
  }

  Future<void> _calculateStats() async {
    final selectedSessionId = _selectedSessionId;

    int chatMsg = 0, chatTok = 0, chatChar = 0, chatRegen = 0, chatDel = 0;
    int charMsg = 0, charTok = 0, charChar = 0, charRegen = 0, charDel = 0;
    int genMsg = 0, genTok = 0, genChar = 0, genRegen = 0, genDel = 0;

    int? chatFirstMsg, charFirstMsg, genFirstMsg;

    for (final session in _allSessions) {
      final isCurrentChar = session.characterId == _selectedCharId;
      final isCurrentChat = session.id == selectedSessionId;

      // Deleted messages are removed from the session, so they can't be counted
      // from the live message list. Read the persisted per-session counter that
      // `ChatMessageService.deleteMessages` maintains instead.
      final sessionDeleted = session.deletedMessageCount;
      genDel += sessionDeleted;
      if (isCurrentChar) charDel += sessionDeleted;
      if (isCurrentChat) chatDel += sessionDeleted;

      for (final msg in session.messages) {
        final int tokens = (msg.tokens?.toInt()) ?? (msg.content.length ~/ 4);
        final int chars = msg.content.length.toInt();
        final int regens = msg.swipes.length > 1
            ? (msg.swipes.length - 1).toInt()
            : 0;
        final ts = msg.timestamp;

        // General
        genMsg++;
        genTok += tokens;
        genChar += chars;
        genRegen += regens;
        if (ts != null && (genFirstMsg == null || ts < genFirstMsg)) {
          genFirstMsg = ts;
        }

        // Character
        if (isCurrentChar) {
          charMsg++;
          charTok += tokens;
          charChar += chars;
          charRegen += regens;
          if (ts != null && (charFirstMsg == null || ts < charFirstMsg)) {
            charFirstMsg = ts;
          }
        }

        // Chat
        if (isCurrentChat) {
          chatMsg++;
          chatTok += tokens;
          chatChar += chars;
          chatRegen += regens;
          if (ts != null && (chatFirstMsg == null || ts < chatFirstMsg)) {
            chatFirstMsg = ts;
          }
        }
      }
    }

    String formatDate(int? ts) {
      if (ts == null) return '-';
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }

    setState(() {
      _chatStats = _chatStats.copyWith(
        messages: chatMsg,
        tokens: chatTok,
        characters: chatChar,
        regenerations: chatRegen,
        deleted: chatDel,
        firstMessage: formatDate(chatFirstMsg),
      );
      _charStats = _charStats.copyWith(
        messages: charMsg,
        tokens: charTok,
        characters: charChar,
        regenerations: charRegen,
        deleted: charDel,
        firstMessage: formatDate(charFirstMsg),
      );
      _generalStats = _generalStats.copyWith(
        messages: genMsg,
        tokens: genTok,
        characters: genChar,
        regenerations: genRegen,
        deleted: genDel,
        firstMessage: formatDate(genFirstMsg),
      );
    });

    await _updateTimeStats();
  }

  String _formatTime(int seconds) {
    return formatDuration(seconds);
  }

  String _formatNumber(int number) {
    return number.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]},',
    );
  }

  _StatsData get _currentStats {
    switch (_currentTab) {
      case 'char':
        return _charStats;
      case 'general':
        return _generalStats;
      case 'chat':
      default:
        return _chatStats;
    }
  }

  Widget _buildHero(_StatsData stats) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            context.cs.primary,
            Color.lerp(context.cs.primary, Colors.black, 0.2)!,
          ],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      child: Column(
        children: [
          RollingNumber(
            value: _loading ? '...' : _formatNumber(stats.messages),
            style: const TextStyle(
              fontSize: 40,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.1,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'MESSAGES',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.75),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      RollingNumber(
                        value: _loading ? '...' : _formatNumber(stats.tokens),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'TOKENS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Colors.white.withValues(alpha: 0.65),
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 1,
                  height: 28,
                  color: Colors.white.withValues(alpha: 0.2),
                ),
                Expanded(
                  child: Column(
                    children: [
                      RollingNumber(
                        value: _loading
                            ? '...'
                            : _formatNumber(stats.characters),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'CHARACTERS',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Colors.white.withValues(alpha: 0.65),
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    bool isDate = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: context.cs.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 12),
          isDate
              ? AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    value,
                    key: ValueKey(value),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: context.cs.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.right,
                  ),
                )
              : RollingNumber(
                  value: value,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: context.cs.onSurfaceVariant,
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildTopModels() {
    final maxCount = _topModels.isEmpty ? 1 : _topModels.first.value;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Icon(
                  Icons.leaderboard_outlined,
                  size: 18,
                  color: context.cs.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Top Models',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: context.cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
          if (_topModels.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
              child: Text(
                _loading ? '...' : 'No model usage yet',
                style: TextStyle(
                  fontSize: 13,
                  color: context.cs.onSurfaceVariant,
                ),
              ),
            )
          else
            for (var i = 0; i < _topModels.length; i++)
              _buildModelRow(i, _topModels[i], maxCount),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _buildModelRow(int index, MapEntry<String, int> entry, int maxCount) {
    final fraction = maxCount == 0 ? 0.0 : entry.value / maxCount;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        entry.key,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: context.cs.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    RollingNumber(
                      value: _formatNumber(entry.value),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: context.cs.primary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: fraction.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: Colors.white.withValues(alpha: 0.06),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      context.cs.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeparator() {
    return Padding(
      padding: const EdgeInsets.only(left: 64),
      child: Container(
        height: 0.5,
        color: Colors.white.withValues(alpha: 0.06),
      ),
    );
  }

  /// Human label for a chat/session in the chat picker: `<character> · <chat>`.
  String _sessionLabel(ChatSession s) {
    final char = _allCharacters.where((c) => c.id == s.characterId).firstOrNull;
    // Never fall back to the raw character id — an orphaned session shows a
    // readable placeholder instead of a bare timestamp-looking number.
    final charName = (char?.name.trim().isNotEmpty ?? false)
        ? char!.name
        : 'Unknown character';
    final name = s.sessionVars['sessionName']?.trim();
    final chatName = (name != null && name.isNotEmpty)
        ? name
        : 'Chat #${s.sessionIndex + 1}';
    return '$charName · $chatName';
  }

  Widget _buildChatPicker() {
    final selected = _allSessions
        .where((s) => s.id == _selectedSessionId)
        .firstOrNull;
    final selectedChar = selected == null
        ? null
        : _allCharacters.where((c) => c.id == selected.characterId).firstOrNull;
    final label = selected == null ? '—' : _sessionLabel(selected);
    final charColor = selectedChar?.color ?? '#66ccff';
    final parsedColor = Color(int.parse(charColor.replaceFirst('#', '0xFF')));
    final selectedAvatar = selectedChar?.avatarPath;
    final selectedName = selectedChar?.name ?? '?';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: () => setState(() => _showChatDropdown = !_showChatDropdown),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: parsedColor,
                    shape: BoxShape.circle,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: selectedAvatar != null
                      ? Image.file(
                          File(resolveGlazeFilePath(selectedAvatar)!),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              _buildInitials(selectedName),
                        )
                      : const Icon(
                          Icons.chat_bubble,
                          color: Colors.white,
                          size: 18,
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  _showChatDropdown
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  color: context.cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(height: 0, width: double.infinity),
          secondChild: Container(
            margin: const EdgeInsets.only(top: 8),
            constraints: const BoxConstraints(maxHeight: 240),
            decoration: BoxDecoration(
              color: const Color(0xFF282828).withValues(alpha: 0.9),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: _allSessions.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      child: Text(
                        'No chats yet',
                        style: TextStyle(
                          fontSize: 14,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: _allSessions.length,
                      separatorBuilder: (context, index) => Container(
                        height: 0.5,
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                      itemBuilder: (context, index) {
                        final session = _allSessions[index];
                        final active = session.id == _selectedSessionId;
                        final char = _allCharacters
                            .where((c) => c.id == session.characterId)
                            .firstOrNull;
                        final avatarPath = char?.avatarPath;
                        final charName = char?.name ?? '?';
                        final cColor = Color(
                          int.parse(
                            (char?.color ?? '#66ccff').replaceFirst(
                              '#',
                              '0xFF',
                            ),
                          ),
                        );
                        return InkWell(
                          onTap: () {
                            setState(() {
                              _selectedSessionId = session.id;
                              _showChatDropdown = false;
                            });
                            unawaited(_calculateStats());
                          },
                          child: Container(
                            color: active
                                ? context.cs.primary.withValues(alpha: 0.08)
                                : Colors.transparent,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: cColor,
                                    shape: BoxShape.circle,
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: avatarPath != null
                                      ? Image.file(
                                          File(
                                            resolveGlazeFilePath(avatarPath)!,
                                          ),
                                          fit: BoxFit.cover,
                                          errorBuilder:
                                              (context, error, stackTrace) =>
                                                  _buildInitials(charName),
                                        )
                                      : _buildInitials(charName),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _sessionLabel(session),
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                      color: context.cs.onSurface,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (active)
                                  Icon(
                                    Icons.check,
                                    color: context.cs.primary,
                                    size: 20,
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          crossFadeState: _showChatDropdown
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }

  Widget _buildCharPicker() {
    final selectedChar = _allCharacters
        .where((c) => c.id == _selectedCharId)
        .firstOrNull;
    final charName = selectedChar?.name ?? '—';
    final charColor = selectedChar?.color ?? '#66ccff';
    final parsedColor = Color(int.parse(charColor.replaceFirst('#', '0xFF')));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: () => setState(() => _showCharDropdown = !_showCharDropdown),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: parsedColor,
                    shape: BoxShape.circle,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: selectedChar?.avatarPath != null
                      ? Image.file(
                          File(
                            resolveGlazeFilePath(selectedChar!.avatarPath!)!,
                          ),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              _buildInitials(charName),
                        )
                      : _buildInitials(charName),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    charName,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(
                  _showCharDropdown
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  color: context.cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(height: 0, width: double.infinity),
          secondChild: Container(
            margin: const EdgeInsets.only(top: 8),
            constraints: const BoxConstraints(maxHeight: 240),
            decoration: BoxDecoration(
              color: const Color(0xFF282828).withValues(alpha: 0.9),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: _allCharacters.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      child: Text(
                        _loading ? '...' : 'No characters yet',
                        style: TextStyle(
                          fontSize: 14,
                          color: context.cs.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: _allCharacters.length,
                      separatorBuilder: (context, index) => Container(
                        height: 0.5,
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                      itemBuilder: (context, index) {
                        final char = _allCharacters[index];
                        final active = char.id == _selectedCharId;
                        final cColor = Color(
                          int.parse(
                            (char.color ?? '#66ccff').replaceFirst('#', '0xFF'),
                          ),
                        );
                        return InkWell(
                          onTap: () {
                            setState(() {
                              _selectedCharId = char.id;
                              _showCharDropdown = false;
                            });
                            unawaited(_calculateStats());
                          },
                          child: Container(
                            color: active
                                ? context.cs.primary.withValues(alpha: 0.08)
                                : Colors.transparent,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: cColor,
                                    shape: BoxShape.circle,
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: char.avatarPath != null
                                      ? Image.file(
                                          File(
                                            resolveGlazeFilePath(
                                              char.avatarPath!,
                                            )!,
                                          ),
                                          fit: BoxFit.cover,
                                          errorBuilder:
                                              (context, error, stackTrace) =>
                                                  _buildInitials(char.name),
                                        )
                                      : _buildInitials(char.name),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    char.name,
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500,
                                      color: context.cs.onSurface,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (active)
                                  Icon(
                                    Icons.check,
                                    color: context.cs.primary,
                                    size: 20,
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          crossFadeState: _showCharDropdown
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }

  Widget _buildInitials(String name) {
    return Center(
      child: Text(
        name.isNotEmpty ? name[0].toUpperCase() : '?',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stats = _currentStats;

    return SheetView(
      title: 'Statistics',
      showHandle: true,
      fitContent: true,
      headerBottom: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: GlazeTabBar(
          tabs: const [
            GlazeTabItem(label: 'Chat', icon: Icons.chat_bubble),
            GlazeTabItem(label: 'Character', icon: Icons.person),
            GlazeTabItem(label: 'General', icon: Icons.public),
          ],
          activeIndex: _currentTab == 'chat'
              ? 0
              : (_currentTab == 'char' ? 1 : 2),
          onChanged: (index) {
            setState(() {
              _currentTab = index == 0
                  ? 'chat'
                  : (index == 1 ? 'char' : 'general');
            });
          },
        ),
      ),
      body: Builder(
        builder: (context) => SwipeTabSwitcher(
          index: _currentTab == 'chat' ? 0 : (_currentTab == 'char' ? 1 : 2),
          length: 3,
          onChanged: (index) => setState(() {
            _currentTab = index == 0
                ? 'chat'
                : (index == 1 ? 'char' : 'general');
          }),
          child: TabSlideSwitcher(
            index: _currentTab == 'chat' ? 0 : (_currentTab == 'char' ? 1 : 2),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.of(context).padding.top + 12,
                16,
                MediaQuery.of(context).padding.bottom + 24,
              ),
              children: [
                if (_currentTab == 'chat') ...[
                  _buildChatPicker(),
                  const SizedBox(height: 12),
                ],
                if (_currentTab == 'char') ...[
                  _buildCharPicker(),
                  const SizedBox(height: 12),
                ],
                _buildHero(stats),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      _buildStatItem(
                        icon: Icons.refresh,
                        color: const Color(0xFF4CAF50),
                        label: 'Regenerations',
                        value: _loading
                            ? '...'
                            : _formatNumber(stats.regenerations),
                      ),
                      _buildSeparator(),
                      _buildStatItem(
                        icon: Icons.delete_outline,
                        color: const Color(0xFFF44336),
                        label: 'Deleted',
                        value: _loading ? '...' : _formatNumber(stats.deleted),
                      ),
                      _buildSeparator(),
                      _buildStatItem(
                        icon: Icons.access_time,
                        color: const Color(0xFF2196F3),
                        label: _currentTab == 'general'
                            ? 'App Time'
                            : 'Time Spent',
                        value: _loading ? '...' : _formatTime(stats.timeSpent),
                      ),
                      _buildSeparator(),
                      _buildStatItem(
                        icon: Icons.history,
                        color: const Color(0xFFFF9800),
                        label: 'stats_first_msg'.tr(),
                        value: _loading ? '...' : stats.firstMessage,
                        isDate: true,
                      ),
                    ],
                  ),
                ),
                if (_currentTab == 'general') ...[
                  const SizedBox(height: 12),
                  _buildTopModels(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
