using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace VntBrandRepackager
{
    internal sealed class BrandPackageRequest
    {
        public string InstallerPath { get; set; }
        public string ProductName { get; set; }
        public string OutputDirectory { get; set; }
        public string OutputInstallerPath { get; set; }
        public string IconPath { get; set; }
        public bool HideAboutPage { get; set; }
        public bool UpdateEnabled { get; set; }
    }

    internal sealed class BrandPackageResult
    {
        public string InstallerPath { get; set; }
        public string Sha256Path { get; set; }
        public string Sha256 { get; set; }
        public string Version { get; set; }
        public string ExecutableName { get; set; }
        public PackageFormat Format { get; set; }
        public string ApplicationId { get; set; }

        public string ProcessIdentifier
        {
            get
            {
                return Format == PackageFormat.AndroidApk
                    ? ApplicationId
                    : ExecutableName;
            }
        }
    }

    internal sealed class BrandPackager
    {
        private const string ToolchainResourceName =
            "VntBrandRepackager.Toolchain.zip";
        private static readonly UTF8Encoding Utf8WithoutBom = new UTF8Encoding(false);
        private readonly Action<string> _log;

        public BrandPackager(Action<string> log)
        {
            _log = log ?? delegate { };
        }

        public BrandPackageResult Pack(BrandPackageRequest request)
        {
            var inspection = ValidateRequest(request);
            if (inspection.Format == PackageFormat.AndroidApk)
            {
                return new AndroidBrandPackager(_log).Pack(request, inspection);
            }

            return PackWindows(request, inspection);
        }

        private BrandPackageResult PackWindows(
            BrandPackageRequest request,
            PackageDetectionResult initialInspection)
        {
            var tempRoot = Path.Combine(
                Path.GetTempPath(),
                "VntBrandRepackager_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempRoot);

            try
            {
                _log("正在创建源安装包只读快照并重新按内容识别");
                var sourceSnapshot = PackageInputSnapshot.Create(
                    request.InstallerPath,
                    tempRoot,
                    ".exe");
                if (sourceSnapshot.Inspection.Format !=
                        PackageFormat.WindowsExecutable ||
                    initialInspection.Format !=
                        PackageFormat.WindowsExecutable)
                {
                    throw new InvalidDataException(
                        "源安装包在初筛与只读快照复检之间格式不一致");
                }
                var trustStore = new WindowsPackageTrustStore(_log);
                var trustedSourceHash = trustStore.RequireTrustedInput(
                    sourceSnapshot.Path);
                if (!string.Equals(
                    trustedSourceHash,
                    sourceSnapshot.Sha256,
                    StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "Windows 源安装包快照与信任校验 SHA-256 不一致");
                }

                _log("正在释放内置 Inno Setup 工具链");
                var toolchainDirectory = ExtractEmbeddedToolchain(tempRoot);
                var setupIconPath = Path.Combine(
                    toolchainDirectory,
                    "assets",
                    "app_icon.ico");
                var executableIconPath = string.Empty;
                if (string.IsNullOrWhiteSpace(request.IconPath))
                {
                    _log("未添加新图标，将保留源安装包的现有图标");
                }
                else
                {
                    _log("正在转换并优化自定义图标");
                    var normalizedIconPath = Path.Combine(
                        tempRoot,
                        "brand_icon.ico");
                    var iconResult = IconProcessor.CreateWindowsIcon(
                        request.IconPath,
                        normalizedIconPath);
                    setupIconPath = normalizedIconPath;
                    executableIconPath = normalizedIconPath;
                    var sourceDescription = iconResult.SourceWidth + "×" +
                        iconResult.SourceHeight + "，" +
                        IconProcessor.FormatBytes(iconResult.SourceBytes);
                    var outputDescription = IconProcessor.FormatBytes(
                        iconResult.OutputBytes);
                    if (iconResult.WasCompressed)
                    {
                        _log("源图标较大（" + sourceDescription +
                            "），已自动等比压缩为最大 256×256 的多尺寸 ICO（" +
                            outputDescription + "）");
                    }
                    else
                    {
                        _log("已将图标（" + sourceDescription +
                            "）转换为 Windows 多尺寸 ICO（" +
                            outputDescription + "）");
                    }
                }
                var payloadZip = Path.Combine(tempRoot, "brand_payload.zip");
                var payloadDirectory = Path.Combine(tempRoot, "payload");
                Directory.CreateDirectory(payloadDirectory);

                _log("正在从安装包读取品牌母包数据");
                ExportPayload(sourceSnapshot.Path, payloadZip);
                SafeExtractZip(payloadZip, payloadDirectory);
                var packagedConfigDirectory = Path.Combine(payloadDirectory, "config");
                if (Directory.Exists(packagedConfigDirectory))
                {
                    Directory.Delete(packagedConfigDirectory, true);
                }
                var runtimeAssetsDirectory = Path.Combine(
                    payloadDirectory,
                    "data",
                    "flutter_assets",
                    "assets");
                var runtimeIconPath = Path.Combine(
                    runtimeAssetsDirectory,
                    "app_icon.ico");
                if (!string.IsNullOrWhiteSpace(executableIconPath))
                {
                    if (!File.Exists(runtimeIconPath))
                    {
                        throw new InvalidDataException(
                            "品牌母包缺少运行时托盘图标资源");
                    }
                    File.Copy(executableIconPath, runtimeIconPath, true);
                    var launcherIconPath = Path.Combine(
                        runtimeAssetsDirectory,
                        "ic_launcher.png");
                    var appIconPngPath = Path.Combine(
                        runtimeAssetsDirectory,
                        "app_icon.png");
                    if (!File.Exists(launcherIconPath) ||
                        !File.Exists(appIconPngPath))
                    {
                        throw new InvalidDataException(
                            "品牌母包缺少应用内图标资源");
                    }
                    IconProcessor.CreateSquarePng(
                        request.IconPath,
                        launcherIconPath,
                        144);
                    IconProcessor.CreateSquarePng(
                        request.IconPath,
                        appIconPngPath,
                        512);
                    _log("已同步安装包、主程序、托盘和应用内图标");
                }
                else if (File.Exists(runtimeIconPath))
                {
                    setupIconPath = runtimeIconPath;
                }

                var manifestPath = Path.Combine(
                    payloadDirectory,
                    "brand_package_manifest.json");
                var manifest = ReadAndValidateManifest(manifestPath);
                if (request.HideAboutPage &&
                    !ManifestHasCapability(manifest, "hideAboutPage"))
                {
                    throw new InvalidDataException(
                        "该母版不支持隐藏关于页面，请使用 v4.8.18 或更高版本的品牌母版");
                }
                if (!request.UpdateEnabled &&
                    !ManifestHasCapability(manifest, "removeUpdateFeature"))
                {
                    throw new InvalidDataException(
                        "该母版不支持完整移除升级功能，请使用 v4.8.19 或更高版本的品牌母版");
                }
                _log(request.UpdateEnabled
                    ? "将保留软件升级功能（请确保使用同品牌更新包）"
                    : "将移除自动检查、升级入口和更新执行功能");
                var version = Convert.ToString(manifest["version"]);
                var oldExecutableName = Convert.ToString(manifest["executableName"]);
                var payloadRoot = Path.GetFullPath(payloadDirectory).TrimEnd(
                    Path.DirectorySeparatorChar,
                    Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
                var oldExecutablePath = Path.GetFullPath(Path.Combine(
                    payloadDirectory,
                    oldExecutableName));
                if (!oldExecutablePath.StartsWith(
                    payloadRoot,
                    StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("品牌母包主程序路径越界");
                }
                if (!File.Exists(oldExecutablePath))
                {
                    throw new InvalidDataException(
                        "品牌母包缺少主程序：" + oldExecutableName);
                }

                var productName = request.ProductName.Trim();
                var executableName = productName + ".exe";
                var newExecutablePath = Path.Combine(payloadDirectory, executableName);
                if (!string.Equals(
                    oldExecutablePath,
                    newExecutablePath,
                    StringComparison.Ordinal))
                {
                    if (string.Equals(
                        oldExecutablePath,
                        newExecutablePath,
                        StringComparison.OrdinalIgnoreCase))
                    {
                        var temporaryExecutablePath = Path.Combine(
                            payloadDirectory,
                            ".rename_" + Guid.NewGuid().ToString("N") + ".exe");
                        File.Move(oldExecutablePath, temporaryExecutablePath);
                        File.Move(temporaryExecutablePath, newExecutablePath);
                    }
                    else
                    {
                        if (File.Exists(newExecutablePath))
                        {
                            File.Delete(newExecutablePath);
                        }
                        File.Move(oldExecutablePath, newExecutablePath);
                    }
                }

                _log("正在同步 EXE 名称、进程描述和产品资源");
                PatchExecutable(
                    Path.Combine(toolchainDirectory, "rcedit", "rcedit-x64.exe"),
                    newExecutablePath,
                    productName,
                    executableName,
                    version,
                    executableIconPath);

                var brandId = "brand_" + ComputeSha256Text(productName).Substring(0, 24);
                var branding = new Dictionary<string, object>
                {
                    { "schemaVersion", 1 },
                    { "brandId", brandId },
                    { "productName", productName },
                    { "windowTitle", productName },
                    { "trayTooltip", productName },
                    { "executableName", executableName },
                    { "installerBaseName", productName },
                    { "updateEnabled", request.UpdateEnabled },
                    { "hideAboutPage", request.HideAboutPage }
                };
                WriteJson(
                    Path.Combine(payloadDirectory, "branding.json"),
                    branding);

                manifest["executableName"] = executableName;
                manifest["sourceProductName"] = productName;
                manifest["brandId"] = brandId;
                manifest["hideAboutPage"] = request.HideAboutPage;
                manifest["updateEnabled"] = request.UpdateEnabled;
                manifest["removeUpdateFeature"] = !request.UpdateEnabled;
                WriteJson(manifestPath, manifest);

                File.Delete(payloadZip);
                ZipFile.CreateFromDirectory(
                    payloadDirectory,
                    payloadZip,
                    CompressionLevel.Optimal,
                    false);

                Directory.CreateDirectory(request.OutputDirectory);
                var outputBaseName = string.IsNullOrWhiteSpace(
                    request.OutputInstallerPath)
                    ? productName.Replace(' ', '_') + "_" + version +
                        "_Windows_Setup"
                    : Path.GetFileNameWithoutExtension(request.OutputInstallerPath);
                var setupPath = string.IsNullOrWhiteSpace(
                    request.OutputInstallerPath)
                    ? Path.Combine(request.OutputDirectory, outputBaseName + ".exe")
                    : request.OutputInstallerPath;
                var stagingOutputDirectory = Path.Combine(
                    tempRoot,
                    "installer_output");
                Directory.CreateDirectory(stagingOutputDirectory);
                var stagedSetupPath = Path.Combine(
                    stagingOutputDirectory,
                    outputBaseName + ".exe");
                var issPath = Path.Combine(tempRoot, "brand_installer.iss");
                File.WriteAllText(
                    issPath,
                    BuildInnoScript(
                        productName,
                        executableName,
                        version,
                        CreateStableAppId(productName),
                        payloadZip,
                        setupIconPath,
                        Path.Combine(toolchainDirectory, "assets", "ChineseSimplified.isl"),
                        stagingOutputDirectory,
                        outputBaseName),
                    Utf8WithoutBom);

                _log("正在使用内置 Inno Setup 重新封装（无需编译 Flutter/Rust）");
                RunProcess(
                    Path.Combine(toolchainDirectory, "inno", "ISCC.exe"),
                    "/Qp " + Quote(issPath),
                    tempRoot,
                    TimeSpan.FromMinutes(10),
                    true);
                if (!File.Exists(stagedSetupPath))
                {
                    throw new InvalidOperationException("Inno Setup 未生成目标安装包");
                }

                var hash = ComputeFileSha256(stagedSetupPath);
                trustStore.RegisterTrustedOutput(hash);
                var shaPath = PackageOutputPublisher.Publish(
                    stagedSetupPath,
                    setupPath,
                    hash);
                _log("SHA-256：" + hash);

                return new BrandPackageResult
                {
                    InstallerPath = setupPath,
                    Sha256Path = shaPath,
                    Sha256 = hash,
                    Version = version,
                    ExecutableName = executableName,
                    Format = PackageFormat.WindowsExecutable,
                    ApplicationId = string.Empty
                };
            }
            finally
            {
                TryDeleteDirectory(tempRoot);
            }
        }

        public static void VerifyEmbeddedToolchain(Action<string> log)
        {
            var tempRoot = Path.Combine(
                Path.GetTempPath(),
                "VntBrandRepackager_SelfTest_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempRoot);
            try
            {
                var directory = ExtractEmbeddedToolchain(tempRoot);
                var required = new[]
                {
                    Path.Combine(directory, "inno", "ISCC.exe"),
                    Path.Combine(directory, "inno", "ISCmplr.dll"),
                    Path.Combine(directory, "rcedit", "rcedit-x64.exe"),
                    Path.Combine(directory, "assets", "ChineseSimplified.isl"),
                    Path.Combine(directory, "assets", "app_icon.ico"),
                    Path.Combine(directory, "licenses", "INNO_SETUP_LICENSE.txt"),
                    Path.Combine(directory, "licenses", "RCEDIT_LICENSE.txt"),
                    Path.Combine(directory, "android", "jre", "bin", "java.exe"),
                    Path.Combine(directory, "android", "jre", "bin", "keytool.exe"),
                    Path.Combine(directory, "android", "jre", "release"),
                    Path.Combine(directory, "android", "apktool.jar"),
                    Path.Combine(directory, "android", "apksigner.jar"),
                    Path.Combine(directory, "android", "zipalign.exe"),
                    Path.Combine(directory, "android", "libwinpthread-1.dll"),
                    Path.Combine(directory, "licenses", "APKTOOL_LICENSE.md"),
                    Path.Combine(directory, "licenses", "ANDROID_BUILD_TOOLS_NOTICE.txt"),
                    Path.Combine(directory, "licenses", "ANDROID_COMPONENTS.txt")
                };
                foreach (var path in required)
                {
                    if (!File.Exists(path))
                    {
                        throw new FileNotFoundException("内置工具链文件缺失", path);
                    }
                }
                var java = Path.Combine(
                    directory,
                    "android",
                    "jre",
                    "bin",
                    "java.exe");
                RunProcess(
                    java,
                    "-jar " + Quote(Path.Combine(
                        directory,
                        "android",
                        "apktool.jar")) + " --version",
                    tempRoot,
                    TimeSpan.FromMinutes(1),
                    true);
                RunProcess(
                    java,
                    "-jar " + Quote(Path.Combine(
                        directory,
                        "android",
                        "apksigner.jar")) + " version",
                    tempRoot,
                    TimeSpan.FromMinutes(1),
                    true);
                RunProcess(
                    Path.Combine(
                        directory,
                        "android",
                        "jre",
                        "bin",
                        "keytool.exe"),
                    "-help",
                    tempRoot,
                    TimeSpan.FromMinutes(1),
                    true);
                if (log != null)
                {
                    log("已验证内置 Inno Setup、APKTool、Java、签名/对齐组件和许可证");
                }
            }
            finally
            {
                TryDeleteDirectory(tempRoot);
            }
        }

        internal static PackageDetectionResult ValidateInputs(
            BrandPackageRequest request)
        {
            if (request == null)
            {
                throw new ArgumentNullException("request");
            }
            request.InstallerPath = Path.GetFullPath(request.InstallerPath ?? string.Empty);
            var inspection = PackageDetector.RequireSupported(request.InstallerPath);
            ValidateProductName(request.ProductName);
            if (!string.IsNullOrWhiteSpace(request.IconPath))
            {
                request.IconPath = Path.GetFullPath(request.IconPath);
                var extension = Path.GetExtension(request.IconPath);
                var supported = new[]
                {
                    ".ico", ".png", ".jpg", ".jpeg", ".bmp"
                };
                if (!File.Exists(request.IconPath) ||
                    !supported.Contains(extension, StringComparer.OrdinalIgnoreCase))
                {
                    throw new ArgumentException(
                        "新图标必须是有效的 ICO、PNG、JPG、JPEG 或 BMP 文件");
                }
            }
            return inspection;
        }

        private static PackageDetectionResult ValidateRequest(
            BrandPackageRequest request)
        {
            var inspection = ValidateInputs(request);
            var expectedExtension = inspection.SuggestedExtension;
            if (!string.IsNullOrWhiteSpace(request.OutputInstallerPath))
            {
                request.OutputInstallerPath = Path.GetFullPath(
                    request.OutputInstallerPath);
                if (!string.Equals(
                    Path.GetExtension(request.OutputInstallerPath),
                    expectedExtension,
                    StringComparison.OrdinalIgnoreCase))
                {
                    throw new ArgumentException(
                        "已识别为 " + inspection.PlatformDisplayName +
                        "，保存文件必须使用 " + expectedExtension + " 扩展名");
                }
                if (string.Equals(
                    request.OutputInstallerPath,
                    request.InstallerPath,
                    StringComparison.OrdinalIgnoreCase))
                {
                    throw new ArgumentException("不能覆盖正在使用的源母版安装包");
                }
                request.OutputDirectory = Path.GetDirectoryName(
                    request.OutputInstallerPath);
            }
            else
            {
                if (string.IsNullOrWhiteSpace(request.OutputDirectory))
                {
                    throw new ArgumentException("请选择安装包保存位置");
                }
                request.OutputDirectory = Path.GetFullPath(
                    request.OutputDirectory);
            }
            return inspection;
        }

        private static void ValidateProductName(string value)
        {
            var name = (value ?? string.Empty).Trim();
            if (name.Length < 1 || name.Length > 64)
            {
                throw new ArgumentException("软件名称长度必须为 1-64 个字符");
            }
            if (name.EndsWith(".", StringComparison.Ordinal) ||
                name.EndsWith(" ", StringComparison.Ordinal) ||
                name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                name.IndexOf('{') >= 0 ||
                name.IndexOf('}') >= 0)
            {
                throw new ArgumentException("软件名称包含 Windows 文件名不允许的字符");
            }
            var reserved = new Regex(
                @"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (reserved.IsMatch(name))
            {
                throw new ArgumentException("软件名称是 Windows 保留名称");
            }
        }

        private static string ExtractEmbeddedToolchain(string tempRoot)
        {
            var zipPath = Path.Combine(tempRoot, "toolchain.zip");
            var destination = Path.Combine(tempRoot, "toolchain");
            using (var resource = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream(ToolchainResourceName))
            {
                if (resource == null)
                {
                    throw new InvalidOperationException("程序未内置 Inno Setup 工具链");
                }
                using (var output = File.Create(zipPath))
                {
                    resource.CopyTo(output);
                }
            }
            Directory.CreateDirectory(destination);
            SafeExtractZip(zipPath, destination);
            return destination;
        }

        private void ExportPayload(string installerPath, string outputZip)
        {
            var arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART " +
                Quote("/BRAND-EXPORT=" + outputZip);
            var result = RunProcess(
                installerPath,
                arguments,
                Path.GetDirectoryName(installerPath),
                TimeSpan.FromMinutes(3),
                false);
            if (!File.Exists(outputZip))
            {
                throw new InvalidDataException(
                    "该安装包不是支持一键换牌的品牌母版，或母包数据损坏。" +
                    "安装包退出码：" + result);
            }
        }

        private static Dictionary<string, object> ReadAndValidateManifest(
            string manifestPath)
        {
            if (!File.Exists(manifestPath))
            {
                throw new InvalidDataException("安装包缺少品牌母包清单");
            }
            var manifest = new JavaScriptSerializer()
                .Deserialize<Dictionary<string, object>>(
                    File.ReadAllText(manifestPath, Encoding.UTF8));
            if (manifest == null ||
                !manifest.ContainsKey("brandReady") ||
                !Convert.ToBoolean(manifest["brandReady"]) ||
                !manifest.ContainsKey("version") ||
                !manifest.ContainsKey("executableName"))
            {
                throw new InvalidDataException("品牌母包清单格式无效");
            }
            var version = Convert.ToString(manifest["version"]);
            if (!Regex.IsMatch(version, @"^\d+(\.\d+){1,3}$"))
            {
                throw new InvalidDataException("品牌母包版本号无效");
            }
            var executableName = Convert.ToString(manifest["executableName"]);
            if (string.IsNullOrWhiteSpace(executableName) ||
                Path.IsPathRooted(executableName) ||
                !string.Equals(
                    Path.GetFileName(executableName),
                    executableName,
                    StringComparison.Ordinal) ||
                !string.Equals(
                    Path.GetExtension(executableName),
                    ".exe",
                    StringComparison.OrdinalIgnoreCase) ||
                executableName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            {
                throw new InvalidDataException(
                    "品牌母包 executableName 必须是根目录下的有效 EXE 文件名");
            }
            return manifest;
        }

        private static bool ManifestHasCapability(
            IDictionary<string, object> manifest,
            string capability)
        {
            object value;
            if (!manifest.TryGetValue("capabilities", out value) ||
                value == null || value is string)
            {
                return false;
            }
            var values = value as System.Collections.IEnumerable;
            if (values == null)
            {
                return false;
            }
            foreach (var item in values)
            {
                if (string.Equals(
                    Convert.ToString(item),
                    capability,
                    StringComparison.Ordinal))
                {
                    return true;
                }
            }
            return false;
        }

        private static void PatchExecutable(
            string rceditPath,
            string executablePath,
            string productName,
            string executableName,
            string version,
            string iconPath)
        {
            var arguments = new StringBuilder();
            arguments.Append(Quote(executablePath));
            AppendVersionString(arguments, "FileDescription", productName);
            AppendVersionString(arguments, "ProductName", productName);
            AppendVersionString(arguments, "InternalName", productName);
            AppendVersionString(arguments, "OriginalFilename", executableName);
            AppendVersionString(arguments, "CompanyName", productName);
            arguments.Append(" --set-file-version ").Append(Quote(version));
            arguments.Append(" --set-product-version ").Append(Quote(version));
            if (!string.IsNullOrWhiteSpace(iconPath))
            {
                arguments.Append(" --set-icon ").Append(Quote(iconPath));
            }
            RunProcess(
                rceditPath,
                arguments.ToString(),
                Path.GetDirectoryName(executablePath),
                TimeSpan.FromMinutes(2),
                true);
        }

        private static void AppendVersionString(
            StringBuilder arguments,
            string key,
            string value)
        {
            arguments.Append(" --set-version-string ")
                .Append(Quote(key))
                .Append(' ')
                .Append(Quote(value));
        }

        private static string BuildInnoScript(
            string productName,
            string executableName,
            string version,
            string appId,
            string payloadZip,
            string iconPath,
            string languagePath,
            string outputDirectory,
            string outputBaseName)
        {
            var template = @"#define MyAppName ""{0}""
#define MyAppVersion ""{1}""
#define MyAppExeName ""{2}""
#define MyAppPayload ""{3}""
#define MyAppIcon ""{4}""

[Setup]
AppId={{{{{5}}}
AppName={{#MyAppName}}
AppVersion={{#MyAppVersion}}
AppVerName={{#MyAppName}} v{{#MyAppVersion}}
AppPublisher={{#MyAppName}}
DefaultDirName={{autopf}}\{{#MyAppName}}
DefaultGroupName={{#MyAppName}}
AllowNoIcons=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=none
SolidCompression=no
ArchiveExtraction=full
WizardStyle=modern
SetupIconFile={{#MyAppIcon}}
UninstallDisplayIcon={{app}}\{{#MyAppExeName}}
UninstallDisplayName={{#MyAppName}} v{{#MyAppVersion}}
OutputDir={6}
OutputBaseFilename={7}
DisableProgramGroupPage=no
ShowLanguageDialog=no
CloseApplications=yes
RestartApplications=no
RestartIfNeededByRun=no
VersionInfoDescription=VNT_BRAND_READY_V1
VersionInfoProductName={{#MyAppName}}

[Languages]
Name: ""chinesesimplified""; MessagesFile: ""{8}""

[Tasks]
Name: ""desktopicon""; Description: ""创建桌面快捷方式""; GroupDescription: ""附加快捷方式：""; Flags: unchecked

[Files]
Source: ""{{#MyAppPayload}}""; Flags: dontcopy noencryption

[Icons]
Name: ""{{group}}\{{#MyAppName}}""; Filename: ""{{app}}\{{#MyAppExeName}}""; WorkingDir: ""{{app}}""; IconFilename: ""{{app}}\{{#MyAppExeName}}""
Name: ""{{autodesktop}}\{{#MyAppName}}""; Filename: ""{{app}}\{{#MyAppExeName}}""; WorkingDir: ""{{app}}""; IconFilename: ""{{app}}\{{#MyAppExeName}}""; Tasks: desktopicon

[Run]
Filename: ""powershell.exe""; Parameters: ""-NoProfile -ExecutionPolicy Bypass -File """"{{app}}\scripts\bootstrap_vntcrustdesk.ps1"""" -AppDir """"{{app}}"""" -MsiPath """"{{app}}\remote_assist\artifacts\vntcrustdesk.msi""""""; Flags: runhidden waituntilterminated; Check: not IsBrandValidationMode
Filename: ""{{app}}\{{#MyAppExeName}}""; Description: ""启动 {{#MyAppName}}""; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: ""powershell.exe""; Parameters: ""-NoProfile -ExecutionPolicy Bypass -File """"{{app}}\scripts\uninstall_vntcrustdesk.ps1"""" -AppDir """"{{app}}""""""; Flags: runhidden waituntilterminated; Check: not IsBrandValidationMode

[UninstallDelete]
Type: files; Name: ""{{app}}\*""
Type: filesandordirs; Name: ""{{app}}\data""
Type: filesandordirs; Name: ""{{app}}\dlls""
Type: filesandordirs; Name: ""{{app}}\remote_assist""
Type: filesandordirs; Name: ""{{app}}\scripts""
Type: dirifempty; Name: ""{{app}}""

[Code]
function IsBrandValidationMode: Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 1 to ParamCount do
  begin
    if CompareText(ParamStr(Index), '/BRAND-VALIDATE-INSTALL') = 0 then
    begin
      Result := True;
      exit;
    end;
  end;
end;

function InitializeSetup: Boolean;
var
  ExportPath: String;
begin
  ExportPath := ExpandConstant('{{param:BRAND-EXPORT|}}');
  if ExportPath <> '' then
  begin
    ForceDirectories(ExtractFileDir(ExportPath));
    ExtractTemporaryFile('brand_payload.zip');
    if not FileCopy(ExpandConstant('{{tmp}}\brand_payload.zip'), ExportPath, False) then
      RaiseException('无法导出品牌母包数据');
    Result := False;
    exit;
  end;
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    ForceDirectories(ExpandConstant('{{app}}'));
    ExtractTemporaryFile('brand_payload.zip');
    ExtractArchive(ExpandConstant('{{tmp}}\brand_payload.zip'), ExpandConstant('{{app}}'), '', True, nil);
  end;
end;
";
            return string.Format(
                template,
                EscapeInno(productName),
                EscapeInno(version),
                EscapeInno(executableName),
                EscapeInno(payloadZip),
                EscapeInno(iconPath),
                appId,
                EscapeInno(outputDirectory),
                EscapeInno(outputBaseName),
                EscapeInno(languagePath));
        }

        private static string EscapeInno(string value)
        {
            return (value ?? string.Empty).Replace("\"", "\"\"");
        }

        private static string CreateStableAppId(string productName)
        {
            using (var sha = SHA256.Create())
            {
                var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(productName));
                var guidBytes = new byte[16];
                Array.Copy(hash, guidBytes, guidBytes.Length);
                return new Guid(guidBytes).ToString("D").ToUpperInvariant();
            }
        }

        private static void WriteJson(string path, Dictionary<string, object> value)
        {
            var json = new JavaScriptSerializer().Serialize(value);
            File.WriteAllText(path, json, Utf8WithoutBom);
        }

        private static int RunProcess(
            string executable,
            string arguments,
            string workingDirectory,
            TimeSpan timeout,
            bool requireSuccess)
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = executable,
                Arguments = arguments,
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var process = new Process { StartInfo = startInfo })
            {
                var stdout = new StringBuilder();
                var stderr = new StringBuilder();
                var outputLock = new object();
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs args)
                {
                    if (args.Data != null)
                    {
                        lock (outputLock) { stdout.AppendLine(args.Data); }
                    }
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs args)
                {
                    if (args.Data != null)
                    {
                        lock (outputLock) { stderr.AppendLine(args.Data); }
                    }
                };
                if (!process.Start())
                {
                    throw new InvalidOperationException(
                        "无法启动外部工具：" + executable);
                }
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit((int)timeout.TotalMilliseconds))
                {
                    try { process.Kill(); } catch { }
                    try { process.WaitForExit(5000); } catch { }
                    throw new TimeoutException("外部工具执行超时：" + executable);
                }
                process.WaitForExit();
                if (requireSuccess && process.ExitCode != 0)
                {
                    throw new InvalidOperationException(
                        Path.GetFileName(executable) + " 执行失败，退出码 " +
                        process.ExitCode + Environment.NewLine + stdout.ToString() +
                        Environment.NewLine + stderr.ToString());
                }
                return process.ExitCode;
            }
        }

        private static void SafeExtractZip(string zipPath, string destination)
        {
            var root = Path.GetFullPath(destination)
                .TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            using (var archive = ZipFile.OpenRead(zipPath))
            {
                foreach (var entry in archive.Entries)
                {
                    var target = Path.GetFullPath(Path.Combine(destination, entry.FullName));
                    if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidDataException("ZIP 包含越权路径：" + entry.FullName);
                    }
                    if (string.IsNullOrEmpty(entry.Name))
                    {
                        Directory.CreateDirectory(target);
                        continue;
                    }
                    Directory.CreateDirectory(Path.GetDirectoryName(target));
                    entry.ExtractToFile(target, true);
                }
            }
        }

        private static string ComputeFileSha256(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = File.OpenRead(path))
            {
                return BitConverter.ToString(sha.ComputeHash(stream))
                    .Replace("-", string.Empty);
            }
        }

        private static string ComputeSha256Text(string value)
        {
            using (var sha = SHA256.Create())
            {
                return BitConverter.ToString(
                    sha.ComputeHash(Encoding.UTF8.GetBytes(value)))
                    .Replace("-", string.Empty)
                    .ToLowerInvariant();
            }
        }

        private static string Quote(string value)
        {
            return "\"" + (value ?? string.Empty).Replace("\"", "\\\"") + "\"";
        }

        private static void TryDeleteDirectory(string path)
        {
            if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
            {
                return;
            }
            for (var attempt = 0; attempt < 5; attempt++)
            {
                try
                {
                    Directory.Delete(path, true);
                    return;
                }
                catch
                {
                    System.Threading.Thread.Sleep(300);
                }
            }
        }
    }
}
