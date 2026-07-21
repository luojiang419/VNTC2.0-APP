using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: AssemblyTitle("VNTS2 Manager")]
[assembly: AssemblyDescription("VNTS 2.0 Windows 服务管理器")]
[assembly: AssemblyCompany("VNTS2")]
[assembly: AssemblyProduct("VNTS 2.0")]
[assembly: AssemblyCopyright("Copyright © 2026 VNTS2")]
[assembly: AssemblyVersion("2.0.0.0")]
[assembly: AssemblyFileVersion("2.0.0.0")]

namespace Vnts2.WindowsManager
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 2 && args[0] == "--validate-only")
            {
                var model = new Dictionary<string, object>
                {
                    { "Title", "VNTS 2.0 Windows 服务管理器" },
                    { "Implementation", "CSharpWinForms" },
                    { "ExecutableGui", true },
                    { "UsesPowerShellGui", false },
                    { "DefaultServiceName", "vnts2" },
                    { "PortableDataRelativePath", "data" },
                    { "ExistingDeploymentAction", "MigrateExistingService" },
                    { "DefaultTheme", "Dark" },
                    { "ThemeToggle", true },
                    { "NativeDarkTitleBar", true },
                    { "EmbeddedApplicationIcon", true },
                    { "TraySupport", true },
                    { "SingleInstance", true },
                    { "CrossEditionSingleInstance", false },
                    { "IndependentEdition", true },
                    { "SingleInstanceMutexName", SingleInstanceGuard.MutexName },
                    { "ActivationEventName", SingleInstanceGuard.ActivationEventName },
                    { "CloseBehaviors", new[] { "MinimizeToTray", "StopServiceAndExit" } },
                    { "DefaultCloseBehavior", "MinimizeToTray" },
                    { "StartupBehaviors", new[] { "Disabled", "Normal", "SilentToTray" } },
                    { "StartupTaskName", StartupTaskManager.TaskName },
                    { "SilentStartArgument", "--silent" },
                    { "StructuredConfigDialog", true },
                    { "TextEditorConfig", false },
                    { "ConfigSections", new[] { "基础网络", "Web 管理", "WireGuard", "服务器互联", "高级安全" } },
                    { "ConfigDialogFontSize", 10.5 },
                    { "ConfigInputFontSize", 11.0 },
                    { "ConfigInputHeight", 36 },
                    { "ConfigAdaptiveLayout", true },
                    { "RuntimeLogRelativePath", @"data\logs\vnts2.log" },
                    { "ActionCount", 9 },
                    { "Actions", new[] { "配置", "安装或更新", "启动", "停止", "诊断", "网络管理", "Web 控制台", "卸载", "刷新日志" } }
                };
                File.WriteAllText(args[1], new JavaScriptSerializer().Serialize(model), new UTF8Encoding(false));
                return 0;
            }
            if (args.Length == 3 && args[0] == "--status-only")
            {
                try
                {
                    string directory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                    ServiceStatus status = new PowerShellRunner(directory).GetStatus(args[1]);
                    var result = new Dictionary<string, object>
                    {
                        { "Name", status.Name },
                        { "Installed", status.Installed },
                        { "State", status.State },
                        { "ProcessId", status.ProcessId },
                        { "ExecutablePath", status.ExecutablePath },
                        { "ConfigPath", status.ConfigPath },
                        { "DataPath", status.DataPath },
                        { "PortableLayout", status.PortableLayout },
                        { "InvokedBy", "VNTS2-Manager.exe" }
                    };
                    File.WriteAllText(args[2], new JavaScriptSerializer().Serialize(result), new UTF8Encoding(false));
                    return 0;
                }
                catch (Exception exception)
                {
                    File.WriteAllText(args[2], exception.ToString(), new UTF8Encoding(false));
                    return 2;
                }
            }
            if ((args.Length == 3 || args.Length == 4) && args[0] == "--enable-web-only")
            {
                try
                {
                    string directory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                    var runner = new PowerShellRunner(directory);
                    ServiceStatus status = runner.GetStatus(args[1]);
                    WebConsoleSettings settings = WebConsoleManager.Enable(
                        runner, status, args.Length == 4 ? args[3] : null);
                    var result = new Dictionary<string, object>
                    {
                        { "Endpoint", settings.Endpoint },
                        { "Username", settings.Username },
                        { "Password", settings.Password },
                        { "BackupPath", settings.BackupPath },
                        { "InvokedBy", "VNTS2-Manager.exe" }
                    };
                    File.WriteAllText(args[2], new JavaScriptSerializer().Serialize(result), new UTF8Encoding(false));
                    return 0;
                }
                catch (Exception exception)
                {
                    File.WriteAllText(args[2], exception.ToString(), new UTF8Encoding(false));
                    return 2;
                }
            }
            if (args.Length == 3 && args[0] == "--network-api-check")
            {
                try
                {
                    string directory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                    var runner = new PowerShellRunner(directory);
                    ServiceStatus service = runner.GetStatus(args[1]);
                    if (!service.Installed || string.IsNullOrWhiteSpace(service.ConfigPath))
                        throw new InvalidOperationException("服务尚未安装，无法检查网络管理接口。");
                    var client = LocalApiClient.FromConfig(service.ConfigPath);
                    ServerStatusData status = client.GetServerStatus();
                    List<NetworkInfoData> networks = client.GetNetworks();
                    var result = new Dictionary<string, object>
                    {
                        { "ApiReady", true },
                        { "NetworkCount", networks.Count },
                        { "VntQuicListener", status.listeners == null ? null : status.listeners.vnt_quic },
                        { "InvokedBy", "VNTS2-Manager.exe" }
                    };
                    File.WriteAllText(args[2], new JavaScriptSerializer().Serialize(result), new UTF8Encoding(false));
                    return 0;
                }
                catch (Exception exception)
                {
                    File.WriteAllText(args[2], exception.ToString(), new UTF8Encoding(false));
                    return 2;
                }
            }
            if (args.Length == 3 && args[0] == "--config-roundtrip-check")
            {
                try
                {
                    ServerConfigSettings settings = ConfigFileEditor.Load(args[1]);
                    ConfigSettingsForm.ValidateSettings(settings);
                    string backupPath = ConfigFileEditor.Save(args[1], settings);
                    var result = new Dictionary<string, object>
                    {
                        { "TcpBind", settings.TcpBind },
                        { "QuicBind", settings.QuicBind },
                        { "WebEnabled", settings.WebEnabled },
                        { "WireGuardEnabled", settings.WireGuardEnabled },
                        { "WireGuardMasterKeyFile", settings.WireGuardMasterKeyFile },
                        { "WireGuardBind", settings.WireGuardBind },
                        { "WireGuardPublicEndpoint", settings.WireGuardPublicEndpoint },
                        { "WireGuardDns", settings.WireGuardDns },
                        { "ServerQuicEnabled", settings.ServerQuicEnabled },
                        { "BackupPath", backupPath },
                        { "StructuredEditor", true }
                    };
                    File.WriteAllText(args[2], new JavaScriptSerializer().Serialize(result), new UTF8Encoding(false));
                    return 0;
                }
                catch (Exception exception)
                {
                    File.WriteAllText(args[2], exception.ToString(), new UTF8Encoding(false));
                    return 2;
                }
            }
            if (args.Length == 3 && args[0] == "--desktop-preferences-check")
            {
                try
                {
                    GuiSettingsManager.SaveDesktopBehavior(
                        args[1], GuiBehavior.StopServiceAndExit, GuiBehavior.StartupSilent);
                    var result = new Dictionary<string, object>
                    {
                        { "CloseBehavior", GuiSettingsManager.LoadCloseBehavior(args[1]) },
                        { "StartupBehavior", GuiSettingsManager.LoadStartupBehavior(args[1]) },
                        { "NormalTaskCommand", StartupTaskManager.BuildTaskCommand(GuiBehavior.StartupNormal, Application.ExecutablePath) },
                        { "SilentTaskCommand", StartupTaskManager.BuildTaskCommand(GuiBehavior.StartupSilent, Application.ExecutablePath) }
                    };
                    File.WriteAllText(args[2], new JavaScriptSerializer().Serialize(result), new UTF8Encoding(false));
                    return 0;
                }
                catch (Exception exception)
                {
                    File.WriteAllText(args[2], exception.ToString(), new UTF8Encoding(false));
                    return 2;
                }
            }
            SingleInstanceGuard instanceGuard;
            if (!SingleInstanceGuard.TryAcquire(out instanceGuard)) return 0;
            using (instanceGuard)
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                bool silentStart = args.Any(delegate(string value)
                {
                    return string.Equals(value, "--silent", StringComparison.OrdinalIgnoreCase);
                });
                using (var form = new ManagerForm(silentStart))
                {
                    form.StartActivationListener(instanceGuard.ActivationEvent);
                    Application.Run(form);
                }
            }
            return 0;
        }
    }

    internal sealed class SingleInstanceGuard : IDisposable
    {
        internal const string MutexName = @"Local\VNTS2.Manager.SingleInstance.v1";
        internal const string ActivationEventName = @"Local\VNTS2.Manager.Activate.v1";
        private readonly Mutex mutex;
        private readonly EventWaitHandle activationEvent;
        private bool ownsMutex;

        private SingleInstanceGuard(Mutex mutex)
        {
            this.mutex = mutex;
            activationEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ActivationEventName);
            ownsMutex = true;
        }

        internal WaitHandle ActivationEvent { get { return activationEvent; } }

        internal static bool TryAcquire(out SingleInstanceGuard guard)
        {
            guard = null;
            Mutex candidate = null;
            try
            {
                bool createdNew;
                candidate = new Mutex(true, MutexName, out createdNew);
                if (!createdNew)
                {
                    candidate.Dispose();
                    NotifyExistingInstance();
                    return false;
                }
                try
                {
                    guard = new SingleInstanceGuard(candidate);
                }
                catch
                {
                    try { candidate.ReleaseMutex(); }
                    catch (ApplicationException) { }
                    candidate.Dispose();
                    throw;
                }
                return true;
            }
            catch (UnauthorizedAccessException)
            {
                if (candidate != null) candidate.Dispose();
                NotifyExistingInstance();
                return false;
            }
        }

        private static void NotifyExistingInstance()
        {
            try
            {
                using (EventWaitHandle activation = EventWaitHandle.OpenExisting(ActivationEventName))
                {
                    activation.Set();
                }
            }
            catch (WaitHandleCannotBeOpenedException) { }
            catch (UnauthorizedAccessException) { }
        }

        public void Dispose()
        {
            if (ownsMutex)
            {
                ownsMutex = false;
                try { mutex.ReleaseMutex(); }
                catch (ApplicationException) { }
            }
            activationEvent.Dispose();
            mutex.Dispose();
        }
    }

    internal sealed class ServiceStatus
    {
        internal string Name;
        internal bool Installed;
        internal string State;
        internal int ProcessId;
        internal string StartName;
        internal string ExecutablePath;
        internal string ConfigPath;
        internal string DataPath;
        internal bool PortableLayout;
        internal string PathName;
    }

    internal sealed class WebConsoleSettings
    {
        internal string Endpoint;
        internal string Username;
        internal string Password;
        internal string BackupPath;
    }

    internal static class WebConsoleManager
    {
        private const string DefaultEndpoint = "127.0.0.1:29871";
        private const string DefaultUsername = "admin";
        private const string PasswordAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@$%*-_";

        internal static WebConsoleSettings Enable(
            PowerShellRunner runner,
            ServiceStatus status,
            string endpointOverride = null)
        {
            if (status == null || !status.Installed)
                throw new InvalidOperationException("请先安装 Windows 服务，再启用 Web 控制台。");
            if (string.IsNullOrWhiteSpace(status.ConfigPath) || !File.Exists(status.ConfigPath))
                throw new FileNotFoundException("已安装服务的配置文件不存在。", status == null ? null : status.ConfigPath);

            string endpoint = string.IsNullOrWhiteSpace(endpointOverride) ? DefaultEndpoint : endpointOverride.Trim();
            ValidateLoopbackEndpoint(endpoint);
            string username = ReadRootString(status.ConfigPath, "username");
            if (string.IsNullOrWhiteSpace(username)) username = DefaultUsername;
            string password = ReadRootString(status.ConfigPath, "password");
            if (!IsStrongPassword(password, username)) password = GeneratePassword();

            string backupDirectory = Path.Combine(Path.GetDirectoryName(status.ConfigPath), ".backups");
            Directory.CreateDirectory(backupDirectory);
            string backupPath = Path.Combine(
                backupDirectory,
                "config.toml.pre-web-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") + ".bak");
            string temporaryPath = status.ConfigPath + ".web-" + Guid.NewGuid().ToString("N") + ".tmp";
            bool wasRunning = string.Equals(status.State, "Running", StringComparison.OrdinalIgnoreCase);
            bool replaced = false;

            try
            {
                WriteUpdatedConfig(status.ConfigPath, temporaryPath, endpoint, username, password);
                File.Replace(temporaryPath, status.ConfigPath, backupPath, true);
                replaced = true;

                string serviceArgument = "-ServiceName " + PowerShellRunner.Quote(status.Name);
                if (wasRunning) runner.Invoke("stop-vnts2-service.ps1", serviceArgument);
                runner.Invoke("start-vnts2-service.ps1", serviceArgument);
                WaitForEndpoint(endpoint, TimeSpan.FromSeconds(15));

                return new WebConsoleSettings
                {
                    Endpoint = endpoint,
                    Username = username,
                    Password = password,
                    BackupPath = backupPath
                };
            }
            catch (Exception exception)
            {
                if (replaced)
                {
                    try
                    {
                        File.Copy(backupPath, status.ConfigPath, true);
                        string serviceArgument = "-ServiceName " + PowerShellRunner.Quote(status.Name);
                        if (wasRunning) runner.Invoke("start-vnts2-service.ps1", serviceArgument);
                        else runner.Invoke("stop-vnts2-service.ps1", serviceArgument);
                    }
                    catch (Exception rollbackException)
                    {
                        throw new InvalidOperationException(
                            "启用 Web 控制台失败，且自动恢复失败。原始配置备份位于：" + backupPath +
                            "\r\n启用错误：" + exception.Message + "\r\n恢复错误：" + rollbackException.Message,
                            exception);
                    }
                }
                throw new InvalidOperationException("启用 Web 控制台失败，原配置已保留或恢复：" + exception.Message, exception);
            }
            finally
            {
                if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
            }
        }

        internal static string ReadEndpoint(string configPath)
        {
            return ReadRootString(configPath, "web_bind");
        }

        internal static void ValidateLoopbackEndpoint(string endpoint)
        {
            Match loopback = Regex.Match(endpoint ?? string.Empty, "^(?:127\\.0\\.0\\.1|localhost):(\\d{1,5})$");
            Match ipv6 = Regex.Match(endpoint ?? string.Empty, "^\\[::1\\]:(\\d{1,5})$");
            if (!loopback.Success && !ipv6.Success)
                throw new InvalidOperationException("Web 管理端必须使用回环地址：" + endpoint);
            int port = int.Parse((loopback.Success ? loopback : ipv6).Groups[1].Value);
            if (port < 1 || port > 65535) throw new InvalidOperationException("Web 管理端端口无效。");
        }

        internal static string ToUrl(string endpoint)
        {
            ValidateLoopbackEndpoint(endpoint);
            Match ipv6 = Regex.Match(endpoint, "^\\[::1\\]:(\\d{1,5})$");
            string port = endpoint.Substring(endpoint.LastIndexOf(':') + 1);
            return "http://" + (ipv6.Success ? "[::1]" : "127.0.0.1") + ":" + port + "/";
        }

        internal static string ReadRootString(string configPath, string name)
        {
            var pattern = new Regex("^\\s*" + Regex.Escape(name) + "\\s*=\\s*\"([^\"]*)\"\\s*(?:#.*)?$");
            foreach (string line in File.ReadAllLines(configPath))
            {
                if (Regex.IsMatch(line, "^\\s*\\[")) break;
                Match match = pattern.Match(line);
                if (match.Success) return match.Groups[1].Value;
            }
            return null;
        }

        private static void WriteUpdatedConfig(
            string sourcePath,
            string destinationPath,
            string endpoint,
            string username,
            string password)
        {
            string original = File.ReadAllText(sourcePath);
            string newline = original.Contains("\r\n") ? "\r\n" : "\n";
            var lines = File.ReadAllLines(sourcePath).ToList();
            SetRootString(lines, "web_bind", endpoint);
            SetRootString(lines, "username", username);
            SetRootString(lines, "password", password);
            File.WriteAllText(destinationPath, string.Join(newline, lines) + newline, new UTF8Encoding(false));
        }

        private static void SetRootString(List<string> lines, string name, string value)
        {
            int rootEnd = lines.FindIndex(delegate(string line) { return Regex.IsMatch(line, "^\\s*\\["); });
            if (rootEnd < 0) rootEnd = lines.Count;
            var pattern = new Regex("^\\s*" + Regex.Escape(name) + "\\s*=");
            for (int index = 0; index < rootEnd; index++)
            {
                if (!pattern.IsMatch(lines[index])) continue;
                lines[index] = name + " = \"" + value + "\"";
                return;
            }
            lines.Insert(rootEnd, name + " = \"" + value + "\"");
        }

        private static bool IsStrongPassword(string password, string username)
        {
            return !string.IsNullOrWhiteSpace(password) &&
                !string.Equals(password, "admin", StringComparison.Ordinal) &&
                !string.Equals(password, username, StringComparison.Ordinal);
        }

        private static string GeneratePassword()
        {
            var value = new char[24];
            var bytes = new byte[value.Length];
            using (var random = new RNGCryptoServiceProvider()) random.GetBytes(bytes);
            for (int index = 0; index < value.Length; index++)
                value[index] = PasswordAlphabet[bytes[index] & 63];
            return new string(value);
        }

        internal static void WaitForEndpoint(string endpoint, TimeSpan timeout)
        {
            ValidateLoopbackEndpoint(endpoint);
            int port = int.Parse(endpoint.Substring(endpoint.LastIndexOf(':') + 1));
            string host = endpoint.StartsWith("[::1]", StringComparison.OrdinalIgnoreCase) ? "::1" : "127.0.0.1";
            DateTime deadline = DateTime.UtcNow.Add(timeout);
            do
            {
                using (var client = new TcpClient())
                {
                    try
                    {
                        IAsyncResult result = client.BeginConnect(host, port, null, null);
                        if (result.AsyncWaitHandle.WaitOne(500) && client.Connected)
                        {
                            client.EndConnect(result);
                            return;
                        }
                    }
                    catch (SocketException) { }
                }
                Thread.Sleep(200);
            } while (DateTime.UtcNow < deadline);
            throw new TimeoutException("服务已启动，但 Web 控制台在 15 秒内未开始监听 " + endpoint + "。");
        }
    }

    internal sealed class ServerConfigSettings
    {
        internal string TcpBind;
        internal string QuicBind;
        internal string WsBind;
        internal string Network;
        internal List<string> WhiteList = new List<string>();
        internal ulong LeaseDuration;
        internal bool Persistence;
        internal bool WebEnabled;
        internal string WebBind;
        internal string Username;
        internal string Password;
        internal bool WireGuardEnabled;
        internal string WireGuardMasterKeyFile;
        internal string WireGuardBind;
        internal string WireGuardPublicEndpoint;
        internal int WireGuardMaxActivePeers;
        internal List<string> WireGuardDns = new List<string>();
        internal bool ServerQuicEnabled;
        internal string ServerQuicBind;
        internal List<string> PeerServers = new List<string>();
        internal string ServerToken;
        internal string CertificateFile;
        internal string PrivateKeyFile;
    }

    internal static class WireGuardDefaults
    {
        internal const string MasterKeyFile = "wireguard-master.key";
        internal const string Bind = "0.0.0.0:41194";
        internal const int Port = 41194;

        internal static void ApplyMissing(ServerConfigSettings settings)
        {
            if (string.IsNullOrWhiteSpace(settings.WireGuardMasterKeyFile))
                settings.WireGuardMasterKeyFile = MasterKeyFile;
            if (string.IsNullOrWhiteSpace(settings.WireGuardBind))
                settings.WireGuardBind = Bind;
            if (string.IsNullOrWhiteSpace(settings.WireGuardPublicEndpoint))
                settings.WireGuardPublicEndpoint = GetPublicEndpoint();
        }

        internal static string GetPublicEndpoint()
        {
            string fallback = null;
            try
            {
                foreach (NetworkInterface adapter in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (adapter.OperationalStatus != OperationalStatus.Up ||
                        adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                        adapter.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;
                    IPInterfaceProperties properties = adapter.GetIPProperties();
                    foreach (UnicastIPAddressInformation item in properties.UnicastAddresses)
                    {
                        IPAddress address = item.Address;
                        byte[] bytes;
                        if (address.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(address)) continue;
                        bytes = address.GetAddressBytes();
                        if (bytes[0] == 169 && bytes[1] == 254) continue;
                        if (bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)) continue;
                        if (fallback == null) fallback = address.ToString();
                        if (properties.GatewayAddresses.Any(delegate(GatewayIPAddressInformation gateway)
                            { return gateway.Address.AddressFamily == AddressFamily.InterNetwork && !gateway.Address.Equals(IPAddress.Any); }))
                            return address + ":" + Port;
                    }
                }
            }
            catch (NetworkInformationException) { }
            catch (SocketException) { }
            if (!string.IsNullOrWhiteSpace(fallback)) return fallback + ":" + Port;
            try
            {
                string host = Dns.GetHostName();
                if (!string.IsNullOrWhiteSpace(host) && Uri.CheckHostName(host) != UriHostNameType.Unknown)
                    return host + ":" + Port;
            }
            catch (SocketException) { }
            return IPAddress.Loopback + ":" + Port;
        }

        internal static void EnsureDefaultMasterKey(string configPath, ServerConfigSettings settings)
        {
            if (!settings.WireGuardEnabled ||
                !string.Equals(settings.WireGuardMasterKeyFile.Trim(), MasterKeyFile, StringComparison.OrdinalIgnoreCase)) return;
            string keyPath = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(configPath)), MasterKeyFile);
            if (File.Exists(keyPath))
            {
                if (new FileInfo(keyPath).Length != 32)
                    throw new InvalidOperationException("WireGuard 主密钥文件必须是 32 字节：" + keyPath);
                return;
            }
            byte[] key = new byte[32];
            using (var random = new RNGCryptoServiceProvider()) random.GetBytes(key);
            try
            {
                using (var stream = new FileStream(keyPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    stream.Write(key, 0, key.Length);
                    stream.Flush(true);
                }
            }
            catch (IOException)
            {
                if (!File.Exists(keyPath) || new FileInfo(keyPath).Length != 32) throw;
            }
        }
    }

    internal static class ConfigFileEditor
    {
        private static readonly string[] OrderedKeys =
        {
            "tcp_bind", "quic_bind", "ws_bind", "network", "white_list", "lease_duration", "persistence",
            "web_bind", "username", "password", "cert", "key",
            "wireguard_master_key_file", "wireguard_bind", "wireguard_public_endpoint", "wireguard_dns", "wireguard_max_active_peers",
            "server_quic_bind", "peer_servers", "server_token"
        };

        internal static ServerConfigSettings Load(string path)
        {
            if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
                throw new FileNotFoundException("配置文件不存在。", path);

            Dictionary<string, string> values = ReadRootValues(path);
            string wireGuardKey = GetString(values, "wireguard_master_key_file");
            string wireGuardBind = GetString(values, "wireguard_bind");
            string wireGuardEndpoint = GetString(values, "wireguard_public_endpoint");
            var settings = new ServerConfigSettings
            {
                TcpBind = GetString(values, "tcp_bind") ?? string.Empty,
                QuicBind = GetString(values, "quic_bind") ?? string.Empty,
                WsBind = GetString(values, "ws_bind") ?? string.Empty,
                Network = GetString(values, "network") ?? "10.26.0.0/24",
                WhiteList = GetStringList(values, "white_list"),
                LeaseDuration = GetUnsigned(values, "lease_duration", 86400),
                Persistence = GetBoolean(values, "persistence", false),
                WebBind = GetString(values, "web_bind"),
                Username = GetString(values, "username"),
                Password = GetString(values, "password"),
                WireGuardMasterKeyFile = wireGuardKey,
                WireGuardBind = wireGuardBind,
                WireGuardPublicEndpoint = wireGuardEndpoint,
                WireGuardDns = GetStringList(values, "wireguard_dns"),
                WireGuardMaxActivePeers = (int)Math.Min(int.MaxValue, GetUnsigned(values, "wireguard_max_active_peers", 4096)),
                ServerQuicBind = GetString(values, "server_quic_bind"),
                PeerServers = GetStringList(values, "peer_servers"),
                ServerToken = GetString(values, "server_token"),
                CertificateFile = GetString(values, "cert"),
                PrivateKeyFile = GetString(values, "key")
            };
            settings.WebEnabled = !string.IsNullOrWhiteSpace(settings.WebBind) ||
                !string.IsNullOrWhiteSpace(settings.Username) || !string.IsNullOrWhiteSpace(settings.Password);
            settings.WireGuardEnabled = !string.IsNullOrWhiteSpace(wireGuardKey) ||
                !string.IsNullOrWhiteSpace(wireGuardBind) || !string.IsNullOrWhiteSpace(wireGuardEndpoint);
            WireGuardDefaults.ApplyMissing(settings);
            settings.ServerQuicEnabled = !string.IsNullOrWhiteSpace(settings.ServerQuicBind) ||
                settings.PeerServers.Count > 0 || !string.IsNullOrWhiteSpace(settings.ServerToken);
            return settings;
        }

        internal static string Save(string path, ServerConfigSettings settings)
        {
            if (settings == null) throw new ArgumentNullException("settings");
            WireGuardDefaults.EnsureDefaultMasterKey(path, settings);
            string original = File.ReadAllText(path, Encoding.UTF8);
            string newline = original.Contains("\r\n") ? "\r\n" : "\n";
            List<string> lines = File.ReadAllLines(path, Encoding.UTF8).ToList();
            Dictionary<string, string> rendered = Render(settings);
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int rootEnd = lines.FindIndex(delegate(string line) { return Regex.IsMatch(line, "^\\s*\\["); });
            if (rootEnd < 0) rootEnd = lines.Count;

            var updated = new List<string>();
            for (int index = 0; index < rootEnd; index++)
            {
                string key;
                if (!TryReadRootKey(lines[index], out key) || !OrderedKeys.Contains(key, StringComparer.OrdinalIgnoreCase))
                {
                    updated.Add(lines[index]);
                    continue;
                }
                string value;
                if (!seen.Add(key) || !rendered.TryGetValue(key, out value)) continue;
                string comment = ReadInlineComment(lines[index]);
                updated.Add(key + " = " + value + (string.IsNullOrEmpty(comment) ? string.Empty : " " + comment));
            }

            var missing = new List<string>();
            foreach (string key in OrderedKeys)
            {
                string value;
                if (!seen.Contains(key) && rendered.TryGetValue(key, out value))
                    missing.Add(key + " = " + value);
            }
            if (missing.Count > 0)
            {
                if (updated.Count > 0 && !string.IsNullOrWhiteSpace(updated[updated.Count - 1])) updated.Add(string.Empty);
                updated.AddRange(missing);
                if (rootEnd < lines.Count) updated.Add(string.Empty);
            }
            for (int index = rootEnd; index < lines.Count; index++) updated.Add(lines[index]);

            string directory = Path.GetDirectoryName(path);
            string backupDirectory = Path.Combine(directory, ".backups");
            Directory.CreateDirectory(backupDirectory);
            string backupPath = Path.Combine(backupDirectory,
                "config.toml.pre-gui-" + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff") + ".bak");
            string temporaryPath = path + ".gui-" + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllText(temporaryPath, string.Join(newline, updated) + newline, new UTF8Encoding(false));
                File.Replace(temporaryPath, path, backupPath, true);
                return backupPath;
            }
            finally
            {
                if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
            }
        }

        private static Dictionary<string, string> ReadRootValues(string path)
        {
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string line in File.ReadAllLines(path, Encoding.UTF8))
            {
                if (Regex.IsMatch(line, "^\\s*\\[")) break;
                Match match = Regex.Match(line, "^\\s*([A-Za-z0-9_-]+)\\s*=\\s*(.*)$");
                if (!match.Success) continue;
                values[match.Groups[1].Value] = RemoveInlineComment(match.Groups[2].Value).Trim();
            }
            return values;
        }

        private static Dictionary<string, string> Render(ServerConfigSettings settings)
        {
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "network", Quote(settings.Network) },
                { "white_list", QuoteList(settings.WhiteList) },
                { "lease_duration", settings.LeaseDuration.ToString() },
                { "persistence", settings.Persistence ? "true" : "false" },
                { "wireguard_max_active_peers", settings.WireGuardMaxActivePeers.ToString() }
            };
            AddOptional(values, "tcp_bind", settings.TcpBind);
            AddOptional(values, "quic_bind", settings.QuicBind);
            AddOptional(values, "ws_bind", settings.WsBind);
            AddOptional(values, "cert", settings.CertificateFile);
            AddOptional(values, "key", settings.PrivateKeyFile);
            if (settings.WebEnabled)
            {
                values["web_bind"] = Quote(settings.WebBind);
                values["username"] = Quote(settings.Username);
                values["password"] = Quote(settings.Password);
            }
            if (settings.WireGuardEnabled)
            {
                values["wireguard_master_key_file"] = Quote(settings.WireGuardMasterKeyFile);
                values["wireguard_bind"] = Quote(settings.WireGuardBind);
                AddOptional(values, "wireguard_public_endpoint", settings.WireGuardPublicEndpoint);
                values["wireguard_dns"] = QuoteList(settings.WireGuardDns);
            }
            if (settings.ServerQuicEnabled)
            {
                values["server_quic_bind"] = Quote(settings.ServerQuicBind);
                values["peer_servers"] = QuoteList(settings.PeerServers);
                values["server_token"] = Quote(settings.ServerToken);
            }
            return values;
        }

        private static void AddOptional(Dictionary<string, string> values, string key, string value)
        {
            if (!string.IsNullOrWhiteSpace(value)) values[key] = Quote(value.Trim());
        }

        private static bool TryReadRootKey(string line, out string key)
        {
            Match match = Regex.Match(line, "^\\s*([A-Za-z0-9_-]+)\\s*=");
            key = match.Success ? match.Groups[1].Value : null;
            return match.Success;
        }

        private static string ReadInlineComment(string line)
        {
            int index = FindCommentIndex(line);
            return index < 0 ? null : line.Substring(index).TrimEnd();
        }

        private static string RemoveInlineComment(string value)
        {
            int index = FindCommentIndex(value);
            return index < 0 ? value : value.Substring(0, index);
        }

        private static int FindCommentIndex(string value)
        {
            bool quoted = false;
            bool literal = false;
            bool escaped = false;
            for (int index = 0; index < value.Length; index++)
            {
                char item = value[index];
                if (escaped) { escaped = false; continue; }
                if (quoted && item == '\\') { escaped = true; continue; }
                if (!literal && item == '"') { quoted = !quoted; continue; }
                if (!quoted && item == '\'') { literal = !literal; continue; }
                if (!quoted && !literal && item == '#') return index;
            }
            return -1;
        }

        private static string GetString(Dictionary<string, string> values, string key)
        {
            string raw;
            if (!values.TryGetValue(key, out raw) || string.IsNullOrWhiteSpace(raw)) return null;
            raw = raw.Trim();
            if (raw.Length >= 2 && raw[0] == '"' && raw[raw.Length - 1] == '"')
                return Unescape(raw.Substring(1, raw.Length - 2));
            if (raw.Length >= 2 && raw[0] == '\'' && raw[raw.Length - 1] == '\'')
                return raw.Substring(1, raw.Length - 2);
            return raw;
        }

        private static List<string> GetStringList(Dictionary<string, string> values, string key)
        {
            string raw;
            var result = new List<string>();
            if (!values.TryGetValue(key, out raw)) return result;
            foreach (Match match in Regex.Matches(raw, "\"(?:\\\\.|[^\"\\\\])*\"|'[^']*'"))
            {
                string item = match.Value;
                result.Add(item[0] == '"' ? Unescape(item.Substring(1, item.Length - 2)) : item.Substring(1, item.Length - 2));
            }
            return result;
        }

        private static ulong GetUnsigned(Dictionary<string, string> values, string key, ulong fallback)
        {
            string raw;
            ulong value;
            return values.TryGetValue(key, out raw) && ulong.TryParse(raw, out value) ? value : fallback;
        }

        private static bool GetBoolean(Dictionary<string, string> values, string key, bool fallback)
        {
            string raw;
            bool value;
            return values.TryGetValue(key, out raw) && bool.TryParse(raw, out value) ? value : fallback;
        }

        private static string Quote(string value)
        {
            string safe = value ?? string.Empty;
            return "\"" + safe.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n") + "\"";
        }

        private static string QuoteList(IEnumerable<string> values)
        {
            return "[" + string.Join(", ", (values ?? Enumerable.Empty<string>()).Select(Quote)) + "]";
        }

        private static string Unescape(string value)
        {
            var result = new StringBuilder();
            bool escaped = false;
            foreach (char item in value)
            {
                if (!escaped)
                {
                    if (item == '\\') escaped = true;
                    else result.Append(item);
                    continue;
                }
                result.Append(item == 'n' ? '\n' : item == 'r' ? '\r' : item == 't' ? '\t' : item);
                escaped = false;
            }
            if (escaped) result.Append('\\');
            return result.ToString();
        }
    }

    internal sealed class ConfigSettingsForm : Form
    {
        private const string SecretAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@$%*-_";

        private readonly TextBox tcpBindBox;
        private readonly TextBox quicBindBox;
        private readonly TextBox wsBindBox;
        private readonly TextBox networkBox;
        private readonly TextBox whiteListBox;
        private readonly TextBox leaseBox;
        private readonly CheckBox persistenceBox;
        private readonly CheckBox webEnabledBox;
        private readonly TextBox webBindBox;
        private readonly TextBox usernameBox;
        private readonly TextBox passwordBox;
        private readonly CheckBox wireGuardEnabledBox;
        private readonly TextBox wireGuardKeyBox;
        private readonly TextBox wireGuardBindBox;
        private readonly TextBox wireGuardPublicBox;
        private readonly TextBox wireGuardDnsBox;
        private readonly TextBox wireGuardMaxBox;
        private readonly CheckBox serverQuicEnabledBox;
        private readonly TextBox serverQuicBindBox;
        private readonly TextBox peerServersBox;
        private readonly TextBox serverTokenBox;
        private readonly TextBox certificateBox;
        private readonly TextBox privateKeyBox;
        private readonly List<Control> webSettingControls = new List<Control>();
        private readonly List<Control> wireGuardSettingControls = new List<Control>();
        private readonly List<Control> serverQuicSettingControls = new List<Control>();

        internal ServerConfigSettings Settings { get; private set; }
        internal bool RestartRequested { get; private set; }

        internal ConfigSettingsForm(
            ServerConfigSettings settings,
            string configPath,
            bool serviceInstalled,
            bool serviceRunning,
            bool darkTheme)
        {
            Text = "VNTS2 配置设置";
            ClientSize = new Size(960, 800);
            MinimumSize = new Size(900, 740);
            StartPosition = FormStartPosition.CenterParent;
            Font = new Font("Microsoft YaHei UI", 10.5F);
            Icon = ApplicationIcon.Load();
            AutoScaleMode = AutoScaleMode.Dpi;

            var header = new Panel { Dock = DockStyle.Top, Height = 84, Tag = "Header" };
            header.Controls.Add(new Label
            {
                Text = "服务配置",
                Font = new Font("Microsoft YaHei UI", 19F, FontStyle.Bold),
                Location = new Point(26, 9),
                AutoSize = true,
                Tag = "HeaderTitle"
            });
            header.Controls.Add(new Label
            {
                Text = "通过设置项安全修改 config.toml；未知配置和自定义网络不会丢失",
                Location = new Point(29, 50),
                AutoSize = true,
                Tag = "HeaderSubtitle"
            });
            Controls.Add(header);

            var footer = new Panel { Dock = DockStyle.Bottom, Height = 82, Padding = new Padding(20, 10, 20, 12) };
            var pathLabel = new Label
            {
                Text = "配置：" + configPath,
                Location = new Point(22, 12),
                Size = new Size(540, 26),
                AutoEllipsis = true,
                Tag = "Muted"
            };
            footer.Controls.Add(pathLabel);
            footer.Controls.Add(new Label
            {
                Text = "保存前会自动备份到 data\\.backups",
                Location = new Point(22, 44),
                AutoSize = true,
                Tag = "Muted"
            });
            var cancelButton = new Button
            {
                Text = "取消",
                Size = new Size(104, 42),
                Location = new Point(826, 20),
                DialogResult = DialogResult.Cancel
            };
            footer.Controls.Add(cancelButton);
            var applyButton = new Button
            {
                Text = serviceRunning ? "保存并重启" : "保存并启动",
                Size = new Size(136, 42),
                Location = new Point(678, 20),
                Enabled = serviceInstalled,
                Tag = "Accent"
            };
            applyButton.Click += delegate { AcceptSettings(true); };
            footer.Controls.Add(applyButton);
            var saveButton = new Button
            {
                Text = "仅保存",
                Size = new Size(104, 42),
                Location = new Point(562, 20)
            };
            saveButton.Click += delegate { AcceptSettings(false); };
            footer.Controls.Add(saveButton);
            footer.Resize += delegate
            {
                cancelButton.Left = footer.ClientSize.Width - 20 - cancelButton.Width;
                applyButton.Left = cancelButton.Left - 12 - applyButton.Width;
                saveButton.Left = applyButton.Left - 12 - saveButton.Width;
                pathLabel.Width = Math.Max(220, saveButton.Left - pathLabel.Left - 18);
            };
            Controls.Add(footer);

            var body = new Panel { Dock = DockStyle.Fill, Padding = new Padding(20, 18, 20, 14) };
            var tabs = new TabControl { Dock = DockStyle.Fill };
            ConfigureTabs(tabs, darkTheme);
            body.Controls.Add(tabs);
            Controls.Add(body);
            body.BringToFront();

            TabPage basicPage = CreatePage("基础网络");
            tcpBindBox = AddTextField(basicPage, "TCP 监听", settings.TcpBind, 22, "例如 0.0.0.0:29872；留空可关闭此监听");
            quicBindBox = AddTextField(basicPage, "QUIC 监听", settings.QuicBind, 102, "局域网或公网客户端使用的 UDP 监听地址");
            wsBindBox = AddTextField(basicPage, "WebSocket 监听", settings.WsBind, 182, "例如 0.0.0.0:29872；留空可关闭此监听");
            networkBox = AddTextField(basicPage, "默认虚拟网段", settings.Network, 262, "IPv4 CIDR，例如 10.26.0.0/24");
            AddLabel(basicPage, "IP 租期（秒）", 342);
            leaseBox = new TextBox
            {
                Location = new Point(205, 337),
                Size = new Size(210, 36),
                AutoSize = false,
                Font = new Font("Segoe UI", 11F),
                Text = Math.Min(315360000, Math.Max(60, settings.LeaseDuration)).ToString(),
                MaxLength = 9
            };
            RestrictToDigits(leaseBox);
            basicPage.Controls.Add(leaseBox);
            persistenceBox = new CheckBox
            {
                Text = "启用持久化（服务重启后保留网络状态）",
                Location = new Point(205, 394),
                AutoSize = true,
                Checked = settings.Persistence
            };
            basicPage.Controls.Add(persistenceBox);
            AddLabel(basicPage, "白名单", 432);
            whiteListBox = new TextBox
            {
                Location = new Point(205, 427),
                Size = new Size(670, 68),
                Multiline = true,
                ScrollBars = ScrollBars.Vertical,
                Font = new Font("Segoe UI", 11F),
                Text = string.Join(Environment.NewLine, settings.WhiteList)
            };
            basicPage.Controls.Add(whiteListBox);
            FitToRight(basicPage, whiteListBox, 24);
            AddHint(basicPage, "每行一项；留空表示不限制", 205, 501);
            tabs.TabPages.Add(basicPage);

            TabPage webPage = CreatePage("Web 管理");
            webEnabledBox = new CheckBox
            {
                Text = "启用本地 Web 管理接口",
                Location = new Point(24, 22),
                AutoSize = true,
                Checked = settings.WebEnabled
            };
            webPage.Controls.Add(webEnabledBox);
            AddHint(webPage, "为安全起见只允许 127.0.0.1、localhost 或 [::1]，局域网管理请使用主界面的网络管理功能。", 24, 58);
            webBindBox = AddTextField(webPage, "监听地址", settings.WebBind ?? "127.0.0.1:29871", 106, "推荐 127.0.0.1:29871");
            usernameBox = AddTextField(webPage, "管理员账号", settings.Username ?? "admin", 186, "用于 Web 控制台和本机管理接口认证");
            passwordBox = AddSecretField(webPage, "管理员密码", settings.Password, 266, webSettingControls);
            var showPassword = new CheckBox { Text = "显示密码", Location = new Point(205, 318), AutoSize = true };
            showPassword.CheckedChanged += delegate { passwordBox.UseSystemPasswordChar = !showPassword.Checked; };
            webPage.Controls.Add(showPassword);
            webSettingControls.Add(showPassword);
            webSettingControls.Add(webBindBox);
            webSettingControls.Add(usernameBox);
            AddHint(webPage, "密码不能为空；程序不会把密码写入运行日志。", 205, 354);
            tabs.TabPages.Add(webPage);

            TabPage wireGuardPage = CreatePage("WireGuard");
            wireGuardEnabledBox = new CheckBox
            {
                Text = "启用 WireGuard 接入",
                Location = new Point(24, 22),
                AutoSize = true,
                Checked = settings.WireGuardEnabled
            };
            wireGuardPage.Controls.Add(wireGuardEnabledBox);
            wireGuardKeyBox = AddTextField(wireGuardPage, "主密钥文件", settings.WireGuardMasterKeyFile, 82, "建议使用 data 内的相对路径，例如 wireguard-master.key");
            wireGuardBindBox = AddTextField(wireGuardPage, "UDP 监听", settings.WireGuardBind, 162, "默认 0.0.0.0:41194，可避开 Windows 常见排除端口");
            wireGuardPublicBox = AddTextField(wireGuardPage, "外部访问地址", settings.WireGuardPublicEndpoint, 242, "客户端实际访问的域名或 IP:端口；一键生成配置时使用");
            AddLabel(wireGuardPage, "最大活跃 Peer", 322);
            wireGuardMaxBox = new TextBox
            {
                Location = new Point(205, 317),
                Size = new Size(210, 36),
                AutoSize = false,
                Font = new Font("Segoe UI", 11F),
                Text = Math.Min(1000000, Math.Max(1, settings.WireGuardMaxActivePeers)).ToString(),
                MaxLength = 7
            };
            RestrictToDigits(wireGuardMaxBox);
            wireGuardPage.Controls.Add(wireGuardMaxBox);
            AddLabel(wireGuardPage, "默认 DNS", 402);
            wireGuardDnsBox = new TextBox
            {
                Location = new Point(205, 397),
                Size = new Size(670, 68),
                Multiline = true,
                ScrollBars = ScrollBars.Vertical,
                Font = new Font("Segoe UI", 11F),
                Text = string.Join(Environment.NewLine, settings.WireGuardDns)
            };
            wireGuardPage.Controls.Add(wireGuardDnsBox);
            FitToRight(wireGuardPage, wireGuardDnsBox, 24);
            AddHint(wireGuardPage, "每行或逗号分隔一个 IPv4/IPv6 DNS，最多 4 个；Peer 可在 Web/Flutter 管理端覆盖。", 205, 472);
            wireGuardSettingControls.AddRange(new Control[] { wireGuardKeyBox, wireGuardBindBox, wireGuardPublicBox, wireGuardMaxBox, wireGuardDnsBox });
            tabs.TabPages.Add(wireGuardPage);

            TabPage serverPage = CreatePage("服务器互联");
            serverQuicEnabledBox = new CheckBox
            {
                Text = "启用服务器 QUIC 互联",
                Location = new Point(24, 22),
                AutoSize = true,
                Checked = settings.ServerQuicEnabled
            };
            serverPage.Controls.Add(serverQuicEnabledBox);
            serverQuicBindBox = AddTextField(serverPage, "QUIC 监听", settings.ServerQuicBind, 82, "例如 0.0.0.0:29873");
            serverTokenBox = AddSecretField(serverPage, "服务器令牌", settings.ServerToken, 162, serverQuicSettingControls);
            AddLabel(serverPage, "Peer 服务器", 246);
            peerServersBox = new TextBox
            {
                Location = new Point(205, 241),
                Size = new Size(670, 132),
                Multiline = true,
                ScrollBars = ScrollBars.Vertical,
                Font = new Font("Segoe UI", 11F),
                Text = string.Join(Environment.NewLine, settings.PeerServers)
            };
            serverPage.Controls.Add(peerServersBox);
            FitToRight(serverPage, peerServersBox, 24);
            serverQuicSettingControls.Add(serverQuicBindBox);
            serverQuicSettingControls.Add(peerServersBox);
            AddHint(serverPage, "每行一个域名或 IP:端口；局域网测试可填写另一台服务器的局域网地址。", 205, 381);
            tabs.TabPages.Add(serverPage);

            TabPage advancedPage = CreatePage("高级安全");
            certificateBox = AddTextField(advancedPage, "TLS 证书文件", settings.CertificateFile, 28, "可选；证书与私钥必须同时填写");
            privateKeyBox = AddTextField(advancedPage, "TLS 私钥文件", settings.PrivateKeyFile, 108, "建议使用 data 内的相对路径并限制文件权限");
            advancedPage.Controls.Add(new Label
            {
                Text = "自定义网络",
                Location = new Point(24, 214),
                Size = new Size(160, 30),
                Font = new Font("Microsoft YaHei UI", 11F, FontStyle.Bold)
            });
            var customNetworkNote = new Label
            {
                Text = "[custom_nets] 由主界面的“网络管理”功能维护。本弹窗保存时会完整保留该区段，\r\n同时保留程序未来新增但当前界面尚未识别的配置项。",
                Location = new Point(205, 211),
                Size = new Size(670, 68),
                Tag = "Muted"
            };
            advancedPage.Controls.Add(customNetworkNote);
            FitToRight(advancedPage, customNetworkNote, 24);
            tabs.TabPages.Add(advancedPage);

            webEnabledBox.CheckedChanged += delegate { SetEnabled(webSettingControls, webEnabledBox.Checked); };
            wireGuardEnabledBox.CheckedChanged += delegate
            {
                if (wireGuardEnabledBox.Checked)
                {
                    if (string.IsNullOrWhiteSpace(wireGuardKeyBox.Text)) wireGuardKeyBox.Text = WireGuardDefaults.MasterKeyFile;
                    if (string.IsNullOrWhiteSpace(wireGuardBindBox.Text)) wireGuardBindBox.Text = WireGuardDefaults.Bind;
                    if (string.IsNullOrWhiteSpace(wireGuardPublicBox.Text)) wireGuardPublicBox.Text = WireGuardDefaults.GetPublicEndpoint();
                }
                SetEnabled(wireGuardSettingControls, wireGuardEnabledBox.Checked);
            };
            serverQuicEnabledBox.CheckedChanged += delegate { SetEnabled(serverQuicSettingControls, serverQuicEnabledBox.Checked); };
            SetEnabled(webSettingControls, webEnabledBox.Checked);
            SetEnabled(wireGuardSettingControls, wireGuardEnabledBox.Checked);
            SetEnabled(serverQuicSettingControls, serverQuicEnabledBox.Checked);

            AcceptButton = saveButton;
            CancelButton = cancelButton;
            ThemeManager.Apply(this, darkTheme);
        }

        private static TabPage CreatePage(string text)
        {
            return new TabPage { Text = text, Padding = new Padding(8), AutoScroll = true, UseVisualStyleBackColor = false };
        }

        private static void ConfigureTabs(TabControl tabs, bool darkTheme)
        {
            tabs.Font = new Font("Microsoft YaHei UI", 10.5F, FontStyle.Bold);
            tabs.DrawMode = TabDrawMode.OwnerDrawFixed;
            tabs.SizeMode = TabSizeMode.Fixed;
            tabs.ItemSize = new Size(164, 42);
            tabs.DrawItem += delegate(object sender, DrawItemEventArgs arguments)
            {
                ThemePalette palette = ThemeManager.GetPalette(darkTheme);
                bool selected = (arguments.State & DrawItemState.Selected) == DrawItemState.Selected;
                using (var background = new SolidBrush(selected ? palette.Surface : palette.SurfaceAlt))
                    arguments.Graphics.FillRectangle(background, arguments.Bounds);
                TextRenderer.DrawText(
                    arguments.Graphics,
                    tabs.TabPages[arguments.Index].Text,
                    tabs.Font,
                    arguments.Bounds,
                    palette.Text,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
            };
        }

        private static void AddLabel(Control parent, string text, int y)
        {
            parent.Controls.Add(new Label
            {
                Text = text,
                Location = new Point(24, y + 7),
                Size = new Size(165, 30),
                Font = new Font("Microsoft YaHei UI", 10.5F)
            });
        }

        private static void AddHint(Control parent, string text, int x, int y)
        {
            var hint = new Label
            {
                Text = text,
                Location = new Point(x, y),
                Size = new Size(670, 34),
                Font = new Font("Microsoft YaHei UI", 9.5F),
                Tag = "Muted"
            };
            parent.Controls.Add(hint);
            FitToRight(parent, hint, 24);
        }

        private static TextBox AddTextField(Control parent, string caption, string value, int y, string hint)
        {
            AddLabel(parent, caption, y);
            var box = new TextBox
            {
                Text = value ?? string.Empty,
                Location = new Point(205, y),
                Size = new Size(670, 36),
                AutoSize = false,
                Font = new Font("Segoe UI", 11F)
            };
            parent.Controls.Add(box);
            FitToRight(parent, box, 24);
            AddHint(parent, hint, 205, y + 40);
            return box;
        }

        private static TextBox AddSecretField(Control parent, string caption, string value, int y, List<Control> settingControls)
        {
            AddLabel(parent, caption, y);
            var box = new TextBox
            {
                Text = value ?? string.Empty,
                Location = new Point(205, y),
                Size = new Size(518, 36),
                AutoSize = false,
                Font = new Font("Segoe UI", 11F),
                UseSystemPasswordChar = true
            };
            parent.Controls.Add(box);
            var generateButton = new Button
            {
                Text = "生成强密钥",
                Location = new Point(735, y - 1),
                Size = new Size(140, 38)
            };
            generateButton.Click += delegate { box.Text = GenerateSecret(32); box.Focus(); box.SelectionStart = box.Text.Length; };
            parent.Controls.Add(generateButton);
            FitSecretRow(parent, box, generateButton, 24);
            settingControls.Add(box);
            settingControls.Add(generateButton);
            return box;
        }

        private static void FitToRight(Control parent, Control control, int rightMargin)
        {
            EventHandler resize = delegate
            {
                control.Width = Math.Max(180, parent.ClientSize.Width - control.Left - rightMargin);
            };
            parent.Resize += resize;
            resize(parent, EventArgs.Empty);
        }

        private static void FitSecretRow(Control parent, Control input, Control action, int rightMargin)
        {
            EventHandler resize = delegate
            {
                action.Left = parent.ClientSize.Width - rightMargin - action.Width;
                input.Width = Math.Max(220, action.Left - input.Left - 12);
            };
            parent.Resize += resize;
            resize(parent, EventArgs.Empty);
        }

        private static void RestrictToDigits(TextBox box)
        {
            box.KeyPress += delegate(object sender, KeyPressEventArgs arguments)
            {
                if (!char.IsControl(arguments.KeyChar) && !char.IsDigit(arguments.KeyChar))
                    arguments.Handled = true;
            };
        }

        private static ulong ParseUnsigned(string value, string caption, ulong minimum, ulong maximum)
        {
            ulong parsed;
            if (!ulong.TryParse((value ?? string.Empty).Trim(), out parsed) || parsed < minimum || parsed > maximum)
                throw new InvalidOperationException(caption + "必须是 " + minimum + " 到 " + maximum + " 之间的整数。");
            return parsed;
        }

        private static string GenerateSecret(int length)
        {
            var bytes = new byte[length];
            using (var random = new RNGCryptoServiceProvider()) random.GetBytes(bytes);
            var result = new char[length];
            for (int index = 0; index < length; index++) result[index] = SecretAlphabet[bytes[index] % SecretAlphabet.Length];
            return new string(result);
        }

        private static void SetEnabled(IEnumerable<Control> controls, bool enabled)
        {
            foreach (Control control in controls) control.Enabled = enabled;
        }

        private void AcceptSettings(bool restart)
        {
            try
            {
                ServerConfigSettings settings = CollectSettings();
                ValidateSettings(settings);
                Settings = settings;
                RestartRequested = restart;
                DialogResult = DialogResult.OK;
                Close();
            }
            catch (Exception exception)
            {
                MessageBox.Show(this, exception.Message, "配置校验失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private ServerConfigSettings CollectSettings()
        {
            return new ServerConfigSettings
            {
                TcpBind = tcpBindBox.Text.Trim(),
                QuicBind = quicBindBox.Text.Trim(),
                WsBind = wsBindBox.Text.Trim(),
                Network = networkBox.Text.Trim(),
                WhiteList = ReadLines(whiteListBox.Text),
                LeaseDuration = ParseUnsigned(leaseBox.Text, "IP 租期", 60, 315360000),
                Persistence = persistenceBox.Checked,
                WebEnabled = webEnabledBox.Checked,
                WebBind = webBindBox.Text.Trim(),
                Username = usernameBox.Text.Trim(),
                Password = passwordBox.Text,
                WireGuardEnabled = wireGuardEnabledBox.Checked,
                WireGuardMasterKeyFile = wireGuardKeyBox.Text.Trim(),
                WireGuardBind = wireGuardBindBox.Text.Trim(),
                WireGuardPublicEndpoint = wireGuardPublicBox.Text.Trim(),
                WireGuardDns = ReadDelimitedValues(wireGuardDnsBox.Text),
                WireGuardMaxActivePeers = (int)ParseUnsigned(wireGuardMaxBox.Text, "最大活跃 Peer", 1, 1000000),
                ServerQuicEnabled = serverQuicEnabledBox.Checked,
                ServerQuicBind = serverQuicBindBox.Text.Trim(),
                PeerServers = ReadLines(peerServersBox.Text),
                ServerToken = serverTokenBox.Text,
                CertificateFile = certificateBox.Text.Trim(),
                PrivateKeyFile = privateKeyBox.Text.Trim()
            };
        }

        private static List<string> ReadLines(string value)
        {
            return (value ?? string.Empty).Replace("\r\n", "\n").Split('\n')
                .Select(delegate(string item) { return item.Trim(); })
                .Where(delegate(string item) { return item.Length > 0; })
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        private static List<string> ReadDelimitedValues(string value)
        {
            return (value ?? string.Empty).Replace("\r\n", "\n").Split(new[] { '\n', ',' })
                .Select(delegate(string item) { return item.Trim(); })
                .Where(delegate(string item) { return item.Length > 0; })
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        internal static void ValidateSettings(ServerConfigSettings settings)
        {
            if (string.IsNullOrWhiteSpace(settings.TcpBind) && string.IsNullOrWhiteSpace(settings.QuicBind) && string.IsNullOrWhiteSpace(settings.WsBind))
                throw new InvalidOperationException("TCP、QUIC、WebSocket 至少需要启用一个监听地址。");
            ValidateOptionalBind(settings.TcpBind, "TCP 监听");
            ValidateOptionalBind(settings.QuicBind, "QUIC 监听");
            ValidateOptionalBind(settings.WsBind, "WebSocket 监听");
            ValidateNetwork(settings.Network);
            ValidateSafeLines(settings.WhiteList, "白名单");

            if (settings.WebEnabled)
            {
                WebConsoleManager.ValidateLoopbackEndpoint(settings.WebBind);
                if (string.IsNullOrWhiteSpace(settings.Username)) throw new InvalidOperationException("启用 Web 管理时必须填写管理员账号。");
                if (string.IsNullOrWhiteSpace(settings.Password))
                    throw new InvalidOperationException("Web 管理密码不能为空。");
            }
            if (settings.WireGuardEnabled)
            {
                if (string.IsNullOrWhiteSpace(settings.WireGuardMasterKeyFile)) throw new InvalidOperationException("启用 WireGuard 时必须填写主密钥文件。");
                ValidateOptionalBind(settings.WireGuardBind, "WireGuard UDP 监听");
                if (string.IsNullOrWhiteSpace(settings.WireGuardBind)) throw new InvalidOperationException("启用 WireGuard 时必须填写 UDP 监听地址。");
                if (string.IsNullOrWhiteSpace(settings.WireGuardPublicEndpoint))
                    throw new InvalidOperationException("启用 WireGuard 时必须填写外部访问地址。");
                ValidateHostEndpoint(settings.WireGuardPublicEndpoint, "WireGuard 外部访问地址");
                if (settings.WireGuardPublicEndpoint.StartsWith("0.0.0.0:", StringComparison.OrdinalIgnoreCase) ||
                    settings.WireGuardPublicEndpoint.StartsWith("[::]:", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("WireGuard 外部访问地址不能使用未指定地址。");
                if (settings.WireGuardDns.Count > 4)
                    throw new InvalidOperationException("WireGuard 默认 DNS 最多允许填写 4 个地址。");
                foreach (string dns in settings.WireGuardDns)
                {
                    IPAddress address;
                    if (!IPAddress.TryParse(dns, out address))
                        throw new InvalidOperationException("WireGuard 默认 DNS 不是有效的 IPv4/IPv6 地址：" + dns);
                }
            }
            if (settings.ServerQuicEnabled)
            {
                if (string.IsNullOrWhiteSpace(settings.ServerQuicBind)) throw new InvalidOperationException("启用服务器互联时必须填写 QUIC 监听地址。");
                ValidateOptionalBind(settings.ServerQuicBind, "服务器 QUIC 监听");
                if (string.IsNullOrWhiteSpace(settings.ServerToken) || settings.ServerToken.Length < 16)
                    throw new InvalidOperationException("服务器互联令牌至少需要 16 位。");
                foreach (string endpoint in settings.PeerServers) ValidateHostEndpoint(endpoint, "Peer 服务器");
            }
            if (string.IsNullOrWhiteSpace(settings.CertificateFile) != string.IsNullOrWhiteSpace(settings.PrivateKeyFile))
                throw new InvalidOperationException("TLS 证书文件和私钥文件必须同时填写或同时留空。");
            ValidateSafeValue(settings.CertificateFile, "TLS 证书文件");
            ValidateSafeValue(settings.PrivateKeyFile, "TLS 私钥文件");
            ValidateSafeValue(settings.WireGuardMasterKeyFile, "WireGuard 主密钥文件");
        }

        private static void ValidateOptionalBind(string value, string caption)
        {
            if (!string.IsNullOrWhiteSpace(value)) ValidateEndpoint(value, caption, true);
        }

        private static void ValidateHostEndpoint(string value, string caption)
        {
            ValidateEndpoint(value, caption, false);
        }

        private static void ValidateEndpoint(string value, string caption, bool requireIp)
        {
            Match match = Regex.Match(value ?? string.Empty, "^(?:\\[([^]]+)\\]|([^:\\s]+)):(\\d{1,5})$");
            int port;
            if (!match.Success || !int.TryParse(match.Groups[3].Value, out port) || port < 1 || port > 65535)
                throw new InvalidOperationException(caption + "格式无效，应为 IP或域名:端口。");
            string host = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
            IPAddress address;
            if (requireIp && !IPAddress.TryParse(host, out address))
                throw new InvalidOperationException(caption + "必须使用有效的 IPv4 或 IPv6 地址。");
            if (!requireIp && !IPAddress.TryParse(host, out address) && Uri.CheckHostName(host) == UriHostNameType.Unknown)
                throw new InvalidOperationException(caption + "包含无效的主机名或 IP 地址。");
        }

        private static void ValidateNetwork(string value)
        {
            string[] parts = (value ?? string.Empty).Split('/');
            IPAddress address;
            int prefix;
            if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out address) || address.AddressFamily != AddressFamily.InterNetwork ||
                !int.TryParse(parts[1], out prefix) || prefix < 0 || prefix > 32)
                throw new InvalidOperationException("默认虚拟网段必须是有效的 IPv4 CIDR，例如 10.26.0.0/24。");
        }

        private static void ValidateSafeLines(IEnumerable<string> values, string caption)
        {
            foreach (string value in values) ValidateSafeValue(value, caption);
        }

        private static void ValidateSafeValue(string value, string caption)
        {
            if (!string.IsNullOrEmpty(value) && value.Any(char.IsControl))
                throw new InvalidOperationException(caption + "不能包含控制字符。");
        }
    }

    internal sealed class WebCredentialsForm : Form
    {
        internal WebCredentialsForm(WebConsoleSettings settings, bool darkTheme)
        {
            Text = "Web 控制台登录信息";
            ClientSize = new Size(560, 265);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            Font = new Font("Microsoft YaHei UI", 9F);
            Icon = ApplicationIcon.Load();

            Controls.Add(new Label
            {
                Text = "Web 控制台已安全启用。请保存登录信息，密码不会写入操作日志。",
                Location = new Point(24, 20),
                Size = new Size(510, 26)
            });
            AddField("地址", "http://" + settings.Endpoint + "/", 58);
            AddField("用户名", settings.Username, 100);
            TextBox passwordBox = AddField("密码", settings.Password, 142);

            var copyButton = new Button
            {
                Text = "复制密码",
                Location = new Point(262, 205),
                Size = new Size(120, 36)
            };
            copyButton.Click += delegate
            {
                Clipboard.SetText(passwordBox.Text);
                copyButton.Text = "已复制";
            };
            Controls.Add(copyButton);

            var openButton = new Button
            {
                Text = "打开控制台",
                Location = new Point(398, 205),
                Size = new Size(132, 36),
                DialogResult = DialogResult.OK
            };
            Controls.Add(openButton);
            AcceptButton = openButton;
            ThemeManager.Apply(this, darkTheme);
        }

        private TextBox AddField(string caption, string value, int y)
        {
            Controls.Add(new Label
            {
                Text = caption,
                Location = new Point(24, y + 5),
                Size = new Size(72, 26)
            });
            var box = new TextBox
            {
                Text = value,
                Location = new Point(100, y),
                Size = new Size(430, 28),
                ReadOnly = true,
                Font = new Font("Consolas", 10F)
            };
            Controls.Add(box);
            return box;
        }
    }

    internal sealed class ApiEnvelope<T>
    {
        public int code { get; set; }
        public string msg { get; set; }
        public T data { get; set; }
    }

    internal sealed class LoginData
    {
        public string token { get; set; }
    }

    internal sealed class ListenerStatusData
    {
        public string vnt_quic { get; set; }
    }

    internal sealed class ServerStatusData
    {
        public ListenerStatusData listeners { get; set; }
    }

    internal sealed class NetworkInfoData
    {
        public string network_code { get; set; }
        public string gateway { get; set; }
        public int netmask { get; set; }
        public string net { get; set; }
        public long lease_duration { get; set; }
        public string source { get; set; }
        public int all_count { get; set; }
        public int online_count { get; set; }
    }

    internal sealed class LocalApiClient
    {
        private readonly string baseUrl;
        private readonly string username;
        private readonly string password;
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();
        private string token;

        private LocalApiClient(string endpoint, string usernameValue, string passwordValue)
        {
            baseUrl = WebConsoleManager.ToUrl(endpoint);
            username = usernameValue;
            password = passwordValue;
        }

        internal static LocalApiClient FromConfig(string configPath)
        {
            if (string.IsNullOrWhiteSpace(configPath) || !File.Exists(configPath))
                throw new FileNotFoundException("本地管理接口配置不存在。", configPath);
            string endpoint = WebConsoleManager.ReadEndpoint(configPath);
            if (string.IsNullOrWhiteSpace(endpoint))
                throw new InvalidOperationException("本地管理接口尚未启用。");
            WebConsoleManager.ValidateLoopbackEndpoint(endpoint);
            string username = WebConsoleManager.ReadRootString(configPath, "username");
            string password = WebConsoleManager.ReadRootString(configPath, "password");
            if (string.IsNullOrWhiteSpace(username) || string.IsNullOrEmpty(password))
                throw new InvalidOperationException("data\\config.toml 缺少本地管理账号或密码。");
            return new LocalApiClient(endpoint, username, password);
        }

        internal ServerStatusData GetServerStatus()
        {
            return SendAuthorized<ServerStatusData>("GET", "api/status", null);
        }

        internal List<NetworkInfoData> GetNetworks()
        {
            List<NetworkInfoData> value = SendAuthorized<List<NetworkInfoData>>("GET", "api/networks", null);
            return value ?? new List<NetworkInfoData>();
        }

        internal void CreateNetwork(string networkCode, string gateway, int netmask, long? leaseDuration)
        {
            var body = new Dictionary<string, object>
            {
                { "network_code", networkCode },
                { "gateway", gateway },
                { "netmask", netmask }
            };
            if (leaseDuration.HasValue) body["lease_duration"] = leaseDuration.Value;
            SendAuthorized<object>("POST", "api/networks", body);
        }

        internal void UpdateNetwork(string networkCode, string gateway, int netmask, long leaseDuration)
        {
            var body = new Dictionary<string, object>
            {
                { "gateway", gateway },
                { "netmask", netmask },
                { "lease_duration", leaseDuration }
            };
            SendAuthorized<object>("PUT", "api/networks/" + Uri.EscapeDataString(networkCode), body);
        }

        internal void DeleteNetwork(string networkCode)
        {
            SendAuthorized<object>("DELETE", "api/networks/" + Uri.EscapeDataString(networkCode), null);
        }

        private T SendAuthorized<T>(string method, string relativePath, object body)
        {
            for (int attempt = 0; attempt < 2; attempt++)
            {
                if (string.IsNullOrEmpty(token)) Login();
                try
                {
                    return SendRequest<T>(method, relativePath, body, token);
                }
                catch (UnauthorizedAccessException)
                {
                    token = null;
                    if (attempt > 0) throw;
                }
            }
            throw new UnauthorizedAccessException("本地管理会话已失效。");
        }

        private void Login()
        {
            var body = new Dictionary<string, object>
            {
                { "username", username },
                { "password", password }
            };
            LoginData login = SendRequest<LoginData>("POST", "api/login", body, null);
            if (login == null || string.IsNullOrWhiteSpace(login.token))
                throw new InvalidOperationException("本地管理接口未返回有效登录令牌。");
            token = login.token;
        }

        private T SendRequest<T>(string method, string relativePath, object body, string bearerToken)
        {
            var request = (HttpWebRequest)WebRequest.Create(new Uri(new Uri(baseUrl), relativePath));
            request.Method = method;
            request.Accept = "application/json";
            request.ContentType = "application/json; charset=utf-8";
            request.UserAgent = "VNTS2-Manager/2.0";
            request.Timeout = 12000;
            request.ReadWriteTimeout = 12000;
            request.KeepAlive = false;
            request.Proxy = null;
            request.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
            if (!string.IsNullOrWhiteSpace(bearerToken))
                request.Headers[HttpRequestHeader.Authorization] = "Bearer " + bearerToken;

            if (body != null)
            {
                byte[] bytes = Encoding.UTF8.GetBytes(serializer.Serialize(body));
                request.ContentLength = bytes.Length;
                using (Stream stream = request.GetRequestStream()) stream.Write(bytes, 0, bytes.Length);
            }
            else
            {
                request.ContentLength = 0;
            }

            try
            {
                using (var response = (HttpWebResponse)request.GetResponse())
                {
                    return ReadEnvelope<T>(response);
                }
            }
            catch (WebException exception)
            {
                var response = exception.Response as HttpWebResponse;
                if (response == null)
                    throw new InvalidOperationException("无法连接本机管理接口，请确认 VNTS2 服务正在运行。", exception);
                using (response)
                {
                    string json = ReadBody(response);
                    throw CreateApiException((int)response.StatusCode, json);
                }
            }
        }

        private T ReadEnvelope<T>(HttpWebResponse response)
        {
            string json = ReadBody(response);
            Dictionary<string, object> raw;
            try
            {
                raw = serializer.Deserialize<Dictionary<string, object>>(json);
            }
            catch (Exception exception)
            {
                throw new InvalidOperationException("本地管理接口返回了无法识别的数据：" + exception.Message, exception);
            }
            object codeValue;
            int code = raw != null && raw.TryGetValue("code", out codeValue) ? Convert.ToInt32(codeValue) : (int)response.StatusCode;
            if (code != 200) throw CreateApiException(code, json);
            if (typeof(T) == typeof(object)) return default(T);
            ApiEnvelope<T> envelope;
            try
            {
                envelope = serializer.Deserialize<ApiEnvelope<T>>(json);
            }
            catch (Exception exception)
            {
                throw new InvalidOperationException("本地管理接口数据结构不匹配：" + exception.Message, exception);
            }
            if (envelope == null) throw new InvalidOperationException("本地管理接口未返回数据。");
            return envelope.data;
        }

        private static string ReadBody(HttpWebResponse response)
        {
            using (Stream stream = response.GetResponseStream())
            using (var reader = new StreamReader(stream, Encoding.UTF8, true))
                return reader.ReadToEnd();
        }

        private Exception CreateApiException(int status, string json)
        {
            string message = null;
            try
            {
                ApiEnvelope<object> envelope = serializer.Deserialize<ApiEnvelope<object>>(json);
                if (envelope != null) message = envelope.msg;
            }
            catch { }
            if (status == 401)
                return new UnauthorizedAccessException(string.IsNullOrWhiteSpace(message) ? "本地管理账号或密码错误。" : message);
            string title = status == 400 ? "请求参数错误" :
                status == 404 ? "资源不存在" :
                status == 409 ? "操作冲突" :
                status == 503 ? "服务暂不可用" : "管理接口请求失败";
            return new InvalidOperationException(string.IsNullOrWhiteSpace(message) ? title : title + "：" + message);
        }
    }

    internal sealed class GuiSettingsData
    {
        public string quic_endpoint { get; set; }
        public string theme { get; set; }
        public string close_behavior { get; set; }
        public string startup_behavior { get; set; }
    }

    internal static class GuiBehavior
    {
        internal const string MinimizeToTray = "minimize_to_tray";
        internal const string StopServiceAndExit = "stop_service_and_exit";
        internal const string StartupDisabled = "disabled";
        internal const string StartupNormal = "normal";
        internal const string StartupSilent = "silent";

        internal static string NormalizeClose(string value)
        {
            return string.Equals(value, StopServiceAndExit, StringComparison.OrdinalIgnoreCase)
                ? StopServiceAndExit
                : MinimizeToTray;
        }

        internal static string NormalizeStartup(string value)
        {
            if (string.Equals(value, StartupNormal, StringComparison.OrdinalIgnoreCase)) return StartupNormal;
            if (string.Equals(value, StartupSilent, StringComparison.OrdinalIgnoreCase)) return StartupSilent;
            return StartupDisabled;
        }

        internal static string CloseLabel(string value)
        {
            return NormalizeClose(value) == StopServiceAndExit ? "关闭服务并退出" : "最小化到托盘";
        }

        internal static string StartupLabel(string value)
        {
            value = NormalizeStartup(value);
            if (value == StartupNormal) return "开机自启（显示主窗口）";
            if (value == StartupSilent) return "开机静默自启（仅托盘运行）";
            return "不开机自启";
        }
    }

    internal static class GuiSettingsManager
    {
        internal static string LoadQuicEndpoint(string path)
        {
            GuiSettingsData data = Load(path);
            return data == null ? null : data.quic_endpoint;
        }

        internal static void SaveQuicEndpoint(string path, string endpoint)
        {
            GuiSettingsData data = Load(path) ?? new GuiSettingsData();
            data.quic_endpoint = endpoint;
            Save(path, data);
        }

        internal static string LoadTheme(string path)
        {
            GuiSettingsData data = Load(path);
            return data != null && string.Equals(data.theme, "light", StringComparison.OrdinalIgnoreCase) ? "light" : "dark";
        }

        internal static void SaveTheme(string path, string theme)
        {
            GuiSettingsData data = Load(path) ?? new GuiSettingsData();
            data.theme = string.Equals(theme, "light", StringComparison.OrdinalIgnoreCase) ? "light" : "dark";
            Save(path, data);
        }

        internal static string LoadCloseBehavior(string path)
        {
            GuiSettingsData data = Load(path);
            return GuiBehavior.NormalizeClose(data == null ? null : data.close_behavior);
        }

        internal static string LoadStartupBehavior(string path)
        {
            GuiSettingsData data = Load(path);
            return GuiBehavior.NormalizeStartup(data == null ? null : data.startup_behavior);
        }

        internal static void SaveDesktopBehavior(string path, string closeBehavior, string startupBehavior)
        {
            GuiSettingsData data = Load(path) ?? new GuiSettingsData();
            data.close_behavior = GuiBehavior.NormalizeClose(closeBehavior);
            data.startup_behavior = GuiBehavior.NormalizeStartup(startupBehavior);
            Save(path, data);
        }

        private static GuiSettingsData Load(string path)
        {
            if (!File.Exists(path)) return null;
            try
            {
                return new JavaScriptSerializer().Deserialize<GuiSettingsData>(File.ReadAllText(path));
            }
            catch (Exception exception)
            {
                throw new InvalidOperationException("GUI 设置文件无法读取：" + path, exception);
            }
        }

        private static void Save(string path, GuiSettingsData data)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string json = new JavaScriptSerializer().Serialize(data);
            File.WriteAllText(path, json, new UTF8Encoding(false));
        }
    }

    internal static class StartupTaskManager
    {
        internal const string TaskName = "VNTS2-Manager-Autostart";

        internal static void Apply(string behavior, string executablePath)
        {
            behavior = GuiBehavior.NormalizeStartup(behavior);
            if (behavior == GuiBehavior.StartupDisabled)
            {
                if (Exists()) RunChecked("删除开机自启计划任务", "/Delete", "/TN", TaskName, "/F");
                return;
            }

            string executable = Path.GetFullPath(executablePath);
            if (!File.Exists(executable)) throw new FileNotFoundException("无法创建开机自启：管理器程序不存在。", executable);
            string command = "\"" + executable + "\"" +
                (behavior == GuiBehavior.StartupSilent ? " --silent" : string.Empty);
            RunChecked(
                "保存开机自启计划任务",
                "/Create", "/TN", TaskName, "/SC", "ONLOGON", "/RL", "HIGHEST", "/F", "/TR", command);
        }

        internal static string BuildTaskCommand(string behavior, string executablePath)
        {
            behavior = GuiBehavior.NormalizeStartup(behavior);
            return "\"" + Path.GetFullPath(executablePath) + "\"" +
                (behavior == GuiBehavior.StartupSilent ? " --silent" : string.Empty);
        }

        private static bool Exists()
        {
            string ignored;
            return Run(out ignored, "/Query", "/TN", TaskName) == 0;
        }

        private static void RunChecked(string operation, params string[] arguments)
        {
            string output;
            int exitCode = Run(out output, arguments);
            if (exitCode != 0)
            {
                string message = string.IsNullOrWhiteSpace(output) ? "schtasks.exe 未返回错误详情。" : output.Trim();
                throw new InvalidOperationException(operation + "失败（退出码 " + exitCode + "）：" + message);
            }
        }

        private static int Run(out string output, params string[] arguments)
        {
            string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string executable = Path.Combine(systemDirectory, "schtasks.exe");
            var start = new ProcessStartInfo
            {
                FileName = executable,
                Arguments = string.Join(" ", arguments.Select(QuoteArgument).ToArray()),
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (Process process = Process.Start(start))
            {
                string standardOutput = process.StandardOutput.ReadToEnd();
                string standardError = process.StandardError.ReadToEnd();
                process.WaitForExit();
                output = string.IsNullOrWhiteSpace(standardError) ? standardOutput : standardError;
                return process.ExitCode;
            }
        }

        private static string QuoteArgument(string argument)
        {
            if (string.IsNullOrEmpty(argument)) return "\"\"";
            if (!argument.Any(delegate(char value) { return char.IsWhiteSpace(value) || value == '\"'; })) return argument;

            var result = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char value in argument)
            {
                if (value == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (value == '\"')
                {
                    result.Append('\\', backslashes * 2 + 1);
                    result.Append('\"');
                    backslashes = 0;
                    continue;
                }
                result.Append('\\', backslashes);
                backslashes = 0;
                result.Append(value);
            }
            result.Append('\\', backslashes * 2);
            result.Append('\"');
            return result.ToString();
        }
    }

    internal sealed class ManagerPreferencesForm : Form
    {
        private readonly ComboBox closeBehaviorBox;
        private readonly ComboBox startupBehaviorBox;

        internal ManagerPreferencesForm(string closeBehavior, string startupBehavior, bool darkTheme)
        {
            Text = "VNTS2 管理器偏好设置";
            ClientSize = new Size(680, 360);
            MinimumSize = new Size(620, 340);
            StartPosition = FormStartPosition.CenterParent;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            Font = new Font("Microsoft YaHei UI", 10F);
            Icon = ApplicationIcon.Load();
            AutoScaleMode = AutoScaleMode.Dpi;

            Controls.Add(new Label
            {
                Text = "桌面与启动行为",
                Location = new Point(28, 24),
                AutoSize = true,
                Font = new Font("Microsoft YaHei UI", 16F, FontStyle.Bold)
            });
            Controls.Add(new Label
            {
                Text = "选择关闭窗口的默认动作，以及登录 Windows 后是否自动运行管理器。",
                Location = new Point(31, 64),
                Size = new Size(610, 30),
                Tag = "Muted"
            });

            Controls.Add(new Label { Text = "默认关闭行为", Location = new Point(31, 112), AutoSize = true, Tag = "Muted" });
            closeBehaviorBox = new ComboBox
            {
                Location = new Point(31, 139),
                Size = new Size(610, 36),
                DropDownStyle = ComboBoxStyle.DropDownList,
                Font = new Font("Microsoft YaHei UI", 11F)
            };
            closeBehaviorBox.Items.AddRange(new object[] { "最小化到托盘（服务继续运行）", "关闭服务并退出" });
            closeBehaviorBox.SelectedIndex = GuiBehavior.NormalizeClose(closeBehavior) == GuiBehavior.StopServiceAndExit ? 1 : 0;
            Controls.Add(closeBehaviorBox);

            Controls.Add(new Label { Text = "开机自启行为", Location = new Point(31, 197), AutoSize = true, Tag = "Muted" });
            startupBehaviorBox = new ComboBox
            {
                Location = new Point(31, 224),
                Size = new Size(610, 36),
                DropDownStyle = ComboBoxStyle.DropDownList,
                Font = new Font("Microsoft YaHei UI", 11F)
            };
            startupBehaviorBox.Items.AddRange(new object[]
            {
                "不开机自启",
                "开机自启（登录后显示主窗口）",
                "开机静默自启（登录后仅托盘运行）"
            });
            string startup = GuiBehavior.NormalizeStartup(startupBehavior);
            startupBehaviorBox.SelectedIndex = startup == GuiBehavior.StartupNormal ? 1 : startup == GuiBehavior.StartupSilent ? 2 : 0;
            Controls.Add(startupBehaviorBox);

            var cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel, Size = new Size(100, 36), Location = new Point(431, 299) };
            var save = new Button { Text = "保存设置", DialogResult = DialogResult.OK, Size = new Size(110, 36), Location = new Point(541, 299) };
            cancel.Tag = "Button";
            save.Tag = "Accent";
            Controls.Add(cancel);
            Controls.Add(save);
            AcceptButton = save;
            CancelButton = cancel;
            ThemeManager.Apply(this, darkTheme);
        }

        internal string SelectedCloseBehavior
        {
            get { return closeBehaviorBox.SelectedIndex == 1 ? GuiBehavior.StopServiceAndExit : GuiBehavior.MinimizeToTray; }
        }

        internal string SelectedStartupBehavior
        {
            get
            {
                return startupBehaviorBox.SelectedIndex == 1 ? GuiBehavior.StartupNormal :
                    startupBehaviorBox.SelectedIndex == 2 ? GuiBehavior.StartupSilent : GuiBehavior.StartupDisabled;
            }
        }
    }

    internal sealed class ThemePalette
    {
        internal Color Background;
        internal Color Surface;
        internal Color SurfaceAlt;
        internal Color Header;
        internal Color Border;
        internal Color Text;
        internal Color Muted;
        internal Color HeaderMuted;
        internal Color Accent;
        internal Color Danger;
        internal Color Warning;
        internal Color Success;
        internal Color Selection;
        internal Color LogBackground;
    }

    internal static class ApplicationIcon
    {
        internal static Icon Load()
        {
            try
            {
                Icon icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                return icon ?? SystemIcons.Application;
            }
            catch
            {
                return SystemIcons.Application;
            }
        }
    }

    internal static class NativeTitleBar
    {
        private const int UseImmersiveDarkMode = 20;
        private const int UseImmersiveDarkModeLegacy = 19;
        private const int BorderColor = 34;
        private const int CaptionColor = 35;
        private const int TextColor = 36;
        private const int DefaultColor = -1;

        [DllImport("dwmapi.dll", PreserveSig = true)]
        private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int valueSize);

        internal static void Apply(Form form, bool dark, ThemePalette palette)
        {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                return;

            if (!form.IsHandleCreated)
            {
                form.HandleCreated += delegate { ApplyToHandle(form, dark, palette); };
                return;
            }

            ApplyToHandle(form, dark, palette);
        }

        private static void ApplyToHandle(Form form, bool dark, ThemePalette palette)
        {
            try
            {
                int enabled = dark ? 1 : 0;
                if (DwmSetWindowAttribute(form.Handle, UseImmersiveDarkMode, ref enabled, sizeof(int)) != 0)
                    DwmSetWindowAttribute(form.Handle, UseImmersiveDarkModeLegacy, ref enabled, sizeof(int));

                int caption = dark ? ToColorRef(palette.Header) : DefaultColor;
                int text = dark ? ToColorRef(palette.Text) : DefaultColor;
                int border = dark ? ToColorRef(palette.Border) : DefaultColor;
                DwmSetWindowAttribute(form.Handle, CaptionColor, ref caption, sizeof(int));
                DwmSetWindowAttribute(form.Handle, TextColor, ref text, sizeof(int));
                DwmSetWindowAttribute(form.Handle, BorderColor, ref border, sizeof(int));
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
        }

        private static int ToColorRef(Color color)
        {
            return color.R | (color.G << 8) | (color.B << 16);
        }
    }

    internal static class ThemeManager
    {
        internal static ThemePalette GetPalette(bool dark)
        {
            return dark
                ? new ThemePalette
                {
                    Background = Color.FromArgb(23, 25, 29),
                    Surface = Color.FromArgb(34, 37, 43),
                    SurfaceAlt = Color.FromArgb(43, 47, 54),
                    Header = Color.FromArgb(29, 32, 37),
                    Border = Color.FromArgb(61, 66, 76),
                    Text = Color.FromArgb(232, 235, 241),
                    Muted = Color.FromArgb(156, 166, 180),
                    HeaderMuted = Color.FromArgb(174, 183, 196),
                    Accent = Color.FromArgb(76, 141, 255),
                    Danger = Color.FromArgb(214, 90, 104),
                    Warning = Color.FromArgb(229, 166, 72),
                    Success = Color.FromArgb(71, 190, 134),
                    Selection = Color.FromArgb(49, 83, 135),
                    LogBackground = Color.FromArgb(18, 20, 24)
                }
                : new ThemePalette
                {
                    Background = Color.FromArgb(245, 247, 250),
                    Surface = Color.White,
                    SurfaceAlt = Color.FromArgb(239, 243, 248),
                    Header = Color.FromArgb(35, 42, 52),
                    Border = Color.FromArgb(214, 221, 231),
                    Text = Color.FromArgb(22, 38, 62),
                    Muted = Color.FromArgb(92, 105, 123),
                    HeaderMuted = Color.FromArgb(194, 205, 220),
                    Accent = Color.FromArgb(39, 110, 241),
                    Danger = Color.FromArgb(190, 49, 68),
                    Warning = Color.FromArgb(209, 126, 27),
                    Success = Color.FromArgb(28, 143, 88),
                    Selection = Color.FromArgb(211, 226, 251),
                    LogBackground = Color.White
                };
        }

        internal static void Apply(Control root, bool dark)
        {
            ThemePalette palette = GetPalette(dark);
            var form = root as Form;
            if (form != null)
                NativeTitleBar.Apply(form, dark, palette);
            ApplyControl(root, palette);
            root.Invalidate(true);
        }

        private static void ApplyControl(Control control, ThemePalette palette)
        {
            string role = control.Tag as string ?? string.Empty;
            bool inHeader = IsInsideHeader(control);

            var form = control as Form;
            if (form != null)
            {
                form.BackColor = palette.Background;
                form.ForeColor = palette.Text;
            }
            else if (control is GroupBox)
            {
                control.BackColor = palette.Surface;
                control.ForeColor = palette.Text;
            }
            else if (control is TableLayoutPanel || control is FlowLayoutPanel || control is Panel)
            {
                control.BackColor = role == "Header" ? palette.Header :
                    control.Parent is GroupBox ? palette.Surface : palette.Background;
                control.ForeColor = palette.Text;
            }
            else if (control is TabPage)
            {
                control.BackColor = palette.Surface;
                control.ForeColor = palette.Text;
            }

            var tabControl = control as TabControl;
            if (tabControl != null)
            {
                tabControl.BackColor = palette.Background;
                tabControl.ForeColor = palette.Text;
            }

            var label = control as Label;
            if (label != null)
            {
                label.BackColor = Color.Transparent;
                label.ForeColor = role == "HeaderTitle" ? Color.White :
                    role == "HeaderSubtitle" ? palette.HeaderMuted :
                    role == "Muted" ? palette.Muted :
                    inHeader ? Color.White : palette.Text;
            }

            var button = control as Button;
            if (button != null)
            {
                button.FlatStyle = FlatStyle.Flat;
                button.FlatAppearance.BorderSize = 1;
                button.FlatAppearance.BorderColor = role == "Accent" ? palette.Accent :
                    role == "Danger" ? palette.Danger : palette.Border;
                button.BackColor = role == "Accent" ? palette.Accent :
                    role == "Danger" ? palette.Danger : palette.SurfaceAlt;
                button.ForeColor = role == "Accent" || role == "Danger" ? Color.White : palette.Text;
            }

            var textBox = control as TextBox;
            if (textBox != null)
            {
                textBox.BackColor = palette.SurfaceAlt;
                textBox.ForeColor = palette.Text;
            }
            var richText = control as RichTextBox;
            if (richText != null)
            {
                richText.BackColor = role == "RuntimeLog" ? palette.LogBackground : palette.SurfaceAlt;
                richText.ForeColor = palette.Text;
            }
            var numeric = control as NumericUpDown;
            if (numeric != null)
            {
                numeric.BackColor = palette.SurfaceAlt;
                numeric.ForeColor = palette.Text;
            }
            var checkBox = control as CheckBox;
            if (checkBox != null)
            {
                checkBox.BackColor = Color.Transparent;
                checkBox.ForeColor = palette.Muted;
            }

            var grid = control as DataGridView;
            if (grid != null)
            {
                grid.BackgroundColor = palette.Surface;
                grid.GridColor = palette.Border;
                grid.DefaultCellStyle.BackColor = palette.Surface;
                grid.DefaultCellStyle.ForeColor = palette.Text;
                grid.DefaultCellStyle.SelectionBackColor = palette.Selection;
                grid.DefaultCellStyle.SelectionForeColor = palette.Text;
                grid.AlternatingRowsDefaultCellStyle.BackColor = palette.SurfaceAlt;
                grid.ColumnHeadersDefaultCellStyle.BackColor = palette.SurfaceAlt;
                grid.ColumnHeadersDefaultCellStyle.ForeColor = palette.Text;
            }

            foreach (Control child in control.Controls) ApplyControl(child, palette);
        }

        private static bool IsInsideHeader(Control control)
        {
            Control current = control;
            while (current != null)
            {
                if (string.Equals(current.Tag as string, "Header", StringComparison.Ordinal)) return true;
                current = current.Parent;
            }
            return false;
        }
    }

    internal static class RuntimeLogReader
    {
        private const int MaxBytes = 512 * 1024;
        private const int MaxLines = 800;

        internal static string ReadTail(string path)
        {
            if (!File.Exists(path)) return string.Empty;
            byte[] bytes;
            long start;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                start = Math.Max(0, stream.Length - MaxBytes);
                stream.Seek(start, SeekOrigin.Begin);
                bytes = new byte[(int)(stream.Length - start)];
                int offset = 0;
                while (offset < bytes.Length)
                {
                    int count = stream.Read(bytes, offset, bytes.Length - offset);
                    if (count == 0) break;
                    offset += count;
                }
                if (offset != bytes.Length) Array.Resize(ref bytes, offset);
            }
            string text = new UTF8Encoding(false, false).GetString(bytes);
            if (start > 0)
            {
                int newline = text.IndexOf('\n');
                if (newline >= 0) text = text.Substring(newline + 1);
            }
            string[] lines = text.Replace("\r\n", "\n").Split('\n');
            if (lines.Length > MaxLines) lines = lines.Skip(lines.Length - MaxLines).ToArray();
            return string.Join("\r\n", lines).TrimEnd();
        }
    }

    internal static class QuicEndpointHelper
    {
        internal static string Normalize(string value)
        {
            string endpoint = (value ?? string.Empty).Trim();
            if (endpoint.Length == 0) throw new InvalidOperationException("请输入可供客户端连接的 QUIC 地址。");
            if (endpoint.IndexOf("://", StringComparison.Ordinal) < 0) endpoint = "quic://" + endpoint;
            Uri uri;
            if (!Uri.TryCreate(endpoint, UriKind.Absolute, out uri) ||
                !string.Equals(uri.Scheme, "quic", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("QUIC 地址格式应为 quic://主机:端口。");
            if (string.IsNullOrWhiteSpace(uri.Host) || Uri.CheckHostName(uri.Host) == UriHostNameType.Unknown)
                throw new InvalidOperationException("QUIC 地址中的 IP 或域名无效。");
            if (uri.Port < 1 || uri.Port > 65535 || endpoint.LastIndexOf(':') <= endpoint.IndexOf("//", StringComparison.Ordinal) + 1)
                throw new InvalidOperationException("QUIC 地址必须包含 1 到 65535 的端口。");
            if (!string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment) ||
                (!string.IsNullOrEmpty(uri.AbsolutePath) && uri.AbsolutePath != "/"))
                throw new InvalidOperationException("QUIC 地址不能包含账号、路径、查询参数或片段。");
            string host = uri.HostNameType == UriHostNameType.IPv6 ? "[" + uri.Host + "]" : uri.Host;
            return "quic://" + host + ":" + uri.Port;
        }

        internal static string SuggestFromListener(string listener)
        {
            if (string.IsNullOrWhiteSpace(listener))
                throw new InvalidOperationException("服务端尚未启用 VNT QUIC 监听。");
            Uri uri;
            if (!Uri.TryCreate("quic://" + listener.Trim(), UriKind.Absolute, out uri) || uri.Port < 1)
                throw new InvalidOperationException("无法解析服务端 QUIC 监听地址：" + listener);
            string host = uri.Host;
            if (host == "0.0.0.0" || host == "::" || IPAddress.IsLoopback(ParseAddress(host)))
            {
                IPAddress local = FindLanIpv4();
                if (local == null) throw new InvalidOperationException("未识别到可用的局域网 IPv4，请手动填写公网 IP、域名或局域网 IP。");
                host = local.ToString();
            }
            string formatted = host.IndexOf(':') >= 0 ? "[" + host + "]" : host;
            return Normalize("quic://" + formatted + ":" + uri.Port);
        }

        private static IPAddress ParseAddress(string host)
        {
            IPAddress value;
            return IPAddress.TryParse(host, out value) ? value : IPAddress.None;
        }

        private static IPAddress FindLanIpv4()
        {
            var preferred = new List<IPAddress>();
            var fallback = new List<IPAddress>();
            try
            {
                foreach (NetworkInterface item in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (item.OperationalStatus != OperationalStatus.Up || item.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    IPInterfaceProperties properties = item.GetIPProperties();
                    bool hasGateway = properties.GatewayAddresses.Any(delegate(GatewayIPAddressInformation gateway)
                    {
                        return gateway.Address.AddressFamily == AddressFamily.InterNetwork && !gateway.Address.Equals(IPAddress.Any);
                    });
                    foreach (UnicastIPAddressInformation address in properties.UnicastAddresses)
                    {
                        IPAddress ip = address.Address;
                        if (ip.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(ip)) continue;
                        byte[] bytes = ip.GetAddressBytes();
                        if (bytes[0] == 169 && bytes[1] == 254) continue;
                        if (hasGateway && IsPrivateIpv4(bytes)) preferred.Add(ip);
                        else fallback.Add(ip);
                    }
                }
            }
            catch (NetworkInformationException) { }
            if (preferred.Count > 0) return preferred[0];
            return fallback.Count > 0 ? fallback[0] : null;
        }

        private static bool IsPrivateIpv4(byte[] bytes)
        {
            return bytes[0] == 10 ||
                (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                (bytes[0] == 192 && bytes[1] == 168);
        }
    }

    internal sealed class PowerShellRunner
    {
        private readonly string baseDirectory;
        private readonly string powerShellPath;

        internal PowerShellRunner(string directory)
        {
            baseDirectory = directory;
            powerShellPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(powerShellPath))
            {
                throw new FileNotFoundException("缺少系统 Windows PowerShell。", powerShellPath);
            }
        }

        internal string ScriptPath(string name)
        {
            string path = Path.Combine(baseDirectory, name);
            if (!File.Exists(path))
            {
                throw new FileNotFoundException("缺少服务管理组件：" + name, path);
            }
            return path;
        }

        internal ServiceStatus GetStatus(string serviceName)
        {
            string command = "$value = & " + Quote(ScriptPath("status-vnts2-service.ps1")) +
                " -ServiceName " + Quote(serviceName) +
                "; $value | ConvertTo-Json -Compress";
            string json = Run(command).Trim();
            var value = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
            return new ServiceStatus
            {
                Name = GetString(value, "Name"),
                Installed = GetBoolean(value, "Installed"),
                State = GetString(value, "State"),
                ProcessId = GetInteger(value, "ProcessId"),
                StartName = GetString(value, "StartName"),
                ExecutablePath = GetString(value, "ExecutablePath"),
                ConfigPath = GetString(value, "ConfigPath"),
                DataPath = GetString(value, "DataPath"),
                PortableLayout = GetBoolean(value, "PortableLayout"),
                PathName = GetString(value, "PathName")
            };
        }

        internal string Invoke(string scriptName, string arguments)
        {
            string command = "$items = @(& " + Quote(ScriptPath(scriptName)) + " " + arguments +
                "); $items | Format-List * | Out-String -Width 240";
            return Run(command).Trim();
        }

        internal static string Quote(string value)
        {
            return "'" + value.Replace("'", "''") + "'";
        }

        private string Run(string body)
        {
            string prefix = "$ErrorActionPreference='Stop'; " +
                "$OutputEncoding=[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false); ";
            string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(prefix + body));
            var start = new ProcessStartInfo
            {
                FileName = powerShellPath,
                Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encoded,
                WorkingDirectory = baseDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8
            };
            using (Process process = Process.Start(start))
            {
                string output = process.StandardOutput.ReadToEnd();
                string error = process.StandardError.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    string details = string.IsNullOrWhiteSpace(error) ? output : error;
                    throw new InvalidOperationException(details.Trim());
                }
                return output;
            }
        }

        private static string GetString(Dictionary<string, object> value, string key)
        {
            object item;
            return value.TryGetValue(key, out item) && item != null ? Convert.ToString(item) : null;
        }

        private static bool GetBoolean(Dictionary<string, object> value, string key)
        {
            object item;
            return value.TryGetValue(key, out item) && item != null && Convert.ToBoolean(item);
        }

        private static int GetInteger(Dictionary<string, object> value, string key)
        {
            object item;
            return value.TryGetValue(key, out item) && item != null ? Convert.ToInt32(item) : 0;
        }
    }

    internal sealed class NetworkEditorForm : Form
    {
        private readonly TextBox networkCodeBox;
        private readonly TextBox gatewayBox;
        private readonly NumericUpDown netmaskBox;
        private readonly TextBox leaseBox;
        private readonly bool editing;

        internal string NetworkCode { get; private set; }
        internal string Gateway { get; private set; }
        internal int Netmask { get; private set; }
        internal long? LeaseDuration { get; private set; }

        internal NetworkEditorForm(NetworkInfoData network, bool darkTheme)
        {
            editing = network != null;
            Text = editing ? "编辑网络" : "新增网络";
            ClientSize = new Size(520, 355);
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = false;
            StartPosition = FormStartPosition.CenterParent;
            Font = new Font("Microsoft YaHei UI", 9F);
            BackColor = Color.White;
            Icon = ApplicationIcon.Load();

            Controls.Add(new Label
            {
                Text = editing ? "组网编号创建后不可修改，避免已连接设备失去所属网络。" : "填写组网编号和虚拟网段；编号用于客户端加入同一网络。",
                Location = new Point(24, 20),
                Size = new Size(470, 28),
                ForeColor = Color.FromArgb(92, 105, 123)
            });
            networkCodeBox = AddTextField("组网编号", editing ? network.network_code : string.Empty, 60);
            networkCodeBox.ReadOnly = editing;
            if (editing) networkCodeBox.BackColor = Color.FromArgb(245, 247, 250);
            gatewayBox = AddTextField("网关地址", editing ? network.gateway : string.Empty, 112);

            Controls.Add(new Label { Text = "子网掩码", Location = new Point(24, 169), Size = new Size(90, 26) });
            netmaskBox = new NumericUpDown
            {
                Location = new Point(122, 164),
                Size = new Size(120, 28),
                Minimum = 0,
                Maximum = 32,
                Value = editing ? network.netmask : 24,
                Font = new Font("Segoe UI", 10F)
            };
            Controls.Add(netmaskBox);
            Controls.Add(new Label
            {
                Text = "例如 24 表示 255.255.255.0",
                Location = new Point(258, 169),
                Size = new Size(235, 24),
                ForeColor = Color.Gray
            });

            leaseBox = AddTextField("IP 租期（秒）", editing ? network.lease_duration.ToString() : string.Empty, 216);
            Controls.Add(new Label
            {
                Text = editing ? "编辑时必须填写，最小 60 秒。" : "可留空使用服务端默认值；填写时最小 60 秒。",
                Location = new Point(122, 249),
                Size = new Size(370, 24),
                ForeColor = Color.Gray
            });

            var cancel = new Button
            {
                Text = "取消",
                Location = new Point(278, 296),
                Size = new Size(100, 36),
                DialogResult = DialogResult.Cancel
            };
            Controls.Add(cancel);
            var save = new Button
            {
                Text = editing ? "保存修改" : "创建网络",
                Location = new Point(390, 296),
                Size = new Size(105, 36),
                BackColor = Color.FromArgb(39, 110, 241),
                ForeColor = Color.White,
                FlatStyle = FlatStyle.Flat
            };
            save.Click += delegate { ValidateAndClose(); };
            Controls.Add(save);
            AcceptButton = save;
            CancelButton = cancel;
            save.Tag = "Accent";
            ThemeManager.Apply(this, darkTheme);
        }

        private TextBox AddTextField(string caption, string value, int y)
        {
            Controls.Add(new Label { Text = caption, Location = new Point(24, y + 5), Size = new Size(95, 26) });
            var box = new TextBox
            {
                Text = value,
                Location = new Point(122, y),
                Size = new Size(373, 28),
                Font = new Font("Segoe UI", 10F)
            };
            Controls.Add(box);
            return box;
        }

        private void ValidateAndClose()
        {
            string code = networkCodeBox.Text.Trim();
            if (code.Length == 0 || code.Length > 128 || code.Any(char.IsControl))
            {
                ShowValidationError("组网编号不能为空、不能包含控制字符，且不能超过 128 个字符。", networkCodeBox);
                return;
            }

            IPAddress gateway;
            if (!IPAddress.TryParse(gatewayBox.Text.Trim(), out gateway) || gateway.AddressFamily != AddressFamily.InterNetwork)
            {
                ShowValidationError("请输入有效的 IPv4 网关地址，例如 10.26.0.1。", gatewayBox);
                return;
            }

            string leaseText = leaseBox.Text.Trim();
            long? lease = null;
            if (leaseText.Length > 0)
            {
                long value;
                if (!long.TryParse(leaseText, out value) || value < 60)
                {
                    ShowValidationError("IP 租期必须是大于或等于 60 的整数秒数。", leaseBox);
                    return;
                }
                lease = value;
            }
            else if (editing)
            {
                ShowValidationError("编辑网络时必须填写 IP 租期。", leaseBox);
                return;
            }

            NetworkCode = code;
            Gateway = gateway.ToString();
            Netmask = Decimal.ToInt32(netmaskBox.Value);
            LeaseDuration = lease;
            DialogResult = DialogResult.OK;
            Close();
        }

        private void ShowValidationError(string message, Control control)
        {
            MessageBox.Show(this, message, "输入内容无效", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            control.Focus();
        }
    }

    internal sealed class NetworkLoadResult
    {
        internal ServerStatusData Status;
        internal List<NetworkInfoData> Networks;
    }

    internal sealed class NetworkManagerForm : Form
    {
        private static readonly Color Navy = Color.FromArgb(22, 38, 62);
        private static readonly Color Blue = Color.FromArgb(39, 110, 241);
        private static readonly Color Muted = Color.FromArgb(92, 105, 123);

        private readonly LocalApiClient api;
        private readonly string settingsPath;
        private readonly bool darkTheme;
        private readonly TextBox quicAddressBox;
        private readonly Label listenerValue;
        private readonly Label operationStatus;
        private readonly DataGridView networkGrid;
        private readonly List<Button> operationButtons = new List<Button>();
        private List<NetworkInfoData> networks = new List<NetworkInfoData>();
        private ServerStatusData serverStatus;
        private bool endpointInitialized;

        internal NetworkManagerForm(LocalApiClient client, string guiSettingsPath, bool useDarkTheme)
        {
            api = client;
            settingsPath = guiSettingsPath;
            darkTheme = useDarkTheme;
            Text = "VNTS2 网络管理";
            ClientSize = new Size(1240, 690);
            MinimumSize = new Size(1080, 620);
            StartPosition = FormStartPosition.CenterParent;
            Font = new Font("Microsoft YaHei UI", 9F);
            BackColor = Color.FromArgb(245, 247, 250);
            Icon = ApplicationIcon.Load();
            AutoScaleMode = AutoScaleMode.Dpi;

            var header = new Panel { Dock = DockStyle.Top, Height = 82, BackColor = Navy, Tag = "Header" };
            Controls.Add(header);
            header.Controls.Add(new Label
            {
                Text = "网络管理",
                ForeColor = Color.White,
                Font = new Font("Microsoft YaHei UI", 20F, FontStyle.Bold),
                Location = new Point(24, 12),
                AutoSize = true,
                Tag = "HeaderTitle"
            });
            header.Controls.Add(new Label
            {
                Text = "直接管理组网编号并复制客户端连接信息，无需打开浏览器",
                ForeColor = Color.FromArgb(194, 205, 220),
                Location = new Point(27, 51),
                AutoSize = true,
                Tag = "HeaderSubtitle"
            });

            var endpointPanel = new GroupBox
            {
                Text = "客户端 QUIC 连接地址",
                Location = new Point(20, 96),
                Size = new Size(1200, 110),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                BackColor = Color.White,
                ForeColor = Navy,
                Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold)
            };
            Controls.Add(endpointPanel);
            endpointPanel.Controls.Add(new Label
            {
                Text = "共享地址",
                Location = new Point(18, 34),
                Size = new Size(72, 25),
                Font = new Font("Microsoft YaHei UI", 9F)
            });
            quicAddressBox = new TextBox
            {
                Location = new Point(91, 30),
                Size = new Size(600, 28),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                Font = new Font("Consolas", 10F),
                Text = GuiSettingsManager.LoadQuicEndpoint(settingsPath) ?? string.Empty
            };
            endpointInitialized = quicAddressBox.TextLength > 0;
            endpointPanel.Controls.Add(quicAddressBox);
            Button saveEndpoint = CreateButton("保存地址", Blue, Color.White, 102);
            saveEndpoint.Location = new Point(704, 28);
            saveEndpoint.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            saveEndpoint.Click += delegate { SaveEndpoint(); };
            endpointPanel.Controls.Add(saveEndpoint);
            Button copyEndpoint = CreateButton("复制地址", Color.FromArgb(239, 243, 248), Navy, 102);
            copyEndpoint.Location = new Point(818, 28);
            copyEndpoint.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            copyEndpoint.Click += delegate { CopyEndpoint(); };
            endpointPanel.Controls.Add(copyEndpoint);
            Button refresh = CreateButton("刷新列表", Color.FromArgb(239, 243, 248), Navy, 102);
            refresh.Location = new Point(932, 28);
            refresh.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            refresh.Click += async delegate { await LoadData(); };
            endpointPanel.Controls.Add(refresh);
            operationButtons.Add(saveEndpoint);
            operationButtons.Add(copyEndpoint);
            operationButtons.Add(refresh);
            listenerValue = new Label
            {
                Text = "正在读取服务端监听地址…",
                Location = new Point(91, 70),
                Size = new Size(1065, 24),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                ForeColor = Muted,
                Font = new Font("Microsoft YaHei UI", 8.5F)
            };
            endpointPanel.Controls.Add(listenerValue);

            var toolbar = new Panel
            {
                Location = new Point(20, 220),
                Size = new Size(1200, 42),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                BackColor = BackColor
            };
            Controls.Add(toolbar);
            Button add = CreateButton("新增网络", Blue, Color.White, 112);
            add.Location = new Point(0, 2);
            add.Click += async delegate { await AddNetwork(); };
            toolbar.Controls.Add(add);
            Button edit = CreateButton("编辑选中", Color.FromArgb(239, 243, 248), Navy, 112);
            edit.Location = new Point(124, 2);
            edit.Click += async delegate { await EditNetwork(); };
            toolbar.Controls.Add(edit);
            Button delete = CreateButton("删除选中", Color.FromArgb(190, 49, 68), Color.White, 112);
            delete.Location = new Point(248, 2);
            delete.Click += async delegate { await DeleteNetwork(); };
            toolbar.Controls.Add(delete);
            operationButtons.Add(add);
            operationButtons.Add(edit);
            operationButtons.Add(delete);
            operationStatus = new Label
            {
                Text = "准备就绪",
                Location = new Point(382, 10),
                Size = new Size(790, 25),
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                ForeColor = Muted,
                TextAlign = ContentAlignment.MiddleRight
            };
            toolbar.Controls.Add(operationStatus);

            networkGrid = new DataGridView
            {
                Location = new Point(20, 272),
                Size = new Size(1200, 346),
                Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
                BackgroundColor = Color.White,
                BorderStyle = BorderStyle.FixedSingle,
                AllowUserToAddRows = false,
                AllowUserToDeleteRows = false,
                AllowUserToResizeRows = false,
                ReadOnly = true,
                RowHeadersVisible = false,
                SelectionMode = DataGridViewSelectionMode.FullRowSelect,
                MultiSelect = false,
                AutoGenerateColumns = false,
                AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.None,
                RowTemplate = { Height = 34 }
            };
            networkGrid.ColumnHeadersHeight = 36;
            networkGrid.EnableHeadersVisualStyles = false;
            networkGrid.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(239, 243, 248);
            networkGrid.ColumnHeadersDefaultCellStyle.ForeColor = Navy;
            networkGrid.ColumnHeadersDefaultCellStyle.Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold);
            networkGrid.CellContentClick += NetworkGridCellContentClick;
            networkGrid.CellDoubleClick += async delegate(object sender, DataGridViewCellEventArgs args)
            {
                if (args.RowIndex >= 0 && args.ColumnIndex < 7) await EditNetwork();
            };
            AddGridColumns();
            Controls.Add(networkGrid);

            Controls.Add(new Label
            {
                Text = "说明：QUIC 地址为服务器共享连接入口；每一行的组网编号用于区分不同虚拟网络。",
                Location = new Point(22, 634),
                Size = new Size(960, 28),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
                ForeColor = Muted
            });
            var close = new Button
            {
                Text = "关闭",
                Location = new Point(1108, 630),
                Size = new Size(112, 36),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Right,
                DialogResult = DialogResult.Cancel
            };
            Controls.Add(close);
            CancelButton = close;
            ThemeManager.Apply(this, darkTheme);
            Shown += async delegate { await LoadData(); };
        }

        private void AddGridColumns()
        {
            networkGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "networkCode", HeaderText = "组网编号", Width = 130 });
            networkGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "networkNet", HeaderText = "虚拟网段", Width = 125 });
            networkGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "gateway", HeaderText = "网关", Width = 112 });
            networkGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "netmask", HeaderText = "掩码", Width = 58 });
            networkGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "lease", HeaderText = "租期", Width = 104 });
            networkGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "online", HeaderText = "在线/全部", Width = 82 });
            networkGrid.Columns.Add(new DataGridViewTextBoxColumn { Name = "quic", HeaderText = "QUIC 地址", AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill, MinimumWidth = 190 });
            networkGrid.Columns.Add(CreateGridButton("copyQuic", "复制 QUIC", 88));
            networkGrid.Columns.Add(CreateGridButton("copyCode", "复制编号", 84));
            networkGrid.Columns.Add(CreateGridButton("copyAll", "复制全部", 84));
        }

        private static DataGridViewButtonColumn CreateGridButton(string name, string text, int width)
        {
            return new DataGridViewButtonColumn
            {
                Name = name,
                HeaderText = string.Empty,
                Text = text,
                UseColumnTextForButtonValue = true,
                Width = width,
                FlatStyle = FlatStyle.Flat
            };
        }

        private async Task LoadData()
        {
            SetBusy(true);
            operationStatus.Text = "正在从本机服务读取网络…";
            operationStatus.ForeColor = Muted;
            try
            {
                NetworkLoadResult result = await Task.Factory.StartNew(delegate
                {
                    return new NetworkLoadResult { Status = api.GetServerStatus(), Networks = api.GetNetworks() };
                });
                serverStatus = result.Status;
                networks = result.Networks ?? new List<NetworkInfoData>();
                string listener = serverStatus == null || serverStatus.listeners == null ? null : serverStatus.listeners.vnt_quic;
                listenerValue.Text = string.IsNullOrWhiteSpace(listener)
                    ? "服务端 VNT QUIC：未启用。可查看 data\\config.toml 的 quic_bind 设置。"
                    : "服务端实际监听：" + listener + "。0.0.0.0 是监听标记，客户端应使用上方局域网 IP、公网 IP 或域名。";
                if (!endpointInitialized)
                {
                    try { quicAddressBox.Text = QuicEndpointHelper.SuggestFromListener(listener); }
                    catch { quicAddressBox.Text = string.Empty; }
                    endpointInitialized = true;
                }
                PopulateGrid();
                operationStatus.Text = "已加载 " + networks.Count + " 个网络";
            }
            catch (Exception exception)
            {
                ShowOperationError("读取网络失败", exception);
            }
            finally
            {
                SetBusy(false);
            }
        }

        private void PopulateGrid()
        {
            string endpoint;
            try { endpoint = QuicEndpointHelper.Normalize(quicAddressBox.Text); }
            catch { endpoint = "请先设置 QUIC 地址"; }
            networkGrid.Rows.Clear();
            foreach (NetworkInfoData network in networks.OrderBy(delegate(NetworkInfoData item) { return item.network_code; }))
            {
                int index = networkGrid.Rows.Add(
                    network.network_code,
                    network.net,
                    network.gateway,
                    network.netmask,
                    FormatDuration(network.lease_duration),
                    network.online_count + "/" + network.all_count,
                    endpoint);
                networkGrid.Rows[index].Tag = network;
            }
        }

        private void SaveEndpoint()
        {
            try
            {
                string endpoint = QuicEndpointHelper.Normalize(quicAddressBox.Text);
                GuiSettingsManager.SaveQuicEndpoint(settingsPath, endpoint);
                quicAddressBox.Text = endpoint;
                PopulateGrid();
                operationStatus.Text = "QUIC 共享地址已保存到 data\\gui-settings.json";
                operationStatus.ForeColor = Color.FromArgb(28, 143, 88);
            }
            catch (Exception exception)
            {
                ShowOperationError("保存 QUIC 地址失败", exception);
            }
        }

        private void CopyEndpoint()
        {
            try
            {
                string endpoint = QuicEndpointHelper.Normalize(quicAddressBox.Text);
                Clipboard.SetText(endpoint);
                operationStatus.Text = "QUIC 地址已复制";
                operationStatus.ForeColor = Color.FromArgb(28, 143, 88);
            }
            catch (Exception exception)
            {
                ShowOperationError("复制 QUIC 地址失败", exception);
            }
        }

        private void NetworkGridCellContentClick(object sender, DataGridViewCellEventArgs args)
        {
            if (args.RowIndex < 0 || args.ColumnIndex < 0) return;
            string column = networkGrid.Columns[args.ColumnIndex].Name;
            if (column != "copyQuic" && column != "copyCode" && column != "copyAll") return;
            var network = networkGrid.Rows[args.RowIndex].Tag as NetworkInfoData;
            if (network == null) return;
            try
            {
                string endpoint = QuicEndpointHelper.Normalize(quicAddressBox.Text);
                string text = column == "copyQuic" ? endpoint :
                    column == "copyCode" ? network.network_code :
                    "QUIC 地址：" + endpoint + "\r\n组网编号：" + network.network_code;
                Clipboard.SetText(text);
                operationStatus.Text = column == "copyAll" ? "连接信息已复制" : column == "copyCode" ? "组网编号已复制" : "QUIC 地址已复制";
                operationStatus.ForeColor = Color.FromArgb(28, 143, 88);
            }
            catch (Exception exception)
            {
                ShowOperationError("复制失败", exception);
            }
        }

        private async Task AddNetwork()
        {
            using (var editor = new NetworkEditorForm(null, darkTheme))
            {
                if (editor.ShowDialog(this) != DialogResult.OK) return;
                await RunNetworkOperation("创建网络", delegate
                {
                    api.CreateNetwork(editor.NetworkCode, editor.Gateway, editor.Netmask, editor.LeaseDuration);
                });
            }
        }

        private async Task EditNetwork()
        {
            NetworkInfoData selected = GetSelectedNetwork();
            if (selected == null) return;
            using (var editor = new NetworkEditorForm(selected, darkTheme))
            {
                if (editor.ShowDialog(this) != DialogResult.OK) return;
                await RunNetworkOperation("更新网络", delegate
                {
                    api.UpdateNetwork(selected.network_code, editor.Gateway, editor.Netmask, editor.LeaseDuration.Value);
                });
            }
        }

        private async Task DeleteNetwork()
        {
            NetworkInfoData selected = GetSelectedNetwork();
            if (selected == null) return;
            DialogResult answer = MessageBox.Show(
                this,
                "确定删除网络 “" + selected.network_code + "” 吗？\r\n\r\n" +
                "含在线设备、历史设备或 WireGuard Peer 的网络会由服务端拒绝删除。",
                "确认删除网络",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.Yes) return;
            await RunNetworkOperation("删除网络", delegate { api.DeleteNetwork(selected.network_code); });
        }

        private async Task RunNetworkOperation(string name, Action action)
        {
            SetBusy(true);
            operationStatus.Text = "正在" + name + "…";
            operationStatus.ForeColor = Muted;
            try
            {
                await Task.Factory.StartNew(action);
                await LoadData();
                operationStatus.Text = name + "完成";
                operationStatus.ForeColor = Color.FromArgb(28, 143, 88);
            }
            catch (Exception exception)
            {
                ShowOperationError(name + "失败", exception);
            }
            finally
            {
                SetBusy(false);
            }
        }

        private NetworkInfoData GetSelectedNetwork()
        {
            if (networkGrid.CurrentRow == null)
            {
                MessageBox.Show(this, "请先在列表中选择一个网络。", "未选择网络", MessageBoxButtons.OK, MessageBoxIcon.Information);
                return null;
            }
            return networkGrid.CurrentRow.Tag as NetworkInfoData;
        }

        private void SetBusy(bool busy)
        {
            UseWaitCursor = busy;
            quicAddressBox.Enabled = !busy;
            networkGrid.Enabled = !busy;
            foreach (Button button in operationButtons) button.Enabled = !busy;
        }

        private void ShowOperationError(string title, Exception exception)
        {
            operationStatus.Text = title + "：" + exception.Message;
            operationStatus.ForeColor = Color.FromArgb(190, 49, 68);
            MessageBox.Show(this, exception.Message, title, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        private static string FormatDuration(long seconds)
        {
            if (seconds >= 86400)
            {
                long days = seconds / 86400;
                long hours = seconds % 86400 / 3600;
                return hours > 0 ? days + "天" + hours + "小时" : days + "天";
            }
            if (seconds >= 3600)
            {
                long hours = seconds / 3600;
                long minutes = seconds % 3600 / 60;
                return minutes > 0 ? hours + "小时" + minutes + "分" : hours + "小时";
            }
            return seconds >= 60 ? seconds / 60 + "分钟" : seconds + "秒";
        }

        private static Button CreateButton(string text, Color backColor, Color foreColor, int width)
        {
            var button = new Button
            {
                Text = text,
                Size = new Size(width, 34),
                BackColor = backColor,
                ForeColor = foreColor,
                FlatStyle = FlatStyle.Flat,
                Cursor = Cursors.Hand,
                Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold)
            };
            button.Tag = backColor == Blue ? "Accent" :
                backColor == Color.FromArgb(190, 49, 68) ? "Danger" : "Button";
            return button;
        }
    }

    internal sealed class ManagerForm : Form
    {
        private static readonly Color Navy = Color.FromArgb(22, 38, 62);
        private static readonly Color Blue = Color.FromArgb(39, 110, 241);
        private static readonly Color Surface = Color.FromArgb(245, 247, 250);
        private static readonly Color Muted = Color.FromArgb(92, 105, 123);

        private readonly string baseDirectory;
        private readonly PowerShellRunner runner;
        private readonly TextBox serviceNameBox;
        private readonly Label stateValue;
        private readonly Label processValue;
        private readonly Label accountValue;
        private readonly Label executableValue;
        private readonly Label configValue;
        private readonly Label dataValue;
        private readonly RichTextBox runtimeLogBox;
        private readonly Label logPathValue;
        private readonly Label managerStatusValue;
        private readonly CheckBox autoRefreshLogBox;
        private readonly System.Windows.Forms.Timer logTimer;
        private readonly Button refreshButton;
        private readonly Button themeButton;
        private readonly Button closeBehaviorButton;
        private readonly Button preferencesButton;
        private readonly Button configButton;
        private readonly Button installButton;
        private readonly Button startButton;
        private readonly Button stopButton;
        private readonly Button diagnoseButton;
        private readonly Button networksButton;
        private readonly Button webButton;
        private readonly Button uninstallButton;
        private readonly Button refreshLogButton;
        private readonly Button openLogFolderButton;
        private readonly List<Button> operationButtons;
        private readonly string guiSettingsPath;
        private readonly NotifyIcon trayIcon;
        private readonly ContextMenuStrip trayMenu;
        private readonly bool silentStart;
        private RegisteredWaitHandle activationWait;
        private int activationRequested;
        private ServiceStatus currentStatus;
        private bool darkTheme;
        private string closeBehavior;
        private string startupBehavior;
        private bool exitRequested;
        private bool closeOperationBusy;
        private bool logRefreshBusy;
        private string lastRuntimeLog;

        internal ManagerForm(bool silentStart)
        {
            this.silentStart = silentStart;
            baseDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            runner = new PowerShellRunner(baseDirectory);
            guiSettingsPath = Path.Combine(baseDirectory, "data", "gui-settings.json");
            darkTheme = !string.Equals(GuiSettingsManager.LoadTheme(guiSettingsPath), "light", StringComparison.OrdinalIgnoreCase);
            closeBehavior = GuiSettingsManager.LoadCloseBehavior(guiSettingsPath);
            startupBehavior = GuiSettingsManager.LoadStartupBehavior(guiSettingsPath);

            Text = "VNTS 2.0 Windows 服务管理器";
            ClientSize = new Size(980, 765);
            MinimumSize = new Size(900, 725);
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Microsoft YaHei UI", 9F);
            BackColor = Surface;
            Icon = ApplicationIcon.Load();
            AutoScaleMode = AutoScaleMode.Dpi;
            ShowInTaskbar = !silentStart;
            if (silentStart) WindowState = FormWindowState.Minimized;

            var root = new TableLayoutPanel
            {
                Dock = DockStyle.Fill,
                RowCount = 2,
                ColumnCount = 1,
                Margin = Padding.Empty,
                Padding = Padding.Empty,
                BackColor = Surface
            };
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 92F));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            Controls.Add(root);

            var header = new Panel { Dock = DockStyle.Fill, BackColor = Navy, Margin = Padding.Empty, Tag = "Header" };
            root.Controls.Add(header, 0, 0);
            var title = new Label
            {
                Text = "VNTS 2.0",
                ForeColor = Color.White,
                Font = new Font("Microsoft YaHei UI", 21F, FontStyle.Bold),
                Location = new Point(26, 15),
                AutoSize = true,
                Tag = "HeaderTitle"
            };
            header.Controls.Add(title);
            var subtitle = new Label
            {
                Text = "Windows 服务管理中心  ·  安装、更新、运行与诊断",
                ForeColor = Color.FromArgb(194, 205, 220),
                Location = new Point(29, 57),
                AutoSize = true,
                Tag = "HeaderSubtitle"
            };
            header.Controls.Add(subtitle);
            closeBehaviorButton = CreateButton("关闭行为", Color.FromArgb(43, 47, 54), Color.White, 126);
            closeBehaviorButton.Location = new Point(554, 27);
            closeBehaviorButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            closeBehaviorButton.Tag = "ThemeToggle";
            header.Controls.Add(closeBehaviorButton);
            preferencesButton = CreateButton("偏好设置", Color.FromArgb(43, 47, 54), Color.White, 126);
            preferencesButton.Location = new Point(690, 27);
            preferencesButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            preferencesButton.Tag = "ThemeToggle";
            header.Controls.Add(preferencesButton);
            themeButton = CreateButton(darkTheme ? "切换浅色" : "切换深色", Color.FromArgb(43, 47, 54), Color.White, 126);
            themeButton.Location = new Point(826, 27);
            themeButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            themeButton.Tag = "ThemeToggle";
            header.Controls.Add(themeButton);

            var content = new Panel { Dock = DockStyle.Fill, Padding = new Padding(24, 20, 24, 18), Margin = Padding.Empty };
            root.Controls.Add(content, 0, 1);

            var serviceLabel = new Label { Text = "服务名称", Location = new Point(2, 7), AutoSize = true, ForeColor = Muted };
            content.Controls.Add(serviceLabel);
            serviceNameBox = new TextBox
            {
                Text = "vnts2",
                Location = new Point(78, 2),
                Size = new Size(470, 28),
                Font = new Font("Segoe UI", 10F)
            };
            content.Controls.Add(serviceNameBox);
            refreshButton = CreateButton("刷新状态", Blue, Color.White, 130);
            refreshButton.Location = new Point(566, 0);
            content.Controls.Add(refreshButton);

            var statusCard = CreateCard("服务状态", new Rectangle(0, 47, 932, 195));
            content.Controls.Add(statusCard);
            AddCaption(statusCard, "当前状态", 20, 39);
            stateValue = AddValue(statusCard, "正在读取…", 105, 34, 210, true);
            AddCaption(statusCard, "进程 ID", 350, 39);
            processValue = AddValue(statusCard, "-", 425, 39, 100, false);
            AddCaption(statusCard, "运行账户", 600, 39);
            accountValue = AddValue(statusCard, "-", 680, 39, 220, false);
            AddCaption(statusCard, "程序路径", 20, 82);
            executableValue = AddValue(statusCard, "-", 105, 82, 795, false);
            AddCaption(statusCard, "配置路径", 20, 119);
            configValue = AddValue(statusCard, PortableConfigPath, 105, 119, 795, false);
            AddCaption(statusCard, "数据目录", 20, 156);
            dataValue = AddValue(statusCard, PortableDataPath, 105, 156, 795, false);

            var actionCard = CreateCard("快捷操作", new Rectangle(0, 258, 932, 124));
            content.Controls.Add(actionCard);
            var flow = new FlowLayoutPanel
            {
                Location = new Point(13, 31),
                Size = new Size(906, 82),
                WrapContents = true,
                BackColor = Color.White
            };
            actionCard.Controls.Add(flow);
            configButton = AddAction(flow, "配置", 104);
            installButton = AddAction(flow, "安装并启动", 142, Blue, Color.White);
            startButton = AddAction(flow, "启动", 104);
            stopButton = AddAction(flow, "停止", 104);
            diagnoseButton = AddAction(flow, "诊断", 104);
            networksButton = AddAction(flow, "网络管理", 120, Blue, Color.White);
            webButton = AddAction(flow, "Web 控制台", 130);
            uninstallButton = AddAction(flow, "卸载", 104, Color.FromArgb(190, 49, 68), Color.White);
            refreshLogButton = AddAction(flow, "刷新日志", 104);
            operationButtons = new List<Button>
            {
                configButton, installButton, startButton, stopButton,
                diagnoseButton, networksButton, webButton, uninstallButton
            };

            var outputLabel = new Label
            {
                Text = "运行日志",
                Location = new Point(3, 398),
                AutoSize = true,
                ForeColor = Muted,
                Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold),
                Tag = "Muted"
            };
            content.Controls.Add(outputLabel);
            logPathValue = new Label
            {
                Text = "data\\logs\\vnts2.log",
                Location = new Point(76, 398),
                Size = new Size(420, 24),
                AutoEllipsis = true,
                ForeColor = Muted,
                Tag = "Muted"
            };
            content.Controls.Add(logPathValue);
            autoRefreshLogBox = new CheckBox
            {
                Text = "自动刷新",
                Checked = true,
                Location = new Point(514, 395),
                Size = new Size(94, 28),
                Tag = "Muted"
            };
            content.Controls.Add(autoRefreshLogBox);
            openLogFolderButton = CreateButton("打开日志目录", Color.FromArgb(239, 243, 248), Navy, 126);
            openLogFolderButton.Location = new Point(806, 390);
            openLogFolderButton.Size = new Size(126, 32);
            openLogFolderButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
            content.Controls.Add(openLogFolderButton);
            runtimeLogBox = new RichTextBox
            {
                Location = new Point(0, 425),
                Size = new Size(932, 174),
                Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
                ReadOnly = true,
                BackColor = Color.White,
                BorderStyle = BorderStyle.FixedSingle,
                Font = new Font("Consolas", 9F),
                DetectUrls = false,
                WordWrap = false,
                Tag = "RuntimeLog"
            };
            content.Controls.Add(runtimeLogBox);
            managerStatusValue = new Label
            {
                Text = "准备就绪",
                Location = new Point(3, 606),
                Size = new Size(920, 24),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
                AutoEllipsis = true,
                ForeColor = Muted,
                Tag = "Muted"
            };
            content.Controls.Add(managerStatusValue);
            var footer = new Label
            {
                Text = "管理员模式运行  ·  整个目录可迁移  ·  卸载只移除服务注册并保留 data",
                Location = new Point(3, 633),
                Size = new Size(920, 26),
                Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right,
                ForeColor = Muted,
                Tag = "Muted"
            };
            content.Controls.Add(footer);

            logTimer = new System.Windows.Forms.Timer { Interval = 2000 };

            trayMenu = new ContextMenuStrip();
            trayMenu.Items.Add("打开 VNTS2 管理器", null, delegate { RestoreFromTray(); });
            trayMenu.Items.Add(new ToolStripSeparator());
            trayMenu.Items.Add("关闭服务并退出", null, async delegate { await StopServiceAndExit(); });
            trayIcon = new NotifyIcon
            {
                Icon = ApplicationIcon.Load(),
                Text = "VNTS2 Windows 服务管理器",
                ContextMenuStrip = trayMenu,
                Visible = true
            };
            trayIcon.DoubleClick += delegate { RestoreFromTray(); };

            refreshButton.Click += async delegate { await RefreshStatus(false); };
            themeButton.Click += delegate { ToggleTheme(); };
            closeBehaviorButton.Click += delegate { ShowCloseBehaviorMenu(); };
            preferencesButton.Click += async delegate { await OpenPreferences(); };
            serviceNameBox.TextChanged += delegate { stateValue.Text = "待刷新"; stateValue.ForeColor = ThemeManager.GetPalette(darkTheme).Muted; };
            configButton.Click += async delegate { await OpenConfig(); };
            installButton.Click += async delegate { await InstallOrUpdate(); };
            startButton.Click += delegate { RunOperation("启动服务", "start-vnts2-service.ps1", ServiceArgument(), true); };
            stopButton.Click += delegate { RunOperation("停止服务", "stop-vnts2-service.ps1", ServiceArgument(), true); };
            diagnoseButton.Click += delegate { RunOperation("运行诊断", "diagnose-vnts2-service.ps1", ServiceArgument(), true); };
            networksButton.Click += async delegate { await OpenNetworkManager(); };
            webButton.Click += async delegate { await OpenWebConsole(); };
            uninstallButton.Click += delegate { UninstallService(); };
            refreshLogButton.Click += async delegate { await RefreshRuntimeLog(false); };
            openLogFolderButton.Click += delegate { OpenLogFolder(); };
            autoRefreshLogBox.CheckedChanged += delegate { logTimer.Enabled = autoRefreshLogBox.Checked; };
            logTimer.Tick += async delegate { if (autoRefreshLogBox.Checked) await RefreshRuntimeLog(true); };
            Shown += async delegate
            {
                if (silentStart && Volatile.Read(ref activationRequested) == 0) MinimizeToTray(false);
                Log("原生 EXE 服务管理器已启动。");
                await ReconcileStartupTask();
                await RefreshStatus(true);
                await RefreshRuntimeLog(false);
                logTimer.Enabled = autoRefreshLogBox.Checked;
            };
            FormClosing += async delegate(object sender, FormClosingEventArgs eventArgs)
            {
                if (exitRequested || eventArgs.CloseReason == CloseReason.WindowsShutDown ||
                    eventArgs.CloseReason == CloseReason.ApplicationExitCall) return;
                eventArgs.Cancel = true;
                if (closeOperationBusy) return;
                if (closeBehavior == GuiBehavior.StopServiceAndExit) await StopServiceAndExit();
                else MinimizeToTray(true);
            };
            FormClosed += delegate
            {
                if (activationWait != null)
                {
                    activationWait.Unregister(null);
                    activationWait = null;
                }
                logTimer.Stop();
                logTimer.Dispose();
                trayIcon.Visible = false;
                trayIcon.Dispose();
                trayMenu.Dispose();
            };
            ThemeManager.Apply(this, darkTheme);
        }

        internal void StartActivationListener(WaitHandle activationEvent)
        {
            if (activationEvent == null) throw new ArgumentNullException("activationEvent");
            IntPtr unused = Handle;
            activationWait = ThreadPool.RegisterWaitForSingleObject(
                activationEvent,
                delegate(object state, bool timedOut)
                {
                    Interlocked.Exchange(ref activationRequested, 1);
                    if (IsDisposed || Disposing) return;
                    try
                    {
                        BeginInvoke((MethodInvoker)delegate { RestoreFromTray(); });
                    }
                    catch (InvalidOperationException) { }
                },
                null,
                Timeout.Infinite,
                false);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && activationWait != null)
            {
                activationWait.Unregister(null);
                activationWait = null;
            }
            base.Dispose(disposing);
        }

        private void ShowCloseBehaviorMenu()
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("最小化到托盘（服务继续运行）", null, delegate { MinimizeToTray(true); });
            menu.Items.Add("关闭服务并退出", null, async delegate { await StopServiceAndExit(); });
            menu.Closed += delegate { menu.Dispose(); };
            menu.Show(closeBehaviorButton, new Point(0, closeBehaviorButton.Height));
        }

        private void MinimizeToTray(bool showNotification)
        {
            if (exitRequested) return;
            ShowInTaskbar = false;
            Hide();
            if (showNotification)
            {
                trayIcon.BalloonTipTitle = "VNTS2 管理器仍在运行";
                trayIcon.BalloonTipText = "服务保持运行；双击托盘图标可恢复窗口。";
                trayIcon.ShowBalloonTip(2500);
            }
        }

        private void RestoreFromTray()
        {
            if (exitRequested) return;
            ShowInTaskbar = true;
            Show();
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Activate();
            BringToFront();
        }

        private async Task StopServiceAndExit()
        {
            if (closeOperationBusy || exitRequested) return;
            closeOperationBusy = true;
            SetBusy(true);
            Log("正在停止 VNTS2 服务并退出管理器…");
            try
            {
                string serviceName = GetServiceName();
                ServiceStatus status = await Task.Factory.StartNew(delegate { return runner.GetStatus(serviceName); });
                if (status.Installed && !string.Equals(status.State, "Stopped", StringComparison.OrdinalIgnoreCase))
                {
                    string arguments = "-ServiceName " + PowerShellRunner.Quote(serviceName);
                    await Task.Factory.StartNew(delegate { return runner.Invoke("stop-vnts2-service.ps1", arguments); });
                }
                exitRequested = true;
                trayIcon.Visible = false;
                Application.Exit();
            }
            catch (Exception exception)
            {
                RestoreFromTray();
                ShowError("关闭服务失败", exception);
            }
            finally
            {
                if (!exitRequested)
                {
                    closeOperationBusy = false;
                    SetBusy(false);
                }
            }
        }

        private async Task OpenPreferences()
        {
            using (var form = new ManagerPreferencesForm(closeBehavior, startupBehavior, darkTheme))
            {
                if (form.ShowDialog(this) != DialogResult.OK) return;
                string nextClose = form.SelectedCloseBehavior;
                string nextStartup = form.SelectedStartupBehavior;
                string previousStartup = startupBehavior;
                bool taskChanged = !string.Equals(previousStartup, nextStartup, StringComparison.Ordinal);
                SetBusy(true);
                try
                {
                    if (taskChanged)
                    {
                        await Task.Factory.StartNew(delegate { StartupTaskManager.Apply(nextStartup, Application.ExecutablePath); });
                    }
                    try
                    {
                        GuiSettingsManager.SaveDesktopBehavior(guiSettingsPath, nextClose, nextStartup);
                    }
                    catch
                    {
                        if (taskChanged)
                        {
                            try { StartupTaskManager.Apply(previousStartup, Application.ExecutablePath); }
                            catch { }
                        }
                        throw;
                    }
                    closeBehavior = nextClose;
                    startupBehavior = nextStartup;
                    Log("偏好设置已保存：关闭窗口时" + GuiBehavior.CloseLabel(closeBehavior) + "；" +
                        GuiBehavior.StartupLabel(startupBehavior) + "。");
                }
                catch (Exception exception)
                {
                    ShowError("保存偏好设置失败", exception);
                }
                finally
                {
                    SetBusy(false);
                }
            }
        }

        private async Task ReconcileStartupTask()
        {
            if (startupBehavior == GuiBehavior.StartupDisabled) return;
            try
            {
                await Task.Factory.StartNew(delegate { StartupTaskManager.Apply(startupBehavior, Application.ExecutablePath); });
            }
            catch (Exception exception)
            {
                Log("开机自启任务校验失败：" + exception.Message);
            }
        }

        private async Task RefreshStatus(bool silent)
        {
            try
            {
                string name = GetServiceName();
                ServiceStatus status = await Task.Factory.StartNew(delegate { return runner.GetStatus(name); });
                currentStatus = status;
                ApplyStatus(status);
                if (!silent) Log("状态已刷新。");
            }
            catch (Exception ex)
            {
                if (!silent) ShowError("状态读取失败", ex);
            }
        }

        private void ApplyStatus(ServiceStatus status)
        {
            ThemePalette palette = ThemeManager.GetPalette(darkTheme);
            logPathValue.Text = GetRuntimeLogPath();
            if (!status.Installed)
            {
                stateValue.Text = "未安装";
                stateValue.ForeColor = palette.Muted;
                processValue.Text = "-";
                accountValue.Text = "-";
                executableValue.Text = Path.Combine(baseDirectory, "vnts2.exe");
                configValue.Text = PortableConfigPath;
                dataValue.Text = PortableDataPath;
                configButton.Text = "配置";
                installButton.Text = "安装并启动";
                return;
            }

            bool existing = IsExistingDeployment(status);
            stateValue.Text = status.State + (existing ? "  ·  待迁移部署" : "  ·  便携部署");
            stateValue.ForeColor = status.State == "Running" ? palette.Success : palette.Warning;
            processValue.Text = status.ProcessId > 0 ? status.ProcessId.ToString() : "-";
            accountValue.Text = string.IsNullOrEmpty(status.StartName) ? "-" : status.StartName;
            executableValue.Text = string.IsNullOrEmpty(status.ExecutablePath) ? "无法解析" : status.ExecutablePath;
            configValue.Text = string.IsNullOrEmpty(status.ConfigPath) ? "无法解析" : status.ConfigPath;
            dataValue.Text = string.IsNullOrEmpty(status.DataPath) ? "无法解析" : status.DataPath;
            configButton.Text = "编辑配置";
            installButton.Text = existing ? "迁移并启动服务" : "校验并启动";
        }

        private bool IsExistingDeployment(ServiceStatus status)
        {
            if (!status.Installed || string.IsNullOrEmpty(status.ExecutablePath) || string.IsNullOrEmpty(status.ConfigPath)) return status.Installed;
            return !PathEquals(status.ExecutablePath, Path.Combine(baseDirectory, "vnts2.exe")) ||
                !PathEquals(status.ConfigPath, PortableConfigPath) || !status.PortableLayout;
        }

        private async Task InstallOrUpdate()
        {
            string name;
            try { name = GetServiceName(); }
            catch (Exception ex) { ShowError("服务名无效", ex); return; }

            ServiceStatus status;
            try { status = await Task.Factory.StartNew(delegate { return runner.GetStatus(name); }); }
            catch (Exception ex) { ShowError("状态读取失败", ex); return; }

            if (IsExistingDeployment(status))
            {
                if (string.IsNullOrEmpty(status.ExecutablePath))
                {
                    ShowError("无法更新", new InvalidOperationException("无法解析已有服务的程序路径，请先运行诊断。"));
                    return;
                }
                DialogResult answer = MessageBox.Show(
                    this,
                    "服务 " + name + " 已安装于：\r\n" + status.ExecutablePath + "\r\n\r\n" +
                    "是否迁移到当前便携目录？\r\n\r\n" +
                    "程序将使用：\r\n" + Path.Combine(baseDirectory, "vnts2.exe") + "\r\n" +
                    "全部运行数据将进入：\r\n" + PortableDataPath + "\r\n\r\n" +
                    "迁移前会停止服务并校验配置、数据库、证书和密钥；失败自动恢复原服务路径。",
                    "确认迁移已有服务",
                    MessageBoxButtons.YesNo,
                    MessageBoxIcon.Warning,
                    MessageBoxDefaultButton.Button2);
                if (answer != DialogResult.Yes) { Log("已取消迁移服务 " + name + "。"); return; }
                string args = "-ServiceName " + PowerShellRunner.Quote(name) +
                    " -TargetDir " + PowerShellRunner.Quote(baseDirectory) +
                    " -SourceExecutable " + PowerShellRunner.Quote(Path.Combine(baseDirectory, "vnts2.exe")) +
                    " -MigrateExistingData";
                RunOperation("迁移并启动服务", "update-vnts2-service.ps1", args, true);
                return;
            }

            bool created = EnsurePortableConfig();
            if (created) Log("已自动初始化 " + PortableConfigPath + "。");
            string installArgs = "-ServiceName " + PowerShellRunner.Quote(name) + " -TargetDir " + PowerShellRunner.Quote(baseDirectory);
            RunOperation("安装并启动服务", "install-vnts2-service.ps1", installArgs, true);
        }

        private async Task OpenConfig()
        {
            string backupPath = null;
            bool busy = false;
            try
            {
                string path = GetActiveConfigPath();
                if (!File.Exists(path))
                {
                    if (currentStatus != null && currentStatus.Installed)
                        throw new FileNotFoundException("已安装服务的配置文件不存在，拒绝跨部署创建。", path);
                    EnsurePortableConfig();
                    Log("已从模板创建 data\\config.toml，可通过设置弹窗完成配置。");
                }
                ServerConfigSettings settings = ConfigFileEditor.Load(path);
                bool installed = currentStatus != null && currentStatus.Installed;
                bool running = installed && string.Equals(currentStatus.State, "Running", StringComparison.OrdinalIgnoreCase);
                using (var form = new ConfigSettingsForm(settings, path, installed, running, darkTheme))
                {
                    if (form.ShowDialog(this) != DialogResult.OK) return;
                    backupPath = ConfigFileEditor.Save(path, form.Settings);
                    Log("配置已保存；原文件备份到 " + backupPath);
                    if (!form.RestartRequested)
                    {
                        if (installed) Log("配置将在下次启动服务时生效，也可再次打开配置并选择保存应用。");
                        return;
                    }
                }

                busy = true;
                SetBusy(true);
                string serviceName = GetServiceName();
                string arguments = "-ServiceName " + PowerShellRunner.Quote(serviceName);
                try
                {
                    await Task.Factory.StartNew(delegate
                    {
                        if (running) runner.Invoke("stop-vnts2-service.ps1", arguments);
                        runner.Invoke("start-vnts2-service.ps1", arguments);
                    });
                    Log(running ? "配置已应用，服务重启完成。" : "配置已应用，服务启动完成。");
                }
                catch (Exception applyException)
                {
                    try
                    {
                        File.Copy(backupPath, path, true);
                        Task.Factory.StartNew(delegate
                        {
                            if (running) runner.Invoke("start-vnts2-service.ps1", arguments);
                            else runner.Invoke("stop-vnts2-service.ps1", arguments);
                        }).Wait();
                    }
                    catch (Exception rollbackException)
                    {
                        throw new InvalidOperationException(
                            "配置应用失败，且自动恢复运行状态失败。原配置备份位于：" + backupPath +
                            "\r\n应用错误：" + applyException.Message + "\r\n恢复错误：" + rollbackException.Message,
                            applyException);
                    }
                    throw new InvalidOperationException("配置应用失败，已恢复原配置和服务状态：" + applyException.Message, applyException);
                }
                await RefreshStatus(true);
            }
            catch (Exception ex) { ShowError("配置设置失败", ex); }
            finally
            {
                if (busy) SetBusy(false);
            }
        }

        private async Task OpenWebConsole()
        {
            bool busy = false;
            try
            {
                string path = GetActiveConfigPath();
                if (!File.Exists(path)) throw new FileNotFoundException("配置文件不存在。", path);
                string endpoint = WebConsoleManager.ReadEndpoint(path);
                if (string.IsNullOrEmpty(endpoint))
                {
                    if (currentStatus == null || !currentStatus.Installed)
                        throw new InvalidOperationException("请先安装并启动 Windows 服务，再启用 Web 控制台。");
                    DialogResult answer = MessageBox.Show(
                        this,
                        "当前配置尚未启用 Web 控制台。\r\n\r\n" +
                        "是否安全启用？程序将：\r\n" +
                        "· 仅监听本机 127.0.0.1:29871\r\n" +
                        "· 生成 24 位强密码并备份原配置\r\n" +
                        "· 重启服务使配置生效",
                        "启用 Web 控制台",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Question,
                        MessageBoxDefaultButton.Button2);
                    if (answer != DialogResult.Yes)
                    {
                        Log("已取消启用 Web 控制台。");
                        return;
                    }

                    busy = true;
                    SetBusy(true);
                    Log("开始：安全启用 Web 控制台");
                    WebConsoleSettings settings = await Task.Factory.StartNew(
                        delegate { return WebConsoleManager.Enable(runner, currentStatus); });
                    endpoint = settings.Endpoint;
                    Log("完成：Web 控制台已仅在本机启用；原配置已备份到 " + settings.BackupPath);
                    await RefreshStatus(true);
                    using (var credentials = new WebCredentialsForm(settings, darkTheme))
                    {
                        if (credentials.ShowDialog(this) != DialogResult.OK) return;
                    }
                }
                Process.Start(new ProcessStartInfo(WebConsoleManager.ToUrl(endpoint)) { UseShellExecute = true });
            }
            catch (Exception ex) { ShowError("打开 Web 控制台失败", ex); }
            finally
            {
                if (busy) SetBusy(false);
            }
        }

        private async Task OpenNetworkManager()
        {
            bool busy = false;
            try
            {
                string serviceName = GetServiceName();
                ServiceStatus status = await Task.Factory.StartNew(delegate { return runner.GetStatus(serviceName); });
                currentStatus = status;
                ApplyStatus(status);
                if (!status.Installed)
                    throw new InvalidOperationException("请先安装并启动 Windows 服务，再使用网络管理。");
                if (IsExistingDeployment(status))
                    throw new InvalidOperationException("当前服务不是便携部署，请先点击“迁移并启动服务”。");
                if (string.IsNullOrWhiteSpace(status.ConfigPath) || !File.Exists(status.ConfigPath))
                    throw new FileNotFoundException("服务配置文件不存在。", status.ConfigPath);

                string endpoint = WebConsoleManager.ReadEndpoint(status.ConfigPath);
                if (string.IsNullOrWhiteSpace(endpoint))
                {
                    DialogResult enable = MessageBox.Show(
                        this,
                        "网络管理需要使用仅限本机访问的管理接口。\r\n\r\n" +
                        "是否自动启用 127.0.0.1:29871、生成安全凭据并重启服务？\r\n" +
                        "该接口不会开放到局域网或公网。",
                        "启用本地网络管理",
                        MessageBoxButtons.YesNo,
                        MessageBoxIcon.Question,
                        MessageBoxDefaultButton.Button2);
                    if (enable != DialogResult.Yes)
                    {
                        Log("已取消打开网络管理。");
                        return;
                    }
                    busy = true;
                    SetBusy(true);
                    Log("开始：启用本地网络管理接口");
                    WebConsoleSettings settings = await Task.Factory.StartNew(
                        delegate { return WebConsoleManager.Enable(runner, status); });
                    endpoint = settings.Endpoint;
                    Log("完成：本地管理接口已安全启用；原配置已备份到 " + settings.BackupPath);
                    currentStatus = await Task.Factory.StartNew(delegate { return runner.GetStatus(serviceName); });
                    ApplyStatus(currentStatus);
                }
                else
                {
                    WebConsoleManager.ValidateLoopbackEndpoint(endpoint);
                    if (!string.Equals(status.State, "Running", StringComparison.OrdinalIgnoreCase))
                    {
                        DialogResult start = MessageBox.Show(
                            this,
                            "VNTS2 服务当前未运行。是否启动服务并继续打开网络管理？",
                            "启动服务",
                            MessageBoxButtons.YesNo,
                            MessageBoxIcon.Question,
                            MessageBoxDefaultButton.Button1);
                        if (start != DialogResult.Yes)
                        {
                            Log("已取消打开网络管理。");
                            return;
                        }
                        busy = true;
                        SetBusy(true);
                        await Task.Factory.StartNew(delegate { return runner.Invoke("start-vnts2-service.ps1", ServiceArgument()); });
                    }
                    await Task.Factory.StartNew(delegate { WebConsoleManager.WaitForEndpoint(endpoint, TimeSpan.FromSeconds(15)); });
                }

                var client = LocalApiClient.FromConfig(status.ConfigPath);
                await Task.Factory.StartNew(delegate { client.GetServerStatus(); });
                if (busy)
                {
                    SetBusy(false);
                    busy = false;
                }
                Log("已打开网络管理，所有请求仅通过本机回环接口完成。");
                string settingsPath = Path.Combine(
                    string.IsNullOrWhiteSpace(status.DataPath) ? Path.GetDirectoryName(status.ConfigPath) : status.DataPath,
                    "gui-settings.json");
                using (var form = new NetworkManagerForm(client, settingsPath, darkTheme))
                    form.ShowDialog(this);
                await RefreshStatus(true);
            }
            catch (Exception exception)
            {
                ShowError("打开网络管理失败", exception);
            }
            finally
            {
                if (busy) SetBusy(false);
            }
        }

        private void UninstallService()
        {
            string name;
            try { name = GetServiceName(); }
            catch (Exception ex) { ShowError("服务名无效", ex); return; }
            DialogResult answer = MessageBox.Show(
                this,
                "确定卸载 Windows 服务 " + name + " 吗？\r\n配置、数据库、密钥、日志和备份会保留。",
                "确认卸载",
                MessageBoxButtons.YesNo,
                MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2);
            if (answer == DialogResult.Yes)
                RunOperation("卸载服务", "uninstall-vnts2-service.ps1", ServiceArgument(), true);
        }

        private async void RunOperation(string name, string script, string arguments, bool refresh)
        {
            SetBusy(true);
            Log("开始：" + name);
            try
            {
                await Task.Factory.StartNew(delegate { return runner.Invoke(script, arguments); });
                Log("完成：" + name);
            }
            catch (Exception ex) { ShowError(name + "失败", ex); }
            finally
            {
                SetBusy(false);
            }
            if (refresh) await RefreshStatus(true);
            await RefreshRuntimeLog(false);
        }

        private string GetActiveConfigPath()
        {
            string name = GetServiceName();
            if (currentStatus == null || !string.Equals(currentStatus.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                currentStatus = runner.GetStatus(name);
                ApplyStatus(currentStatus);
            }
            if (currentStatus.Installed)
            {
                if (string.IsNullOrEmpty(currentStatus.ConfigPath)) throw new InvalidOperationException("无法解析已安装服务的配置路径。");
                return currentStatus.ConfigPath;
            }
            return PortableConfigPath;
        }

        private string PortableDataPath
        {
            get { return Path.Combine(baseDirectory, "data"); }
        }

        private string PortableConfigPath
        {
            get { return Path.Combine(PortableDataPath, "config.toml"); }
        }

        private bool EnsurePortableConfig()
        {
            if (File.Exists(PortableConfigPath)) return false;
            string template = Path.Combine(baseDirectory, "config.example.toml");
            if (!File.Exists(template)) throw new FileNotFoundException("缺少配置模板。", template);
            Directory.CreateDirectory(PortableDataPath);
            File.Copy(template, PortableConfigPath, false);
            ServerConfigSettings settings = ConfigFileEditor.Load(PortableConfigPath);
            settings.WireGuardEnabled = true;
            WireGuardDefaults.ApplyMissing(settings);
            ConfigSettingsForm.ValidateSettings(settings);
            ConfigFileEditor.Save(PortableConfigPath, settings);
            return true;
        }

        private string GetServiceName()
        {
            string value = serviceNameBox.Text.Trim();
            if (!Regex.IsMatch(value, "^[A-Za-z0-9_.-]{1,80}$"))
                throw new InvalidOperationException("服务名只能包含字母、数字、点、下划线和连字符，长度不能超过 80。 ");
            return value;
        }

        private string ServiceArgument()
        {
            return "-ServiceName " + PowerShellRunner.Quote(GetServiceName());
        }

        private void ToggleTheme()
        {
            bool previous = darkTheme;
            try
            {
                darkTheme = !darkTheme;
                GuiSettingsManager.SaveTheme(guiSettingsPath, darkTheme ? "dark" : "light");
                ThemeManager.Apply(this, darkTheme);
                themeButton.Text = darkTheme ? "切换浅色" : "切换深色";
                if (currentStatus != null) ApplyStatus(currentStatus);
                ColorizeRuntimeLog();
                Log(darkTheme ? "已切换为深色主题。" : "已切换为浅色主题。");
            }
            catch (Exception exception)
            {
                darkTheme = previous;
                ThemeManager.Apply(this, darkTheme);
                ShowError("切换主题失败", exception);
            }
        }

        private async Task RefreshRuntimeLog(bool silent)
        {
            if (logRefreshBusy) return;
            logRefreshBusy = true;
            try
            {
                string path = GetRuntimeLogPath();
                logPathValue.Text = path;
                string text = await Task.Factory.StartNew(delegate { return RuntimeLogReader.ReadTail(path); });
                if (string.IsNullOrEmpty(text))
                    text = File.Exists(path) ? "日志文件当前为空。" : "运行日志尚未生成；启动服务后会自动显示。";
                if (!string.Equals(lastRuntimeLog, text, StringComparison.Ordinal))
                {
                    lastRuntimeLog = text;
                    runtimeLogBox.Text = text;
                    ColorizeRuntimeLog();
                    runtimeLogBox.SelectionStart = runtimeLogBox.TextLength;
                    runtimeLogBox.ScrollToCaret();
                }
                if (!silent) Log("运行日志已刷新。");
            }
            catch (Exception exception)
            {
                if (silent)
                {
                    managerStatusValue.Text = "日志自动刷新失败：" + exception.Message;
                    managerStatusValue.ForeColor = ThemeManager.GetPalette(darkTheme).Danger;
                }
                else
                {
                    ShowError("刷新运行日志失败", exception);
                }
            }
            finally
            {
                logRefreshBusy = false;
            }
        }

        private void ColorizeRuntimeLog()
        {
            ThemePalette palette = ThemeManager.GetPalette(darkTheme);
            runtimeLogBox.SuspendLayout();
            try
            {
                runtimeLogBox.BackColor = palette.LogBackground;
                runtimeLogBox.SelectAll();
                runtimeLogBox.SelectionColor = palette.Text;
                ColorLogMatches("(?im)^.*(?:\\bERROR\\b|失败|error:).*$", palette.Danger);
                ColorLogMatches("(?im)^.*(?:\\bWARN\\b|警告|warning:).*$", palette.Warning);
                runtimeLogBox.SelectionStart = runtimeLogBox.TextLength;
                runtimeLogBox.SelectionLength = 0;
                runtimeLogBox.SelectionColor = palette.Text;
            }
            finally
            {
                runtimeLogBox.ResumeLayout();
            }
        }

        private void ColorLogMatches(string pattern, Color color)
        {
            foreach (Match match in Regex.Matches(runtimeLogBox.Text, pattern))
            {
                runtimeLogBox.Select(match.Index, match.Length);
                runtimeLogBox.SelectionColor = color;
            }
        }

        private void OpenLogFolder()
        {
            try
            {
                string directory = Path.GetDirectoryName(GetRuntimeLogPath());
                Directory.CreateDirectory(directory);
                Process.Start(new ProcessStartInfo("explorer.exe", "\"" + directory + "\"") { UseShellExecute = true });
                Log("已打开日志目录。");
            }
            catch (Exception exception)
            {
                ShowError("打开日志目录失败", exception);
            }
        }

        private string GetRuntimeLogPath()
        {
            string dataPath = currentStatus != null && currentStatus.Installed && !string.IsNullOrWhiteSpace(currentStatus.DataPath)
                ? currentStatus.DataPath
                : PortableDataPath;
            return Path.Combine(dataPath, "logs", "vnts2.log");
        }

        private void SetBusy(bool busy)
        {
            UseWaitCursor = busy;
            refreshButton.Enabled = !busy;
            serviceNameBox.Enabled = !busy;
            closeBehaviorButton.Enabled = !busy;
            preferencesButton.Enabled = !busy;
            foreach (Button button in operationButtons) button.Enabled = !busy;
        }

        private void Log(string message)
        {
            string compact = Regex.Replace((message ?? string.Empty).Trim(), "\\s+", " ");
            if (compact.Length > 220) compact = compact.Substring(0, 217) + "…";
            managerStatusValue.Text = "[" + DateTime.Now.ToString("HH:mm:ss") + "] " + compact;
            managerStatusValue.ForeColor = ThemeManager.GetPalette(darkTheme).Muted;
        }

        private void ShowError(string title, Exception exception)
        {
            string message = exception.Message.Trim();
            Log("失败：" + title + "；" + message);
            managerStatusValue.ForeColor = ThemeManager.GetPalette(darkTheme).Danger;
            MessageBox.Show(this, message, title, MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        private static bool PathEquals(string left, string right)
        {
            try { return string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase); }
            catch { return false; }
        }

        private static GroupBox CreateCard(string title, Rectangle bounds)
        {
            return new GroupBox
            {
                Text = title,
                Bounds = bounds,
                Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right,
                BackColor = Color.White,
                ForeColor = Navy,
                Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold)
            };
        }

        private static void AddCaption(Control parent, string text, int x, int y)
        {
            parent.Controls.Add(new Label { Text = text, Location = new Point(x, y), AutoSize = true, ForeColor = Muted, Font = new Font("Microsoft YaHei UI", 9F), Tag = "Muted" });
        }

        private static Label AddValue(Control parent, string text, int x, int y, int width, bool bold)
        {
            var label = new Label
            {
                Text = text,
                Location = new Point(x, y),
                Size = new Size(width, 27),
                AutoEllipsis = true,
                ForeColor = Navy,
                Font = new Font("Microsoft YaHei UI", bold ? 11F : 9F, bold ? FontStyle.Bold : FontStyle.Regular)
            };
            parent.Controls.Add(label);
            return label;
        }

        private static Button CreateButton(string text, Color backColor, Color foreColor, int width)
        {
            var button = new Button
            {
                Text = text,
                Size = new Size(width, 34),
                BackColor = backColor,
                ForeColor = foreColor,
                FlatStyle = FlatStyle.Flat,
                Cursor = Cursors.Hand,
                Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Bold)
            };
            button.Tag = backColor == Blue ? "Accent" :
                backColor == Color.FromArgb(190, 49, 68) ? "Danger" : "Button";
            return button;
        }

        private static Button AddAction(FlowLayoutPanel panel, string text, int width)
        {
            return AddAction(panel, text, width, Color.FromArgb(239, 243, 248), Navy);
        }

        private static Button AddAction(FlowLayoutPanel panel, string text, int width, Color backColor, Color foreColor)
        {
            Button button = CreateButton(text, backColor, foreColor, width);
            button.Margin = new Padding(4, 4, 4, 5);
            button.FlatAppearance.BorderColor = Color.FromArgb(214, 221, 231);
            panel.Controls.Add(button);
            return button;
        }
    }
}
