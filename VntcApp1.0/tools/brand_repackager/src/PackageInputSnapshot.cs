using System;
using System.IO;
using System.Security.Cryptography;

namespace VntBrandRepackager
{
    internal sealed class PackageInputSnapshot
    {
        public string Path { get; private set; }
        public long Length { get; private set; }
        public string Sha256 { get; private set; }
        public PackageDetectionResult Inspection { get; private set; }

        private PackageInputSnapshot(
            string path,
            long length,
            string sha256,
            PackageDetectionResult inspection)
        {
            Path = path;
            Length = length;
            Sha256 = sha256;
            Inspection = inspection;
        }

        public static PackageInputSnapshot Create(
            string sourcePath,
            string tempRoot,
            string snapshotExtension)
        {
            var sourceFullPath = System.IO.Path.GetFullPath(sourcePath);
            var tempFullPath = System.IO.Path.GetFullPath(tempRoot);
            var extension = string.Equals(
                snapshotExtension,
                ".apk",
                StringComparison.OrdinalIgnoreCase)
                ? ".apk"
                : ".exe";
            var snapshotPath = System.IO.Path.Combine(
                tempFullPath,
                "source_snapshot" + extension);

            long sourceLength;
            string sourceHash;
            using (var source = new FileStream(
                sourceFullPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read))
            using (var destination = new FileStream(
                snapshotPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None))
            using (var sha = SHA256.Create())
            {
                sourceLength = source.Length;
                var buffer = new byte[1024 * 1024];
                long copied = 0;
                int read;
                while ((read = source.Read(buffer, 0, buffer.Length)) > 0)
                {
                    destination.Write(buffer, 0, read);
                    sha.TransformBlock(buffer, 0, read, buffer, 0);
                    copied = checked(copied + read);
                }
                sha.TransformFinalBlock(new byte[0], 0, 0);
                destination.Flush(true);
                if (copied != sourceLength || source.Position != sourceLength ||
                    source.Length != sourceLength)
                {
                    throw new InvalidDataException(
                        "源安装包在创建只读快照时长度发生变化");
                }
                sourceHash = BitConverter.ToString(sha.Hash)
                    .Replace("-", string.Empty);
            }

            var snapshotLength = new FileInfo(snapshotPath).Length;
            var snapshotHash = ComputeFileSha256(snapshotPath);
            if (snapshotLength != sourceLength ||
                !string.Equals(
                    snapshotHash,
                    sourceHash,
                    StringComparison.Ordinal))
            {
                throw new InvalidDataException(
                    "源安装包只读快照的长度或 SHA-256 复核失败");
            }

            var inspection = PackageDetector.RequireSupported(snapshotPath);
            return new PackageInputSnapshot(
                snapshotPath,
                snapshotLength,
                snapshotHash,
                inspection);
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
    }
}
