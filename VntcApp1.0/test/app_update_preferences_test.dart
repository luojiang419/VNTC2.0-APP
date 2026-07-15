import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vnt_app/update/app_update_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('更新策略默认使用手动更新', () async {
    final preferences = AppUpdatePreferences();

    expect(await preferences.loadMode(), AppUpdateMode.manual);
  });

  test('更新策略可以持久化三种模式', () async {
    final preferences = AppUpdatePreferences();

    for (final mode in AppUpdateMode.values) {
      await preferences.saveMode(mode);
      expect(await preferences.loadMode(), mode);
    }
  });

  test('未知的持久化值安全回退到手动更新', () async {
    SharedPreferences.setMockInitialValues({
      AppUpdatePreferences.preferenceKey: 'future-mode',
    });

    expect(
      await AppUpdatePreferences().loadMode(),
      AppUpdateMode.manual,
    );
  });

  test('更新策略行为与三态定义一致', () {
    expect(AppUpdateMode.manual.checksForUpdates, isTrue);
    expect(AppUpdateMode.manual.installsAutomatically, isFalse);
    expect(AppUpdateMode.automatic.checksForUpdates, isTrue);
    expect(AppUpdateMode.automatic.installsAutomatically, isTrue);
    expect(AppUpdateMode.disabled.checksForUpdates, isFalse);
    expect(AppUpdateMode.disabled.installsAutomatically, isFalse);
  });

  test('更新策略提供设置页所需的三组名称和说明', () {
    expect(AppUpdateMode.manual.label, '手动更新');
    expect(AppUpdateMode.manual.description, contains('弹窗提示'));
    expect(AppUpdateMode.automatic.label, '自动更新');
    expect(AppUpdateMode.automatic.description, contains('直接进入安装'));
    expect(AppUpdateMode.disabled.label, '关闭更新');
    expect(AppUpdateMode.disabled.description, contains('不检测'));
  });
}
