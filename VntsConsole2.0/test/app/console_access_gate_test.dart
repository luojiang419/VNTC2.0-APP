import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/app/app.dart';
import 'package:vnts_console/app/app_controller.dart';
import 'package:vnts_console/core/networking/api_client.dart';

void main() {
  testWidgets('未登录时只显示全屏门禁，输入账号密码后才能进入软件', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1180, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final apiClient = _GateApiClient();
    final controller = AppController(
      themeMode: ThemeMode.dark,
      apiClient: apiClient,
      autoLockHours: 0,
    );
    addTearDown(controller.dispose);
    addTearDown(apiClient.close);

    await tester.pumpWidget(VntsConsoleApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('console-access-gate')), findsOneWidget);
    expect(find.byKey(const Key('navigation-expanded')), findsNothing);
    expect(find.byKey(const Key('navigation-collapsed')), findsNothing);
    expect(find.text('立即登录'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('login-now'))).onPressed,
      isNull,
    );

    await tester.enterText(find.byKey(const Key('access-username')), 'admin');
    await tester.enterText(find.byKey(const Key('access-password')), 'x');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('login-now'))).onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('login-now')));
    await tester.pumpAndSettle();

    expect(controller.isAuthenticated, isTrue);
    expect(find.byKey(const Key('console-access-gate')), findsNothing);
    expect(find.byKey(const Key('navigation-expanded')), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('控制台已锁定'), findsOneWidget);
    expect(find.byKey(const Key('navigation-expanded')), findsNothing);
  });
}

class _GateApiClient extends ApiClient {
  _GateApiClient() : super(baseUri: Uri.parse('http://127.0.0.1:29871/api/'));

  bool _loggedIn = false;

  @override
  bool get hasSession => _loggedIn;

  @override
  Future<void> login({
    required String username,
    required String password,
  }) async {
    _loggedIn = true;
  }

  @override
  void clearSession() {
    _loggedIn = false;
    super.clearSession();
  }
}
