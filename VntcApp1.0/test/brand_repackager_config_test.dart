import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relativePath) => File(relativePath).readAsStringSync();

void main() {
  test('一键换牌工具将 EXE 和 APK 工具链嵌入单个 EXE', () {
    final buildScript = _read('tools/brand_repackager/build.ps1');
    final androidToolchain = _read(
      'tools/brand_repackager/prepare_android_toolchain.ps1',
    );
    final packager = _read(
      'tools/brand_repackager/src/BrandPackager.cs',
    );

    expect(buildScript, contains('VntBrandRepackager.Toolchain.zip'));
    expect(
      buildScript,
      contains('VntBrandRepackager.OfficialAndroidSigningTrust.json'),
    );
    expect(buildScript, contains('Inno Setup 6'));
    expect(buildScript, contains('rcedit-x64.exe'));
    expect(buildScript, contains('INNO_SETUP_LICENSE.txt'));
    expect(buildScript, contains('prepare_android_toolchain.ps1'));
    expect(androidToolchain, contains('apktool_3.0.2.jar'));
    expect(androidToolchain, contains('OpenJDK17U-jdk_x64_windows_hotspot'));
    expect(androidToolchain, contains('apksigner.jar'));
    expect(androidToolchain, contains('zipalign.exe'));
    expect(
      androidToolchain,
      contains(r"$androidBuildToolsVersion = '36.0.0'"),
    );
    expect(androidToolchain, isNot(contains('Sort-Object')));
    expect(packager, contains('GetManifestResourceStream'));
    expect(packager, contains('ISCC.exe'));
    expect(packager, contains('--set-version-string'));
  });

  test('Windows 安装包提供可重复换牌的母包导出协议', () {
    final installer = _read('scripts/export_installer_package.ps1');
    final packager = _read(
      'tools/brand_repackager/src/BrandPackager.cs',
    );
    final detector = _read(
      'tools/brand_repackager/src/PackageDetection.cs',
    );

    expect(installer, contains('brand_package_manifest.json'));
    expect(installer, contains('BRAND-EXPORT'));
    expect(installer, contains('brand_payload.zip'));
    expect(installer, contains('ArchiveExtraction=full'));
    expect(installer, contains('VersionInfoDescription=VNT_BRAND_READY_V1'));
    expect(packager, contains('/BRAND-EXPORT='));
    expect(detector, contains('WindowsBrandReadyMarker'));
    expect(packager, contains('brand_package_manifest.json'));
    expect(packager, contains('updateEnabled'));
  });

  test('统一入口按文件内容自动识别 EXE/APK 且没有模式选择', () {
    final mainForm = _read('tools/brand_repackager/src/MainForm.cs');
    final program = _read('tools/brand_repackager/src/Program.cs');
    final detector = _read(
      'tools/brand_repackager/src/PackageDetection.cs',
    );

    expect(mainForm, contains('*.exe;*.apk'));
    expect(mainForm, contains('PackageDetector.Inspect'));
    expect(mainForm, contains('已识别：'));
    expect(mainForm, isNot(contains('RadioButton')));
    expect(program, isNot(contains('--platform')));
    expect(detector, contains('ValidatePortableExecutableHeaders'));
    expect(detector, contains('AndroidManifest.xml'));
    expect(detector, contains('resources.arsc'));
    expect(detector, contains('classes.dex'));
    expect(detector, contains('android_brand_package_manifest.json'));
  });

  test('Android 签名档案使用 DPAPI 且不会明文落盘密码', () {
    final signing = _read(
      'tools/brand_repackager/src/AndroidSigningProfileStore.cs',
    );

    expect(signing, contains('DataProtectionScope.CurrentUser'));
    expect(signing, contains('RandomNumberGenerator.Create'));
    expect(signing, contains('passwordProtectedBase64'));
    expect(signing, contains('[ScriptIgnore]'));
    expect(signing, contains('LoadRequired'));
    expect(signing, contains('PKCS12'));
  });

  test('Android 来源必须匹配官方证书或本机唯一品牌签名档案', () {
    final packager = _read(
      'tools/brand_repackager/src/AndroidBrandPackager.cs',
    );
    final trustReader = _read(
      'tools/brand_repackager/src/OfficialAndroidSigningTrust.cs',
    );
    final trustConfig = jsonDecode(
      _read('config/android_official_signing_trust.json'),
    ) as Map<String, dynamic>;
    final signing = _read(
      'tools/brand_repackager/src/AndroidSigningProfileStore.cs',
    );
    final exportScript = _read('scripts/export_android_brand_package.ps1');
    const retiredDebugCertificate =
        'AD610311193E90CD37E58D7B46E3DEBAA301C88D4E67B4D9440E1022A52A4AB9';

    expect(trustConfig.keys.toSet(), {
      'schemaVersion',
      'keyId',
      'brandId',
      'applicationId',
      'alias',
      'certificateSha256',
    });
    expect(trustConfig['schemaVersion'], 1);
    expect(trustConfig['keyId'], 'vnt-official-android-release-v1');
    expect(trustConfig['brandId'], 'official');
    expect(trustConfig['applicationId'], 'top.wherewego.vnt_app');
    expect(trustConfig['alias'], 'vnt_official_android_release_v1');
    expect(
      trustConfig['certificateSha256'],
      matches(RegExp(r'^[0-9A-F]{64}$')),
    );
    expect(packager, contains('OfficialAndroidSigningTrust.Load()'));
    expect(packager, contains('officialTrust.CertificateSha256'));
    expect(packager, contains('officialTrust.ApplicationId'));
    expect(packager, isNot(contains(retiredDebugCertificate)));
    expect(exportScript, isNot(contains(retiredDebugCertificate)));
    expect(trustReader, contains('GetManifestResourceStream(ResourceName)'));
    expect(trustReader, contains('RequiredPropertyNames'));
    expect(
        trustReader, contains('values.Count != RequiredPropertyNames.Length'));
    expect(trustReader, contains('包含未知、转义或重复字段'));
    expect(trustReader, contains(r'^[0-9A-F]{64}$'));
    expect(packager, contains('metadata.SourceBrandId'));
    expect(packager, contains('metadata.SourceApplicationId'));
    expect(packager, contains('profileStore.LoadRequired('));
    expect(packager, contains('profileStore.ValidateCertificate('));
    expect(signing, contains('TryLoadByBrandId('));
    expect(signing, contains('LoadRequiredByBrandId('));
    expect(signing, contains('LoadProfilesStrict()'));
    expect(signing, contains('检测到重复的 Android brandId 签名档案'));
    expect(signing, contains('检测到不完整的 Android 签名档案目录'));
  });

  test('换牌工具构建前扫描内置工具链且只嵌入公开信任配置', () {
    final buildScript = _read('tools/brand_repackager/build.ps1');

    expect(
      buildScript,
      contains(r'$officialAndroidTrustConfig = Join-Path $projectRoot'),
    );
    expect(buildScript, contains('Assert-NoSensitiveSigningMaterial'));
    expect(buildScript, contains("'.p12', '.pfx', '.jks', '.keystore'"));
    expect(buildScript, contains("'profile.json'"));
    expect(buildScript, contains('passwordProtectedBase64'));
    expect(buildScript, contains(r'\bDPAPI\b'));
    expect(buildScript, contains(r'DataProtectionScope\.CurrentUser'));
    expect(
      buildScript.indexOf('Assert-NoSensitiveSigningMaterial -Path'),
      lessThan(buildScript.indexOf('CreateFromDirectory(')),
    );
    expect(
      buildScript,
      contains(
        r'/resource:$officialAndroidTrustConfig,'
        'VntBrandRepackager.OfficialAndroidSigningTrust.json',
      ),
    );
  });

  test('Android 新品牌随机 applicationId 且同 brandId 复用旧档案', () {
    final packager = _read(
      'tools/brand_repackager/src/AndroidBrandPackager.cs',
    );
    final signing = _read(
      'tools/brand_repackager/src/AndroidSigningProfileStore.cs',
    );

    expect(packager, contains('CreateApplicationId()'));
    expect(packager, contains('RandomNumberGenerator.Create'));
    expect(packager, contains('generator.GetBytes(random)'));
    expect(packager, contains('GetOrCreateByBrandId('));
    expect(packager, contains('signingProfile.ApplicationId'));
    expect(signing, contains('TryLoadByBrandId(brandId, out existing)'));
    expect(signing, contains('return existing;'));
  });

  test('Windows 导出协议执行前强制 SHA-256 来源信任门', () {
    final packager = _read(
      'tools/brand_repackager/src/BrandPackager.cs',
    );
    final trustStore = _read(
      'tools/brand_repackager/src/WindowsPackageTrustStore.cs',
    );

    for (final hash in <String>[
      '6D1741B0C5DD859F6389848021C105F673F5E8CB070FB12193BD1ECA047DA14A',
      'E1457C5F7C05D10172554375F32E8686E574F6AE11B221ECCD1799668E4EFDC4',
      'F736C1E0F262449D386FC37DAEE4428FAF85349AB841EF4C7CB7239FCB21481A',
      '29B0D2C39E0EA205092362130D454D146D2599096D8DBBEF91B454C92E470E28',
    ]) {
      expect(trustStore, contains(hash));
    }
    expect(trustStore, contains('ProtectedData.Protect'));
    expect(trustStore, contains('ProtectedData.Unprotect'));
    expect(trustStore, contains('DataProtectionScope.CurrentUser'));
    expect(trustStore, contains('内容识别不等于来源可信'));
    expect(packager, contains('trustStore.RequireTrustedInput('));
    expect(packager, contains('trustStore.RegisterTrustedOutput(hash)'));
    expect(
      packager.indexOf('trustStore.RequireTrustedInput('),
      lessThan(packager.indexOf('ExportPayload(sourceSnapshot.Path')),
    );
  });

  test('输入安装包使用拒绝写删除共享的快照并重新识别', () {
    final snapshot = _read(
      'tools/brand_repackager/src/PackageInputSnapshot.cs',
    );
    final windowsPackager = _read(
      'tools/brand_repackager/src/BrandPackager.cs',
    );
    final androidPackager = _read(
      'tools/brand_repackager/src/AndroidBrandPackager.cs',
    );

    expect(snapshot, contains('FileAccess.Read'));
    expect(snapshot, contains('FileShare.Read'));
    expect(snapshot, contains('source.Length'));
    expect(snapshot, contains('ComputeFileSha256(snapshotPath)'));
    expect(
        snapshot, contains('PackageDetector.RequireSupported(snapshotPath)'));
    expect(windowsPackager, contains('ExportPayload(sourceSnapshot.Path'));
    expect(
        androidPackager, contains('ValidateApkArchiveSafety(sourceApkPath)'));
    expect(androidPackager, contains('Quote(sourceApkPath)'));
  });

  test('安装包与 SHA 旁车在跨进程锁内成对发布并复核', () {
    final publisher = _read(
      'tools/brand_repackager/src/PackageOutputPublisher.cs',
    );
    final windowsPackager = _read(
      'tools/brand_repackager/src/BrandPackager.cs',
    );
    final androidPackager = _read(
      'tools/brand_repackager/src/AndroidBrandPackager.cs',
    );

    expect(publisher, contains('new Mutex('));
    expect(publisher, contains('normalizedOutputPath.ToUpperInvariant()'));
    expect(publisher, contains('RestorePreviousFile('));
    expect(publisher, contains('ComputeFileSha256(outputPath)'));
    expect(publisher, contains('安装包与 SHA-256 旁车发布后复核不一致'));
    expect(windowsPackager, contains('PackageOutputPublisher.Publish('));
    expect(androidPackager, contains('PackageOutputPublisher.Publish('));
  });

  test('最终 APK 二次解码核对二进制 Manifest、权限和启动器名称', () {
    final packager = _read(
      'tools/brand_repackager/src/AndroidBrandPackager.cs',
    );

    expect(packager, contains('final-decoded'));
    expect(packager, contains('VerifyFinalDecodedPackage('));
    expect(packager, contains('android + "versionName"'));
    expect(packager, contains('ReadApktoolVersionName('));
    expect(packager, contains('"versionInfo:"'));
    expect(packager, contains('versionInfoCount'));
    expect(packager, contains('"  versionName:"'));
    expect(packager, contains('包含重复的顶层 versionInfo'));
    expect(packager, contains("line.IndexOf('\\t')"));
    expect(packager, contains('REQUEST_INSTALL_PACKAGES'));
    expect(packager, contains('"app_name"'));
    expect(
        packager, contains('EscapeAndroidResourceText(expectedProductName)'));
  });

  test('Android 换牌执行解码、包名重写、对齐、v2/v3 签名和成品复检', () {
    final packager = _read(
      'tools/brand_repackager/src/AndroidBrandPackager.cs',
    );

    expect(packager, contains('d -f -s'));
    expect(packager, contains('ModifyManifest('));
    expect(packager, contains('REQUEST_INSTALL_PACKAGES'));
    expect(packager, contains('CreateApplicationId('));
    expect(packager, contains('zipalign'));
    expect(packager, contains('--v2-signing-enabled true'));
    expect(packager, contains('--v3-signing-enabled true'));
    expect(packager, contains('PackageDetector.RequireSupported(signedApk)'));
    expect(packager, contains('LoadRequired('));
    expect(packager, contains('GetOrCreateByBrandId('));
  });

  test('Android 自定义图标限制大图输入并生成六档启动图标', () {
    final iconProcessor = _read(
      'tools/brand_repackager/src/AndroidIconProcessor.cs',
    );

    for (final entry in <String>[
      '"ldpi", 36',
      '"mdpi", 48',
      '"hdpi", 72',
      '"xhdpi", 96',
      '"xxhdpi", 144',
      '"xxxhdpi", 192',
    ]) {
      expect(iconProcessor, contains(entry));
    }
    expect(iconProcessor, contains('MaximumSourceBytes'));
    expect(iconProcessor, contains('MaximumSourcePixels'));
    expect(iconProcessor, contains('InterpolationMode.HighQualityBicubic'));
    expect(iconProcessor, contains('ImageFormat.Png'));
  });

  test('不同安装路径使用独立单实例标识', () {
    final singleInstance = _read('windows/runner/single_instance.h');

    expect(singleInstance, contains('GetModuleFileNameW'));
    expect(singleInstance, contains('GetVntInstanceIdentity'));
    expect(singleInstance, contains('GetVntSingleInstanceMutexName'));
    expect(singleInstance, isNot(contains('8D79499C')));
  });

  test('换牌 GUI 使用保存窗口并支持可选大图自动压缩', () {
    final mainForm = _read('tools/brand_repackager/src/MainForm.cs');
    final packager = _read(
      'tools/brand_repackager/src/BrandPackager.cs',
    );
    final iconProcessor = _read(
      'tools/brand_repackager/src/IconProcessor.cs',
    );

    expect(mainForm, contains('输入新名称'));
    expect(mainForm, contains('添加新图标（可选）'));
    expect(mainForm, contains('SaveFileDialog'));
    expect(mainForm, isNot(contains('FolderBrowserDialog')));
    expect(packager, contains('OutputInstallerPath'));
    expect(packager, contains('PackageOutputPublisher.Publish'));
    expect(packager, contains('IconProcessor.CreateWindowsIcon'));
    expect(packager, contains('IconProcessor.CreateSquarePng'));
    expect(packager, contains('ic_launcher.png'));
    expect(packager, contains('app_icon.png'));
    expect(packager, contains('flutter_assets'));
    expect(packager, contains(r'(\..*)?$'));
    expect(packager, contains("name.IndexOf('{')"));
    expect(iconProcessor, contains('256'));
    expect(iconProcessor, contains('InterpolationMode.HighQualityBicubic'));
    expect(iconProcessor, contains('ImageFormat.Png'));
  });

  test('CLI 日志不会覆盖输入、图标或输出文件', () {
    final program = _read('tools/brand_repackager/src/Program.cs');

    expect(program, contains('ValidateLogPath(options, logPath)'));
    expect(program, contains('new[] { "input", "save", "icon" }'));
    expect(program, contains('日志文件不能与 --'));
    expect(program, contains('Path.GetExtension(logPath)'));
    expect(program, contains('".log"'));
    expect(program, contains('.sha256'));
    expect(program, contains('以免覆盖 EXE、APK'));
    expect(
      program.indexOf('ValidateLogPath(options, logPath)'),
      lessThan(program.indexOf('Directory.CreateDirectory(outputDirectory)')),
    );
    expect(
      program.indexOf('ValidateLogPath(options, logPath)'),
      lessThan(program.indexOf('File.WriteAllLines(')),
    );
  });

  test('Windows 母包主程序名禁止绝对路径和目录穿越', () {
    final packager = _read(
      'tools/brand_repackager/src/BrandPackager.cs',
    );

    expect(packager, contains('Path.IsPathRooted(executableName)'));
    expect(packager, contains('Path.GetFileName(executableName)'));
    expect(packager, contains('品牌母包主程序路径越界'));
    expect(packager, contains('executableName 必须是根目录下的有效 EXE 文件名'));
  });

  test('换牌工具提供隐藏关于页面选项并校验母版能力', () {
    final mainForm = _read('tools/brand_repackager/src/MainForm.cs');
    final program = _read('tools/brand_repackager/src/Program.cs');
    final packager = _read(
      'tools/brand_repackager/src/BrandPackager.cs',
    );
    final installer = _read('scripts/export_installer_package.ps1');

    expect(mainForm, contains('隐藏“关于”页面（仅客户分发版）'));
    expect(mainForm, contains('_hideAboutPageCheck.Checked'));
    expect(program, contains('GetFlag(options, "hide-about")'));
    expect(packager, contains('{ "hideAboutPage", request.HideAboutPage }'));
    expect(packager, contains('ManifestHasCapability'));
    expect(installer, contains("'hideAboutPage'"));
  });

  test('换牌工具默认移除升级功能并允许显式保留', () {
    final mainForm = _read('tools/brand_repackager/src/MainForm.cs');
    final program = _read('tools/brand_repackager/src/Program.cs');
    final packager = _read(
      'tools/brand_repackager/src/BrandPackager.cs',
    );
    final installer = _read('scripts/export_installer_package.ps1');

    expect(mainForm, contains('移除升级功能（推荐，默认勾选）'));
    expect(mainForm, contains('checkBox.Checked = defaultChecked'));
    expect(
      mainForm,
      contains('UpdateEnabled = !_removeUpdateFeatureCheck.Checked'),
    );
    expect(
      program,
      contains('UpdateEnabled = !GetFlag(options, "remove-update", true)'),
    );
    expect(
      packager,
      contains('{ "updateEnabled", request.UpdateEnabled }'),
    );
    expect(packager, contains('removeUpdateFeature'));
    expect(installer, contains("'removeUpdateFeature'"));
  });
}
