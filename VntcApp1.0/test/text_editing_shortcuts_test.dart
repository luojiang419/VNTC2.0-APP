import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/utils/text_editing_shortcuts.dart';

void main() {
  test('replaceSelectionWithText replaces current selection', () {
    const value = TextEditingValue(
      text: 'hello world',
      selection: TextSelection(baseOffset: 6, extentOffset: 11),
    );

    final nextValue = replaceSelectionWithText(value, 'VNT');

    expect(nextValue.text, 'hello VNT');
    expect(nextValue.selection, const TextSelection.collapsed(offset: 9));
  });

  testWidgets('paste action inserts clipboard text into focused TextField',
      (tester) async {
    final controller = TextEditingController(text: 'hello world');
    final clipboard = _MemoryClipboard(' VNT');
    addTearDown(controller.dispose);

    await _pumpField(tester, controller, clipboard: clipboard);
    controller.selection = const TextSelection.collapsed(offset: 5);

    await _invokeTextEditAction(
      tester,
      VntTextEditOperation.paste,
    );

    expect(controller.text, 'hello VNT world');
    expect(controller.selection, const TextSelection.collapsed(offset: 9));
  });

  testWidgets('copy and cut actions use the focused TextField selection',
      (tester) async {
    final controller = TextEditingController(text: 'hello world');
    final clipboard = _MemoryClipboard();
    addTearDown(controller.dispose);

    await _pumpField(tester, controller, clipboard: clipboard);
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);

    await _invokeTextEditAction(
      tester,
      VntTextEditOperation.copy,
    );
    expect(clipboard.text, 'hello');
    expect(controller.text, 'hello world');

    await _invokeTextEditAction(
      tester,
      VntTextEditOperation.cut,
    );
    expect(clipboard.text, 'hello');
    expect(controller.text, ' world');
  });

  testWidgets('select all action selects focused TextField text',
      (tester) async {
    final controller = TextEditingController(text: 'hello world');
    addTearDown(controller.dispose);

    await _pumpField(tester, controller);

    await _invokeTextEditAction(
      tester,
      VntTextEditOperation.selectAll,
    );

    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 11),
    );
  });
}

Future<void> _pumpField(
  WidgetTester tester,
  TextEditingController controller, {
  VntClipboardBridge clipboard = const SystemVntClipboardBridge(),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: VntTextEditingShortcuts(
          clipboard: clipboard,
          child: TextField(
            autofocus: true,
            controller: controller,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byType(TextField));
  await tester.pump();
}

class _MemoryClipboard extends VntClipboardBridge {
  _MemoryClipboard([this.text]);

  String? text;

  @override
  Future<String?> getText() async => text;

  @override
  Future<void> setText(String text) async {
    this.text = text;
  }
}

Future<void> _invokeTextEditAction(
  WidgetTester tester,
  VntTextEditOperation operation,
) async {
  final context = tester.element(find.byType(TextField));
  final result = Actions.invoke(context, VntTextEditIntent(operation));
  if (result is Future) {
    await result;
  }
  await tester.pump();
}
