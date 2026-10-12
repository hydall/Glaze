import '../../../core/models/chat_message.dart';

/// What a plugin-visible message looked like at the last notification.
typedef PluginMessageSignature = ({String content, bool hidden, int swipeId});

Map<String, PluginMessageSignature> pluginMessageSignatures(
  List<ChatMessage> messages,
) => {
  for (final m in messages)
    m.id: (content: m.content, hidden: m.isHidden, swipeId: m.swipeId),
};

/// One `message:added|updated|deleted` notification.
typedef PluginMessageChange = ({
  String change,
  String id,
  ChatMessage? message,
  int index,
});

/// Changes between two settled snapshots of the same chat, in list order;
/// deletions come first.
List<PluginMessageChange> diffPluginMessages(
  Map<String, PluginMessageSignature> before,
  List<ChatMessage> after,
) {
  final out = <PluginMessageChange>[];
  final present = {for (final m in after) m.id};
  for (final id in before.keys) {
    if (!present.contains(id)) {
      out.add((change: 'deleted', id: id, message: null, index: -1));
    }
  }
  for (final (index, m) in after.indexed) {
    final old = before[m.id];
    if (old == null) {
      out.add((change: 'added', id: m.id, message: m, index: index));
    } else if (old.content != m.content ||
        old.hidden != m.isHidden ||
        old.swipeId != m.swipeId) {
      out.add((change: 'updated', id: m.id, message: m, index: index));
    }
  }
  return out;
}
