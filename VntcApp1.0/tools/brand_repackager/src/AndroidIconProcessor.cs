using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;

namespace VntBrandRepackager
{
    internal sealed class AndroidIconProcessingResult
    {
        public int SourceWidth { get; set; }
        public int SourceHeight { get; set; }
        public long SourceBytes { get; set; }
        public long OutputBytes { get; set; }
        public bool WasCompressed { get; set; }
        public int ReplacedResourceCount { get; set; }
        public int ReplacedFlutterAssetCount { get; set; }
    }

    internal static class AndroidIconProcessor
    {
        private const long MaximumSourceBytes = 64L * 1024L * 1024L;
        private const long MaximumSourcePixels = 40000000L;
        private const int MaximumSourceDimension = 16384;

        private static readonly KeyValuePair<string, int>[] DensitySizes =
        {
            new KeyValuePair<string, int>("ldpi", 36),
            new KeyValuePair<string, int>("mdpi", 48),
            new KeyValuePair<string, int>("hdpi", 72),
            new KeyValuePair<string, int>("xhdpi", 96),
            new KeyValuePair<string, int>("xxhdpi", 144),
            new KeyValuePair<string, int>("xxxhdpi", 192)
        };

        private static readonly string[] RasterExtensions =
        {
            ".png", ".webp", ".jpg", ".jpeg", ".bmp"
        };

        public static AndroidIconProcessingResult ReplaceLauncherIcons(
            string decodedDirectory,
            string sourcePath)
        {
            decodedDirectory = Path.GetFullPath(decodedDirectory ?? string.Empty);
            sourcePath = Path.GetFullPath(sourcePath ?? string.Empty);
            if (!Directory.Exists(decodedDirectory))
            {
                throw new DirectoryNotFoundException(
                    "APK 解码目录不存在：" + decodedDirectory);
            }

            var sourceInfo = new FileInfo(sourcePath);
            if (!sourceInfo.Exists)
            {
                throw new FileNotFoundException("自定义图标文件不存在", sourcePath);
            }
            if (sourceInfo.Length <= 0 || sourceInfo.Length > MaximumSourceBytes)
            {
                throw new ArgumentException("图标源文件必须大于 0 且不能超过 64 MB");
            }

            using (var source = LoadSourceBitmap(sourcePath))
            {
                ValidateDimensions(source.Width, source.Height);
                var outputBytes = 0L;
                var resourceCount = 0;
                var assetCount = 0;
                var resDirectory = Path.Combine(decodedDirectory, "res");
                if (!Directory.Exists(resDirectory))
                {
                    throw new InvalidDataException("APK 解码结果缺少 res 资源目录");
                }

                foreach (var density in DensitySizes)
                {
                    var directories = Directory.GetDirectories(
                            resDirectory,
                            "mipmap-*",
                            SearchOption.TopDirectoryOnly)
                        .Where(path => DirectoryMatchesDensity(path, density.Key))
                        .ToList();
                    if (directories.Count == 0)
                    {
                        var canonical = Path.Combine(
                            resDirectory,
                            "mipmap-" + density.Key + "-v4");
                        Directory.CreateDirectory(canonical);
                        directories.Add(canonical);
                    }

                    foreach (var directory in directories)
                    {
                        var rasterFiles = Directory.GetFiles(
                                directory,
                                "ic_launcher.*",
                                SearchOption.TopDirectoryOnly)
                            .Where(IsRasterPath)
                            .ToArray();
                        foreach (var rasterFile in rasterFiles)
                        {
                            File.Delete(rasterFile);
                        }

                        var target = Path.Combine(directory, "ic_launcher.png");
                        outputBytes += WriteSquarePng(source, density.Value, target);
                        resourceCount++;
                    }
                }

                var flutterAssets = Path.Combine(
                    decodedDirectory,
                    "assets",
                    "flutter_assets",
                    "assets");
                if (Directory.Exists(flutterAssets))
                {
                    var appIcon = Path.Combine(flutterAssets, "app_icon.png");
                    if (File.Exists(appIcon))
                    {
                        outputBytes += WriteSquarePng(source, 512, appIcon);
                        assetCount++;
                    }
                    var launcherIcon = Path.Combine(
                        flutterAssets,
                        "ic_launcher.png");
                    if (File.Exists(launcherIcon))
                    {
                        outputBytes += WriteSquarePng(source, 192, launcherIcon);
                        assetCount++;
                    }
                }

                return new AndroidIconProcessingResult
                {
                    SourceWidth = source.Width,
                    SourceHeight = source.Height,
                    SourceBytes = sourceInfo.Length,
                    OutputBytes = outputBytes,
                    WasCompressed = source.Width > 512 || source.Height > 512 ||
                        sourceInfo.Length > 2L * 1024L * 1024L,
                    ReplacedResourceCount = resourceCount,
                    ReplacedFlutterAssetCount = assetCount
                };
            }
        }

        private static Bitmap LoadSourceBitmap(string sourcePath)
        {
            var extension = Path.GetExtension(sourcePath).ToLowerInvariant();
            try
            {
                if (extension == ".ico")
                {
                    using (var icon = new Icon(sourcePath, 256, 256))
                    using (var bitmap = icon.ToBitmap())
                    {
                        return CopyToArgbBitmap(bitmap);
                    }
                }

                using (var stream = new FileStream(
                    sourcePath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.Read))
                using (var image = Image.FromStream(stream, true, true))
                {
                    ValidateDimensions(image.Width, image.Height);
                    return CopyToArgbBitmap(image);
                }
            }
            catch (Exception error)
            {
                throw new InvalidDataException(
                    "无法读取自定义图标，请确认图片没有损坏：" + error.Message,
                    error);
            }
        }

        private static Bitmap CopyToArgbBitmap(Image source)
        {
            var result = new Bitmap(
                source.Width,
                source.Height,
                PixelFormat.Format32bppArgb);
            result.SetResolution(96, 96);
            using (var graphics = Graphics.FromImage(result))
            {
                graphics.Clear(Color.Transparent);
                graphics.CompositingMode = CompositingMode.SourceCopy;
                graphics.DrawImageUnscaled(source, 0, 0);
            }
            return result;
        }

        private static long WriteSquarePng(
            Image source,
            int size,
            string targetPath)
        {
            var directory = Path.GetDirectoryName(targetPath);
            if (string.IsNullOrEmpty(directory))
            {
                throw new InvalidOperationException("Android 图标目标目录无效");
            }
            Directory.CreateDirectory(directory);

            using (var output = new Bitmap(size, size, PixelFormat.Format32bppArgb))
            {
                output.SetResolution(96, 96);
                using (var graphics = Graphics.FromImage(output))
                {
                    graphics.Clear(Color.Transparent);
                    graphics.CompositingMode = CompositingMode.SourceOver;
                    graphics.CompositingQuality = CompositingQuality.HighQuality;
                    graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                    graphics.SmoothingMode = SmoothingMode.HighQuality;

                    var scale = Math.Min(
                        (double)size / source.Width,
                        (double)size / source.Height);
                    var width = Math.Max(1, (int)Math.Round(source.Width * scale));
                    var height = Math.Max(1, (int)Math.Round(source.Height * scale));
                    var x = (size - width) / 2;
                    var y = (size - height) / 2;
                    graphics.DrawImage(
                        source,
                        new Rectangle(x, y, width, height),
                        0,
                        0,
                        source.Width,
                        source.Height,
                        GraphicsUnit.Pixel);
                }

                var temporary = targetPath + ".tmp_" + Guid.NewGuid().ToString("N");
                try
                {
                    output.Save(temporary, ImageFormat.Png);
                    if (File.Exists(targetPath))
                    {
                        File.Delete(targetPath);
                    }
                    File.Move(temporary, targetPath);
                }
                finally
                {
                    TryDeleteFile(temporary);
                }
            }
            return new FileInfo(targetPath).Length;
        }

        private static bool DirectoryMatchesDensity(string path, string density)
        {
            return Regex.IsMatch(
                Path.GetFileName(path),
                "^mipmap-(?:[^-]+-)*" + Regex.Escape(density) +
                    "(?:-[^-]+)*$",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }

        private static bool IsRasterPath(string path)
        {
            return RasterExtensions.Contains(
                Path.GetExtension(path),
                StringComparer.OrdinalIgnoreCase);
        }

        private static void ValidateDimensions(int width, int height)
        {
            var pixels = (long)width * height;
            if (width <= 0 || height <= 0 || width > MaximumSourceDimension ||
                height > MaximumSourceDimension || pixels > MaximumSourcePixels)
            {
                throw new InvalidDataException(
                    "图标尺寸无效或过大（最大 16384 像素边长、4000 万像素）");
            }
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
                // 临时文件清理失败不覆盖原始异常。
            }
        }
    }
}
