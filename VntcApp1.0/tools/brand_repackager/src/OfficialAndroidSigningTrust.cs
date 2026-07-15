using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace VntBrandRepackager
{
    internal sealed class OfficialAndroidSigningTrust
    {
        internal const string ResourceName =
            "VntBrandRepackager.OfficialAndroidSigningTrust.json";
        private const int ExpectedSchemaVersion = 1;
        private const string ExpectedKeyId =
            "vnt-official-android-release-v1";
        private const string ExpectedBrandId = "official";
        private const string ExpectedApplicationId =
            "top.wherewego.vnt_app";
        private const string ExpectedAlias =
            "vnt_official_android_release_v1";
        private const int MaximumResourceBytes = 32 * 1024;

        private static readonly UTF8Encoding StrictUtf8 =
            new UTF8Encoding(false, true);
        private static readonly Regex CanonicalPropertyPattern = new Regex(
            "\\\"(?<name>(?:\\\\[\\\"\\\\/bfnrt]|\\\\u[0-9A-Fa-f]{4}|[^\\\"\\\\\\x00-\\x1F])*)\\\"\\s*:",
            RegexOptions.CultureInvariant);
        private static readonly Regex CertificateSha256Pattern = new Regex(
            "^[0-9A-F]{64}$",
            RegexOptions.CultureInvariant);

        private static readonly string[] RequiredPropertyNames =
        {
            "schemaVersion",
            "keyId",
            "brandId",
            "applicationId",
            "alias",
            "certificateSha256"
        };

        private OfficialAndroidSigningTrust(
            string keyId,
            string brandId,
            string applicationId,
            string alias,
            string certificateSha256)
        {
            KeyId = keyId;
            BrandId = brandId;
            ApplicationId = applicationId;
            Alias = alias;
            CertificateSha256 = certificateSha256;
        }

        public string KeyId { get; private set; }
        public string BrandId { get; private set; }
        public string ApplicationId { get; private set; }
        public string Alias { get; private set; }
        public string CertificateSha256 { get; private set; }

        public static OfficialAndroidSigningTrust Load()
        {
            var assembly = Assembly.GetExecutingAssembly();
            var resourceMatches = assembly.GetManifestResourceNames()
                .Where(name => string.Equals(
                    name,
                    ResourceName,
                    StringComparison.Ordinal))
                .ToList();
            if (resourceMatches.Count != 1)
            {
                throw new InvalidDataException(
                    "程序缺少唯一的 Android 官方签名公开信任配置：" +
                    ResourceName);
            }

            string json;
            using (var stream = assembly.GetManifestResourceStream(ResourceName))
            {
                if (stream == null || !stream.CanRead ||
                    stream.Length <= 0 || stream.Length > MaximumResourceBytes)
                {
                    throw new InvalidDataException(
                        "Android 官方签名公开信任配置不存在、为空或过大");
                }
                var bytes = new byte[(int)stream.Length];
                var offset = 0;
                while (offset < bytes.Length)
                {
                    var read = stream.Read(bytes, offset, bytes.Length - offset);
                    if (read <= 0)
                    {
                        throw new EndOfStreamException(
                            "Android 官方签名公开信任配置读取不完整");
                    }
                    offset += read;
                }
                if (stream.ReadByte() != -1)
                {
                    throw new InvalidDataException(
                        "Android 官方签名公开信任配置长度发生变化");
                }
                try
                {
                    json = StrictUtf8.GetString(bytes);
                }
                catch (DecoderFallbackException error)
                {
                    throw new InvalidDataException(
                        "Android 官方签名公开信任配置不是有效 UTF-8",
                        error);
                }
            }

            EnsureCanonicalPropertyNames(json);
            Dictionary<string, object> values;
            try
            {
                var serializer = new JavaScriptSerializer
                {
                    MaxJsonLength = MaximumResourceBytes,
                    RecursionLimit = 4
                };
                values = serializer.DeserializeObject(json) as
                    Dictionary<string, object>;
            }
            catch (Exception error)
            {
                throw new InvalidDataException(
                    "Android 官方签名公开信任配置 JSON 无效：" +
                    error.Message,
                    error);
            }
            if (values == null || values.Count != RequiredPropertyNames.Length ||
                RequiredPropertyNames.Any(name => !values.ContainsKey(name)))
            {
                throw new InvalidDataException(
                    "Android 官方签名公开信任配置字段不完整或包含未知字段");
            }

            object rawSchemaVersion;
            if (!values.TryGetValue("schemaVersion", out rawSchemaVersion) ||
                !(rawSchemaVersion is int) ||
                (int)rawSchemaVersion != ExpectedSchemaVersion)
            {
                throw new InvalidDataException(
                    "Android 官方签名公开信任配置 schemaVersion 必须为 1");
            }

            var keyId = ReadRequiredCanonicalString(values, "keyId");
            var brandId = ReadRequiredCanonicalString(values, "brandId");
            var applicationId = ReadRequiredCanonicalString(
                values,
                "applicationId");
            var alias = ReadRequiredCanonicalString(values, "alias");
            var certificateSha256 = ReadRequiredCanonicalString(
                values,
                "certificateSha256");

            EnsureExpectedValue(keyId, ExpectedKeyId, "keyId");
            EnsureExpectedValue(brandId, ExpectedBrandId, "brandId");
            EnsureExpectedValue(
                applicationId,
                ExpectedApplicationId,
                "applicationId");
            EnsureExpectedValue(alias, ExpectedAlias, "alias");
            if (!CertificateSha256Pattern.IsMatch(certificateSha256))
            {
                throw new InvalidDataException(
                    "Android 官方签名公开信任配置 certificateSha256 " +
                    "必须是 64 位大写十六进制");
            }

            return new OfficialAndroidSigningTrust(
                keyId,
                brandId,
                applicationId,
                alias,
                certificateSha256);
        }

        private static void EnsureCanonicalPropertyNames(string json)
        {
            var matches = CanonicalPropertyPattern.Matches(json);
            if (matches.Count != RequiredPropertyNames.Length)
            {
                throw new InvalidDataException(
                    "Android 官方签名公开信任配置必须且只能包含规定字段");
            }
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (Match match in matches)
            {
                var name = match.Groups["name"].Value;
                if (name.IndexOf('\\') >= 0 ||
                    !RequiredPropertyNames.Contains(name, StringComparer.Ordinal) ||
                    !names.Add(name))
                {
                    throw new InvalidDataException(
                        "Android 官方签名公开信任配置包含未知、转义或重复字段");
                }
            }
        }

        private static string ReadRequiredCanonicalString(
            IDictionary<string, object> values,
            string name)
        {
            object raw;
            if (!values.TryGetValue(name, out raw) || !(raw is string))
            {
                throw new InvalidDataException(
                    "Android 官方签名公开信任配置字段类型无效：" + name);
            }
            var value = (string)raw;
            if (string.IsNullOrWhiteSpace(value) ||
                !string.Equals(value, value.Trim(), StringComparison.Ordinal) ||
                value.Length > 256 ||
                value.Any(character => char.IsControl(character)))
            {
                throw new InvalidDataException(
                    "Android 官方签名公开信任配置字段内容无效：" + name);
            }
            return value;
        }

        private static void EnsureExpectedValue(
            string actual,
            string expected,
            string fieldName)
        {
            if (!string.Equals(actual, expected, StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "Android 官方签名公开信任配置 " + fieldName +
                    " 与当前协议不匹配");
            }
        }
    }
}
