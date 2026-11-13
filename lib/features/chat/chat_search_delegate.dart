import 'package:flutter/material.dart';

import '../../core/models/chat_message.dart';

class SearchMatch {
  final int messageIndex;
  final int matchIndexInMessage;
  const SearchMatch(this.messageIndex, this.matchIndexInMessage);
}

class ChatSearchDelegate extends ChangeNotifier {
  bool _showSearch = false;
  String _searchQuery = '';
  List<SearchMatch> _searchMatches = [];
  int _searchCurrentIndex = 0;
  int _searchRevision = 0;
  int? _countedMessagesSignature;
  final TextEditingController searchController = TextEditingController();

  bool get showSearch => _showSearch;
  String get searchQuery => _searchQuery;
  List<SearchMatch> get searchMatches => _searchMatches;
  int get searchCurrentIndex => _searchCurrentIndex;
  int get matchCount => _searchMatches.length;

  /// The match the reader is on, or null while there is none.
  SearchMatch? get activeMatch =>
      _searchMatches.isEmpty || _searchCurrentIndex >= _searchMatches.length
      ? null
      : _searchMatches[_searchCurrentIndex];

  /// The active match as the page numbers it. [searchMatches] are counted
  /// over the whole chat, but the page holds only the scrollback window —
  /// the messages from [visibleStartIndex] on — and numbers its highlights
  /// from the first of those. Handing it the chat-wide index sent it to the
  /// wrong hit, or past its last one, which left the arrows looking dead.
  /// -1 when the active match sits in a message the page does not have yet;
  /// `ChatNotifier.revealMessageIndex` widens the window to it first.
  int pageMatchIndex(int visibleStartIndex) {
    final active = activeMatch;
    if (active == null || active.messageIndex < visibleStartIndex) return -1;
    var before = 0;
    for (final match in _searchMatches) {
      if (match.messageIndex < visibleStartIndex) before++;
    }
    return _searchCurrentIndex - before;
  }

  /// Bumped every time the match list is recounted over a *changed* message
  /// list (see [syncWithMessages]). The query and the active index can both
  /// come out of such a recount unchanged, so they are not enough to tell the
  /// WebView that its highlights are stale — this counter is.
  int get searchRevision => _searchRevision;

  VoidCallback? get onSearchPrev => _searchCurrentIndex > 0 ? searchPrev : null;
  VoidCallback? get onSearchNext =>
      _searchCurrentIndex < _searchMatches.length - 1 ? searchNext : null;

  void openSearch() {
    _searchQuery = '';
    _searchMatches = [];
    _searchCurrentIndex = 0;
    _countedMessagesSignature = null;
    searchController.clear();
    _showSearch = true;
    notifyListeners();
  }

  /// Desktop header: the search icon swaps the character block for the field.
  /// Highlighting still follows the query (see [syncInlineQuery]); this only
  /// says whether the field is shown.
  bool _inlineOpen = false;
  bool get inlineOpen => _inlineOpen;

  void openInline() {
    if (_inlineOpen) return;
    _inlineOpen = true;
    notifyListeners();
  }

  void closeSearch() {
    searchController.clear();
    _inlineOpen = false;
    _showSearch = false;
    _searchQuery = '';
    _searchMatches = [];
    _searchCurrentIndex = 0;
    _countedMessagesSignature = null;
    notifyListeners();
  }

  /// Desktop keeps the search field mounted in the header, so "search mode"
  /// follows the query instead of an explicit open/close. Unlike [openSearch]
  /// this never touches [searchController] — the user is typing into it.
  void syncInlineQuery(String query, List<ChatMessage> messages) {
    if (query.isEmpty) {
      if (!_showSearch) return;
      _showSearch = false;
      _searchQuery = '';
      _searchMatches = [];
      _searchCurrentIndex = 0;
      _countedMessagesSignature = null;
      notifyListeners();
      return;
    }
    _showSearch = true;
    search(query, messages);
  }

  /// Where the scrollback window the page holds starts; kept up to date by
  /// the chat screen. A new query starts on the first hit in that window —
  /// where the reader is — rather than the first in the whole chat, which on
  /// a long chat would load all of its history on the first keystroke. With
  /// no hit in the window it starts on the newest hit before it, the nearest
  /// one to load.
  int windowStart = 0;

  void search(String query, List<ChatMessage> messages) {
    _searchQuery = query;
    _searchMatches = _collectMatches(query, messages);
    final inWindow = _searchMatches.indexWhere(
      (m) => m.messageIndex >= windowStart,
    );
    _searchCurrentIndex = inWindow >= 0
        ? inWindow
        : (_searchMatches.isEmpty ? 0 : _searchMatches.length - 1);
    _countedMessagesSignature = _signatureOf(messages);
    notifyListeners();
  }

  /// Recounts the active query against [messages] when the chat changed
  /// underneath an open search.
  ///
  /// The match list used to be built only from the text field's `onChanged`,
  /// so editing (or deleting, or swiping) a message while the search bar was
  /// open froze it: the "n / m" counter kept reporting occurrences that no
  /// longer existed, and prev/next walked positions that had moved. The
  /// delegate now fingerprints the messages it counted over and recounts as
  /// soon as that fingerprint moves.
  ///
  /// Returns `true` when a recount happened, i.e. when listeners were
  /// notified.
  bool syncWithMessages(List<ChatMessage> messages) {
    if (!_showSearch || _searchQuery.isEmpty) return false;
    final signature = _signatureOf(messages);
    if (signature == _countedMessagesSignature) return false;
    _countedMessagesSignature = signature;

    final matches = _collectMatches(_searchQuery, messages);
    _searchMatches = matches;
    // Stay on the occurrence the reader was looking at instead of snapping
    // back to the first one; only clamp when the edit dropped the matches
    // after it.
    final lastIndex = matches.length - 1;
    _searchCurrentIndex = _searchCurrentIndex > lastIndex
        ? (lastIndex < 0 ? 0 : lastIndex)
        : _searchCurrentIndex;
    // The bubbles that changed were re-rendered by the message sync, which
    // highlights them without global match numbering — always ask for a fresh
    // highlight pass, even when the count and the index both came out the same.
    _searchRevision++;
    notifyListeners();
    return true;
  }

  /// Cheap fingerprint of everything [_collectMatches] reads. Ids are included
  /// so an insert/delete that happens to preserve the total text still counts
  /// as a change.
  int _signatureOf(List<ChatMessage> messages) => Object.hashAll([
    for (final m in messages) ...[m.id, m.content, m.reasoning],
  ]);

  List<SearchMatch> _collectMatches(String query, List<ChatMessage> messages) {
    final matches = <SearchMatch>[];
    if (query.isEmpty) return matches;
    final lower = query.toLowerCase();
    for (int i = 0; i < messages.length; i++) {
      var raw = messages[i].content;
      if (raw.contains('<think')) {
        raw = raw.replaceAll(
          RegExp(
            r'<think\b[^>]*>[\s\S]*?<\/think\b[^>]*>',
            caseSensitive: false,
          ),
          '',
        );
        raw = raw.replaceAll(
          RegExp(
            r'<think\b([^>]*?)(?:>|\n)([\s\S]*?)<\/think\b',
            caseSensitive: false,
          ),
          '',
        );
      }
      if (raw.contains('<thinking')) {
        raw = raw.replaceAll(
          RegExp(
            r'<thinking\b[^>]*>[\s\S]*?<\/thinking\b[^>]*>',
            caseSensitive: false,
          ),
          '',
        );
        raw = raw.replaceAll(
          RegExp(
            r'<thinking\b([^>]*?)(?:>|\n)([\s\S]*?)<\/thinking\b',
            caseSensitive: false,
          ),
          '',
        );
      }
      raw = raw.trim();
      final content = raw.toLowerCase();

      final reasoning = messages[i].reasoning?.toLowerCase() ?? '';

      int matchIndex = 0;

      if (reasoning.isNotEmpty) {
        int startIndex = 0;
        while (true) {
          final idx = reasoning.indexOf(lower, startIndex);
          if (idx == -1) break;
          matches.add(SearchMatch(i, matchIndex));
          matchIndex++;
          startIndex = idx + lower.length;
        }
      }

      int startIndex = 0;
      while (true) {
        final idx = content.indexOf(lower, startIndex);
        if (idx == -1) break;
        matches.add(SearchMatch(i, matchIndex));
        matchIndex++;
        startIndex = idx + lower.length;
      }
    }
    return matches;
  }

  void searchNext() {
    if (_searchCurrentIndex < _searchMatches.length - 1) {
      _searchCurrentIndex++;
      notifyListeners();
    }
  }

  void searchPrev() {
    if (_searchCurrentIndex > 0) {
      _searchCurrentIndex--;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    searchController.dispose();
    super.dispose();
  }
}
