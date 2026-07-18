import 'package:shared_preferences/shared_preferences.dart';

enum AppExperienceMode {
  regular('regular'),
  professional('professional');

  const AppExperienceMode(this.storageValue);

  final String storageValue;

  bool get isProfessional => this == AppExperienceMode.professional;

  String get label => switch (this) {
        // 保留 regular 存储值兼容旧版本，界面统一使用“极简模式”。
        AppExperienceMode.regular => '极简模式',
        AppExperienceMode.professional => '专业模式',
      };

  static AppExperienceMode fromStorage(String? value) {
    for (final mode in values) {
      if (mode.storageValue == value) {
        return mode;
      }
    }
    return AppExperienceMode.regular;
  }
}

class AppExperiencePreferences {
  static const modePreferenceKey = 'app_experience_mode';
  static const onboardingPreferenceKey =
      'regular_mode_add_config_onboarding_completed';

  Future<AppExperienceMode> loadMode() async {
    final preferences = await SharedPreferences.getInstance();
    return AppExperienceMode.fromStorage(
      preferences.getString(modePreferenceKey),
    );
  }

  Future<void> saveMode(AppExperienceMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(modePreferenceKey, mode.storageValue);
  }

  Future<bool> hasCompletedOnboarding() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(onboardingPreferenceKey) ?? false;
  }

  Future<void> completeOnboarding() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(onboardingPreferenceKey, true);
  }
}
