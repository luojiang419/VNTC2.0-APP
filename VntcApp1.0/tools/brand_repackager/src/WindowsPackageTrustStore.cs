using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace VntBrandRepackager
{
    internal sealed class WindowsPackageTrustStore
    {
        private const string StoreHeader = "VNT_WINDOWS_TRUST_V1";
        private const string StoreFileName = "trusted-output-hashes.dat";
        private static readonly byte[] StoreEntropy = Encoding.UTF8.GetBytes(
            "VNTBrandRepackager.WindowsTrustedOutputs.v1");
        private static readonly Regex Sha256Pattern = new Regex(
            @"^[0-9A-F]{64}$",
            RegexOptions.CultureInvariant);

        // 发布新的官方母版后，仅需在这里追加其最终 SHA-256 常量。
        private static readonly HashSet<string> OfficialMotherHashes =
            new HashSet<string>(StringComparer.Ordinal)
            {
                // VNT App v4.8.17 Windows 品牌母版
                "6D1741B0C5DD859F6389848021C105F673F5E8CB070FB12193BD1ECA047DA14A",
                // VNT App v4.8.18 Windows 品牌母版
                "E1457C5F7C05D10172554375F32E8686E574F6AE11B221ECCD1799668E4EFDC4",
                // VNT App v4.8.19 Windows 品牌母版
                "F736C1E0F262449D386FC37DAEE4428FAF85349AB841EF4C7CB7239FCB21481A",
                // VNT App v4.8.20 Windows 品牌母版
                "29B0D2C39E0EA205092362130D454D146D2599096D8DBBEF91B454C92E470E28"
            };

        private readonly string _rootDirectory;
        private readonly string _storePath;
        private readonly Action<string> _log;

        public WindowsPackageTrustStore(Action<string> log)
            : this(GetDefaultRootDirectory(), log)
        {
        }

        internal WindowsPackageTrustStore(
            string rootDirectory,
            Action<string> log)
        {
            if (string.IsNullOrWhiteSpace(rootDirectory))
            {
                throw new ArgumentException("Windows 安装包信任存储目录不能为空");
            }
            _rootDirectory = Path.GetFullPath(rootDirectory);
            _storePath = Path.Combine(_rootDirectory, StoreFileName);
            _log = log ?? delegate { };
        }

        public string RequireTrustedInput(string installerPath)
        {
            var hash = ComputeFileSha256(installerPath);
            if (OfficialMotherHashes.Contains(hash))
            {
                _log("已通过官方 Windows 母版 SHA-256 信任校验：" + hash);
                return hash;
            }

            using (var mutex = CreateStoreMutex())
            {
                ExecuteWithMutex(mutex, delegate
                {
                    if (!LoadTrustedOutputHashes().Contains(hash))
                    {
                        throw new InvalidDataException(
                            "该 Windows 安装包仅通过了内容格式识别，但来源不受信任。" +
                            "内容识别不等于来源可信；仅允许官方母版，或本工具此前" +
                            "成功生成并由当前 Windows 用户登记的原始安装包。" +
                            " SHA-256：" + hash);
                    }
                });
            }
            _log("已通过本机可信输出 SHA-256 校验：" + hash);
            return hash;
        }

        public void RegisterTrustedOutput(string sha256)
        {
            var normalized = NormalizeSha256(sha256);
            using (var mutex = CreateStoreMutex())
            {
                ExecuteWithMutex(mutex, delegate
                {
                    var hashes = LoadTrustedOutputHashes();
                    if (hashes.Add(normalized))
                    {
                        SaveTrustedOutputHashes(hashes);
                    }
                });
            }
            _log("已登记本机可信 Windows 输出哈希：" + normalized);
        }

        private HashSet<string> LoadTrustedOutputHashes()
        {
            var hashes = new HashSet<string>(StringComparer.Ordinal);
            if (!File.Exists(_storePath))
            {
                return hashes;
            }

            byte[] protectedBytes = null;
            byte[] clearBytes = null;
            try
            {
                protectedBytes = File.ReadAllBytes(_storePath);
                if (protectedBytes.Length == 0)
                {
                    throw new InvalidDataException("Windows 本机可信哈希存储为空");
                }
                clearBytes = ProtectedData.Unprotect(
                    protectedBytes,
                    StoreEntropy,
                    DataProtectionScope.CurrentUser);
                var lines = Encoding.UTF8.GetString(clearBytes)
                    .Replace("\r", string.Empty)
                    .Split('\n');
                if (lines.Length < 1 ||
                    !string.Equals(lines[0], StoreHeader, StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "Windows 本机可信哈希存储版本或头部无效");
                }
                for (var index = 1; index < lines.Length; index++)
                {
                    if (lines[index].Length == 0)
                    {
                        continue;
                    }
                    var hash = NormalizeSha256(lines[index]);
                    if (!hashes.Add(hash))
                    {
                        throw new InvalidDataException(
                            "Windows 本机可信哈希存储包含重复记录");
                    }
                }
                return hashes;
            }
            catch (CryptographicException error)
            {
                throw new CryptographicException(
                    "无法使用当前 Windows 用户解密本机可信输出哈希存储，" +
                    "已拒绝执行安装包",
                    error);
            }
            finally
            {
                if (protectedBytes != null)
                {
                    Array.Clear(protectedBytes, 0, protectedBytes.Length);
                }
                if (clearBytes != null)
                {
                    Array.Clear(clearBytes, 0, clearBytes.Length);
                }
            }
        }

        private void SaveTrustedOutputHashes(HashSet<string> hashes)
        {
            Directory.CreateDirectory(_rootDirectory);
            var clearText = StoreHeader + "\n" +
                string.Join("\n", hashes.OrderBy(value => value).ToArray()) +
                "\n";
            var clearBytes = Encoding.UTF8.GetBytes(clearText);
            byte[] protectedBytes = null;
            var pendingPath = _storePath + ".new-" + Guid.NewGuid().ToString("N");
            var backupPath = _storePath + ".backup-" + Guid.NewGuid().ToString("N");
            try
            {
                protectedBytes = ProtectedData.Protect(
                    clearBytes,
                    StoreEntropy,
                    DataProtectionScope.CurrentUser);
                File.WriteAllBytes(pendingPath, protectedBytes);
                if (File.Exists(_storePath))
                {
                    File.Replace(pendingPath, _storePath, backupPath, true);
                    TryDeleteFile(backupPath);
                }
                else
                {
                    File.Move(pendingPath, _storePath);
                }
            }
            finally
            {
                Array.Clear(clearBytes, 0, clearBytes.Length);
                if (protectedBytes != null)
                {
                    Array.Clear(protectedBytes, 0, protectedBytes.Length);
                }
                TryDeleteFile(pendingPath);
            }
        }

        private static void ExecuteWithMutex(Mutex mutex, Action action)
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
                    throw new TimeoutException("等待 Windows 安装包信任存储锁超时");
                }
                action();
            }
            finally
            {
                if (acquired)
                {
                    mutex.ReleaseMutex();
                }
            }
        }

        private static Mutex CreateStoreMutex()
        {
            return new Mutex(
                false,
                @"Local\VNTBrandRepackager.WindowsTrustedOutputs.v1");
        }

        private static string NormalizeSha256(string value)
        {
            var normalized = (value ?? string.Empty)
                .Replace(" ", string.Empty)
                .ToUpperInvariant();
            if (!Sha256Pattern.IsMatch(normalized))
            {
                throw new InvalidDataException("Windows 安装包 SHA-256 格式无效");
            }
            return normalized;
        }

        private static string ComputeFileSha256(string path)
        {
            var fullPath = Path.GetFullPath(path);
            using (var sha = SHA256.Create())
            using (var stream = new FileStream(
                fullPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read))
            {
                return BitConverter.ToString(sha.ComputeHash(stream))
                    .Replace("-", string.Empty);
            }
        }

        private static string GetDefaultRootDirectory()
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "VNTBrandRepackager",
                "windows-trust");
        }

        private static void TryDeleteFile(string path)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            }
            catch
            {
            }
        }
    }
}
