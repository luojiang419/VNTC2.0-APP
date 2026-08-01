using System;
using System.IO;
using System.IO.Compression;
using System.Text;

namespace VntBrandRepackager
{
    internal sealed class AndroidBinaryManifestInfo
    {
        public string PackageName { get; set; }

        public string VersionName { get; set; }

        public string VersionCode { get; set; }
    }

    internal static class AndroidBinaryManifestReader
    {
        private const ushort XmlType = 0x0003;
        private const ushort StringPoolType = 0x0001;
        private const ushort StartElementType = 0x0102;
        private const uint NoIndex = 0xFFFFFFFF;
        private const uint Utf8Flag = 0x00000100;
        private const byte StringValueType = 0x03;
        private const byte IntegerDecimalValueType = 0x10;
        private const byte IntegerHexValueType = 0x11;

        public static AndroidBinaryManifestInfo Read(ZipArchiveEntry entry)
        {
            if (entry == null)
            {
                throw new ArgumentNullException("entry");
            }
            if (entry.Length <= 0 || entry.Length > int.MaxValue)
            {
                throw new InvalidDataException("AndroidManifest.xml 大小无效");
            }

            byte[] data;
            using (var input = entry.Open())
            using (var output = new MemoryStream((int)entry.Length))
            {
                input.CopyTo(output);
                data = output.ToArray();
            }
            return Parse(data);
        }

        private static AndroidBinaryManifestInfo Parse(byte[] data)
        {
            if (data.Length < 8 || ReadUInt16(data, 0) != XmlType ||
                ReadUInt16(data, 2) != 8 || ReadUInt32(data, 4) != data.Length)
            {
                throw new InvalidDataException("AndroidManifest.xml 二进制 XML 头无效");
            }

            StringPool strings = null;
            var offset = 8;
            while (offset < data.Length)
            {
                RequireRange(data, offset, 8, "二进制 XML 子块头越界");
                var type = ReadUInt16(data, offset);
                var headerSize = ReadUInt16(data, offset + 2);
                var chunkSize = CheckedInt(ReadUInt32(data, offset + 4));
                if (headerSize < 8 || chunkSize < headerSize)
                {
                    throw new InvalidDataException("AndroidManifest.xml 子块大小无效");
                }
                RequireRange(data, offset, chunkSize, "二进制 XML 子块越界");

                if (type == StringPoolType)
                {
                    if (strings != null)
                    {
                        throw new InvalidDataException(
                            "AndroidManifest.xml 包含重复字符串池");
                    }
                    strings = StringPool.Parse(data, offset, headerSize, chunkSize);
                }
                else if (type == StartElementType)
                {
                    if (strings == null)
                    {
                        throw new InvalidDataException(
                            "AndroidManifest.xml 元素早于字符串池");
                    }
                    var result = TryReadManifestElement(
                        data,
                        offset,
                        headerSize,
                        chunkSize,
                        strings);
                    if (result != null)
                    {
                        return result;
                    }
                }
                offset += chunkSize;
            }
            throw new InvalidDataException("AndroidManifest.xml 缺少 manifest 根元素");
        }

        private static AndroidBinaryManifestInfo TryReadManifestElement(
            byte[] data,
            int offset,
            int headerSize,
            int chunkSize,
            StringPool strings)
        {
            if (headerSize < 16 || chunkSize < 36)
            {
                throw new InvalidDataException("AndroidManifest.xml 元素块无效");
            }
            RequireRange(data, offset + 16, 20, "二进制 XML 元素扩展头越界");
            var elementName = strings.Get(ReadUInt32(data, offset + 20));
            if (!string.Equals(elementName, "manifest", StringComparison.Ordinal))
            {
                return null;
            }

            var attributeStart = ReadUInt16(data, offset + 24);
            var attributeSize = ReadUInt16(data, offset + 26);
            var attributeCount = ReadUInt16(data, offset + 28);
            if (attributeSize < 20)
            {
                throw new InvalidDataException("AndroidManifest.xml 属性结构大小无效");
            }
            var attributesOffset = checked(offset + 16 + attributeStart);
            var attributesBytes = checked((int)attributeSize * (int)attributeCount);
            if (attributesOffset < offset + headerSize ||
                attributesOffset + attributesBytes > offset + chunkSize)
            {
                throw new InvalidDataException("AndroidManifest.xml 属性区域越界");
            }

            var packageName = string.Empty;
            var versionName = string.Empty;
            var versionCode = string.Empty;
            for (var index = 0; index < attributeCount; index++)
            {
                var attributeOffset = checked(
                    attributesOffset + index * (int)attributeSize);
                var name = strings.Get(ReadUInt32(data, attributeOffset + 4));
                if (string.Equals(name, "package", StringComparison.Ordinal))
                {
                    packageName = ReadStringAttribute(
                        data,
                        attributeOffset,
                        strings,
                        "package");
                }
                else if (string.Equals(name, "versionName", StringComparison.Ordinal))
                {
                    versionName = ReadStringAttribute(
                        data,
                        attributeOffset,
                        strings,
                        "versionName");
                }
                else if (string.Equals(name, "versionCode", StringComparison.Ordinal))
                {
                    versionCode = ReadIntegerAttribute(
                        data,
                        attributeOffset,
                        strings,
                        "versionCode");
                }
            }

            if (string.IsNullOrWhiteSpace(packageName) ||
                string.IsNullOrWhiteSpace(versionName))
            {
                throw new InvalidDataException(
                    "AndroidManifest.xml 缺少 package 或 versionName");
            }
            return new AndroidBinaryManifestInfo
            {
                PackageName = packageName.Trim(),
                VersionName = versionName.Trim(),
                VersionCode = versionCode.Trim()
            };
        }

        private static string ReadStringAttribute(
            byte[] data,
            int offset,
            StringPool strings,
            string description)
        {
            var rawValue = ReadUInt32(data, offset + 8);
            if (rawValue != NoIndex)
            {
                return strings.Get(rawValue);
            }
            var valueSize = ReadUInt16(data, offset + 12);
            var valueType = data[offset + 15];
            var valueData = ReadUInt32(data, offset + 16);
            if (valueSize != 8 || valueType != StringValueType)
            {
                throw new InvalidDataException(
                    "AndroidManifest.xml 的 " + description + " 不是字符串");
            }
            return strings.Get(valueData);
        }

        private static string ReadIntegerAttribute(
            byte[] data,
            int offset,
            StringPool strings,
            string description)
        {
            var rawValue = ReadUInt32(data, offset + 8);
            if (rawValue != NoIndex)
            {
                return strings.Get(rawValue);
            }
            var valueSize = ReadUInt16(data, offset + 12);
            var valueType = data[offset + 15];
            var valueData = ReadUInt32(data, offset + 16);
            if (valueSize != 8 ||
                (valueType != IntegerDecimalValueType &&
                 valueType != IntegerHexValueType))
            {
                throw new InvalidDataException(
                    "AndroidManifest.xml 的 " + description + " 不是整数");
            }
            return valueData.ToString(
                System.Globalization.CultureInfo.InvariantCulture);
        }

        private static ushort ReadUInt16(byte[] data, int offset)
        {
            RequireRange(data, offset, 2, "二进制 XML UInt16 越界");
            return (ushort)(data[offset] | (data[offset + 1] << 8));
        }

        private static uint ReadUInt32(byte[] data, int offset)
        {
            RequireRange(data, offset, 4, "二进制 XML UInt32 越界");
            return (uint)data[offset] |
                ((uint)data[offset + 1] << 8) |
                ((uint)data[offset + 2] << 16) |
                ((uint)data[offset + 3] << 24);
        }

        private static int CheckedInt(uint value)
        {
            if (value > int.MaxValue)
            {
                throw new InvalidDataException("二进制 XML 数值超出支持范围");
            }
            return (int)value;
        }

        private static void RequireRange(
            byte[] data,
            int offset,
            int count,
            string message)
        {
            if (offset < 0 || count < 0 || offset > data.Length - count)
            {
                throw new InvalidDataException(message);
            }
        }

        private sealed class StringPool
        {
            private readonly byte[] _data;
            private readonly int _chunkOffset;
            private readonly int _chunkSize;
            private readonly int _stringsOffset;
            private readonly uint[] _offsets;
            private readonly bool _utf8;

            private StringPool(
                byte[] data,
                int chunkOffset,
                int chunkSize,
                int stringsOffset,
                uint[] offsets,
                bool utf8)
            {
                _data = data;
                _chunkOffset = chunkOffset;
                _chunkSize = chunkSize;
                _stringsOffset = stringsOffset;
                _offsets = offsets;
                _utf8 = utf8;
            }

            public static StringPool Parse(
                byte[] data,
                int chunkOffset,
                int headerSize,
                int chunkSize)
            {
                if (headerSize < 28 || chunkSize < headerSize)
                {
                    throw new InvalidDataException("二进制 XML 字符串池头无效");
                }
                var stringCount = CheckedInt(ReadUInt32(data, chunkOffset + 8));
                var styleCount = CheckedInt(ReadUInt32(data, chunkOffset + 12));
                var flags = ReadUInt32(data, chunkOffset + 16);
                var stringsStart = CheckedInt(ReadUInt32(data, chunkOffset + 20));
                var stylesStart = CheckedInt(ReadUInt32(data, chunkOffset + 24));
                if (stringCount <= 0 || stringCount > 1000000 || styleCount < 0)
                {
                    throw new InvalidDataException("二进制 XML 字符串池数量无效");
                }
                var offsetsBytes = checked((stringCount + styleCount) * 4);
                if (headerSize + offsetsBytes > chunkSize ||
                    stringsStart < headerSize + offsetsBytes ||
                    stringsStart >= chunkSize ||
                    (stylesStart != 0 &&
                     (stylesStart <= stringsStart || stylesStart >= chunkSize)))
                {
                    throw new InvalidDataException("二进制 XML 字符串池偏移无效");
                }

                var offsets = new uint[stringCount];
                for (var index = 0; index < stringCount; index++)
                {
                    offsets[index] = ReadUInt32(
                        data,
                        chunkOffset + headerSize + index * 4);
                }
                return new StringPool(
                    data,
                    chunkOffset,
                    chunkSize,
                    stringsStart,
                    offsets,
                    (flags & Utf8Flag) != 0);
            }

            public string Get(uint index)
            {
                if (index == NoIndex || index >= _offsets.Length)
                {
                    throw new InvalidDataException("二进制 XML 字符串索引越界");
                }
                var stringOffset = checked(
                    _chunkOffset + _stringsOffset + CheckedInt(_offsets[index]));
                if (stringOffset >= _chunkOffset + _chunkSize)
                {
                    throw new InvalidDataException("二进制 XML 字符串偏移越界");
                }
                return _utf8
                    ? ReadUtf8String(stringOffset)
                    : ReadUtf16String(stringOffset);
            }

            private string ReadUtf8String(int offset)
            {
                ReadUtf8Length(ref offset);
                var byteLength = ReadUtf8Length(ref offset);
                RequireChunkRange(offset, byteLength + 1);
                if (_data[offset + byteLength] != 0)
                {
                    throw new InvalidDataException("二进制 XML UTF-8 字符串未终止");
                }
                try
                {
                    return new UTF8Encoding(false, true).GetString(
                        _data,
                        offset,
                        byteLength);
                }
                catch (DecoderFallbackException error)
                {
                    throw new InvalidDataException(
                        "二进制 XML 包含无效 UTF-8 字符串",
                        error);
                }
            }

            private string ReadUtf16String(int offset)
            {
                var characterLength = ReadUtf16Length(ref offset);
                var byteLength = checked(characterLength * 2);
                RequireChunkRange(offset, byteLength + 2);
                if (_data[offset + byteLength] != 0 ||
                    _data[offset + byteLength + 1] != 0)
                {
                    throw new InvalidDataException("二进制 XML UTF-16 字符串未终止");
                }
                return Encoding.Unicode.GetString(_data, offset, byteLength);
            }

            private int ReadUtf8Length(ref int offset)
            {
                RequireChunkRange(offset, 1);
                var first = _data[offset++];
                if ((first & 0x80) == 0)
                {
                    return first;
                }
                RequireChunkRange(offset, 1);
                return ((first & 0x7F) << 8) | _data[offset++];
            }

            private int ReadUtf16Length(ref int offset)
            {
                RequireChunkRange(offset, 2);
                var first = ReadUInt16(_data, offset);
                offset += 2;
                if ((first & 0x8000) == 0)
                {
                    return first;
                }
                RequireChunkRange(offset, 2);
                var second = ReadUInt16(_data, offset);
                offset += 2;
                return checked(((first & 0x7FFF) << 16) | second);
            }

            private void RequireChunkRange(int offset, int count)
            {
                if (offset < _chunkOffset || count < 0 ||
                    offset > _chunkOffset + _chunkSize - count)
                {
                    throw new InvalidDataException("二进制 XML 字符串数据越界");
                }
            }
        }
    }
}
