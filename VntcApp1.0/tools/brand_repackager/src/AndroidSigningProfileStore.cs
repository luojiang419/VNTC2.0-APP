using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace VntBrandRepackager
{
    internal sealed class AndroidSigningProfile
    {
        public string ProfileId { get; private set; }
        public string BrandId { get; private set; }
        public string ApplicationId { get; private set; }
        public string Alias { get; private set; }
        public string CertificateSha256 { get; private set; }
        public string KeystorePath { get; private set; }
        public string CreatedAtUtc { get; private set; }

        // 仅供当前进程签名使用；该值不会写入 profile.json。
        [ScriptIgnore]
        public string Password { get; private set; }

        internal AndroidSigningProfile(
            string profileId,
            string brandId,
            string applicationId,
            string alias,
            string certificateSha256,
            string keystorePath,
            string createdAtUtc,
            string password)
        {
            ProfileId = profileId;
            BrandId = brandId;
            ApplicationId = applicationId;
            Alias = alias;
            CertificateSha256 = certificateSha256;
            KeystorePath = keystorePath;
            CreatedAtUtc = createdAtUtc;
            Password = password;
        }
    }

    internal sealed class AndroidSigningProfileConflictException :
        InvalidOperationException
    {
        public AndroidSigningProfileConflictException(string message)
            : base(message)
        {
        }
    }

    internal sealed class AndroidSigningProfileStore
    {
        private const int ProfileSchemaVersion = 1;
        private const string ProfileFileName = "profile.json";
        private const string KeystoreFileName = "signing.p12";
        private const string StorePasswordEnvironmentName =
            "VNT_ANDROID_STORE_PASSWORD";
        private const string KeyPasswordEnvironmentName =
            "VNT_ANDROID_KEY_PASSWORD";
        private static readonly UTF8Encoding Utf8WithoutBom =
            new UTF8Encoding(false);
        private static readonly byte[] PasswordEntropy = Encoding.UTF8.GetBytes(
            "VNTBrandRepackager.AndroidSigningProfile.v1");
        private static readonly Regex BrandIdPattern = new Regex(
            @"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
            RegexOptions.CultureInvariant);
        private static readonly Regex ApplicationIdPattern = new Regex(
            @"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$",
            RegexOptions.CultureInvariant);
        private static readonly Regex CertificateSha256Pattern = new Regex(
            @"SHA256:\s*([0-9A-Fa-f:]{64,95})",
            RegexOptions.CultureInvariant);

        private readonly string _rootDirectory;
        private readonly Action<string> _log;

        public AndroidSigningProfileStore(Action<string> log)
            : this(GetDefaultRootDirectory(), log)
        {
        }

        internal AndroidSigningProfileStore(
            string rootDirectory,
            Action<string> log)
        {
            if (string.IsNullOrWhiteSpace(rootDirectory))
            {
                throw new ArgumentException("Android 签名档案根目录不能为空");
            }
            _rootDirectory = Path.GetFullPath(rootDirectory);
            _log = log ?? delegate { };
        }

        public AndroidSigningProfile GetOrCreate(
            string keytoolPath,
            string brandId,
            string applicationId)
        {
            ValidateIdentity(brandId, applicationId);
            keytoolPath = ValidateKeytoolPath(keytoolPath);

            var profileId = CreateProfileId(brandId, applicationId);
            var profileDirectory = GetProfileDirectory(profileId);
            if (Directory.Exists(profileDirectory))
            {
                var existing = LoadRequired(brandId, applicationId);
                ValidateCertificate(keytoolPath, existing);
                _log("已复用 Android 品牌签名档案：" + existing.ProfileId);
                return existing;
            }

            Directory.CreateDirectory(_rootDirectory);
            EnsureNoIdentityConflict(brandId, applicationId, profileId);

            var stagingDirectory = GetProfileDirectory(
                ".create_" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(stagingDirectory);
            try
            {
                var profile = CreateProfile(
                    keytoolPath,
                    stagingDirectory,
                    profileId,
                    brandId,
                    applicationId);
                try
                {
                    Directory.Move(stagingDirectory, profileDirectory);
                }
                catch (IOException)
                {
                    // 另一个进程可能刚完成同一档案；仅在目标确实出现时复用。
                    if (!Directory.Exists(profileDirectory))
                    {
                        throw;
                    }
                    TryDeleteDirectory(stagingDirectory);
                    var concurrent = LoadRequired(brandId, applicationId);
                    ValidateCertificate(keytoolPath, concurrent);
                    _log("已复用并发创建的 Android 品牌签名档案：" +
                        concurrent.ProfileId);
                    return concurrent;
                }

                _log("已创建 Android 品牌签名档案：" + profile.ProfileId);
                return new AndroidSigningProfile(
                    profile.ProfileId,
                    profile.BrandId,
                    profile.ApplicationId,
                    profile.Alias,
                    profile.CertificateSha256,
                    Path.Combine(profileDirectory, KeystoreFileName),
                    profile.CreatedAtUtc,
                    profile.Password);
            }
            catch
            {
                TryDeleteDirectory(stagingDirectory);
                throw;
            }
        }

        public AndroidSigningProfile GetOrCreateByBrandId(
            string keytoolPath,
            string brandId,
            string newApplicationId)
        {
            ValidateIdentity(brandId, newApplicationId);
            keytoolPath = ValidateKeytoolPath(keytoolPath);

            using (var mutex = CreateStoreMutex())
            {
                var acquired = false;
                try
                {
                    try
                    {
                        acquired = mutex.WaitOne(TimeSpan.FromMinutes(1));
                    }
                    catch (AbandonedMutexException)
                    {
                        acquired = true;
                    }
                    if (!acquired)
                    {
                        throw new TimeoutException(
                            "等待 Android 品牌签名档案锁超时");
                    }

                    AndroidSigningProfile existing;
                    if (TryLoadByBrandId(brandId, out existing))
                    {
                        ValidateCertificate(keytoolPath, existing);
                        _log("已按 brandId 复用 Android 品牌签名档案：" +
                            existing.ProfileId);
                        return existing;
                    }
                    return GetOrCreate(
                        keytoolPath,
                        brandId,
                        newApplicationId);
                }
                finally
                {
                    if (acquired)
                    {
                        mutex.ReleaseMutex();
                    }
                }
            }
        }

        public bool TryLoad(
            string brandId,
            string applicationId,
            out AndroidSigningProfile profile)
        {
            ValidateIdentity(brandId, applicationId);
            var profileId = CreateProfileId(brandId, applicationId);
            var profileDirectory = GetProfileDirectory(profileId);
            if (!Directory.Exists(profileDirectory))
            {
                if (Directory.Exists(_rootDirectory))
                {
                    EnsureNoIdentityConflict(brandId, applicationId, profileId);
                }
                profile = null;
                return false;
            }

            profile = ReadProfile(profileDirectory, brandId, applicationId);
            return true;
        }

        public AndroidSigningProfile LoadRequired(
            string brandId,
            string applicationId)
        {
            ValidateIdentity(brandId, applicationId);
            var profile = LoadProfilesStrict().SingleOrDefault(candidate =>
                string.Equals(
                    candidate.BrandId,
                    brandId,
                    StringComparison.Ordinal) &&
                string.Equals(
                    candidate.ApplicationId,
                    applicationId,
                    StringComparison.Ordinal));
            if (profile == null)
            {
                throw new FileNotFoundException(
                    "未找到源 APK 对应的本机 Android 签名档案。" +
                    "内容识别不等于来源可信；为防止导入伪造或无法覆盖升级的 APK，" +
                    "已拒绝重新签名。",
                    GetProfileDirectory(CreateProfileId(brandId, applicationId)));
            }
            return profile;
        }

        public bool TryLoadByBrandId(
            string brandId,
            out AndroidSigningProfile profile)
        {
            ValidateBrandId(brandId);
            var matches = LoadProfilesStrict()
                .Where(candidate => string.Equals(
                    candidate.BrandId,
                    brandId,
                    StringComparison.Ordinal))
                .ToList();
            if (matches.Count > 1)
            {
                throw new AndroidSigningProfileConflictException(
                    "检测到重复的 Android brandId 签名档案，已拒绝继续");
            }
            profile = matches.Count == 1 ? matches[0] : null;
            return profile != null;
        }

        public AndroidSigningProfile LoadRequiredByBrandId(string brandId)
        {
            AndroidSigningProfile profile;
            if (!TryLoadByBrandId(brandId, out profile))
            {
                throw new FileNotFoundException(
                    "未找到该 brandId 唯一对应的本机 Android 签名档案。" +
                    "为保护覆盖升级和签名身份，已拒绝继续。",
                    _rootDirectory);
            }
            return profile;
        }

        private AndroidSigningProfile CreateProfile(
            string keytoolPath,
            string stagingDirectory,
            string profileId,
            string brandId,
            string applicationId)
        {
            var password = CreateStrongPassword();
            var alias = "vnt_" + profileId.Substring(profileId.Length - 16);
            var keystorePath = Path.Combine(stagingDirectory, KeystoreFileName);
            var distinguishedName = "CN=VNT Android Brand " +
                profileId.Substring(profileId.Length - 12) +
                ", OU=VNT Brand Repackager, O=Local Brand Signing, C=CN";

            var arguments = new StringBuilder();
            arguments.Append("-J-Duser.language=en -J-Duser.country=US ");
            arguments.Append("-genkeypair -noprompt -keyalg RSA -keysize 3072 ");
            arguments.Append("-sigalg SHA256withRSA -validity 9125 ");
            arguments.Append("-storetype PKCS12 -alias ").Append(Quote(alias));
            arguments.Append(" -dname ").Append(Quote(distinguishedName));
            arguments.Append(" -keystore ").Append(Quote(keystorePath));
            arguments.Append(" -storepass:env ")
                .Append(StorePasswordEnvironmentName);
            arguments.Append(" -keypass:env ")
                .Append(KeyPasswordEnvironmentName);

            _log("正在生成 Android 品牌专用 PKCS12 签名证书");
            RunKeytool(
                keytoolPath,
                arguments.ToString(),
                stagingDirectory,
                password,
                TimeSpan.FromMinutes(2));
            if (!File.Exists(keystorePath) || new FileInfo(keystorePath).Length == 0)
            {
                throw new InvalidDataException("keytool 未生成有效的 PKCS12 密钥库");
            }

            var certificateSha256 = ReadCertificateSha256(
                keytoolPath,
                keystorePath,
                alias,
                password,
                stagingDirectory);
            var createdAtUtc = DateTime.UtcNow.ToString(
                "o",
                CultureInfo.InvariantCulture);
            var protectedPassword = ProtectPassword(password);
            var json = new Dictionary<string, object>
            {
                { "schemaVersion", ProfileSchemaVersion },
                { "profileId", profileId },
                { "brandId", brandId },
                { "applicationId", applicationId },
                { "alias", alias },
                { "certSHA256", certificateSha256 },
                { "passwordProtectedBase64", protectedPassword },
                { "createdAtUtc", createdAtUtc }
            };
            WriteJsonCreateNew(
                Path.Combine(stagingDirectory, ProfileFileName),
                json);

            return new AndroidSigningProfile(
                profileId,
                brandId,
                applicationId,
                alias,
                certificateSha256,
                keystorePath,
                createdAtUtc,
                password);
        }

        private AndroidSigningProfile ReadProfile(
            string profileDirectory,
            string expectedBrandId,
            string expectedApplicationId)
        {
            EnsureChildPath(profileDirectory);
            var profilePath = Path.Combine(profileDirectory, ProfileFileName);
            var keystorePath = Path.Combine(profileDirectory, KeystoreFileName);
            if (!File.Exists(profilePath))
            {
                throw new InvalidDataException(
                    "Android 签名档案不完整：缺少 " + ProfileFileName);
            }
            if (!File.Exists(keystorePath) || new FileInfo(keystorePath).Length == 0)
            {
                throw new InvalidDataException(
                    "Android 签名档案不完整：缺少有效的 " + KeystoreFileName);
            }

            Dictionary<string, object> values;
            try
            {
                values = new JavaScriptSerializer()
                    .Deserialize<Dictionary<string, object>>(
                        File.ReadAllText(profilePath, Encoding.UTF8));
            }
            catch (Exception error)
            {
                throw new InvalidDataException("Android 签名档案 JSON 无效", error);
            }
            if (values == null || ReadInteger(values, "schemaVersion") !=
                ProfileSchemaVersion)
            {
                throw new InvalidDataException("Android 签名档案版本不受支持");
            }

            var profileId = ReadRequiredString(values, "profileId");
            var brandId = ReadRequiredString(values, "brandId");
            var applicationId = ReadRequiredString(values, "applicationId");
            var alias = ReadRequiredString(values, "alias");
            var certSha256 = NormalizeCertificateSha256(
                ReadRequiredString(values, "certSHA256"));
            var protectedPassword = ReadRequiredString(
                values,
                "passwordProtectedBase64");
            var createdAtUtc = ReadRequiredString(values, "createdAtUtc");

            var expectedProfileId = CreateProfileId(
                expectedBrandId,
                expectedApplicationId);
            if (!string.Equals(profileId, expectedProfileId, StringComparison.Ordinal) ||
                !string.Equals(brandId, expectedBrandId, StringComparison.Ordinal) ||
                !string.Equals(
                    applicationId,
                    expectedApplicationId,
                    StringComparison.Ordinal))
            {
                throw new AndroidSigningProfileConflictException(
                    "Android 签名档案身份与请求的品牌/applicationId 不一致");
            }
            if (!string.Equals(
                Path.GetFileName(profileDirectory),
                profileId,
                StringComparison.Ordinal))
            {
                throw new AndroidSigningProfileConflictException(
                    "Android 签名档案目录与 profileId 不一致");
            }
            DateTime created;
            if (!DateTime.TryParse(
                createdAtUtc,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal,
                out created))
            {
                throw new InvalidDataException("Android 签名档案创建时间无效");
            }

            string password;
            try
            {
                password = UnprotectPassword(protectedPassword);
            }
            catch (Exception error)
            {
                throw new CryptographicException(
                    "无法使用当前 Windows 用户解密 Android 签名档案密码",
                    error);
            }
            if (string.IsNullOrEmpty(password))
            {
                throw new CryptographicException("Android 签名档案密码为空");
            }

            return new AndroidSigningProfile(
                profileId,
                brandId,
                applicationId,
                alias,
                certSha256,
                keystorePath,
                createdAtUtc,
                password);
        }

        private List<AndroidSigningProfile> LoadProfilesStrict()
        {
            var profiles = new List<AndroidSigningProfile>();
            if (!Directory.Exists(_rootDirectory))
            {
                return profiles;
            }

            var seenBrandIds = new HashSet<string>(StringComparer.Ordinal);
            var seenApplicationIds = new HashSet<string>(StringComparer.Ordinal);
            var directories = Directory.GetDirectories(
                _rootDirectory,
                "android_*",
                SearchOption.TopDirectoryOnly);
            Array.Sort(directories, StringComparer.OrdinalIgnoreCase);
            foreach (var directory in directories)
            {
                string brandId;
                string applicationId;
                ReadProfileIdentity(directory, out brandId, out applicationId);
                var profile = ReadProfile(directory, brandId, applicationId);
                if (!seenBrandIds.Add(profile.BrandId))
                {
                    throw new AndroidSigningProfileConflictException(
                        "检测到重复的 Android brandId 签名档案：" +
                        profile.BrandId);
                }
                if (!seenApplicationIds.Add(profile.ApplicationId))
                {
                    throw new AndroidSigningProfileConflictException(
                        "检测到重复的 Android applicationId 签名档案：" +
                        profile.ApplicationId);
                }
                profiles.Add(profile);
            }
            return profiles;
        }

        private void ReadProfileIdentity(
            string profileDirectory,
            out string brandId,
            out string applicationId)
        {
            EnsureChildPath(profileDirectory);
            var profilePath = Path.Combine(profileDirectory, ProfileFileName);
            if (!File.Exists(profilePath))
            {
                throw new InvalidDataException(
                    "检测到不完整的 Android 签名档案目录：" +
                    profileDirectory);
            }

            Dictionary<string, object> values;
            try
            {
                values = new JavaScriptSerializer()
                    .Deserialize<Dictionary<string, object>>(
                        File.ReadAllText(profilePath, Encoding.UTF8));
            }
            catch (Exception error)
            {
                throw new InvalidDataException(
                    "检测到无法读取的 Android 签名档案：" + profilePath,
                    error);
            }
            if (values == null || ReadInteger(values, "schemaVersion") !=
                ProfileSchemaVersion)
            {
                throw new InvalidDataException(
                    "检测到版本无效的 Android 签名档案：" + profilePath);
            }
            brandId = ReadRequiredString(values, "brandId");
            applicationId = ReadRequiredString(values, "applicationId");
            ValidateIdentity(brandId, applicationId);
        }

        private void EnsureNoIdentityConflict(
            string brandId,
            string applicationId,
            string expectedProfileId)
        {
            foreach (var profile in LoadProfilesStrict())
            {
                if (string.Equals(
                    profile.BrandId,
                    brandId,
                    StringComparison.Ordinal) &&
                    string.Equals(
                        profile.ApplicationId,
                        applicationId,
                        StringComparison.Ordinal))
                {
                    if (!string.Equals(
                        profile.ProfileId,
                        expectedProfileId,
                        StringComparison.Ordinal))
                    {
                        throw new AndroidSigningProfileConflictException(
                            "相同品牌/applicationId 的签名档案位于冲突目录");
                    }
                }
                else if (string.Equals(
                    profile.BrandId,
                    brandId,
                    StringComparison.Ordinal))
                {
                    throw new AndroidSigningProfileConflictException(
                        "该 brandId 已绑定其他 applicationId；为保护覆盖升级，" +
                        "拒绝生成第二套签名档案");
                }
                else if (string.Equals(
                    profile.ApplicationId,
                    applicationId,
                    StringComparison.Ordinal))
                {
                    throw new AndroidSigningProfileConflictException(
                        "该 applicationId 已绑定其他 brandId；为保护覆盖升级，" +
                        "拒绝生成第二套签名档案");
                }
            }
        }

        public void ValidateCertificate(
            string keytoolPath,
            AndroidSigningProfile profile)
        {
            keytoolPath = ValidateKeytoolPath(keytoolPath);
            if (profile == null)
            {
                throw new ArgumentNullException("profile");
            }
            var actual = ReadCertificateSha256(
                keytoolPath,
                profile.KeystorePath,
                profile.Alias,
                profile.Password,
                Path.GetDirectoryName(profile.KeystorePath));
            if (!string.Equals(
                actual,
                profile.CertificateSha256,
                StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException(
                    "Android 签名证书指纹与 profile.json 不一致");
            }
        }

        private static string ReadCertificateSha256(
            string keytoolPath,
            string keystorePath,
            string alias,
            string password,
            string workingDirectory)
        {
            var arguments = "-J-Duser.language=en -J-Duser.country=US " +
                "-list -v -storetype PKCS12 -alias " + Quote(alias) +
                " -keystore " + Quote(keystorePath) +
                " -storepass:env " + StorePasswordEnvironmentName;
            var result = RunKeytool(
                keytoolPath,
                arguments,
                workingDirectory,
                password,
                TimeSpan.FromMinutes(1));
            var match = CertificateSha256Pattern.Match(
                result.StandardOutput + Environment.NewLine + result.StandardError);
            if (!match.Success)
            {
                throw new InvalidDataException(
                    "无法从 keytool 输出读取 Android 证书 SHA-256 指纹");
            }
            return NormalizeCertificateSha256(match.Groups[1].Value);
        }

        private static ProcessResult RunKeytool(
            string keytoolPath,
            string arguments,
            string workingDirectory,
            string password,
            TimeSpan timeout)
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = keytoolPath,
                Arguments = arguments,
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            startInfo.EnvironmentVariables[StorePasswordEnvironmentName] = password;
            startInfo.EnvironmentVariables[KeyPasswordEnvironmentName] = password;

            using (var process = new Process { StartInfo = startInfo })
            {
                var stdout = new StringBuilder();
                var stderr = new StringBuilder();
                var outputLock = new object();
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null)
                    {
                        lock (outputLock) { stdout.AppendLine(e.Data); }
                    }
                };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e)
                {
                    if (e.Data != null)
                    {
                        lock (outputLock) { stderr.AppendLine(e.Data); }
                    }
                };
                if (!process.Start())
                {
                    throw new InvalidOperationException("无法启动 keytool");
                }
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit((int)timeout.TotalMilliseconds))
                {
                    try { process.Kill(); } catch { }
                    try { process.WaitForExit(5000); } catch { }
                    throw new TimeoutException("keytool 执行超时");
                }
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    throw new InvalidOperationException(
                        "keytool 执行失败，退出码 " + process.ExitCode +
                        Environment.NewLine + stdout.ToString() +
                        Environment.NewLine + stderr.ToString());
                }
                return new ProcessResult
                {
                    StandardOutput = stdout.ToString(),
                    StandardError = stderr.ToString()
                };
            }
        }

        private static string ProtectPassword(string password)
        {
            var clearBytes = Encoding.UTF8.GetBytes(password);
            try
            {
                return Convert.ToBase64String(ProtectedData.Protect(
                    clearBytes,
                    PasswordEntropy,
                    DataProtectionScope.CurrentUser));
            }
            finally
            {
                Array.Clear(clearBytes, 0, clearBytes.Length);
            }
        }

        private static string UnprotectPassword(string protectedBase64)
        {
            var protectedBytes = Convert.FromBase64String(protectedBase64);
            byte[] clearBytes = null;
            try
            {
                clearBytes = ProtectedData.Unprotect(
                    protectedBytes,
                    PasswordEntropy,
                    DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(clearBytes);
            }
            finally
            {
                Array.Clear(protectedBytes, 0, protectedBytes.Length);
                if (clearBytes != null)
                {
                    Array.Clear(clearBytes, 0, clearBytes.Length);
                }
            }
        }

        private static string CreateStrongPassword()
        {
            var random = new byte[48];
            using (var generator = RandomNumberGenerator.Create())
            {
                generator.GetBytes(random);
            }
            try
            {
                return BitConverter.ToString(random).Replace("-", string.Empty);
            }
            finally
            {
                Array.Clear(random, 0, random.Length);
            }
        }

        private static string CreateProfileId(
            string brandId,
            string applicationId)
        {
            var identity = brandId.Length.ToString(CultureInfo.InvariantCulture) +
                ":" + brandId + applicationId.Length.ToString(
                    CultureInfo.InvariantCulture) + ":" + applicationId;
            using (var sha = SHA256.Create())
            {
                var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(identity));
                return "android_" + BitConverter.ToString(hash)
                    .Replace("-", string.Empty)
                    .ToLowerInvariant()
                    .Substring(0, 32);
            }
        }

        private static string NormalizeCertificateSha256(string value)
        {
            var normalized = (value ?? string.Empty)
                .Replace(":", string.Empty)
                .Replace(" ", string.Empty)
                .ToUpperInvariant();
            if (!Regex.IsMatch(
                normalized,
                @"^[0-9A-F]{64}$",
                RegexOptions.CultureInvariant))
            {
                throw new InvalidDataException("Android 证书 SHA-256 指纹无效");
            }
            return normalized;
        }

        private static void ValidateIdentity(
            string brandId,
            string applicationId)
        {
            ValidateBrandId(brandId);
            if (string.IsNullOrWhiteSpace(applicationId) ||
                applicationId.Length > 255 ||
                !ApplicationIdPattern.IsMatch(applicationId) ||
                applicationId.Contains(".."))
            {
                throw new ArgumentException("Android applicationId 格式无效");
            }
        }

        private static void ValidateBrandId(string brandId)
        {
            if (string.IsNullOrWhiteSpace(brandId) ||
                !BrandIdPattern.IsMatch(brandId) ||
                brandId.Contains("..") ||
                brandId.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            {
                throw new ArgumentException("brandId 格式无效");
            }
        }

        private Mutex CreateStoreMutex()
        {
            string mutexId;
            using (var sha = SHA256.Create())
            {
                mutexId = BitConverter.ToString(sha.ComputeHash(
                        Encoding.UTF8.GetBytes(_rootDirectory.ToUpperInvariant())))
                    .Replace("-", string.Empty)
                    .Substring(0, 32);
            }
            return new Mutex(
                false,
                @"Local\VNTBrandRepackager.AndroidSigningProfiles." + mutexId);
        }

        private static string ValidateKeytoolPath(string keytoolPath)
        {
            if (string.IsNullOrWhiteSpace(keytoolPath))
            {
                throw new ArgumentException("keytool 路径不能为空");
            }
            var fullPath = Path.GetFullPath(keytoolPath);
            if (!File.Exists(fullPath))
            {
                throw new FileNotFoundException("找不到内置 keytool", fullPath);
            }
            return fullPath;
        }

        private string GetProfileDirectory(string profileId)
        {
            var path = Path.GetFullPath(Path.Combine(_rootDirectory, profileId));
            EnsureChildPath(path);
            return path;
        }

        private void EnsureChildPath(string path)
        {
            var root = _rootDirectory.TrimEnd(
                Path.DirectorySeparatorChar,
                Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            var fullPath = Path.GetFullPath(path);
            if (!fullPath.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("Android 签名档案路径越界");
            }
        }

        private static string GetDefaultRootDirectory()
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "VNTBrandRepackager",
                "android-signing");
        }

        private static void WriteJsonCreateNew(
            string path,
            Dictionary<string, object> value)
        {
            var bytes = Utf8WithoutBom.GetBytes(
                new JavaScriptSerializer().Serialize(value));
            using (var stream = new FileStream(
                path,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.WriteThrough))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush();
            }
        }

        private static int ReadInteger(
            IDictionary<string, object> values,
            string key)
        {
            object value;
            if (!values.TryGetValue(key, out value))
            {
                throw new InvalidDataException("Android 签名档案缺少字段：" + key);
            }
            try
            {
                return Convert.ToInt32(value, CultureInfo.InvariantCulture);
            }
            catch (Exception error)
            {
                throw new InvalidDataException(
                    "Android 签名档案字段不是整数：" + key,
                    error);
            }
        }

        private static string ReadRequiredString(
            IDictionary<string, object> values,
            string key)
        {
            object value;
            if (!values.TryGetValue(key, out value) || value == null)
            {
                throw new InvalidDataException("Android 签名档案缺少字段：" + key);
            }
            var text = Convert.ToString(value, CultureInfo.InvariantCulture);
            if (string.IsNullOrWhiteSpace(text))
            {
                throw new InvalidDataException("Android 签名档案字段为空：" + key);
            }
            return text;
        }

        private static string Quote(string value)
        {
            return "\"" + (value ?? string.Empty).Replace("\"", "\\\"") + "\"";
        }

        private static void TryDeleteDirectory(string path)
        {
            try
            {
                if (Directory.Exists(path))
                {
                    Directory.Delete(path, true);
                }
            }
            catch
            {
                // 清理失败不覆盖原始签名档案异常。
            }
        }

        private sealed class ProcessResult
        {
            public string StandardOutput { get; set; }
            public string StandardError { get; set; }
        }
    }
}
