using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace VntBrandRepackager
{
    internal enum PackageFormat
    {
        Unknown = 0,
        WindowsExecutable = 1,
        AndroidApk = 2
    }

    internal sealed class PackageDetectionResult
    {
        private readonly string[] _capabilities;

        private PackageDetectionResult(
            string inputPath,
            PackageFormat format,
            bool isSupported,
            string errorMessage,
            string version,
            string brandId,
            string applicationId,
            IEnumerable<string> capabilities)
        {
            InputPath = inputPath ?? string.Empty;
            Format = format;
            IsSupported = isSupported;
            ErrorMessage = errorMessage ?? string.Empty;
            Version = version ?? string.Empty;
            BrandId = brandId ?? string.Empty;
            ApplicationId = applicationId ?? string.Empty;
            _capabilities = capabilities == null
                ? new string[0]
                : capabilities.ToArray();
        }

        public string InputPath { get; private set; }

        public PackageFormat Format { get; private set; }

        public bool IsSupported { get; private set; }

        public string ErrorMessage { get; private set; }

        public string Version { get; private set; }

        public string BrandId { get; private set; }

        public string ApplicationId { get; private set; }

        public string SuggestedExtension
        {
            get
            {
                if (Format == PackageFormat.WindowsExecutable)
                {
                    return ".exe";
                }
                return Format == PackageFormat.AndroidApk ? ".apk" : string.Empty;
            }
        }

        public string PlatformDisplayName
        {
            get
            {
                if (Format == PackageFormat.WindowsExecutable)
                {
                    return "Windows EXE";
                }
                return Format == PackageFormat.AndroidApk
                    ? "Android APK"
                    : "未知格式";
            }
        }

        public string[] Capabilities
        {
            get { return (string[])_capabilities.Clone(); }
        }

        public bool HasCapability(string capability)
        {
            return !string.IsNullOrEmpty(capability) &&
                _capabilities.Contains(capability, StringComparer.Ordinal);
        }

        internal static PackageDetectionResult Supported(
            string inputPath,
            PackageFormat format,
            string version,
            string brandId,
            string applicationId,
            IEnumerable<string> capabilities)
        {
            return new PackageDetectionResult(
                inputPath,
                format,
                true,
                string.Empty,
                version,
                brandId,
                applicationId,
                capabilities);
        }

        internal static PackageDetectionResult Unsupported(
            string inputPath,
            PackageFormat format,
            string errorMessage)
        {
            return new PackageDetectionResult(
                inputPath,
                format,
                false,
                errorMessage,
                string.Empty,
                string.Empty,
                string.Empty,
                null);
        }
    }

    internal static class PackageDetector
    {
        internal const string WindowsBrandReadyMarker = "VNT_BRAND_READY_V1";
        internal const string AndroidManifestEntryPath = "AndroidManifest.xml";
        internal const string AndroidResourcesEntryPath = "resources.arsc";
        internal const string AndroidBrandManifestEntryPath =
            "assets/flutter_assets/assets/android_brand_package_manifest.json";
        internal const string AndroidBrandingEntryPath =
            "assets/flutter_assets/assets/android_branding.json";

        private const long MaximumAndroidBinaryManifestBytes = 16L * 1024L * 1024L;
        private const long MaximumAndroidResourcesBytes = 1024L * 1024L * 1024L;
        private const long MaximumDexBytes = 1024L * 1024L * 1024L;
        private const long MaximumBrandManifestBytes = 64L * 1024L;
        private const long MaximumBrandingBytes = 64L * 1024L;

        private static readonly string[] RequiredAndroidCapabilities =
        {
            "androidRuntimeBrandingV1",
            "hideAboutPage",
            "removeUpdateFeature",
            "launcherIconV1",
            "applicationIdRewriteV1"
        };

        private static readonly Regex AndroidApplicationIdPattern = new Regex(
            @"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$",
            RegexOptions.CultureInvariant);

        private static readonly Regex DexEntryPattern = new Regex(
            @"^classes(?:[1-9][0-9]*)?\.dex$",
            RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

        public static PackageDetectionResult Inspect(string inputPath)
        {
            if (string.IsNullOrWhiteSpace(inputPath))
            {
                return PackageDetectionResult.Unsupported(
                    string.Empty,
                    PackageFormat.Unknown,
                    "请选择要导入的安装包");
            }

            string fullPath;
            try
            {
                fullPath = Path.GetFullPath(inputPath);
            }
            catch (Exception error)
            {
                return PackageDetectionResult.Unsupported(
                    inputPath,
                    PackageFormat.Unknown,
                    "安装包路径无效：" + error.Message);
            }

            if (!File.Exists(fullPath))
            {
                return PackageDetectionResult.Unsupported(
                    fullPath,
                    PackageFormat.Unknown,
                    "安装包不存在");
            }

            byte[] signature;
            try
            {
                signature = ReadFilePrefix(fullPath, 4);
            }
            catch (Exception error)
            {
                return PackageDetectionResult.Unsupported(
                    fullPath,
                    PackageFormat.Unknown,
                    "无法读取安装包：" + error.Message);
            }

            if (signature.Length >= 2 && signature[0] == 0x4D &&
                signature[1] == 0x5A)
            {
                return InspectWindowsExecutable(fullPath);
            }

            if (signature.Length == 4 && signature[0] == 0x50 &&
                signature[1] == 0x4B && signature[2] == 0x03 &&
                signature[3] == 0x04)
            {
                return InspectAndroidApk(fullPath);
            }

            return PackageDetectionResult.Unsupported(
                fullPath,
                PackageFormat.Unknown,
                "无法按文件内容识别安装包；仅支持品牌母版 Windows EXE 或 Android APK");
        }

        public static PackageDetectionResult RequireSupported(string inputPath)
        {
            var result = Inspect(inputPath);
            if (!result.IsSupported)
            {
                throw new InvalidDataException(result.ErrorMessage);
            }
            return result;
        }

        public static string[] GetRequiredAndroidCapabilities()
        {
            return (string[])RequiredAndroidCapabilities.Clone();
        }

        private static PackageDetectionResult InspectWindowsExecutable(string path)
        {
            try
            {
                ValidatePortableExecutableHeaders(path);
                var versionInfo = FileVersionInfo.GetVersionInfo(path);
                if (!string.Equals(
                    (versionInfo.FileDescription ?? string.Empty).TrimEnd(),
                    WindowsBrandReadyMarker,
                    StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "该 Windows 安装包不是支持一键换牌的品牌母版（缺少品牌母版标记）");
                }

                var version = FirstNotEmpty(
                    versionInfo.ProductVersion,
                    versionInfo.FileVersion);
                return PackageDetectionResult.Supported(
                    path,
                    PackageFormat.WindowsExecutable,
                    version,
                    string.Empty,
                    string.Empty,
                    null);
            }
            catch (Exception error)
            {
                return PackageDetectionResult.Unsupported(
                    path,
                    PackageFormat.WindowsExecutable,
                    "Windows EXE 校验失败：" + error.Message);
            }
        }

        private static PackageDetectionResult InspectAndroidApk(string path)
        {
            try
            {
                using (var archive = ZipFile.OpenRead(path))
                {
                    var entries = IndexCriticalEntries(archive);
                    var binaryManifest = RequireSingleEntry(
                        entries,
                        AndroidManifestEntryPath);
                    var resources = RequireSingleEntry(
                        entries,
                        AndroidResourcesEntryPath);
                    var brandManifest = RequireSingleEntry(
                        entries,
                        AndroidBrandManifestEntryPath);
                    var branding = RequireSingleEntry(
                        entries,
                        AndroidBrandingEntryPath);

                    ValidateBinaryXml(binaryManifest);
                    ValidateResourcesTable(resources);
                    ValidateDexEntries(entries);
                    ValidateEntrySize(
                        brandManifest,
                        2,
                        MaximumBrandManifestBytes,
                        "Android 品牌母版清单");
                    ValidateEntrySize(
                        branding,
                        2,
                        MaximumBrandingBytes,
                        "Android 运行时品牌配置");

                    var manifest = ReadJsonObject(
                        brandManifest,
                        MaximumBrandManifestBytes,
                        "Android 品牌母版清单");
                    var capabilities = ValidateAndroidBrandManifest(manifest);
                    var brandingValues = ReadJsonObject(
                        branding,
                        MaximumBrandingBytes,
                        "Android 运行时品牌配置");
                    var version = ReadOptionalString(manifest, "versionName");
                    if (string.IsNullOrEmpty(version))
                    {
                        version = ReadOptionalString(manifest, "version");
                    }
                    if (string.IsNullOrEmpty(version) ||
                        !Regex.IsMatch(version, @"^\d+(\.\d+){1,3}$"))
                    {
                        throw new InvalidDataException("品牌母版清单版本号无效");
                    }
                    var applicationId = RequireString(manifest, "applicationId");
                    var brandId = RequireString(manifest, "brandId");
                    ValidateAndroidRuntimeBranding(
                        brandingValues,
                        brandId,
                        applicationId);

                    return PackageDetectionResult.Supported(
                        path,
                        PackageFormat.AndroidApk,
                        version,
                        brandId,
                        applicationId,
                        capabilities);
                }
            }
            catch (Exception error)
            {
                return PackageDetectionResult.Unsupported(
                    path,
                    PackageFormat.AndroidApk,
                    "Android APK 校验失败：" + error.Message);
            }
        }

        private static void ValidatePortableExecutableHeaders(string path)
        {
            using (var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read))
            using (var reader = new BinaryReader(stream))
            {
                if (stream.Length < 68 || reader.ReadUInt16() != 0x5A4D)
                {
                    throw new InvalidDataException("MZ 文件头无效");
                }
                stream.Position = 0x3C;
                var peOffset = reader.ReadUInt32();
                if (peOffset < 0x40 || peOffset > stream.Length - 24)
                {
                    throw new InvalidDataException("PE 头偏移越界");
                }
                stream.Position = peOffset;
                if (reader.ReadUInt32() != 0x00004550)
                {
                    throw new InvalidDataException("PE 签名无效");
                }
            }
        }

        private static Dictionary<string, List<ZipArchiveEntry>> IndexCriticalEntries(
            ZipArchive archive)
        {
            var result = new Dictionary<string, List<ZipArchiveEntry>>(
                StringComparer.OrdinalIgnoreCase);
            foreach (var entry in archive.Entries)
            {
                var originalPath = entry.FullName ?? string.Empty;
                var rawPath = originalPath.Replace('\\', '/');
                var normalizedPath = NormalizeArchivePath(rawPath);
                string criticalPath;
                if (!TryGetCriticalPath(normalizedPath, out criticalPath))
                {
                    continue;
                }
                if (!string.Equals(originalPath, normalizedPath, StringComparison.Ordinal) ||
                    !string.Equals(normalizedPath, criticalPath, StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "APK 关键条目路径或大小写不规范：" + entry.FullName);
                }

                List<ZipArchiveEntry> values;
                if (!result.TryGetValue(criticalPath, out values))
                {
                    values = new List<ZipArchiveEntry>();
                    result.Add(criticalPath, values);
                }
                values.Add(entry);
                if (values.Count > 1)
                {
                    throw new InvalidDataException(
                        "APK 包含重复关键条目：" + criticalPath);
                }
            }
            return result;
        }

        private static string NormalizeArchivePath(string path)
        {
            if (string.IsNullOrEmpty(path))
            {
                return string.Empty;
            }
            if (path[0] == '/')
            {
                throw new InvalidDataException("APK 包含绝对路径条目");
            }

            var parts = path.Split('/');
            var normalized = new List<string>();
            foreach (var part in parts)
            {
                if (part.Length == 0 || part == ".")
                {
                    continue;
                }
                if (part == "..")
                {
                    throw new InvalidDataException("APK 包含越权路径条目");
                }
                normalized.Add(part);
            }
            return string.Join("/", normalized.ToArray());
        }

        private static bool TryGetCriticalPath(
            string normalizedPath,
            out string criticalPath)
        {
            var fixedPaths = new[]
            {
                AndroidManifestEntryPath,
                AndroidResourcesEntryPath,
                AndroidBrandManifestEntryPath,
                AndroidBrandingEntryPath
            };
            foreach (var fixedPath in fixedPaths)
            {
                if (string.Equals(
                    normalizedPath,
                    fixedPath,
                    StringComparison.OrdinalIgnoreCase))
                {
                    criticalPath = fixedPath;
                    return true;
                }
            }

            if (DexEntryPattern.IsMatch(normalizedPath))
            {
                criticalPath = normalizedPath.ToLowerInvariant();
                return true;
            }
            criticalPath = string.Empty;
            return false;
        }

        private static ZipArchiveEntry RequireSingleEntry(
            IDictionary<string, List<ZipArchiveEntry>> entries,
            string path)
        {
            List<ZipArchiveEntry> values;
            if (!entries.TryGetValue(path, out values) || values.Count != 1 ||
                string.IsNullOrEmpty(values[0].Name))
            {
                throw new InvalidDataException("APK 缺少关键条目：" + path);
            }
            return values[0];
        }

        private static void ValidateBinaryXml(ZipArchiveEntry entry)
        {
            ValidateEntrySize(
                entry,
                8,
                MaximumAndroidBinaryManifestBytes,
                AndroidManifestEntryPath);
            var header = ReadEntryPrefix(entry, 8);
            var chunkType = ReadUInt16LittleEndian(header, 0);
            var headerSize = ReadUInt16LittleEndian(header, 2);
            var chunkSize = ReadUInt32LittleEndian(header, 4);
            if (chunkType != 0x0003 || headerSize != 0x0008 ||
                chunkSize != (ulong)entry.Length)
            {
                throw new InvalidDataException("AndroidManifest.xml 不是有效的二进制 XML");
            }
        }

        private static void ValidateResourcesTable(ZipArchiveEntry entry)
        {
            ValidateEntrySize(
                entry,
                12,
                MaximumAndroidResourcesBytes,
                AndroidResourcesEntryPath);
            var header = ReadEntryPrefix(entry, 12);
            var chunkType = ReadUInt16LittleEndian(header, 0);
            var headerSize = ReadUInt16LittleEndian(header, 2);
            var chunkSize = ReadUInt32LittleEndian(header, 4);
            if (chunkType != 0x0002 || headerSize < 0x000C ||
                chunkSize != (ulong)entry.Length)
            {
                throw new InvalidDataException("resources.arsc 资源表头无效");
            }
        }

        private static void ValidateDexEntries(
            IDictionary<string, List<ZipArchiveEntry>> entries)
        {
            var dexEntries = entries
                .Where(pair => DexEntryPattern.IsMatch(pair.Key))
                .Select(pair => pair.Value[0])
                .ToList();
            if (!entries.ContainsKey("classes.dex") || dexEntries.Count == 0)
            {
                throw new InvalidDataException("APK 缺少 classes.dex");
            }

            foreach (var entry in dexEntries)
            {
                ValidateEntrySize(entry, 112, MaximumDexBytes, entry.FullName);
                var header = ReadEntryPrefix(entry, 8);
                var valid = header[0] == 0x64 && header[1] == 0x65 &&
                    header[2] == 0x78 && header[3] == 0x0A &&
                    IsAsciiDigit(header[4]) && IsAsciiDigit(header[5]) &&
                    IsAsciiDigit(header[6]) && header[7] == 0x00;
                if (!valid)
                {
                    throw new InvalidDataException(
                        entry.FullName + " 的 DEX 文件头无效");
                }
            }
        }

        private static List<string> ValidateAndroidBrandManifest(
            IDictionary<string, object> manifest)
        {
            if (ReadRequiredInteger(manifest, "schemaVersion") != 1)
            {
                throw new InvalidDataException("品牌母版清单 schemaVersion 不受支持");
            }
            object brandReady;
            if (!manifest.TryGetValue("brandReady", out brandReady) ||
                !(brandReady is bool) || !(bool)brandReady)
            {
                throw new InvalidDataException("品牌母版清单的 brandReady 必须为 true");
            }
            if (!string.Equals(
                RequireString(manifest, "platform"),
                "android",
                StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("品牌母版清单 platform 不是 android");
            }
            var applicationId = RequireString(manifest, "applicationId");
            if (applicationId.Length > 255 ||
                !AndroidApplicationIdPattern.IsMatch(applicationId))
            {
                throw new InvalidDataException("品牌母版清单 applicationId 无效");
            }
            var brandingAsset = RequireString(manifest, "brandingAsset");
            if (!string.Equals(
                brandingAsset,
                AndroidBrandingEntryPath,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException("品牌母版清单 brandingAsset 路径无效");
            }

            object rawCapabilities;
            if (!manifest.TryGetValue("capabilities", out rawCapabilities) ||
                rawCapabilities == null || rawCapabilities is string)
            {
                throw new InvalidDataException("品牌母版清单 capabilities 必须为数组");
            }
            var enumerable = rawCapabilities as IEnumerable;
            if (enumerable == null)
            {
                throw new InvalidDataException("品牌母版清单 capabilities 必须为数组");
            }

            var capabilities = new List<string>();
            foreach (var value in enumerable)
            {
                var capability = value as string;
                if (string.IsNullOrWhiteSpace(capability))
                {
                    throw new InvalidDataException("品牌母版清单包含无效 capability");
                }
                if (capabilities.Contains(capability, StringComparer.Ordinal))
                {
                    throw new InvalidDataException(
                        "品牌母版清单包含重复 capability：" + capability);
                }
                capabilities.Add(capability);
            }
            foreach (var required in RequiredAndroidCapabilities)
            {
                if (!capabilities.Contains(required, StringComparer.Ordinal))
                {
                    throw new InvalidDataException(
                        "Android 品牌母版缺少能力：" + required);
                }
            }
            return capabilities;
        }

        private static void ValidateAndroidRuntimeBranding(
            IDictionary<string, object> branding,
            string expectedBrandId,
            string expectedApplicationId)
        {
            if (ReadRequiredInteger(branding, "schemaVersion") != 1)
            {
                throw new InvalidDataException(
                    "Android 运行时品牌配置 schemaVersion 不受支持");
            }
            var brandId = RequireString(branding, "brandId");
            var applicationId = RequireString(branding, "androidPackageName");
            var productName = RequireString(branding, "productName");
            if (!string.Equals(brandId, expectedBrandId, StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Android 运行时品牌配置 brandId 与母版清单不一致");
            }
            if (!string.Equals(
                applicationId,
                expectedApplicationId,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Android 运行时品牌配置 applicationId 与母版清单不一致");
            }
            if (productName.Length > 128)
            {
                throw new InvalidDataException("Android 运行时产品名称过长");
            }
            ReadRequiredBoolean(branding, "updateEnabled");
            ReadRequiredBoolean(branding, "hideAboutPage");
        }

        private static Dictionary<string, object> ReadJsonObject(
            ZipArchiveEntry entry,
            long maximumBytes,
            string description)
        {
            ValidateEntrySize(entry, 2, maximumBytes, description);
            byte[] bytes;
            using (var input = entry.Open())
            using (var output = new MemoryStream((int)entry.Length))
            {
                input.CopyTo(output);
                bytes = output.ToArray();
            }

            string json;
            try
            {
                json = new UTF8Encoding(false, true).GetString(bytes);
            }
            catch (DecoderFallbackException error)
            {
                throw new InvalidDataException(description + "不是有效的 UTF-8", error);
            }

            Dictionary<string, object> result;
            try
            {
                result = new JavaScriptSerializer()
                    .Deserialize<Dictionary<string, object>>(json);
            }
            catch (Exception error)
            {
                throw new InvalidDataException(description + "不是有效的 JSON", error);
            }
            if (result == null)
            {
                throw new InvalidDataException(description + "必须是 JSON 对象");
            }
            return result;
        }

        private static string RequireString(
            IDictionary<string, object> values,
            string key)
        {
            object raw;
            var value = values.TryGetValue(key, out raw) ? raw as string : null;
            if (string.IsNullOrWhiteSpace(value))
            {
                throw new InvalidDataException("品牌母版清单缺少字段：" + key);
            }
            return value.Trim();
        }

        private static string ReadOptionalString(
            IDictionary<string, object> values,
            string key)
        {
            object raw;
            var value = values.TryGetValue(key, out raw) ? raw as string : null;
            return string.IsNullOrWhiteSpace(value) ? string.Empty : value.Trim();
        }

        private static int ReadRequiredInteger(
            IDictionary<string, object> values,
            string key)
        {
            object raw;
            if (!values.TryGetValue(key, out raw) || raw == null)
            {
                throw new InvalidDataException("品牌配置缺少整数字段：" + key);
            }
            try
            {
                return Convert.ToInt32(raw);
            }
            catch (Exception error)
            {
                throw new InvalidDataException(
                    "品牌配置字段不是整数：" + key,
                    error);
            }
        }

        private static bool ReadRequiredBoolean(
            IDictionary<string, object> values,
            string key)
        {
            object raw;
            if (!values.TryGetValue(key, out raw) || !(raw is bool))
            {
                throw new InvalidDataException("品牌配置字段不是布尔值：" + key);
            }
            return (bool)raw;
        }

        private static void ValidateEntrySize(
            ZipArchiveEntry entry,
            long minimumBytes,
            long maximumBytes,
            string description)
        {
            if (entry.Length < minimumBytes || entry.Length > maximumBytes)
            {
                throw new InvalidDataException(
                    description + "大小无效（" + entry.Length + " 字节）");
            }
        }

        private static byte[] ReadEntryPrefix(ZipArchiveEntry entry, int count)
        {
            var buffer = new byte[count];
            using (var stream = entry.Open())
            {
                ReadExactly(stream, buffer, 0, buffer.Length);
            }
            return buffer;
        }

        private static byte[] ReadFilePrefix(string path, int count)
        {
            var buffer = new byte[count];
            int read;
            using (var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read))
            {
                read = stream.Read(buffer, 0, buffer.Length);
            }
            if (read == buffer.Length)
            {
                return buffer;
            }
            var result = new byte[read];
            Array.Copy(buffer, result, read);
            return result;
        }

        private static void ReadExactly(
            Stream stream,
            byte[] buffer,
            int offset,
            int count)
        {
            while (count > 0)
            {
                var read = stream.Read(buffer, offset, count);
                if (read <= 0)
                {
                    throw new EndOfStreamException("安装包关键条目被截断");
                }
                offset += read;
                count -= read;
            }
        }

        private static ushort ReadUInt16LittleEndian(byte[] value, int offset)
        {
            return (ushort)(value[offset] | (value[offset + 1] << 8));
        }

        private static uint ReadUInt32LittleEndian(byte[] value, int offset)
        {
            return (uint)value[offset] |
                ((uint)value[offset + 1] << 8) |
                ((uint)value[offset + 2] << 16) |
                ((uint)value[offset + 3] << 24);
        }

        private static bool IsAsciiDigit(byte value)
        {
            return value >= 0x30 && value <= 0x39;
        }

        private static string FirstNotEmpty(params string[] values)
        {
            foreach (var value in values)
            {
                if (!string.IsNullOrWhiteSpace(value))
                {
                    return value.Trim();
                }
            }
            return string.Empty;
        }
    }
}
