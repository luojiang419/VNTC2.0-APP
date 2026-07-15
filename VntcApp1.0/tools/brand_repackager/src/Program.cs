using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Windows.Forms;

namespace VntBrandRepackager
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            if (args.Length > 0)
            {
                Environment.ExitCode = RunCommandLine(args);
                return;
            }

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }

        private static int RunCommandLine(string[] args)
        {
            var options = ParseOptions(args);
            var lines = new List<string>();
            Action<string> log = null;

            try
            {
                var outputDirectory = Path.GetFullPath(GetOption(
                    options,
                    "output",
                    Environment.CurrentDirectory));
                var logPath = Path.GetFullPath(GetOption(
                    options,
                    "log",
                    Path.Combine(outputDirectory, "brand_repackager.log")));
                ValidateLogPath(options, logPath);
                Directory.CreateDirectory(outputDirectory);
                var logDirectory = Path.GetDirectoryName(logPath);
                if (!string.IsNullOrWhiteSpace(logDirectory))
                {
                    Directory.CreateDirectory(logDirectory);
                }
                log = delegate(string message)
                {
                    var line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
                        " | " + message;
                    lines.Add(line);
                    File.WriteAllLines(
                        logPath,
                        lines.ToArray(),
                        new UTF8Encoding(false));
                };

                if (options.ContainsKey("self-test"))
                {
                    BrandPackager.VerifyEmbeddedToolchain(log);
                    log("内置工具链自检通过");
                    return 0;
                }
                if (options.ContainsKey("inspect"))
                {
                    var inspection = PackageDetector.RequireSupported(
                        GetRequiredOption(options, "input"));
                    log("识别类型：" + inspection.PlatformDisplayName);
                    log("版本：" + inspection.Version);
                    if (!string.IsNullOrWhiteSpace(inspection.ApplicationId))
                    {
                        log("Android applicationId：" + inspection.ApplicationId);
                    }
                    log("安装包内容识别通过");
                    return 0;
                }
                if (!options.ContainsKey("pack"))
                {
                    throw new ArgumentException(
                        "仅支持 --self-test、--inspect 或 --pack 命令");
                }

                var request = new BrandPackageRequest
                {
                    InstallerPath = GetRequiredOption(options, "input"),
                    ProductName = GetRequiredOption(options, "name"),
                    OutputDirectory = outputDirectory,
                    OutputInstallerPath = GetOption(options, "save", string.Empty),
                    IconPath = GetOption(options, "icon", string.Empty),
                    HideAboutPage = GetFlag(options, "hide-about"),
                    UpdateEnabled = !GetFlag(options, "remove-update", true)
                };
                var result = new BrandPackager(log).Pack(request);
                log("打包完成：" + result.InstallerPath);
                return 0;
            }
            catch (Exception error)
            {
                if (log != null)
                {
                    log("失败：" + error);
                }
                return 1;
            }
        }

        private static void ValidateLogPath(
            IDictionary<string, string> options,
            string logPath)
        {
            if (!string.Equals(
                Path.GetExtension(logPath),
                ".log",
                StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException(
                    "日志文件必须使用 .log 扩展名，以免覆盖 EXE、APK 或 .sha256 校验文件");
            }

            foreach (var key in new[] { "input", "save", "icon" })
            {
                string value;
                if (!options.TryGetValue(key, out value) ||
                    string.IsNullOrWhiteSpace(value))
                {
                    continue;
                }
                if (string.Equals(
                    logPath,
                    Path.GetFullPath(value),
                    StringComparison.OrdinalIgnoreCase))
                {
                    throw new ArgumentException(
                        "日志文件不能与 --" + key + " 指向同一文件");
                }
            }
        }

        private static Dictionary<string, string> ParseOptions(string[] args)
        {
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var index = 0; index < args.Length; index++)
            {
                var current = args[index];
                if (!current.StartsWith("--", StringComparison.Ordinal))
                {
                    continue;
                }
                var key = current.Substring(2);
                var value = "true";
                if (index + 1 < args.Length &&
                    !args[index + 1].StartsWith("--", StringComparison.Ordinal))
                {
                    value = args[++index];
                }
                result[key] = value;
            }
            return result;
        }

        private static string GetRequiredOption(
            IDictionary<string, string> options,
            string key)
        {
            string value;
            if (!options.TryGetValue(key, out value) || string.IsNullOrWhiteSpace(value))
            {
                throw new ArgumentException("缺少参数 --" + key);
            }
            return value;
        }

        private static string GetOption(
            IDictionary<string, string> options,
            string key,
            string fallback)
        {
            string value;
            return options.TryGetValue(key, out value) ? value : fallback;
        }

        private static bool GetFlag(
            IDictionary<string, string> options,
            string key,
            bool defaultValue = false)
        {
            string value;
            if (!options.TryGetValue(key, out value))
            {
                return defaultValue;
            }
            return !string.Equals(value, "false", StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(value, "0", StringComparison.OrdinalIgnoreCase);
        }
    }
}
