using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Xml;
using System.Xml.Linq;

namespace VntBrandRepackager
{
    internal sealed class AndroidBrandPackager
    {
        private const string ToolchainResourceName =
            "VntBrandRepackager.Toolchain.zip";
        private const string StorePasswordEnvironmentName =
            "VNT_ANDROID_STORE_PASSWORD";
        private const string KeyPasswordEnvironmentName =
            "VNT_ANDROID_KEY_PASSWORD";
        private const long MaximumInputApkBytes = 1536L * 1024L * 1024L;
        private const long MaximumArchiveExpandedBytes = 4L * 1024L * 1024L * 1024L;
        private const int MaximumArchiveEntries = 100000;
        private const int MaximumCapturedProcessCharacters = 4 * 1024 * 1024;

        private static readonly UTF8Encoding Utf8WithoutBom =
            new UTF8Encoding(false);
        private static readonly Regex ApplicationIdPattern = new Regex(
            @"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$",
            RegexOptions.CultureInvariant);
        private static readonly Regex BrandIdPattern = new Regex(
            @"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
            RegexOptions.CultureInvariant);
        private static readonly Regex CertificateDigestPattern = new Regex(
            @"Signer #\d+ certificate SHA-256 digest:\s*([0-9A-Fa-f:]{64,95})",
            RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

        private readonly Action<string> _log;

        public AndroidBrandPackager(Action<string> log)
        {
            _log = log ?? delegate { };
        }

        public BrandPackageResult Pack(
            BrandPackageRequest request,
            PackageDetectionResult inspection)
        {
            ValidateRequest(request, inspection);
            var officialTrust = OfficialAndroidSigningTrust.Load();
            var tempRoot = Path.Combine(
                Path.GetTempPath(),
                "VntApk_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempRoot);

            try
            {
                _log("正在创建源 APK 只读快照并重新按内容识别");
                var sourceSnapshot = PackageInputSnapshot.Create(
                    request.InstallerPath,
                    tempRoot,
                    ".apk");
                if (sourceSnapshot.Inspection.Format !=
                        PackageFormat.AndroidApk ||
                    inspection.Format != PackageFormat.AndroidApk)
                {
                    throw new InvalidDataException(
                        "源安装包在初筛与只读快照复检之间格式不一致");
                }
                inspection = sourceSnapshot.Inspection;
                var sourceApkPath = sourceSnapshot.Path;

                _log("正在安全释放内置 Android 重封装工具链");
                var tools = ExtractEmbeddedToolchain(tempRoot);
                ValidateApkArchiveSafety(sourceApkPath);

                _log("正在验证源 APK 签名和完整性");
                var sourceSignature = VerifyApkSignature(
                    tools,
                    sourceApkPath,
                    tempRoot,
                    false);

                var decodedDirectory = Path.Combine(tempRoot, "decoded");
                var frameworkDirectory = Path.Combine(tempRoot, "framework");
                Directory.CreateDirectory(frameworkDirectory);
                _log("正在解码 APK（保留原始 DEX，不反编译业务代码）");
                RunApktool(
                    tools,
                    tempRoot,
                    "d -f -s -p " + Quote(frameworkDirectory) +
                        " -o " + Quote(decodedDirectory) + " " +
                        Quote(sourceApkPath),
                    TimeSpan.FromMinutes(15),
                    "APKTool 解码");
                if (!Directory.Exists(decodedDirectory))
                {
                    throw new InvalidOperationException("APKTool 未生成解码目录");
                }

                var metadata = ReadAndValidateDecodedPackage(
                    decodedDirectory,
                    inspection);
                if (!string.Equals(
                    metadata.SourceCertificateSha256,
                    string.Empty,
                    StringComparison.Ordinal) &&
                    !string.Equals(
                        metadata.SourceCertificateSha256,
                        sourceSignature.CertificateSha256,
                        StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException(
                        "源 APK 实际签名证书与品牌清单记录不一致");
                }

                var profileStore = new AndroidSigningProfileStore(_log);
                if (string.Equals(
                    metadata.SourceBrandId,
                    officialTrust.BrandId,
                    StringComparison.Ordinal))
                {
                    if (!string.Equals(
                        metadata.SourceApplicationId,
                        officialTrust.ApplicationId,
                        StringComparison.Ordinal))
                    {
                        throw new InvalidDataException(
                            "官方 Android 母版 applicationId 与公开信任配置不一致");
                    }
                    EnsureCertificateMatches(
                        sourceSignature.CertificateSha256,
                        officialTrust.CertificateSha256,
                        "官方 Android 母版证书指纹不受信任。" +
                        "内容识别不等于来源可信，请使用官方原始母版 APK");
                    _log(
                        "已通过官方 Android 母版公开签名信任校验（" +
                        officialTrust.KeyId + " / " +
                        officialTrust.Alias + "）");
                }
                else
                {
                    var sourceProfile = profileStore.LoadRequired(
                        metadata.SourceBrandId,
                        metadata.SourceApplicationId);
                    profileStore.ValidateCertificate(
                        tools.KeytoolPath,
                        sourceProfile);
                    EnsureCertificateMatches(
                        sourceSignature.CertificateSha256,
                        sourceProfile.CertificateSha256,
                        "源 APK 证书与本机签名档案不一致。" +
                        "内容识别不等于来源可信，已拒绝重新封装");
                    _log("已通过源品牌 APK 与本机签名档案的双向信任校验");
                }

                var productName = request.ProductName.Trim();
                var identityName = productName.Normalize(NormalizationForm.FormC);
                var targetBrandId = CreateBrandId(identityName);
                var signingProfile = profileStore.GetOrCreateByBrandId(
                    tools.KeytoolPath,
                    targetBrandId,
                    CreateApplicationId());
                var targetApplicationId = signingProfile.ApplicationId;
                if (string.Equals(
                    metadata.SourceBrandId,
                    targetBrandId,
                    StringComparison.Ordinal))
                {
                    _log("已识别为同品牌 APK，将强制复用原 applicationId 和签名");
                }

                _log("正在同步应用名称、applicationId 和默认进程标识");
                ModifyManifest(
                    metadata.ManifestPath,
                    metadata.SourceApplicationId,
                    metadata.SourcePackageName,
                    targetApplicationId,
                    request.UpdateEnabled);
                ModifyStringResources(decodedDirectory, productName);
                WriteBrandingFiles(
                    metadata,
                    productName,
                    targetBrandId,
                    targetApplicationId,
                    request,
                    signingProfile);

                if (string.IsNullOrWhiteSpace(request.IconPath))
                {
                    _log("未添加新图标，将完整保留源 APK 图标");
                }
                else
                {
                    _log("正在生成 Android 六档图标并同步 Flutter 图标资源");
                    var iconResult = AndroidIconProcessor.ReplaceLauncherIcons(
                        decodedDirectory,
                        request.IconPath);
                    var sourceDescription = iconResult.SourceWidth + "×" +
                        iconResult.SourceHeight + "，" +
                        IconProcessor.FormatBytes(iconResult.SourceBytes);
                    _log((iconResult.WasCompressed
                            ? "源图标较大（" + sourceDescription +
                                "），已自动压缩、透明居中并等比缩放"
                            : "已转换自定义图标（" + sourceDescription + "）") +
                        "；Android 资源 " + iconResult.ReplacedResourceCount +
                        " 个，Flutter 资源 " +
                        iconResult.ReplacedFlutterAssetCount + " 个");
                }

                var unsignedApk = Path.Combine(tempRoot, "unsigned.apk");
                _log("正在使用内置 APKTool 回编译 APK");
                RunApktool(
                    tools,
                    tempRoot,
                    "b -f -p " + Quote(frameworkDirectory) +
                        " -o " + Quote(unsignedApk) + " " +
                        Quote(decodedDirectory),
                    TimeSpan.FromMinutes(15),
                    "APKTool 回编译");
                RequireNonEmptyFile(unsignedApk, "APKTool 未生成未签名 APK");

                var alignedApk = Path.Combine(tempRoot, "aligned.apk");
                _log("正在执行 4 字节及 16 KiB 原生库对齐");
                RunProcess(
                    tools.ZipalignPath,
                    "-f -P 16 4 " + Quote(unsignedApk) + " " +
                        Quote(alignedApk),
                    tempRoot,
                    TimeSpan.FromMinutes(5),
                    null,
                    "zipalign 对齐");
                RequireNonEmptyFile(alignedApk, "zipalign 未生成对齐后的 APK");

                var signedApk = Path.Combine(tempRoot, "signed.apk");
                _log("正在使用品牌专用证书生成 APK v2/v3 签名");
                SignApk(
                    tools,
                    signingProfile,
                    alignedApk,
                    signedApk,
                    tempRoot);
                RequireNonEmptyFile(signedApk, "apksigner 未生成已签名 APK");

                var finalSignature = VerifyApkSignature(
                    tools,
                    signedApk,
                    tempRoot,
                    true);
                EnsureCertificateMatches(
                    finalSignature.CertificateSha256,
                    signingProfile.CertificateSha256,
                    "输出 APK 的签名证书与品牌签名档案不一致");
                VerifyZipAlignment(tools, signedApk, tempRoot);

                _log("正在按文件内容复检最终 Android 安装包");
                var finalInspection = PackageDetector.RequireSupported(signedApk);
                if (finalInspection.Format != PackageFormat.AndroidApk ||
                    !string.Equals(
                        finalInspection.BrandId,
                        targetBrandId,
                        StringComparison.Ordinal) ||
                    !string.Equals(
                        finalInspection.ApplicationId,
                        targetApplicationId,
                        StringComparison.Ordinal) ||
                    !string.Equals(
                        finalInspection.Version,
                        inspection.Version,
                        StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "最终 APK 品牌身份或版本复检不一致");
                }

                _log("正在二次解码最终 APK 并核对二进制 Manifest 与资源");
                var finalDecodedDirectory = Path.Combine(
                    tempRoot,
                    "final-decoded");
                RunApktool(
                    tools,
                    tempRoot,
                    "d -f -s -p " + Quote(frameworkDirectory) +
                        " -o " + Quote(finalDecodedDirectory) + " " +
                        Quote(signedApk),
                    TimeSpan.FromMinutes(15),
                    "最终 APK 二次解码");
                var finalMetadata = ReadAndValidateDecodedPackage(
                    finalDecodedDirectory,
                    finalInspection);
                VerifyFinalDecodedPackage(
                    finalMetadata,
                    targetBrandId,
                    targetApplicationId,
                    productName,
                    inspection.Version,
                    request.UpdateEnabled,
                    signingProfile.CertificateSha256);

                var outputPath = ResolveOutputPath(
                    request,
                    productName,
                    inspection.Version);
                var hash = ComputeFileSha256(signedApk);
                var shaPath = PackageOutputPublisher.Publish(
                    signedApk,
                    outputPath,
                    hash);
                _log("SHA-256：" + hash);

                return new BrandPackageResult
                {
                    InstallerPath = outputPath,
                    Sha256Path = shaPath,
                    Sha256 = hash,
                    Version = inspection.Version,
                    ExecutableName = targetApplicationId,
                    Format = PackageFormat.AndroidApk,
                    ApplicationId = targetApplicationId
                };
            }
            finally
            {
                if (!TryDeleteDirectory(tempRoot))
                {
                    _log("警告：临时目录未能完全清理，可稍后删除：" + tempRoot);
                }
            }
        }

        private static void ValidateRequest(
            BrandPackageRequest request,
            PackageDetectionResult inspection)
        {
            if (request == null)
            {
                throw new ArgumentNullException("request");
            }
            if (inspection == null || !inspection.IsSupported ||
                inspection.Format != PackageFormat.AndroidApk)
            {
                throw new ArgumentException("导入文件不是受支持的 Android 品牌 APK");
            }
            if (!File.Exists(request.InstallerPath))
            {
                throw new FileNotFoundException("源 APK 不存在", request.InstallerPath);
            }
            var inputInfo = new FileInfo(request.InstallerPath);
            if (inputInfo.Length <= 0 || inputInfo.Length > MaximumInputApkBytes)
            {
                throw new ArgumentException("源 APK 必须大于 0 且不能超过 1.5 GB");
            }
            if (string.IsNullOrWhiteSpace(inspection.ApplicationId) ||
                !ApplicationIdPattern.IsMatch(inspection.ApplicationId))
            {
                throw new InvalidDataException("源 APK 的 applicationId 无效");
            }
        }

        private static ToolchainPaths ExtractEmbeddedToolchain(string tempRoot)
        {
            var destination = Path.Combine(tempRoot, "toolchain");
            Directory.CreateDirectory(destination);
            var rootPrefix = Path.GetFullPath(destination).TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var entryCount = 0;
            var expandedBytes = 0L;

            using (var resource = Assembly.GetExecutingAssembly()
                .GetManifestResourceStream(ToolchainResourceName))
            {
                if (resource == null)
                {
                    throw new InvalidOperationException(
                        "程序缺少内置工具链资源：" + ToolchainResourceName);
                }
                using (var archive = new ZipArchive(
                    resource,
                    ZipArchiveMode.Read,
                    false))
                {
                    foreach (var entry in archive.Entries)
                    {
                        entryCount++;
                        if (entryCount > 30000)
                        {
                            throw new InvalidDataException("内置工具链条目数量异常");
                        }
                        var normalized = ValidateRelativeArchivePath(
                            entry.FullName,
                            "内置工具链");
                        if (string.IsNullOrEmpty(normalized))
                        {
                            continue;
                        }
                        if (!seen.Add(normalized))
                        {
                            throw new InvalidDataException(
                                "内置工具链包含重复路径：" + normalized);
                        }
                        RejectSymbolicLink(entry, "内置工具链");
                        expandedBytes = CheckedAdd(
                            expandedBytes,
                            entry.Length,
                            "内置工具链展开大小溢出");
                        if (entry.Length > 768L * 1024L * 1024L ||
                            expandedBytes > 2L * 1024L * 1024L * 1024L)
                        {
                            throw new InvalidDataException("内置工具链展开大小异常");
                        }

                        var target = Path.GetFullPath(Path.Combine(
                            destination,
                            normalized.Replace('/', Path.DirectorySeparatorChar)));
                        if (!target.StartsWith(
                            rootPrefix,
                            StringComparison.OrdinalIgnoreCase))
                        {
                            throw new InvalidDataException("内置工具链路径越界");
                        }
                        if (string.IsNullOrEmpty(entry.Name))
                        {
                            Directory.CreateDirectory(target);
                            continue;
                        }
                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        using (var input = entry.Open())
                        using (var output = new FileStream(
                            target,
                            FileMode.CreateNew,
                            FileAccess.Write,
                            FileShare.None))
                        {
                            input.CopyTo(output);
                        }
                        if (new FileInfo(target).Length != entry.Length)
                        {
                            throw new InvalidDataException(
                                "内置工具链文件释放不完整：" + normalized);
                        }
                    }
                }
            }

            var androidRoot = Path.Combine(destination, "android");
            var result = new ToolchainPaths
            {
                RootDirectory = destination,
                AndroidRootDirectory = androidRoot,
                JavaHomeDirectory = Path.Combine(androidRoot, "jre"),
                JavaPath = Path.Combine(androidRoot, "jre", "bin", "java.exe"),
                KeytoolPath = Path.Combine(androidRoot, "jre", "bin", "keytool.exe"),
                ApktoolJarPath = Path.Combine(androidRoot, "apktool.jar"),
                ZipalignPath = Path.Combine(androidRoot, "zipalign.exe"),
                ApksignerJarPath = Path.Combine(androidRoot, "apksigner.jar")
            };
            foreach (var required in new[]
            {
                result.JavaPath,
                result.KeytoolPath,
                result.ApktoolJarPath,
                result.ZipalignPath,
                result.ApksignerJarPath
            })
            {
                RequireNonEmptyFile(required, "内置 Android 工具链文件缺失");
            }
            return result;
        }

        private static void ValidateApkArchiveSafety(string apkPath)
        {
            // APK 内经 AAPT2 优化后的物理资源名允许仅大小写不同；APKTool
            // 会依据 resources.arsc 恢复逻辑资源名，因此这里只拒绝完全重复路径。
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var totalBytes = 0L;
            var count = 0;
            try
            {
                using (var archive = ZipFile.OpenRead(apkPath))
                {
                    foreach (var entry in archive.Entries)
                    {
                        count++;
                        if (count > MaximumArchiveEntries)
                        {
                            throw new InvalidDataException("APK 条目数量超过安全上限");
                        }
                        var path = ValidateRelativeArchivePath(entry.FullName, "APK");
                        if (string.IsNullOrEmpty(path))
                        {
                            continue;
                        }
                        if (path.Length > 512 || path.Split('/').Any(
                            part => part.Length > 240))
                        {
                            throw new InvalidDataException("APK 包含过长路径：" + path);
                        }
                        if (!seen.Add(path))
                        {
                            throw new InvalidDataException(
                                "APK 包含大小写冲突或重复路径：" + path);
                        }
                        RejectSymbolicLink(entry, "APK");
                        if (entry.Length < 0 || entry.Length > 2L * 1024L * 1024L * 1024L)
                        {
                            throw new InvalidDataException("APK 单个条目大小异常：" + path);
                        }
                        totalBytes = CheckedAdd(
                            totalBytes,
                            entry.Length,
                            "APK 展开大小溢出");
                        if (totalBytes > MaximumArchiveExpandedBytes)
                        {
                            throw new InvalidDataException("APK 展开大小超过 4 GB 安全上限");
                        }
                        if (entry.Length > 16L * 1024L * 1024L &&
                            entry.CompressedLength == 0)
                        {
                            throw new InvalidDataException("APK 包含异常高压缩比条目：" + path);
                        }
                        if (entry.CompressedLength > 0 && entry.Length > 1024L * 1024L &&
                            entry.Length / entry.CompressedLength > 5000)
                        {
                            throw new InvalidDataException("APK 包含异常高压缩比条目：" + path);
                        }
                    }
                }
            }
            catch (InvalidDataException)
            {
                throw;
            }
            catch (Exception error)
            {
                throw new InvalidDataException("无法安全读取源 APK：" + error.Message, error);
            }
        }

        private DecodedPackageMetadata ReadAndValidateDecodedPackage(
            string decodedDirectory,
            PackageDetectionResult inspection)
        {
            var manifestPath = Path.Combine(decodedDirectory, "AndroidManifest.xml");
            var brandingPath = Path.Combine(
                decodedDirectory,
                PackageDetector.AndroidBrandingEntryPath.Replace(
                    '/',
                    Path.DirectorySeparatorChar));
            var brandManifestPath = Path.Combine(
                decodedDirectory,
                PackageDetector.AndroidBrandManifestEntryPath.Replace(
                    '/',
                    Path.DirectorySeparatorChar));
            RequireNonEmptyFile(manifestPath, "APK 解码结果缺少 AndroidManifest.xml");
            RequireNonEmptyFile(brandingPath, "APK 解码结果缺少 Android 运行时品牌配置");
            RequireNonEmptyFile(brandManifestPath, "APK 解码结果缺少 Android 品牌母版清单");

            var manifestValues = ReadJsonObject(
                brandManifestPath,
                64L * 1024L,
                "Android 品牌母版清单");
            var brandingValues = ReadJsonObject(
                brandingPath,
                64L * 1024L,
                "Android 运行时品牌配置");
            RequireSchemaVersion(manifestValues, "Android 品牌母版清单");
            RequireSchemaVersion(brandingValues, "Android 运行时品牌配置");
            if (!RequireBoolean(manifestValues, "brandReady", "Android 品牌母版清单"))
            {
                throw new InvalidDataException("Android 品牌母版清单 brandReady 必须为 true");
            }
            if (!string.Equals(
                RequireString(manifestValues, "platform", "Android 品牌母版清单"),
                "android",
                StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Android 品牌母版清单 platform 不是 android");
            }
            if (!string.Equals(
                RequireString(
                    manifestValues,
                    "brandingAsset",
                    "Android 品牌母版清单"),
                PackageDetector.AndroidBrandingEntryPath,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException("Android 品牌母版清单 brandingAsset 路径无效");
            }
            ValidateCapabilities(manifestValues, inspection);

            var sourceApplicationId = RequireString(
                manifestValues,
                "applicationId",
                "Android 品牌母版清单");
            var sourcePackageName = RequireString(
                manifestValues,
                "sourcePackageName",
                "Android 品牌母版清单");
            ValidateApplicationId(sourceApplicationId, "源 applicationId");
            ValidateApplicationId(sourcePackageName, "源 Java 包名");
            if (!string.Equals(
                sourceApplicationId,
                inspection.ApplicationId,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "品牌母版清单 applicationId 与导入检测结果不一致");
            }

            var markerBrandId = ReadOptionalString(manifestValues, "brandId");
            var brandingBrandId = RequireString(
                brandingValues,
                "brandId",
                "Android 运行时品牌配置");
            ValidateBrandId(brandingBrandId);
            string sourceBrandId;
            if (string.IsNullOrEmpty(markerBrandId))
            {
                if (!string.Equals(
                    brandingBrandId,
                    "official",
                    StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "已换牌 APK 的品牌母版清单缺少 brandId");
                }
                sourceBrandId = "official";
            }
            else
            {
                ValidateBrandId(markerBrandId);
                if (!string.Equals(
                    markerBrandId,
                    brandingBrandId,
                    StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "品牌母版清单与运行时配置的 brandId 不一致");
                }
                sourceBrandId = markerBrandId;
            }

            var brandingApplicationId = RequireString(
                brandingValues,
                "androidPackageName",
                "Android 运行时品牌配置");
            if (!string.Equals(
                brandingApplicationId,
                sourceApplicationId,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "运行时品牌配置与母版清单的 applicationId 不一致");
            }

            var document = LoadXmlDocument(manifestPath, 32L * 1024L * 1024L);
            var root = document.Root;
            if (root == null || root.Name.LocalName != "manifest")
            {
                throw new InvalidDataException("解码后的 AndroidManifest.xml 根节点无效");
            }
            var decodedApplicationId = ((string)root.Attribute("package") ?? string.Empty)
                .Trim();
            if (!string.Equals(
                decodedApplicationId,
                sourceApplicationId,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "AndroidManifest.xml 包名与品牌母版清单不一致");
            }

            var version = ReadOptionalString(manifestValues, "versionName");
            if (string.IsNullOrEmpty(version))
            {
                version = RequireString(
                    manifestValues,
                    "version",
                    "Android 品牌母版清单");
            }
            if (!string.Equals(version, inspection.Version, StringComparison.Ordinal))
            {
                throw new InvalidDataException("解码后品牌母版版本与导入检测结果不一致");
            }

            var sourceCertificate = ReadOptionalString(
                manifestValues,
                "certificateSha256");
            if (!string.Equals(sourceBrandId, "official", StringComparison.Ordinal))
            {
                if (string.IsNullOrEmpty(sourceCertificate))
                {
                    throw new InvalidDataException(
                        "已换牌 APK 的品牌母版清单缺少签名证书指纹");
                }
                sourceCertificate = NormalizeCertificateSha256(sourceCertificate);
            }
            else if (!string.IsNullOrEmpty(sourceCertificate))
            {
                sourceCertificate = NormalizeCertificateSha256(sourceCertificate);
            }

            return new DecodedPackageMetadata
            {
                DecodedDirectory = decodedDirectory,
                ManifestPath = manifestPath,
                BrandingPath = brandingPath,
                BrandManifestPath = brandManifestPath,
                ManifestValues = manifestValues,
                BrandingValues = brandingValues,
                SourceApplicationId = sourceApplicationId,
                SourcePackageName = sourcePackageName,
                SourceBrandId = sourceBrandId,
                SourceCertificateSha256 = sourceCertificate,
                Version = version
            };
        }

        private static void ModifyManifest(
            string manifestPath,
            string sourceApplicationId,
            string sourcePackageName,
            string targetApplicationId,
            bool updateEnabled)
        {
            ValidateApplicationId(sourceApplicationId, "源 applicationId");
            ValidateApplicationId(sourcePackageName, "源 Java 包名");
            ValidateApplicationId(targetApplicationId, "目标 applicationId");
            var document = LoadXmlDocument(manifestPath, 32L * 1024L * 1024L);
            var root = document.Root;
            if (root == null || root.Name.LocalName != "manifest")
            {
                throw new InvalidDataException("AndroidManifest.xml 根节点无效");
            }
            var packageAttribute = root.Attribute("package");
            if (packageAttribute == null || !string.Equals(
                packageAttribute.Value,
                sourceApplicationId,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException("AndroidManifest.xml 源包名已发生变化");
            }

            XNamespace android = "http://schemas.android.com/apk/res/android";
            foreach (var element in root.DescendantsAndSelf())
            {
                foreach (var attribute in element.Attributes().ToList())
                {
                    if (attribute.IsNamespaceDeclaration ||
                        attribute.Name.NamespaceName ==
                            "http://www.w3.org/2000/xmlns/")
                    {
                        continue;
                    }
                    if (IsAndroidClassAttribute(element, attribute, android))
                    {
                        attribute.Value = QualifyClassName(
                            attribute.Value,
                            sourcePackageName);
                        continue;
                    }
                    attribute.Value = ReplacePackageScopedValue(
                        attribute.Value,
                        sourceApplicationId,
                        targetApplicationId);
                }
            }
            packageAttribute.Value = targetApplicationId;

            var applications = root.Elements()
                .Where(item => item.Name.LocalName == "application")
                .ToList();
            if (applications.Count != 1)
            {
                throw new InvalidDataException(
                    "AndroidManifest.xml 必须且只能包含一个 application");
            }
            var application = applications[0];
            if (!string.Equals(
                (string)application.Attribute(android + "label"),
                "@string/app_name",
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Android 品牌母版 application 必须引用 @string/app_name");
            }
            ValidateComponentLabel(
                application,
                android,
                "MyTileService",
                "@string/app_name",
                "service");
            ValidateComponentLabel(
                application,
                android,
                "InputService",
                "@string/remote_assist_input_service_name",
                "service");
            ValidateComponentLabel(
                application,
                android,
                "VntWidgetSmall",
                "@string/widget_small_description",
                "receiver");
            ValidateComponentLabel(
                application,
                android,
                "VntWidgetLarge",
                "@string/widget_large_description",
                "receiver");
            ValidateManifestCapabilityMarker(application, android);

            const string installPermission =
                "android.permission.REQUEST_INSTALL_PACKAGES";
            var permissionNodes = root.Elements()
                .Where(item => item.Name.LocalName == "uses-permission" &&
                    string.Equals(
                        (string)item.Attribute(android + "name"),
                        installPermission,
                        StringComparison.Ordinal))
                .ToList();
            if (updateEnabled)
            {
                if (permissionNodes.Count == 0)
                {
                    var permission = new XElement(
                        "uses-permission",
                        new XAttribute(android + "name", installPermission));
                    application.AddBeforeSelf(permission);
                }
                else
                {
                    foreach (var duplicate in permissionNodes.Skip(1))
                    {
                        duplicate.Remove();
                    }
                }
            }
            else
            {
                foreach (var permission in permissionNodes)
                {
                    permission.Remove();
                }
            }
            SaveXmlDocument(document, manifestPath);
        }

        private static void VerifyFinalDecodedPackage(
            DecodedPackageMetadata metadata,
            string expectedBrandId,
            string expectedApplicationId,
            string expectedProductName,
            string expectedVersion,
            bool updateEnabled,
            string expectedCertificateSha256)
        {
            if (!string.Equals(
                    metadata.SourceBrandId,
                    expectedBrandId,
                    StringComparison.Ordinal) ||
                !string.Equals(
                    metadata.SourceApplicationId,
                    expectedApplicationId,
                    StringComparison.Ordinal) ||
                !string.Equals(
                    metadata.Version,
                    expectedVersion,
                    StringComparison.Ordinal) ||
                !string.Equals(
                    metadata.SourceCertificateSha256,
                    NormalizeCertificateSha256(expectedCertificateSha256),
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException(
                    "最终 APK 二次解码后的品牌、包名、版本或证书记录不一致");
            }

            var document = LoadXmlDocument(
                metadata.ManifestPath,
                32L * 1024L * 1024L);
            var root = document.Root;
            if (root == null || root.Name.LocalName != "manifest")
            {
                throw new InvalidDataException(
                    "最终 APK 二次解码后的 Manifest 根节点无效");
            }
            XNamespace android = "http://schemas.android.com/apk/res/android";
            if (!string.Equals(
                (string)root.Attribute("package"),
                expectedApplicationId,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "最终 APK 二进制 Manifest 的 applicationId 不一致");
            }
            var decodedVersionName =
                (string)root.Attribute(android + "versionName");
            if (string.IsNullOrWhiteSpace(decodedVersionName))
            {
                // APKTool 3.x normally moves versionName out of its decoded
                // AndroidManifest.xml and records the value it read from the
                // binary manifest in apktool.yml instead.
                decodedVersionName = ReadApktoolVersionName(
                    metadata.DecodedDirectory);
            }
            if (!string.Equals(
                decodedVersionName,
                expectedVersion,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "最终 APK 二进制 Manifest 的 versionName 不一致");
            }

            const string installPermission =
                "android.permission.REQUEST_INSTALL_PACKAGES";
            var installPermissionCount = root.Elements()
                .Count(item => item.Name.LocalName == "uses-permission" &&
                    string.Equals(
                        (string)item.Attribute(android + "name"),
                        installPermission,
                        StringComparison.Ordinal));
            if ((updateEnabled && installPermissionCount != 1) ||
                (!updateEnabled && installPermissionCount != 0))
            {
                throw new InvalidDataException(
                    "最终 APK 二进制 Manifest 的升级安装权限与选项不一致");
            }

            var stringsPath = Path.Combine(
                metadata.DecodedDirectory,
                "res",
                "values",
                "strings.xml");
            var strings = LoadXmlDocument(stringsPath, 8L * 1024L * 1024L);
            var appNames = strings.Root == null
                ? new List<XElement>()
                : strings.Root.Elements()
                    .Where(item => item.Name.LocalName == "string" &&
                        string.Equals(
                            (string)item.Attribute("name"),
                            "app_name",
                            StringComparison.Ordinal))
                    .ToList();
            if (appNames.Count != 1 || !string.Equals(
                appNames[0].Value,
                EscapeAndroidResourceText(expectedProductName),
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "最终 APK 的启动器显示名称与新品牌名称不一致");
            }
        }

        private static string ReadApktoolVersionName(string decodedDirectory)
        {
            var path = Path.Combine(decodedDirectory, "apktool.yml");
            var info = new FileInfo(path);
            if (!info.Exists || info.Length <= 0 || info.Length > 1024 * 1024)
            {
                throw new InvalidDataException(
                    "最终 APK 二次解码结果缺少有效的 apktool.yml");
            }

            string[] lines;
            try
            {
                using (var reader = new StreamReader(
                    path,
                    new UTF8Encoding(false, true),
                    true))
                {
                    lines = reader.ReadToEnd().Replace("\r\n", "\n")
                        .Replace('\r', '\n')
                        .Split('\n');
                }
            }
            catch (Exception error)
            {
                throw new InvalidDataException(
                    "最终 APK 的 apktool.yml 不是有效 UTF-8",
                    error);
            }

            var versionInfoCount = 0;
            var insideVersionInfo = false;
            string versionName = null;
            foreach (var line in lines)
            {
                if (line.IndexOf('\t') >= 0)
                {
                    throw new InvalidDataException(
                        "最终 APK 的 apktool.yml 包含不受支持的制表符缩进");
                }

                var lineWithoutTrailingWhitespace = line.TrimEnd();
                if (string.Equals(
                    lineWithoutTrailingWhitespace,
                    "versionInfo:",
                    StringComparison.Ordinal))
                {
                    versionInfoCount++;
                    if (versionInfoCount > 1)
                    {
                        throw new InvalidDataException(
                            "最终 APK 的 apktool.yml 包含重复的顶层 versionInfo");
                    }
                    insideVersionInfo = true;
                    continue;
                }

                if (!insideVersionInfo)
                {
                    continue;
                }

                if (lineWithoutTrailingWhitespace.Length == 0)
                {
                    continue;
                }
                if (lineWithoutTrailingWhitespace[0] != ' ')
                {
                    insideVersionInfo = false;
                    continue;
                }
                if (!lineWithoutTrailingWhitespace.StartsWith(
                    "  versionName:",
                    StringComparison.Ordinal))
                {
                    continue;
                }
                if (lineWithoutTrailingWhitespace.Length > 2 &&
                    lineWithoutTrailingWhitespace[2] == ' ')
                {
                    continue;
                }
                if (versionName != null)
                {
                    throw new InvalidDataException(
                        "最终 APK 的 apktool.yml 包含重复 versionName");
                }
                versionName = lineWithoutTrailingWhitespace
                    .Substring("  versionName:".Length)
                    .Trim();
                if (versionName.Length >= 2 &&
                    ((versionName[0] == '\'' &&
                      versionName[versionName.Length - 1] == '\'') ||
                     (versionName[0] == '"' &&
                      versionName[versionName.Length - 1] == '"')))
                {
                    versionName = versionName.Substring(
                        1,
                        versionName.Length - 2);
                }
            }
            if (versionInfoCount != 1 || string.IsNullOrWhiteSpace(versionName))
            {
                throw new InvalidDataException(
                    "最终 APK 的 apktool.yml 缺少 versionInfo.versionName");
            }
            return versionName;
        }

        private static void ModifyStringResources(
            string decodedDirectory,
            string productName)
        {
            var escapedName = EscapeAndroidResourceText(productName);
            var formattedName = escapedName.Replace("%", "%%");
            var replacements = new Dictionary<string, string>(
                StringComparer.Ordinal)
            {
                { "app_name", escapedName },
                { "widget_small_description",
                    EscapeAndroidResourceText(productName + " 快捷开关") },
                { "widget_large_description",
                    EscapeAndroidResourceText(productName + " 状态面板") },
                { "widget_status_icon_description",
                    EscapeAndroidResourceText(productName + " 状态图标") },
                { "notification_icon_description",
                    EscapeAndroidResourceText(productName + " 图标") },
                { "remote_assist_accessibility_description",
                    EscapeAndroidResourceText(
                        "允许通过 " + productName +
                        " 远程协助控制本机触摸和输入操作") },
                { "remote_assist_input_service_name",
                    EscapeAndroidResourceText(productName + " 远程协助输入服务") },
                { "notification_channel_name",
                    EscapeAndroidResourceText(productName + " 连接状态") },
                { "notification_channel_description",
                    EscapeAndroidResourceText(
                        "显示 " + productName + " 连接状态和快速切换按钮") },
                { "notification_title_format", formattedName + " - %1$s" },
                { "remote_assist_running_title",
                    EscapeAndroidResourceText("远程协助服务运行中") },
                { "remote_assist_running_description",
                    EscapeAndroidResourceText(
                        "本机已准备接受来自 " + productName +
                        " 网络的远程协助请求") },
                { "remote_assist_channel_name",
                    EscapeAndroidResourceText(productName + " 远程协助") },
                { "remote_assist_channel_description",
                    EscapeAndroidResourceText(
                        "用于保持 " + productName +
                        " Android 远程协助受控服务存活") }
            };

            var resDirectory = Path.Combine(decodedDirectory, "res");
            if (!Directory.Exists(resDirectory))
            {
                throw new InvalidDataException("APK 解码结果缺少 res 目录");
            }
            var counts = replacements.Keys.ToDictionary(
                key => key,
                key => 0,
                StringComparer.Ordinal);
            var baseCounts = replacements.Keys.ToDictionary(
                key => key,
                key => 0,
                StringComparer.Ordinal);
            var valuesDirectories = Directory.GetDirectories(
                resDirectory,
                "values*",
                SearchOption.TopDirectoryOnly);
            foreach (var directory in valuesDirectories)
            {
                var isBaseValues = string.Equals(
                    Path.GetFileName(directory),
                    "values",
                    StringComparison.OrdinalIgnoreCase);
                foreach (var xmlPath in Directory.GetFiles(
                    directory,
                    "*.xml",
                    SearchOption.TopDirectoryOnly))
                {
                    var document = LoadXmlDocument(xmlPath, 32L * 1024L * 1024L);
                    var changed = false;
                    if (document.Root == null ||
                        document.Root.Name.LocalName != "resources")
                    {
                        continue;
                    }
                    foreach (var element in document.Root.Elements()
                        .Where(item => item.Name.LocalName == "string"))
                    {
                        var name = ((string)element.Attribute("name") ?? string.Empty)
                            .Trim();
                        string replacement;
                        if (!replacements.TryGetValue(name, out replacement))
                        {
                            continue;
                        }
                        element.Value = replacement;
                        if (name == "notification_title_format")
                        {
                            element.SetAttributeValue("formatted", "true");
                        }
                        counts[name]++;
                        if (isBaseValues)
                        {
                            baseCounts[name]++;
                        }
                        changed = true;
                    }
                    if (changed)
                    {
                        SaveXmlDocument(document, xmlPath);
                    }
                }
            }
            var baseStringsPath = Path.Combine(
                resDirectory,
                "values",
                "strings.xml");
            RequireNonEmptyFile(
                baseStringsPath,
                "Android 品牌母版缺少基础 strings.xml");
            var missingBaseNames = replacements.Keys
                .Where(name => baseCounts[name] == 0)
                .ToList();
            if (missingBaseNames.Count > 0)
            {
                // Release 资源收缩可能移除当前 ABI 未引用的预留原生服务字符串；
                // 重封时补回品牌契约所需资源，确保后续组件启用时仍显示新名称。
                var baseDocument = LoadXmlDocument(
                    baseStringsPath,
                    32L * 1024L * 1024L);
                if (baseDocument.Root == null ||
                    baseDocument.Root.Name.LocalName != "resources")
                {
                    throw new InvalidDataException("基础 strings.xml 根节点无效");
                }
                foreach (var name in missingBaseNames)
                {
                    var element = new XElement(
                        "string",
                        new XAttribute("name", name),
                        replacements[name]);
                    if (name == "notification_title_format")
                    {
                        element.SetAttributeValue("formatted", "true");
                    }
                    baseDocument.Root.Add(element);
                    baseCounts[name] = 1;
                    counts[name]++;
                }
                SaveXmlDocument(baseDocument, baseStringsPath);
            }
            foreach (var name in replacements.Keys)
            {
                if (counts[name] == 0 || baseCounts[name] != 1)
                {
                    throw new InvalidDataException(
                        "Android 品牌母版基础字符串资源重复或无效：" + name);
                }
            }
        }

        private static void WriteBrandingFiles(
            DecodedPackageMetadata metadata,
            string productName,
            string targetBrandId,
            string targetApplicationId,
            BrandPackageRequest request,
            AndroidSigningProfile signingProfile)
        {
            var branding = metadata.BrandingValues;
            branding["schemaVersion"] = 1;
            branding["brandId"] = targetBrandId;
            branding["productName"] = productName;
            branding["windowTitle"] = productName;
            branding["trayTooltip"] = productName;
            branding["executableName"] = productName + ".exe";
            branding["installerBaseName"] = productName;
            branding["updateEnabled"] = request.UpdateEnabled;
            branding["hideAboutPage"] = request.HideAboutPage;
            branding["androidPackageName"] = targetApplicationId;
            WriteJson(metadata.BrandingPath, branding);

            var manifest = metadata.ManifestValues;
            manifest["schemaVersion"] = 1;
            manifest["brandReady"] = true;
            manifest["platform"] = "android";
            manifest["applicationId"] = targetApplicationId;
            manifest["sourcePackageName"] = metadata.SourcePackageName;
            manifest["brandingAsset"] = PackageDetector.AndroidBrandingEntryPath;
            manifest["brandId"] = targetBrandId;
            manifest["sourceProductName"] = productName;
            manifest["hideAboutPage"] = request.HideAboutPage;
            manifest["updateEnabled"] = request.UpdateEnabled;
            manifest["removeUpdateFeature"] = !request.UpdateEnabled;
            manifest["processIdentifier"] = targetApplicationId;
            manifest["signingProfileId"] = signingProfile.ProfileId;
            manifest["certificateSha256"] = signingProfile.CertificateSha256;
            WriteJson(metadata.BrandManifestPath, manifest);
        }

        private static void SignApk(
            ToolchainPaths tools,
            AndroidSigningProfile profile,
            string inputPath,
            string outputPath,
            string workingDirectory)
        {
            var environment = CreateJavaEnvironment(tools, workingDirectory);
            environment[StorePasswordEnvironmentName] = profile.Password;
            environment[KeyPasswordEnvironmentName] = profile.Password;
            var arguments = BuildJavaPrefix(tools, workingDirectory) +
                " -jar " + Quote(tools.ApksignerJarPath) +
                " sign --ks " + Quote(profile.KeystorePath) +
                " --ks-type PKCS12 --ks-key-alias " + Quote(profile.Alias) +
                " --ks-pass env:" + StorePasswordEnvironmentName +
                " --key-pass env:" + KeyPasswordEnvironmentName +
                " --v1-signing-enabled true" +
                " --v2-signing-enabled true" +
                " --v3-signing-enabled true" +
                " --v4-signing-enabled false" +
                " --out " + Quote(outputPath) + " " + Quote(inputPath);
            RunProcess(
                tools.JavaPath,
                arguments,
                workingDirectory,
                TimeSpan.FromMinutes(5),
                environment,
                "apksigner 签名");
        }

        private static ApkSignatureInfo VerifyApkSignature(
            ToolchainPaths tools,
            string apkPath,
            string workingDirectory,
            bool requireV2AndV3)
        {
            var arguments = BuildJavaPrefix(tools, workingDirectory) +
                " -jar " + Quote(tools.ApksignerJarPath) +
                " verify --verbose --print-certs " + Quote(apkPath);
            var result = RunProcess(
                tools.JavaPath,
                arguments,
                workingDirectory,
                TimeSpan.FromMinutes(5),
                CreateJavaEnvironment(tools, workingDirectory),
                "apksigner 验签");
            var output = result.StandardOutput + Environment.NewLine +
                result.StandardError;
            var matches = CertificateDigestPattern.Matches(output);
            var certificates = matches.Cast<Match>()
                .Select(match => NormalizeCertificateSha256(match.Groups[1].Value))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            if (certificates.Count != 1)
            {
                throw new InvalidDataException(
                    "APK 必须且只能包含一个可识别的签名证书");
            }
            if (requireV2AndV3)
            {
                if (!Regex.IsMatch(
                        output,
                        @"Verified using v2 scheme \(APK Signature Scheme v2\):\s*true",
                        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant) ||
                    !Regex.IsMatch(
                        output,
                        @"Verified using v3 scheme \(APK Signature Scheme v3\):\s*true",
                        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                {
                    throw new InvalidDataException(
                        "输出 APK 未同时通过 v2 和 v3 签名校验");
                }
            }
            return new ApkSignatureInfo
            {
                CertificateSha256 = certificates[0]
            };
        }

        private static void VerifyZipAlignment(
            ToolchainPaths tools,
            string apkPath,
            string workingDirectory)
        {
            RunProcess(
                tools.ZipalignPath,
                "-c -P 16 -v 4 " + Quote(apkPath),
                workingDirectory,
                TimeSpan.FromMinutes(5),
                null,
                "zipalign 对齐复检");
        }

        private static void RunApktool(
            ToolchainPaths tools,
            string workingDirectory,
            string apktoolArguments,
            TimeSpan timeout,
            string description)
        {
            var arguments = BuildJavaPrefix(tools, workingDirectory) +
                " -Xmx2048m -jar " + Quote(tools.ApktoolJarPath) + " " +
                apktoolArguments;
            RunProcess(
                tools.JavaPath,
                arguments,
                workingDirectory,
                timeout,
                CreateJavaEnvironment(tools, workingDirectory),
                description);
        }

        private static string BuildJavaPrefix(
            ToolchainPaths tools,
            string workingDirectory)
        {
            var javaStateDirectory = Path.Combine(workingDirectory, "java-state");
            var javaTempDirectory = Path.Combine(workingDirectory, "java-temp");
            Directory.CreateDirectory(javaStateDirectory);
            Directory.CreateDirectory(javaTempDirectory);
            return "-Duser.language=en -Duser.country=US -Dfile.encoding=UTF-8" +
                " -Duser.home=" + Quote(javaStateDirectory) +
                " -Djava.io.tmpdir=" + Quote(javaTempDirectory);
        }

        private static Dictionary<string, string> CreateJavaEnvironment(
            ToolchainPaths tools,
            string workingDirectory)
        {
            var javaTempDirectory = Path.Combine(workingDirectory, "java-temp");
            Directory.CreateDirectory(javaTempDirectory);
            return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "JAVA_HOME", tools.JavaHomeDirectory },
                { "PATH", Path.Combine(tools.JavaHomeDirectory, "bin") + ";" +
                    (Environment.GetEnvironmentVariable("PATH") ?? string.Empty) },
                { "TEMP", javaTempDirectory },
                { "TMP", javaTempDirectory }
            };
        }

        private static ProcessResult RunProcess(
            string executablePath,
            string arguments,
            string workingDirectory,
            TimeSpan timeout,
            IDictionary<string, string> environment,
            string description)
        {
            RequireNonEmptyFile(executablePath, "找不到内置执行文件");
            var startInfo = new ProcessStartInfo
            {
                FileName = executablePath,
                Arguments = arguments,
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            if (environment != null)
            {
                foreach (var pair in environment)
                {
                    startInfo.EnvironmentVariables[pair.Key] = pair.Value;
                }
            }

            using (var process = new Process { StartInfo = startInfo })
            {
                var standardOutput = new StringBuilder();
                var standardError = new StringBuilder();
                var outputLock = new object();
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null)
                    {
                        AppendCapturedLine(standardOutput, e.Data, outputLock);
                    }
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null)
                    {
                        AppendCapturedLine(standardError, e.Data, outputLock);
                    }
                };
                try
                {
                    if (!process.Start())
                    {
                        throw new InvalidOperationException("无法启动 " + description);
                    }
                }
                catch (Exception error)
                {
                    throw new InvalidOperationException(
                        "无法启动 " + description + "：" + error.Message,
                        error);
                }
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                var milliseconds = timeout.TotalMilliseconds > int.MaxValue
                    ? int.MaxValue
                    : Math.Max(1, (int)timeout.TotalMilliseconds);
                if (!process.WaitForExit(milliseconds))
                {
                    try { process.Kill(); } catch { }
                    try { process.WaitForExit(5000); } catch { }
                    throw new TimeoutException(
                        description + "执行超时（" +
                        Math.Ceiling(timeout.TotalMinutes).ToString(
                            CultureInfo.InvariantCulture) + " 分钟）");
                }
                process.WaitForExit();
                string stdout;
                string stderr;
                lock (outputLock)
                {
                    stdout = standardOutput.ToString();
                    stderr = standardError.ToString();
                }
                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException(
                        description + "失败，退出码 " + process.ExitCode +
                        Environment.NewLine + BuildProcessErrorTail(stdout, stderr));
                }
                return new ProcessResult
                {
                    StandardOutput = stdout,
                    StandardError = stderr
                };
            }
        }

        private static void AppendCapturedLine(
            StringBuilder builder,
            string value,
            object outputLock)
        {
            lock (outputLock)
            {
                if (builder.Length >= MaximumCapturedProcessCharacters)
                {
                    return;
                }
                var remaining = MaximumCapturedProcessCharacters - builder.Length;
                if (value.Length > remaining)
                {
                    builder.Append(value, 0, remaining);
                    return;
                }
                builder.AppendLine(value);
            }
        }

        private static string BuildProcessErrorTail(string stdout, string stderr)
        {
            var combined = (stdout ?? string.Empty) + Environment.NewLine +
                (stderr ?? string.Empty);
            const int maximum = 16000;
            if (combined.Length > maximum)
            {
                combined = "…（仅显示末尾输出）" + Environment.NewLine +
                    combined.Substring(combined.Length - maximum);
            }
            return combined.Trim();
        }

        private static void ValidateCapabilities(
            IDictionary<string, object> manifest,
            PackageDetectionResult inspection)
        {
            object raw;
            if (!manifest.TryGetValue("capabilities", out raw) || raw == null ||
                raw is string)
            {
                throw new InvalidDataException("Android 品牌母版 capabilities 必须为数组");
            }
            var values = raw as IEnumerable;
            if (values == null)
            {
                throw new InvalidDataException("Android 品牌母版 capabilities 必须为数组");
            }
            var capabilities = new HashSet<string>(StringComparer.Ordinal);
            foreach (var value in values)
            {
                var capability = value as string;
                if (string.IsNullOrWhiteSpace(capability) ||
                    !capabilities.Add(capability))
                {
                    throw new InvalidDataException(
                        "Android 品牌母版包含无效或重复 capability");
                }
            }
            foreach (var required in PackageDetector.GetRequiredAndroidCapabilities())
            {
                if (!capabilities.Contains(required) ||
                    !inspection.HasCapability(required))
                {
                    throw new InvalidDataException(
                        "Android 品牌母版缺少能力：" + required);
                }
            }
        }

        private static void ValidateComponentLabel(
            XElement application,
            XNamespace android,
            string classSuffix,
            string expectedLabel,
            string elementName)
        {
            var matches = application.Elements()
                .Where(item => item.Name.LocalName == elementName &&
                    (((string)item.Attribute(android + "name") ?? string.Empty)
                        .EndsWith(
                            "." + classSuffix,
                            StringComparison.Ordinal) ||
                     string.Equals(
                        (string)item.Attribute(android + "name"),
                        classSuffix,
                        StringComparison.Ordinal)))
                .ToList();
            if (matches.Count != 1 || !string.Equals(
                (string)matches[0].Attribute(android + "label"),
                expectedLabel,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Android 品牌母版组件 " + classSuffix +
                    " 必须引用 " + expectedLabel);
            }
        }

        private static void ValidateManifestCapabilityMarker(
            XElement application,
            XNamespace android)
        {
            var matches = application.Elements()
                .Where(item => item.Name.LocalName == "meta-data" &&
                    string.Equals(
                        (string)item.Attribute(android + "name"),
                        "top.wherewego.vnt.android_branding_capabilities",
                        StringComparison.Ordinal))
                .ToList();
            if (matches.Count != 1)
            {
                throw new InvalidDataException(
                    "AndroidManifest.xml 缺少唯一的品牌能力标记");
            }
            var raw = (string)matches[0].Attribute(android + "value") ?? string.Empty;
            var values = new HashSet<string>(
                raw.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)
                    .Select(value => value.Trim()),
                StringComparer.Ordinal);
            foreach (var required in PackageDetector.GetRequiredAndroidCapabilities())
            {
                if (!values.Contains(required))
                {
                    throw new InvalidDataException(
                        "AndroidManifest.xml 品牌能力标记缺少：" + required);
                }
            }
        }

        private static bool IsAndroidClassAttribute(
            XElement element,
            XAttribute attribute,
            XNamespace android)
        {
            if (attribute.Name.Namespace != android)
            {
                return false;
            }
            var elementName = element.Name.LocalName;
            var attributeName = attribute.Name.LocalName;
            if (attributeName == "name" && new[]
            {
                "application", "activity", "activity-alias", "service",
                "receiver", "provider", "instrumentation"
            }.Contains(elementName, StringComparer.Ordinal))
            {
                return true;
            }
            if (elementName == "activity-alias" && attributeName == "targetActivity")
            {
                return true;
            }
            return elementName == "application" && new[]
            {
                "backupAgent", "appComponentFactory", "manageSpaceActivity",
                "zygotePreloadName"
            }.Contains(attributeName, StringComparer.Ordinal);
        }

        private static string QualifyClassName(string value, string packageName)
        {
            var text = (value ?? string.Empty).Trim();
            if (string.IsNullOrEmpty(text) || text.StartsWith("${", StringComparison.Ordinal))
            {
                return value;
            }
            if (text[0] == '.')
            {
                return packageName + text;
            }
            if (text.IndexOf('.') < 0)
            {
                return packageName + "." + text;
            }
            return text;
        }

        private static string ReplacePackageScopedValue(
            string value,
            string sourceApplicationId,
            string targetApplicationId)
        {
            return (value ?? string.Empty)
                .Replace("${applicationId}", targetApplicationId)
                .Replace("${packageName}", targetApplicationId)
                .Replace(sourceApplicationId, targetApplicationId);
        }

        private static string EscapeAndroidResourceText(string value)
        {
            var escaped = (value ?? string.Empty)
                .Replace("\\", "\\\\")
                .Replace("'", "\\'");
            if (escaped.StartsWith("@", StringComparison.Ordinal) ||
                escaped.StartsWith("?", StringComparison.Ordinal))
            {
                escaped = "\\" + escaped;
            }
            return escaped;
        }

        private static XDocument LoadXmlDocument(string path, long maximumBytes)
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length <= 0 || info.Length > maximumBytes)
            {
                throw new InvalidDataException("XML 文件不存在、为空或过大：" + path);
            }
            var settings = new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Prohibit,
                XmlResolver = null,
                MaxCharactersInDocument = maximumBytes * 4
            };
            try
            {
                using (var stream = new FileStream(
                    path,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read))
                using (var reader = XmlReader.Create(stream, settings))
                {
                    return XDocument.Load(
                        reader,
                        LoadOptions.PreserveWhitespace | LoadOptions.SetLineInfo);
                }
            }
            catch (Exception error)
            {
                throw new InvalidDataException(
                    "无法读取 XML 文件 " + Path.GetFileName(path) +
                    "：" + error.Message,
                    error);
            }
        }

        private static void SaveXmlDocument(XDocument document, string path)
        {
            var temporary = path + ".tmp_" + Guid.NewGuid().ToString("N");
            try
            {
                var settings = new XmlWriterSettings
                {
                    Encoding = Utf8WithoutBom,
                    Indent = true,
                    NewLineChars = "\n",
                    NewLineHandling = NewLineHandling.Replace
                };
                using (var stream = new FileStream(
                    temporary,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None))
                using (var writer = XmlWriter.Create(stream, settings))
                {
                    document.Save(writer);
                }
                ReplaceFile(temporary, path);
            }
            finally
            {
                TryDeleteFile(temporary);
            }
        }

        private static Dictionary<string, object> ReadJsonObject(
            string path,
            long maximumBytes,
            string description)
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length <= 1 || info.Length > maximumBytes)
            {
                throw new InvalidDataException(description + "不存在、为空或超过 64 KB");
            }
            string json;
            try
            {
                using (var reader = new StreamReader(
                    path,
                    new UTF8Encoding(false, true),
                    true))
                {
                    json = reader.ReadToEnd();
                }
            }
            catch (Exception error)
            {
                throw new InvalidDataException(description + "不是有效的 UTF-8", error);
            }
            try
            {
                var value = new JavaScriptSerializer()
                    .Deserialize<Dictionary<string, object>>(json);
                if (value == null)
                {
                    throw new InvalidDataException(description + "必须是 JSON 对象");
                }
                return value;
            }
            catch (InvalidDataException)
            {
                throw;
            }
            catch (Exception error)
            {
                throw new InvalidDataException(description + "不是有效的 JSON", error);
            }
        }

        private static void WriteJson(
            string path,
            Dictionary<string, object> value)
        {
            var json = new JavaScriptSerializer().Serialize(value);
            if (Utf8WithoutBom.GetByteCount(json) > 64 * 1024)
            {
                throw new InvalidDataException("品牌 JSON 超过 64 KB 安全上限");
            }
            var temporary = path + ".tmp_" + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllText(temporary, json, Utf8WithoutBom);
                ReplaceFile(temporary, path);
            }
            finally
            {
                TryDeleteFile(temporary);
            }
        }

        private static void ReplaceFile(string sourcePath, string destinationPath)
        {
            if (File.Exists(destinationPath))
            {
                File.Delete(destinationPath);
            }
            File.Move(sourcePath, destinationPath);
        }

        private static void RequireSchemaVersion(
            IDictionary<string, object> values,
            string description)
        {
            object raw;
            int schemaVersion;
            try
            {
                if (!values.TryGetValue("schemaVersion", out raw))
                {
                    throw new FormatException();
                }
                schemaVersion = Convert.ToInt32(raw, CultureInfo.InvariantCulture);
            }
            catch (Exception error)
            {
                throw new InvalidDataException(
                    description + " schemaVersion 无效",
                    error);
            }
            if (schemaVersion != 1)
            {
                throw new InvalidDataException(description + "版本不受支持");
            }
        }

        private static string RequireString(
            IDictionary<string, object> values,
            string key,
            string description)
        {
            object raw;
            var text = values.TryGetValue(key, out raw) ? raw as string : null;
            if (string.IsNullOrWhiteSpace(text))
            {
                throw new InvalidDataException(description + "缺少字段：" + key);
            }
            return text.Trim();
        }

        private static string ReadOptionalString(
            IDictionary<string, object> values,
            string key)
        {
            object raw;
            var text = values.TryGetValue(key, out raw) ? raw as string : null;
            return string.IsNullOrWhiteSpace(text) ? string.Empty : text.Trim();
        }

        private static bool RequireBoolean(
            IDictionary<string, object> values,
            string key,
            string description)
        {
            object raw;
            if (!values.TryGetValue(key, out raw) || !(raw is bool))
            {
                throw new InvalidDataException(
                    description + "字段必须为布尔值：" + key);
            }
            return (bool)raw;
        }

        private static string CreateBrandId(string productName)
        {
            return "brand_" + ComputeSha256Text(productName).Substring(0, 24);
        }

        private static string CreateApplicationId()
        {
            var random = new byte[16];
            using (var generator = RandomNumberGenerator.Create())
            {
                generator.GetBytes(random);
            }
            try
            {
                return "top.wherewego.vnt.b" +
                    BitConverter.ToString(random)
                        .Replace("-", string.Empty)
                        .ToLowerInvariant();
            }
            finally
            {
                Array.Clear(random, 0, random.Length);
            }
        }

        private static string ComputeSha256Text(string value)
        {
            using (var sha = SHA256.Create())
            {
                return BitConverter.ToString(
                        sha.ComputeHash(Encoding.UTF8.GetBytes(value ?? string.Empty)))
                    .Replace("-", string.Empty)
                    .ToLowerInvariant();
            }
        }

        private static string ComputeFileSha256(string path)
        {
            using (var sha = SHA256.Create())
            using (var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read))
            {
                return BitConverter.ToString(sha.ComputeHash(stream))
                    .Replace("-", string.Empty);
            }
        }

        private static string ResolveOutputPath(
            BrandPackageRequest request,
            string productName,
            string version)
        {
            string result;
            if (!string.IsNullOrWhiteSpace(request.OutputInstallerPath))
            {
                result = Path.GetFullPath(request.OutputInstallerPath);
            }
            else
            {
                if (string.IsNullOrWhiteSpace(request.OutputDirectory))
                {
                    throw new ArgumentException("请选择 APK 保存位置");
                }
                result = Path.Combine(
                    Path.GetFullPath(request.OutputDirectory),
                    productName.Replace(' ', '_') + "_" + version +
                        "_Android_arm64.apk");
            }
            if (!string.Equals(
                Path.GetExtension(result),
                ".apk",
                StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("Android 安装包必须保存为 .apk 文件");
            }
            if (string.Equals(
                result,
                Path.GetFullPath(request.InstallerPath),
                StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("不能覆盖正在使用的源 APK");
            }
            return result;
        }

        private static string ValidateRelativeArchivePath(
            string rawPath,
            string description)
        {
            if (string.IsNullOrEmpty(rawPath))
            {
                return string.Empty;
            }
            if (rawPath.IndexOf('\0') >= 0 || rawPath.IndexOf('\\') >= 0 ||
                rawPath.IndexOf(':') >= 0 || rawPath.StartsWith("/", StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    description + "包含非法归档路径：" + rawPath);
            }
            var isDirectory = rawPath.EndsWith("/", StringComparison.Ordinal);
            var parts = rawPath.Split('/');
            var normalized = new List<string>();
            foreach (var part in parts)
            {
                if (part.Length == 0)
                {
                    continue;
                }
                if (part == "." || part == "..")
                {
                    throw new InvalidDataException(
                        description + "包含越权归档路径：" + rawPath);
                }
                normalized.Add(part);
            }
            var result = string.Join("/", normalized.ToArray());
            return isDirectory && result.Length > 0 ? result + "/" : result;
        }

        private static void RejectSymbolicLink(
            ZipArchiveEntry entry,
            string description)
        {
            var unixMode = (entry.ExternalAttributes >> 16) & 0xF000;
            if (unixMode == 0xA000)
            {
                throw new InvalidDataException(
                    description + "不允许符号链接条目：" + entry.FullName);
            }
        }

        private static long CheckedAdd(long left, long right, string message)
        {
            try
            {
                return checked(left + right);
            }
            catch (OverflowException error)
            {
                throw new InvalidDataException(message, error);
            }
        }

        private static void ValidateApplicationId(string value, string description)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length > 255 ||
                !ApplicationIdPattern.IsMatch(value) || value.Contains(".."))
            {
                throw new InvalidDataException(description + "格式无效");
            }
        }

        private static void ValidateBrandId(string value)
        {
            if (string.IsNullOrWhiteSpace(value) || !BrandIdPattern.IsMatch(value) ||
                value.Contains(".."))
            {
                throw new InvalidDataException("Android brandId 格式无效");
            }
        }

        private static string NormalizeCertificateSha256(string value)
        {
            var result = (value ?? string.Empty)
                .Replace(":", string.Empty)
                .Replace(" ", string.Empty)
                .ToUpperInvariant();
            if (!Regex.IsMatch(
                result,
                @"^[0-9A-F]{64}$",
                RegexOptions.CultureInvariant))
            {
                throw new InvalidDataException("Android 签名证书 SHA-256 指纹无效");
            }
            return result;
        }

        private static void EnsureCertificateMatches(
            string actual,
            string expected,
            string message)
        {
            if (!string.Equals(
                NormalizeCertificateSha256(actual),
                NormalizeCertificateSha256(expected),
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(message);
            }
        }

        private static void RequireNonEmptyFile(string path, string message)
        {
            if (!File.Exists(path) || new FileInfo(path).Length <= 0)
            {
                throw new FileNotFoundException(message, path);
            }
        }

        private static string Quote(string value)
        {
            return "\"" + (value ?? string.Empty).Replace("\"", "\\\"") + "\"";
        }

        private static void TryDeleteFile(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.SetAttributes(path, FileAttributes.Normal);
                    File.Delete(path);
                }
            }
            catch
            {
                // 临时文件清理失败不覆盖原始异常。
            }
        }

        private static bool TryDeleteDirectory(string path)
        {
            for (var attempt = 0; attempt < 3; attempt++)
            {
                try
                {
                    if (!Directory.Exists(path))
                    {
                        return true;
                    }
                    foreach (var file in Directory.GetFiles(
                        path,
                        "*",
                        SearchOption.AllDirectories))
                    {
                        try { File.SetAttributes(file, FileAttributes.Normal); }
                        catch { }
                    }
                    Directory.Delete(path, true);
                    return true;
                }
                catch
                {
                    if (attempt < 2)
                    {
                        Thread.Sleep(100);
                    }
                }
            }
            return !Directory.Exists(path);
        }

        private sealed class ToolchainPaths
        {
            public string RootDirectory { get; set; }
            public string AndroidRootDirectory { get; set; }
            public string JavaHomeDirectory { get; set; }
            public string JavaPath { get; set; }
            public string KeytoolPath { get; set; }
            public string ApktoolJarPath { get; set; }
            public string ZipalignPath { get; set; }
            public string ApksignerJarPath { get; set; }
        }

        private sealed class DecodedPackageMetadata
        {
            public string DecodedDirectory { get; set; }
            public string ManifestPath { get; set; }
            public string BrandingPath { get; set; }
            public string BrandManifestPath { get; set; }
            public Dictionary<string, object> ManifestValues { get; set; }
            public Dictionary<string, object> BrandingValues { get; set; }
            public string SourceApplicationId { get; set; }
            public string SourcePackageName { get; set; }
            public string SourceBrandId { get; set; }
            public string SourceCertificateSha256 { get; set; }
            public string Version { get; set; }
        }

        private sealed class ApkSignatureInfo
        {
            public string CertificateSha256 { get; set; }
        }

        private sealed class ProcessResult
        {
            public string StandardOutput { get; set; }
            public string StandardError { get; set; }
        }
    }
}
