import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/features/chat/chrome/chat_chrome_channel.dart';
import 'package:glaze_flutter/features/chat/chrome/chrome_json.dart';
import 'package:glaze_flutter/features/chat/widgets/chat_status_card_shell.dart';

/// The status cards are drawn by the chat page (chrome/cards.js); the shell
/// hands each one to it as a chrome section.
void main() {
  testWidgets('hands the page the card with its spinner and action', (
    tester,
  ) async {
    final channel = ChatChromeChannel();
    var stopped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatStatusCardShell(
            channel: channel,
            slot: 'statusCleaner',
            label: 'Working',
            icon: Icons.sync,
            accent: Colors.orange,
            showSpinner: true,
            action: ChatStatusCardAction(
              onPressed: () => stopped++,
              tooltip: 'Stop work',
              icon: Icons.stop_circle_outlined,
              color: Colors.red,
            ),
          ),
        ),
      ),
    );

    final card = channel.debugSections['statusCleaner']! as Map;
    expect(card['label'], 'Working');
    expect(card['spinner'], isTrue);
    expect(card['accent'], chromeColor(Colors.orange));
    final action = card['action'] as Map;
    expect(action['tip'], 'Stop work');
    expect(action['icon'], chromeIcon(Icons.stop_circle_outlined));
    expect(action['color'], chromeColor(Colors.red));

    // Nothing of it is laid out in Flutter.
    expect(find.text('Working'), findsNothing);

    // The page's tap comes back as an intent naming the card.
    channel.debugIntent('statusAction', {'id': 'statusStudio'});
    expect(stopped, 0);
    channel.debugIntent('statusAction', {'id': 'statusCleaner'});
    expect(stopped, 1);
  });

  testWidgets('a card without an action, and taking it off the page', (
    tester,
  ) async {
    final channel = ChatChromeChannel();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatStatusCardShell(
            channel: channel,
            slot: 'statusStudio',
            label: 'Complete',
            icon: Icons.check_circle_outline,
            accent: Colors.green,
            showSpinner: false,
          ),
        ),
      ),
    );

    final card = channel.debugSections['statusStudio']! as Map;
    expect(card['label'], 'Complete');
    expect(card['spinner'], isFalse);
    expect(card['icon'], chromeIcon(Icons.check_circle_outline));
    expect(card['action'], isNull);

    // Unmounting the shell takes the card off the page.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(channel.debugSections['statusStudio'], isNull);
  });
}
