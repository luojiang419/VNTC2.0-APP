import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/shared/widgets/app_state_view.dart';

void main() {
  testWidgets('加载空白错误状态都有明确文字与动作', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            const Expanded(child: AppStateView.loading()),
            const Expanded(
              child: AppStateView.empty(title: '暂无数据', message: '列表为空'),
            ),
            Expanded(
              child: AppStateView.error(
                message: '服务不可达',
                onAction: () => retried = true,
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('正在加载'), findsOneWidget);
    expect(find.text('暂无数据'), findsOneWidget);
    expect(find.text('加载失败'), findsOneWidget);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    expect(retried, isTrue);
  });
}
