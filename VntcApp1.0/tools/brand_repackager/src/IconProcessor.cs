using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;

namespace VntBrandRepackager
{
    internal sealed class IconProcessingResult
    {
        public int SourceWidth { get; set; }
        public int SourceHeight { get; set; }
        public long SourceBytes { get; set; }
        public long OutputBytes { get; set; }
        public bool WasCompressed { get; set; }
    }

    internal static class IconProcessor
    {
        private sealed class IconFrame
        {
            public byte WidthValue { get; set; }
            public byte HeightValue { get; set; }
            public byte ColorCount { get; set; }
            public byte Reserved { get; set; }
            public ushort Planes { get; set; }
            public ushort BitCount { get; set; }
            public int Width { get; set; }
            public int Height { get; set; }
            public byte[] Data { get; set; }
        }

        private const long MaxSourceBytes = 64L * 1024L * 1024L;
        private const long MaxSourcePixels = 40000000L;
        private const int MaxSourceDimension = 16384;
        private static readonly int[] TargetSizes =
        {
            16, 20, 24, 32, 40, 48, 64, 128, 256
        };

        public static IconProcessingResult CreateWindowsIcon(
            string sourcePath,
            string outputPath)
        {
            sourcePath = Path.GetFullPath(sourcePath ?? string.Empty);
            outputPath = Path.GetFullPath(outputPath ?? string.Empty);
            var sourceInfo = new FileInfo(sourcePath);
            if (!sourceInfo.Exists)
            {
                throw new FileNotFoundException("自定义图标文件不存在", sourcePath);
            }
            if (sourceInfo.Length > MaxSourceBytes)
            {
                throw new ArgumentException("图标源文件不能超过 64 MB");
            }

            var extension = Path.GetExtension(sourcePath).ToLowerInvariant();
            int sourceWidth;
            int sourceHeight;
            if (extension == ".ico")
            {
                var frame = ReadLargestIconFrame(sourcePath);
                sourceWidth = frame.Width;
                sourceHeight = frame.Height;
                ValidateDimensions(sourceWidth, sourceHeight);
                if (IsPng(frame.Data))
                {
                    using (var stream = new MemoryStream(frame.Data, false))
                    using (var image = Image.FromStream(stream, true, true))
                    {
                        sourceWidth = image.Width;
                        sourceHeight = image.Height;
                        ValidateDimensions(sourceWidth, sourceHeight);
                        WriteMultiSizeIcon(image, outputPath);
                    }
                }
                else
                {
                    using (var stream = BuildSingleFrameIcon(frame))
                    using (var icon = new Icon(stream))
                    using (var bitmap = icon.ToBitmap())
                    {
                        sourceWidth = bitmap.Width;
                        sourceHeight = bitmap.Height;
                        ValidateDimensions(sourceWidth, sourceHeight);
                        WriteMultiSizeIcon(bitmap, outputPath);
                    }
                }
            }
            else
            {
                using (var stream = File.OpenRead(sourcePath))
                using (var image = Image.FromStream(stream, true, true))
                {
                    sourceWidth = image.Width;
                    sourceHeight = image.Height;
                    ValidateDimensions(sourceWidth, sourceHeight);
                    WriteMultiSizeIcon(image, outputPath);
                }
            }

            var outputBytes = new FileInfo(outputPath).Length;
            return new IconProcessingResult
            {
                SourceWidth = sourceWidth,
                SourceHeight = sourceHeight,
                SourceBytes = sourceInfo.Length,
                OutputBytes = outputBytes,
                WasCompressed = sourceWidth > 256 || sourceHeight > 256 ||
                    sourceInfo.Length > 1024L * 1024L
            };
        }

        public static void CreateSquarePng(
            string sourcePath,
            string outputPath,
            int size)
        {
            sourcePath = Path.GetFullPath(sourcePath ?? string.Empty);
            outputPath = Path.GetFullPath(outputPath ?? string.Empty);
            var sourceInfo = new FileInfo(sourcePath);
            if (!sourceInfo.Exists)
            {
                throw new FileNotFoundException("自定义图标文件不存在", sourcePath);
            }
            if (sourceInfo.Length <= 0 || sourceInfo.Length > MaxSourceBytes)
            {
                throw new ArgumentException("图标源文件必须大于 0 且不能超过 64 MB");
            }
            if (size < 16 || size > 1024)
            {
                throw new ArgumentOutOfRangeException("size");
            }

            byte[] png;
            if (string.Equals(
                Path.GetExtension(sourcePath),
                ".ico",
                StringComparison.OrdinalIgnoreCase))
            {
                var frame = ReadLargestIconFrame(sourcePath);
                ValidateDimensions(frame.Width, frame.Height);
                if (IsPng(frame.Data))
                {
                    using (var stream = new MemoryStream(frame.Data, false))
                    using (var image = Image.FromStream(stream, true, true))
                    {
                        ValidateDimensions(image.Width, image.Height);
                        png = RenderPng(image, size);
                    }
                }
                else
                {
                    using (var stream = BuildSingleFrameIcon(frame))
                    using (var icon = new Icon(stream))
                    using (var bitmap = icon.ToBitmap())
                    {
                        ValidateDimensions(bitmap.Width, bitmap.Height);
                        png = RenderPng(bitmap, size);
                    }
                }
            }
            else
            {
                using (var stream = File.OpenRead(sourcePath))
                using (var image = Image.FromStream(stream, true, true))
                {
                    ValidateDimensions(image.Width, image.Height);
                    png = RenderPng(image, size);
                }
            }

            var directory = Path.GetDirectoryName(outputPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }
            File.WriteAllBytes(outputPath, png);
        }

        public static string FormatBytes(long bytes)
        {
            if (bytes >= 1024L * 1024L)
            {
                return (bytes / (1024D * 1024D)).ToString("0.##") + " MB";
            }
            if (bytes >= 1024L)
            {
                return (bytes / 1024D).ToString("0.##") + " KB";
            }
            return bytes + " B";
        }

        private static IconFrame ReadLargestIconFrame(string path)
        {
            using (var stream = File.OpenRead(path))
            using (var reader = new BinaryReader(stream))
            {
                if (reader.ReadUInt16() != 0 || reader.ReadUInt16() != 1)
                {
                    throw new InvalidDataException("ICO 文件头无效");
                }
                var count = reader.ReadUInt16();
                if (count < 1 || count > 256)
                {
                    throw new InvalidDataException("ICO 图像数量无效");
                }
                IconFrame largest = null;
                uint largestLength = 0;
                uint largestOffset = 0;
                for (var index = 0; index < count; index++)
                {
                    var widthValue = reader.ReadByte();
                    var heightValue = reader.ReadByte();
                    var width = widthValue == 0 ? 256 : widthValue;
                    var height = heightValue == 0 ? 256 : heightValue;
                    var colorCount = reader.ReadByte();
                    var reserved = reader.ReadByte();
                    var planes = reader.ReadUInt16();
                    var bitCount = reader.ReadUInt16();
                    var dataLength = reader.ReadUInt32();
                    var dataOffset = reader.ReadUInt32();
                    if ((long)dataOffset + dataLength > stream.Length)
                    {
                        throw new InvalidDataException("ICO 图像数据越界");
                    }
                    if (largest == null ||
                        width * height > largest.Width * largest.Height ||
                        (width * height == largest.Width * largest.Height &&
                            dataLength > largestLength))
                    {
                        largest = new IconFrame
                        {
                            WidthValue = widthValue,
                            HeightValue = heightValue,
                            ColorCount = colorCount,
                            Reserved = reserved,
                            Planes = planes,
                            BitCount = bitCount,
                            Width = width,
                            Height = height
                        };
                        largestLength = dataLength;
                        largestOffset = dataOffset;
                    }
                }
                if (largest == null || largestLength < 1)
                {
                    throw new InvalidDataException("ICO 文件不包含有效图像");
                }
                stream.Position = largestOffset;
                largest.Data = reader.ReadBytes(checked((int)largestLength));
                if (largest.Data.Length != largestLength)
                {
                    throw new InvalidDataException("ICO 图像数据不完整");
                }
                return largest;
            }
        }

        private static bool IsPng(byte[] data)
        {
            var signature = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 };
            if (data == null || data.Length < signature.Length)
            {
                return false;
            }
            for (var index = 0; index < signature.Length; index++)
            {
                if (data[index] != signature[index])
                {
                    return false;
                }
            }
            return true;
        }

        private static MemoryStream BuildSingleFrameIcon(IconFrame frame)
        {
            var stream = new MemoryStream();
            using (var writer = new BinaryWriter(stream, System.Text.Encoding.UTF8, true))
            {
                writer.Write((ushort)0);
                writer.Write((ushort)1);
                writer.Write((ushort)1);
                writer.Write(frame.WidthValue);
                writer.Write(frame.HeightValue);
                writer.Write(frame.ColorCount);
                writer.Write(frame.Reserved);
                writer.Write(frame.Planes);
                writer.Write(frame.BitCount);
                writer.Write((uint)frame.Data.Length);
                writer.Write((uint)22);
                writer.Write(frame.Data);
            }
            stream.Position = 0;
            return stream;
        }

        private static void ValidateDimensions(int width, int height)
        {
            if (width < 1 || height < 1)
            {
                throw new ArgumentException("图标图片尺寸无效");
            }
            if (width > MaxSourceDimension || height > MaxSourceDimension ||
                (long)width * height > MaxSourcePixels)
            {
                throw new ArgumentException(
                    "图标像素过大，最大支持约 4000 万像素；请先缩小源图片");
            }
        }

        private static void WriteMultiSizeIcon(Image source, string outputPath)
        {
            var directory = Path.GetDirectoryName(outputPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var images = new List<byte[]>();
            foreach (var size in TargetSizes)
            {
                images.Add(RenderPng(source, size));
            }

            using (var stream = File.Create(outputPath))
            using (var writer = new BinaryWriter(stream))
            {
                writer.Write((ushort)0);
                writer.Write((ushort)1);
                writer.Write((ushort)images.Count);
                var imageOffset = 6 + images.Count * 16;
                for (var index = 0; index < images.Count; index++)
                {
                    var size = TargetSizes[index];
                    writer.Write((byte)(size == 256 ? 0 : size));
                    writer.Write((byte)(size == 256 ? 0 : size));
                    writer.Write((byte)0);
                    writer.Write((byte)0);
                    writer.Write((ushort)1);
                    writer.Write((ushort)32);
                    writer.Write((uint)images[index].Length);
                    writer.Write((uint)imageOffset);
                    imageOffset += images[index].Length;
                }
                foreach (var image in images)
                {
                    writer.Write(image);
                }
            }
        }

        private static byte[] RenderPng(Image source, int size)
        {
            using (var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb))
            using (var graphics = Graphics.FromImage(bitmap))
            {
                graphics.Clear(Color.Transparent);
                graphics.CompositingQuality = CompositingQuality.HighQuality;
                graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                graphics.SmoothingMode = SmoothingMode.HighQuality;

                var scale = Math.Min(
                    (double)size / source.Width,
                    (double)size / source.Height);
                var width = Math.Max(1, (int)Math.Round(source.Width * scale));
                var height = Math.Max(1, (int)Math.Round(source.Height * scale));
                var destination = new Rectangle(
                    (size - width) / 2,
                    (size - height) / 2,
                    width,
                    height);
                graphics.DrawImage(
                    source,
                    destination,
                    0,
                    0,
                    source.Width,
                    source.Height,
                    GraphicsUnit.Pixel);

                using (var output = new MemoryStream())
                {
                    bitmap.Save(output, ImageFormat.Png);
                    return output.ToArray();
                }
            }
        }
    }
}
