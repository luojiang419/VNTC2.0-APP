using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace VntBrandRepackager
{
    internal static class PackageOutputPublisher
    {
        private static readonly UTF8Encoding Utf8WithoutBom =
            new UTF8Encoding(false);
        private static readonly Regex Sha256Pattern = new Regex(
            @"^[0-9A-F]{64}$",
            RegexOptions.CultureInvariant);

        public static string Publish(
            string stagedPackagePath,
            string destinationPath,
            string expectedSha256)
        {
            var stagedPath = Path.GetFullPath(stagedPackagePath);
            var outputPath = Path.GetFullPath(destinationPath);
            var shaPath = outputPath + ".sha256";
            var expectedHash = NormalizeSha256(expectedSha256);
            if (!File.Exists(stagedPath))
            {
                throw new FileNotFoundException("待发布安装包不存在", stagedPath);
            }
            if (!string.Equals(
                ComputeFileSha256(stagedPath),
                expectedHash,
                StringComparison.Ordinal))
            {
                throw new InvalidDataException("待发布安装包 SHA-256 与预期不一致");
            }

            Directory.CreateDirectory(Path.GetDirectoryName(outputPath));
            using (var mutex = CreateOutputMutex(outputPath))
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
                        throw new TimeoutException("等待安装包输出路径发布锁超时");
                    }
                    PublishLocked(stagedPath, outputPath, shaPath, expectedHash);
                }
                finally
                {
                    if (acquired)
                    {
                        mutex.ReleaseMutex();
                    }
                }
            }
            return shaPath;
        }

        private static void PublishLocked(
            string stagedPath,
            string outputPath,
            string shaPath,
            string expectedHash)
        {
            var token = Guid.NewGuid().ToString("N");
            var pendingOutput = outputPath + ".new-" + token;
            var pendingSha = shaPath + ".new-" + token;
            var backupOutput = outputPath + ".backup-" + token;
            var backupSha = shaPath + ".backup-" + token;
            var outputBackedUp = false;
            var shaBackedUp = false;
            var outputPublished = false;
            var shaPublished = false;
            var succeeded = false;

            try
            {
                File.Copy(stagedPath, pendingOutput, false);
                File.WriteAllText(
                    pendingSha,
                    expectedHash + " *" + Path.GetFileName(outputPath) +
                        Environment.NewLine,
                    Utf8WithoutBom);
                if (!string.Equals(
                    ComputeFileSha256(pendingOutput),
                    expectedHash,
                    StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "安装包发布副本 SHA-256 复核失败");
                }

                if (File.Exists(outputPath))
                {
                    File.Move(outputPath, backupOutput);
                    outputBackedUp = true;
                }
                if (File.Exists(shaPath))
                {
                    File.Move(shaPath, backupSha);
                    shaBackedUp = true;
                }

                File.Move(pendingOutput, outputPath);
                outputPublished = true;
                File.Move(pendingSha, shaPath);
                shaPublished = true;

                var finalHash = ComputeFileSha256(outputPath);
                var expectedShaText = expectedHash + " *" +
                    Path.GetFileName(outputPath) + Environment.NewLine;
                var actualShaText = File.ReadAllText(shaPath, Encoding.UTF8);
                if (!string.Equals(
                        finalHash,
                        expectedHash,
                        StringComparison.Ordinal) ||
                    !string.Equals(
                        actualShaText,
                        expectedShaText,
                        StringComparison.Ordinal))
                {
                    throw new InvalidDataException(
                        "安装包与 SHA-256 旁车发布后复核不一致");
                }
                succeeded = true;
            }
            catch (Exception publishError)
            {
                var rollbackErrors = new List<Exception>();
                RestorePreviousFile(
                    outputPath,
                    backupOutput,
                    outputBackedUp,
                    outputPublished,
                    rollbackErrors);
                RestorePreviousFile(
                    shaPath,
                    backupSha,
                    shaBackedUp,
                    shaPublished,
                    rollbackErrors);
                if (rollbackErrors.Count > 0)
                {
                    rollbackErrors.Insert(0, publishError);
                    throw new InvalidOperationException(
                        "安装包双文件发布失败，且旧文件回滚不完整；" +
                        "请检查 .backup-* 文件",
                        new AggregateException(rollbackErrors));
                }
                throw new InvalidOperationException(
                    "安装包双文件发布失败，已恢复发布前文件",
                    publishError);
            }
            finally
            {
                TryDeleteFile(pendingOutput);
                TryDeleteFile(pendingSha);
                if (succeeded)
                {
                    TryDeleteFile(backupOutput);
                    TryDeleteFile(backupSha);
                }
            }
        }

        private static void RestorePreviousFile(
            string destinationPath,
            string backupPath,
            bool wasBackedUp,
            bool wasPublished,
            List<Exception> errors)
        {
            try
            {
                if (wasBackedUp)
                {
                    if (File.Exists(destinationPath))
                    {
                        File.Delete(destinationPath);
                    }
                    File.Move(backupPath, destinationPath);
                }
                else if (wasPublished && File.Exists(destinationPath))
                {
                    File.Delete(destinationPath);
                }
            }
            catch (Exception error)
            {
                errors.Add(error);
            }
        }

        private static Mutex CreateOutputMutex(string normalizedOutputPath)
        {
            string pathId;
            using (var sha = SHA256.Create())
            {
                pathId = BitConverter.ToString(sha.ComputeHash(
                        Encoding.UTF8.GetBytes(
                            normalizedOutputPath.ToUpperInvariant())))
                    .Replace("-", string.Empty)
                    .Substring(0, 32);
            }
            return new Mutex(
                false,
                @"Local\VNTBrandRepackager.PackageOutput." + pathId);
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

        private static string NormalizeSha256(string value)
        {
            var normalized = (value ?? string.Empty).Trim().ToUpperInvariant();
            if (!Sha256Pattern.IsMatch(normalized))
            {
                throw new InvalidDataException("安装包 SHA-256 格式无效");
            }
            return normalized;
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
