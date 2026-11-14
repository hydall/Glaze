import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/widgets/generic_editor.dart';

class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  Map<String, dynamic> item = const {'content': '', 'prompt': ''};

  int onChangedCalls = 0;

  void loadFromStore() {
    setState(() {
      item = const {
        'content': 'a summary that was already saved',
        'prompt': 'a custom prompt',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: GenericEditor(
            item: item,
            config: const [
              GenericEditorSection(
                fields: [
                  GenericEditorField(
                    key: 'content',
                    label: 'Content',
                    type: 'textarea',
                  ),
                  GenericEditorField(
                    key: 'prompt',
                    label: 'Prompt',
                    type: 'textarea',
                  ),
                ],
              ),
            ],
            onChanged: (val) {
              onChangedCalls++;
              setState(() => item = val);
            },
          ),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'syncing a late-loaded item into the controllers never calls onChanged',
    (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(_Host(key: key));
      await tester.pump();

      key.currentState!.loadFromStore();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(key.currentState!.onChangedCalls, 0);
      expect(
        find.text('a summary that was already saved'),
        findsOneWidget,
      );
    },
  );
}
