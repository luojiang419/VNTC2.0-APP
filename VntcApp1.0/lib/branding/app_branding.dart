import 'dart:convert';
import 'dart:io';

class AppBranding {
  const AppBranding._({
    required this.isBranded,
    required this.productName,
    required this.windowTitle,
    required this.trayTooltip,
    required this.executableName,
    required this.installerBaseName,
    required this.updateEnabled,
    required this.hideAboutPage,
    required this.brandId,
    this.loadError,
  });

  static const String fileName = 'branding.json';
  static const String manifestFileName = 'brand_package_manifest.json';
  static const String androidAssetPath = 'assets/android_branding.json';
  static const String defaultProductName = 'VNTC APP2.0';
  static const String defaultExecutableName = 'vnt_app.exe';
  static const String defaultInstallerBaseName = 'VNT_App';

  static const AppBranding defaults = AppBranding._(
    isBranded: false,
    productName: defaultProductName,
    windowTitle: defaultProductName,
    trayTooltip: '$defaultProductName - Virtual Network Tool',
    executableName: defaultExecutableName,
    installerBaseName: defaultInstallerBaseName,
    updateEnabled: true,
    hideAboutPage: false,
    brandId: 'official',
  );

  final bool isBranded;
  final String productName;
  final String windowTitle;
  final String trayTooltip;
  final String executableName;
  final String installerBaseName;
  final bool updateEnabled;
  final bool hideAboutPage;
  final String brandId;
  final String? loadError;

  static AppBranding loadForExecutable([String? executablePath]) {
    final resolvedExecutable = executablePath ?? Platform.resolvedExecutable;
    final executableFile = File(resolvedExecutable);
    final brandingFile = File(
      '${executableFile.parent.path}${Platform.pathSeparator}$fileName',
    );
    return loadFromFile(
      brandingFile,
      fallbackUpdateEnabled: _fallbackUpdateEnabled(
        executableFile: executableFile,
        brandingFile: brandingFile,
      ),
    );
  }

  static AppBranding loadFromFile(
    File file, {
    bool fallbackUpdateEnabled = true,
  }) {
    if (!file.existsSync()) {
      return _fallbackBranding(updateEnabled: fallbackUpdateEnabled);
    }

    try {
      return loadFromJsonText(
        file.readAsStringSync(),
        fallbackUpdateEnabled: fallbackUpdateEnabled,
      );
    } catch (error) {
      return _fallbackBranding(
        updateEnabled: fallbackUpdateEnabled,
        loadError: error.toString(),
      );
    }
  }

  static AppBranding loadFromJsonText(
    String source, {
    bool fallbackUpdateEnabled = true,
  }) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('品牌配置根节点必须是 JSON 对象');
      }
      if (decoded['schemaVersion'] != 1) {
        throw const FormatException('不支持的品牌配置版本');
      }

      final productName = _requiredDisplayText(
        decoded['productName'],
        field: 'productName',
      );
      final windowTitle = _optionalDisplayText(
            decoded['windowTitle'],
            field: 'windowTitle',
          ) ??
          productName;
      final trayTooltip = _optionalDisplayText(
            decoded['trayTooltip'],
            field: 'trayTooltip',
            maxLength: 120,
          ) ??
          windowTitle;
      final executableName = _requiredFileName(
        decoded['executableName'],
        field: 'executableName',
        extension: '.exe',
      );
      final installerBaseName = _requiredFileName(
        decoded['installerBaseName'],
        field: 'installerBaseName',
      );
      final brandId = _requiredIdentifier(decoded['brandId']);

      return AppBranding._(
        isBranded: true,
        productName: productName,
        windowTitle: windowTitle,
        trayTooltip: trayTooltip,
        executableName: executableName,
        installerBaseName: installerBaseName,
        updateEnabled: decoded['updateEnabled'] == true,
        hideAboutPage: _optionalBoolean(
          decoded['hideAboutPage'],
          field: 'hideAboutPage',
          defaultValue: false,
        ),
        brandId: brandId,
      );
    } catch (error) {
      return _fallbackBranding(
        updateEnabled: fallbackUpdateEnabled,
        loadError: error.toString(),
      );
    }
  }

  static AppBranding fallback({
    required bool updateEnabled,
    String? loadError,
  }) {
    return _fallbackBranding(
      updateEnabled: updateEnabled,
      loadError: loadError,
    );
  }

  static AppBranding _fallbackBranding({
    required bool updateEnabled,
    String? loadError,
  }) {
    return AppBranding._(
      isBranded: false,
      productName: defaults.productName,
      windowTitle: defaults.windowTitle,
      trayTooltip: defaults.trayTooltip,
      executableName: defaults.executableName,
      installerBaseName: defaults.installerBaseName,
      updateEnabled: updateEnabled,
      hideAboutPage: defaults.hideAboutPage,
      brandId: defaults.brandId,
      loadError: loadError,
    );
  }

  static bool _fallbackUpdateEnabled({
    required File executableFile,
    required File brandingFile,
  }) {
    final manifestFile = File(
      '${executableFile.parent.path}${Platform.pathSeparator}$manifestFileName',
    );
    if (manifestFile.existsSync()) {
      try {
        final decoded = jsonDecode(manifestFile.readAsStringSync());
        if (decoded is Map<String, dynamic>) {
          final updateEnabled = decoded['updateEnabled'];
          if (updateEnabled is bool) {
            return updateEnabled;
          }
          final removeUpdateFeature = decoded['removeUpdateFeature'];
          if (removeUpdateFeature is bool) {
            return !removeUpdateFeature;
          }
        }
      } catch (_) {
        return false;
      }
    }
    if (brandingFile.existsSync()) {
      return false;
    }
    return executableFile.uri.pathSegments.last.toLowerCase() ==
        defaultExecutableName.toLowerCase();
  }

  static String _requiredDisplayText(
    Object? value, {
    required String field,
    int maxLength = 80,
  }) {
    final parsed = _optionalDisplayText(
      value,
      field: field,
      maxLength: maxLength,
    );
    if (parsed == null) {
      throw FormatException('$field 不能为空');
    }
    return parsed;
  }

  static String? _optionalDisplayText(
    Object? value, {
    required String field,
    int maxLength = 80,
  }) {
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw FormatException('$field 必须是字符串');
    }
    final parsed = value.trim();
    if (parsed.isEmpty) {
      return null;
    }
    if (parsed.length > maxLength || parsed.contains(RegExp(r'[\x00-\x1F]'))) {
      throw FormatException('$field 包含非法字符或长度超过 $maxLength');
    }
    return parsed;
  }

  static String _requiredFileName(
    Object? value, {
    required String field,
    String? extension,
  }) {
    final parsed = _requiredDisplayText(value, field: field);
    if (parsed == '.' ||
        parsed == '..' ||
        parsed.endsWith('.') ||
        parsed.contains(RegExp(r'[\\/:*?"<>|]'))) {
      throw FormatException('$field 不是有效的 Windows 文件名');
    }
    if (extension != null && !parsed.toLowerCase().endsWith(extension)) {
      throw FormatException('$field 必须以 $extension 结尾');
    }
    return parsed;
  }

  static String _requiredIdentifier(Object? value) {
    if (value is! String || !RegExp(r'^[a-zA-Z0-9_-]{8,64}$').hasMatch(value)) {
      throw const FormatException('brandId 格式无效');
    }
    return value;
  }

  static bool _optionalBoolean(
    Object? value, {
    required String field,
    required bool defaultValue,
  }) {
    if (value == null) {
      return defaultValue;
    }
    if (value is! bool) {
      throw FormatException('$field 必须是布尔值');
    }
    return value;
  }
}
