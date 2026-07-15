import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/branding/app_branding.dart';

void main() {
  test('品牌配置同步显示名、进程文件名并默认关闭官方更新', () {
    final temp = Directory.systemTemp.createTempSync('vnt_branding_test_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File('${temp.path}${Platform.pathSeparator}branding.json');
    file.writeAsStringSync(jsonEncode({
      'schemaVersion': 1,
      'brandId': 'brand_12345678',
      'productName': '联网工具',
      'windowTitle': '联网工具',
      'trayTooltip': '联网工具',
      'executableName': '联网工具.exe',
      'installerBaseName': '联网工具',
      'updateEnabled': false,
      'hideAboutPage': true,
    }));

    final branding = AppBranding.loadFromFile(file);

    expect(branding.isBranded, isTrue);
    expect(branding.productName, '联网工具');
    expect(branding.windowTitle, '联网工具');
    expect(branding.executableName, '联网工具.exe');
    expect(branding.updateEnabled, isFalse);
    expect(branding.hideAboutPage, isTrue);
  });

  test('旧品牌配置与官方版本默认显示关于页面', () {
    final temp = Directory.systemTemp.createTempSync('vnt_branding_legacy_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File('${temp.path}${Platform.pathSeparator}branding.json');
    file.writeAsStringSync(jsonEncode({
      'schemaVersion': 1,
      'brandId': 'brand_12345678',
      'productName': '旧版品牌',
      'executableName': '旧版品牌.exe',
      'installerBaseName': '旧版品牌',
    }));

    final branding = AppBranding.loadFromFile(file);

    expect(branding.isBranded, isTrue);
    expect(branding.hideAboutPage, isFalse);
    expect(AppBranding.defaults.hideAboutPage, isFalse);
  });

  test('品牌配置可以显式保留升级功能', () {
    final temp = Directory.systemTemp.createTempSync('vnt_branding_update_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File('${temp.path}${Platform.pathSeparator}branding.json');
    file.writeAsStringSync(jsonEncode({
      'schemaVersion': 1,
      'brandId': 'brand_12345678',
      'productName': '可升级品牌',
      'executableName': '可升级品牌.exe',
      'installerBaseName': '可升级品牌',
      'updateEnabled': true,
    }));

    final branding = AppBranding.loadFromFile(file);

    expect(branding.isBranded, isTrue);
    expect(branding.updateEnabled, isTrue);
    expect(AppBranding.defaults.updateEnabled, isTrue);
  });

  test('关于页面字段类型错误时安全回退为显示', () {
    final temp = Directory.systemTemp.createTempSync('vnt_branding_about_bad_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File('${temp.path}${Platform.pathSeparator}branding.json');
    file.writeAsStringSync(jsonEncode({
      'schemaVersion': 1,
      'brandId': 'brand_12345678',
      'productName': '错误品牌',
      'executableName': '错误品牌.exe',
      'installerBaseName': '错误品牌',
      'hideAboutPage': 'true',
    }));

    final branding = AppBranding.loadFromFile(file);

    expect(branding.isBranded, isFalse);
    expect(branding.hideAboutPage, isFalse);
    expect(branding.updateEnabled, isTrue);
  });

  test('损坏或越权路径配置安全回退到官方品牌', () {
    final temp = Directory.systemTemp.createTempSync('vnt_branding_bad_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final file = File('${temp.path}${Platform.pathSeparator}branding.json');
    file.writeAsStringSync(jsonEncode({
      'schemaVersion': 1,
      'brandId': 'brand_12345678',
      'productName': '联网工具',
      'executableName': r'..\evil.exe',
      'installerBaseName': '联网工具',
    }));

    final branding = AppBranding.loadFromFile(file);

    expect(branding.isBranded, isFalse);
    expect(branding.productName, AppBranding.defaultProductName);
    expect(branding.loadError, isNotNull);
  });

  test('移除升级的换牌程序在配置损坏时仍安全关闭升级', () {
    final temp = Directory.systemTemp.createTempSync('vnt_branding_broken_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final executable = File(
      '${temp.path}${Platform.pathSeparator}稳定客户版.exe',
    )..writeAsBytesSync(const []);
    File('${temp.path}${Platform.pathSeparator}branding.json')
        .writeAsStringSync('{broken');
    File(
      '${temp.path}${Platform.pathSeparator}brand_package_manifest.json',
    ).writeAsStringSync(jsonEncode({
      'updateEnabled': false,
      'removeUpdateFeature': true,
    }));

    final branding = AppBranding.loadForExecutable(executable.path);

    expect(branding.isBranded, isFalse);
    expect(branding.updateEnabled, isFalse);
    expect(branding.loadError, isNotNull);
  });

  test('换牌程序缺失配置时从母版清单恢复升级策略', () {
    final temp = Directory.systemTemp.createTempSync('vnt_branding_missing_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final executable = File(
      '${temp.path}${Platform.pathSeparator}保留升级版.exe',
    )..writeAsBytesSync(const []);
    File(
      '${temp.path}${Platform.pathSeparator}brand_package_manifest.json',
    ).writeAsStringSync(jsonEncode({
      'updateEnabled': true,
      'removeUpdateFeature': false,
    }));

    final branding = AppBranding.loadForExecutable(executable.path);

    expect(branding.updateEnabled, isTrue);
  });

  test('非官方进程在配置和清单都缺失时关闭升级', () {
    final temp = Directory.systemTemp.createTempSync('vnt_branding_no_files_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final executable = File(
      '${temp.path}${Platform.pathSeparator}未知品牌.exe',
    )..writeAsBytesSync(const []);

    final branding = AppBranding.loadForExecutable(executable.path);

    expect(branding.updateEnabled, isFalse);
  });

  test('官方进程未配置品牌时仍保留升级', () {
    final temp = Directory.systemTemp.createTempSync('vnt_branding_official_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final executable = File(
      '${temp.path}${Platform.pathSeparator}vnt_app.exe',
    )..writeAsBytesSync(const []);

    final branding = AppBranding.loadForExecutable(executable.path);

    expect(branding.updateEnabled, isTrue);
  });

  test('Android 内置品牌 JSON 复用名称、升级和关于策略', () {
    final branding = AppBranding.loadFromJsonText(jsonEncode({
      'schemaVersion': 1,
      'brandId': 'android_12345678',
      'productName': '联网工具',
      'windowTitle': '联网工具',
      'trayTooltip': '联网工具',
      'executableName': 'vnt_app.exe',
      'installerBaseName': '联网工具',
      'updateEnabled': false,
      'hideAboutPage': true,
      'androidPackageName': 'top.wherewego.vnt.b12345678',
    }));

    expect(branding.isBranded, isTrue);
    expect(branding.productName, '联网工具');
    expect(branding.updateEnabled, isFalse);
    expect(branding.hideAboutPage, isTrue);
  });

  test('Android 品牌 JSON 损坏时可选择安全关闭升级', () {
    final branding = AppBranding.loadFromJsonText(
      '{broken',
      fallbackUpdateEnabled: false,
    );

    expect(branding.isBranded, isFalse);
    expect(branding.updateEnabled, isFalse);
    expect(branding.loadError, isNotNull);
  });
}
