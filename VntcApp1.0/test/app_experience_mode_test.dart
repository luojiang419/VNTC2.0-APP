import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vnt_app/app_experience_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('体验模式默认使用极简模式', () async {
    expect(
      await AppExperiencePreferences().loadMode(),
      AppExperienceMode.regular,
    );
  });

  test('专业模式与极简模式可以持久化切换', () async {
    final preferences = AppExperiencePreferences();

    await preferences.saveMode(AppExperienceMode.professional);
    expect(await preferences.loadMode(), AppExperienceMode.professional);

    await preferences.saveMode(AppExperienceMode.regular);
    expect(await preferences.loadMode(), AppExperienceMode.regular);
  });

  test('未知模式安全回退到极简模式', () async {
    SharedPreferences.setMockInitialValues({
      AppExperiencePreferences.modePreferenceKey: 'future-mode',
    });

    expect(
      await AppExperiencePreferences().loadMode(),
      AppExperienceMode.regular,
    );
  });

  test('极简模式添加配置引导完成状态可以持久化', () async {
    final preferences = AppExperiencePreferences();

    expect(await preferences.hasCompletedOnboarding(), isFalse);
    await preferences.completeOnboarding();
    expect(await preferences.hasCompletedOnboarding(), isTrue);
  });
}
