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
  final TextEditingController searchController = TextEditingController();

  bool get showSearch => _showSearch;
  String get searchQuery => _searchQuery;
  List<SearchMatch> get searchMatches => _searchMatches;
  int get searchCurrentIndex => _searchCurrentIndex;
  int get matchCount => _searchMatches.length;

  VoidCallback? get onSearchPrev =>
      _searchCurrentIndex > 0 ? searchPrev : null;
  VoidCallback? get onSearchNext =>
      _searchCurrentIndex < _searchMatches.length - 1 ? searchNext : null;

  void openSearch() {
    _searchQuery = '';
    _searchMatches = [];
    _searchCurrentIndex = 0;
    searchController.clear();
    _showSearch = true;
    notifyListeners();
  }

  void closeSearch() {
    searchController.clear();
    _showSearch = false;
    _searchQuery = '';
    _searchMatches = [];
    _searchCurrentIndex = 0;
    notifyListeners();
  }

  void search(String query, List<ChatMessage> messages) {
    final matches = <SearchMatch>[];
    if (query.isNotEmpty) {
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
    }

    _searchQuery = query;
    _searchMatches = matches;
    _searchCurrentIndex = 0;
    notifyListeners();
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
