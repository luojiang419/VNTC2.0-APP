import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:vnt_app/data_persistence.dart';

enum AppLanguage {
  zhHans(
    code: 'zh_CN',
    displayName: '简体中文',
    locale: Locale('zh', 'CN'),
  ),
  en(
    code: 'en',
    displayName: 'English',
    locale: Locale('en'),
  );

  const AppLanguage({
    required this.code,
    required this.displayName,
    required this.locale,
  });

  final String code;
  final String displayName;
  final Locale locale;

  static AppLanguage? tryFromCode(String? code) {
    if (code == null || code.trim().isEmpty) {
      return null;
    }
    for (final language in AppLanguage.values) {
      if (language.code == code) {
        return language;
      }
    }
    return null;
  }

  static AppLanguage fromSystemLocale(Locale locale) {
    final languageCode = locale.languageCode.toLowerCase();
    if (languageCode.startsWith('zh')) {
      return AppLanguage.zhHans;
    }
    return AppLanguage.en;
  }
}

class AppLanguageController extends ChangeNotifier {
  AppLanguageController._();

  static final AppLanguageController instance = AppLanguageController._();

  final DataPersistence _dataPersistence = DataPersistence();

  AppLanguage? _overrideLanguage;

  AppLanguage get language =>
      _overrideLanguage ?? _detectSystemLanguage();
  Locale get locale => language.locale;
  bool get isEnglish => language == AppLanguage.en;
  bool get isUsingSystemLanguage => _overrideLanguage == null;

  AppLanguage _detectSystemLanguage() {
    final locales = PlatformDispatcher.instance.locales;
    if (locales.isNotEmpty) {
      return AppLanguage.fromSystemLocale(locales.first);
    }
    return AppLanguage.fromSystemLocale(PlatformDispatcher.instance.locale);
  }

  Future<void> load() async {
    final savedCode = await _dataPersistence.loadAppLanguageCode();
    _overrideLanguage = AppLanguage.tryFromCode(savedCode);
    notifyListeners();
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (_overrideLanguage == language) {
      return;
    }
    _overrideLanguage = language;
    await _dataPersistence.saveAppLanguageCode(language.code);
    notifyListeners();
  }
}

class AppI18n {
  static String translate(
    String source, [
    Map<String, Object?> args = const {},
  ]) {
    final translated = AppLanguageController.instance.isEnglish
        ? (_englishMap[source] ?? source)
        : source;

    var result = translated;
    for (final entry in args.entries) {
      result = result.replaceAll('{${entry.key}}', '${entry.value ?? ''}');
    }
    return result;
  }

  static final Map<String, String> _englishMap = {
    '仪表盘': 'Dashboard',
    '房间': 'Rooms',
    '链接状态': 'Link Status',
    '配置': 'Configs',
    '设置': 'Settings',
    '关于': 'About',
    '外观': 'Appearance',
    '应用': 'Application',
    '数据管理': 'Data',
    '调试': 'Debug',
    '自定义应用设置': 'Customize application settings',
    '取消': 'Cancel',
    '确定': 'OK',
    '保存': 'Save',
    '创建': 'Create',
    '清除': 'Clear',
    '自定义': 'Custom',
    '编辑': 'Edit',
    '删除': 'Delete',
    '复制': 'Duplicate',
    '查看': 'View',
    '连接': 'Connect',
    '已连接': 'Connected',
    '未连接': 'Disconnected',
    '默认服务器': 'Default server',
    '自动': 'Auto',
    '虚拟IP': 'Virtual IP',
    '服务器': 'Server',
    '设备名': 'Device name',
    'Token': 'Token',
    '主题模式': 'Theme mode',
    '选择应用的外观主题': 'Choose the application theme',
    '浅色': 'Light',
    '深色': 'Dark',
    '跟随系统': 'System',
    '开机自启': 'Auto start',
    '系统启动时自动运行应用': 'Run the app automatically when the system starts',
    '写入 ~/.config/autostart 实现开机自启':
        'Use ~/.config/autostart to enable auto start',
    '下次开机时自动启动应用': 'Start the app automatically after next boot',
    '编辑任务计划': 'Edit scheduled task',
    '开机自启已启用': 'Auto start enabled',
    '开机自启已关闭': 'Auto start disabled',
    '自动连接': 'Auto connect',
    '启动时自动连接默认配置': 'Connect the default config on startup',
    '界面语言': 'Interface language',
    '在简体中文和英文之间切换界面显示':
        'Switch the interface between Simplified Chinese and English',
    '界面语言已切换为 {language}':
        'Interface language switched to {language}',
    '默认配置': 'Default config',
    '自动连接时使用的配置': 'Config used for auto connect',
    '暂无配置': 'No configs',
    '请先在配置页面设置默认配置':
        'Please set a default config on the Config page first',
    '配置不存在，请重新设置':
        'The config no longer exists. Please configure it again.',
    '[{name}] 已连接': '[{name}] already connected',
    '正在连接中，请稍后再试':
        'A connection is already in progress. Please try again shortly.',
    '正在连接 {name} ...': 'Connecting {name} ...',
    '[{name}] 连接成功': '[{name}] connected successfully',
    '[{name}] 已重新连接到服务器':
        '[{name}] reconnected to the server',
    '[{name}] 服务已停止': '[{name}] service stopped',
    '连接失败 {message}': 'Connection failed: {message}',
    '[{name}] VPN连接成功': '[{name}] VPN connected successfully',
    '[{name}] VPN连接失败，请确认已添加VPN权限':
        '[{name}] VPN connection failed. Please confirm VPN permission has been granted.',
    '[{name}] VPN连接异常: {error}':
        '[{name}] VPN connection error: {error}',
    '日间': 'Light',
    '暗黑': 'Dark',
    '关闭按钮默认动作': 'Default close button action',
    '关闭按钮默认动作已设置为{label}':
        'Default close button action set to {label}',
    '每次询问': 'Ask every time',
    '最小化到托盘': 'Minimize to tray',
    '关闭程序': 'Exit application',
    '点击关闭按钮时弹出确认窗口':
        'Show a confirmation dialog when the close button is pressed',
    '点击关闭按钮时隐藏到系统托盘':
        'Hide to the system tray when the close button is pressed',
    '点击关闭按钮时直接退出应用':
        'Exit the app directly when the close button is pressed',
    '备份所有配置': 'Backup all configs',
    '将所有配置导出为文件': 'Export all configs to a file',
    '备份成功: {file}': 'Backup completed: {file}',
    '备份已取消': 'Backup cancelled',
    '备份失败: {error}': 'Backup failed: {error}',
    '配置已备份': 'Configs backed up',
    '恢复备份数据': 'Restore backup data',
    '从备份文件恢复配置': 'Restore configs from a backup file',
    '操作已取消': 'Operation cancelled',
    '分享失败: {error}': 'Share failed: {error}',
    '选择保存位置': 'Choose save location',
    '这是单个组网配置文件，请在配置页面的导入按钮中导入':
        'This is a single network config file. Please import it from the Config page.',
    '恢复成功': 'Restore completed',
    '恢复失败: {error}': 'Restore failed: {error}',
    '清除所有数据': 'Clear all data',
    '删除所有配置和缓存': 'Delete all configs and caches',
    '确定要清除所有数据吗？此操作将删除所有配置，且不可恢复。':
        'Are you sure you want to clear all data? This will delete all configs and cannot be undone.',
    '数据已清除': 'Data cleared',
    '应用日志': 'App logs',
    '查看应用运行日志': 'View application logs',
    '检查更新': 'Check for updates',
    '查看当前版本和更新状态': 'View current version and update status',
    '新建配置': 'New config',
    '导入配置': 'Import config',
    '配置管理': 'Config Management',
    '{count} 个配置': '{count} configs',
    '点击上方按钮新建或导入一个组网配置':
        'Create or import a network config using the buttons above',
    '还没有配置': 'No configs yet',
    '拉下刷新可重新加载配置列表': 'Pull down to reload the config list',
    '连接状态': 'Connection status',
    '网络速度': 'Network Speed',
    '网络质量': 'Network Quality',
    '流量统计': 'Traffic Statistics',
    '当前设备': 'Current Device',
    '当前配置': 'Current Config',
    '连接设备': 'Connected Devices',
    '虚拟 IP': 'Virtual IP',
    '中继服务器': 'Relay Server',
    '已连接网络': 'Network connected',
    '已连接 {name}': 'Connected to {name}',
    '当前设备信息': 'Current device info',
    '组网配置详情': 'Network config details',
    '在线设备': 'Online devices',
    '离线设备': 'Offline devices',
    '在线': 'Online',
    '离线': 'Offline',
    '上传速度': 'Upload speed',
    '下载速度': 'Download speed',
    '上传': 'Upload',
    '下载': 'Download',
    '上传: {value}': 'Upload: {value}',
    '下载: {value}': 'Download: {value}',
    '延迟': 'Latency',
    '丢包': 'Packet Loss',
    '延迟: {value}': 'Latency: {value}',
    '丢包: {value}': 'Packet loss: {value}',
    '点击新建配置': 'Tap to create a config',
    '未知配置名': 'Unknown config',
    '{count} 个活动连接': '{count} active connections',
    '目前有 {count} 个活动连接': 'There are currently {count} active connections',
    '是否断开组网连接?': 'Disconnect from the virtual network?',
    '{algorithm} 加密': '{algorithm} encrypted',
    '未加密': 'Unencrypted',
    '{count} 台': '{count} devices',
    '{online} 在线 / {offline} 离线': '{online} online / {offline} offline',
    '服务器自动分配': 'Assigned automatically by server',
    '用户静态指定': 'User-defined static assignment',
    '{value} 已复制': '{value} copied',
    '基本信息': 'Basic Information',
    '网络信息': 'Network Information',
    '服务器配置': 'Server Configuration',
    '安全配置': 'Security Configuration',
    '网络配置': 'Network Configuration',
    '高级配置': 'Advanced Configuration',
    '路由与映射': 'Routes & Mapping',
    '模拟测试': 'Simulation',
    '可在大厅管理房间，在聊天室交流，在私信中一对一沟通':
        'Manage rooms in the lobby, chat in rooms, and message peers directly',
    '请先连接一个组网配置后再进入大厅、聊天室或私信':
        'Connect to a network config before entering the lobby, rooms, or direct messages',
    '连接成功后即可进入大厅管理房间、在聊天室交流并发起私信。':
        'After connecting, you can manage rooms, chat, and start direct messages.',
    '大厅': 'Lobby',
    '聊天室': 'Chat',
    '私信': 'Direct Messages',
    '默认大厅': 'Default Lobby',
    '在线成员': 'Online Members',
    '联调工具': 'Debug Tools',
    '网络 {networkCount} 个 · 在线设备 {deviceCount} 个':
        '{networkCount} networks · {deviceCount} online devices',
    '刷新发现': 'Refresh discovery',
    '查看诊断': 'View diagnostics',
    '清空聊天数据': 'Clear chat data',
    '发起私信': 'Start direct message',
    '请求控制': 'Request control',
    '邀请控制': 'Invite control',
    '加好友': 'Add friend',
    '设置备注': 'Set remark',
    '拉黑': 'Block',
    '私信会话': 'Direct Message Sessions',
    '还没有私信会话': 'No direct message sessions yet',
    '从在线成员发起私聊后会出现在这里':
        'Direct message sessions will appear here after you start chatting with an online peer.',
    '聊天室已启用': 'Chat is ready',
    '私信已启用': 'Direct messages are ready',
    '从大厅选择默认大厅或房间后开始交流':
        'Select the default lobby or a room to start chatting.',
    '从左侧私信会话或在线成员开始一对一聊天':
        'Start a one-to-one conversation from the direct message list or online members.',
    '暂无消息': 'No messages yet',
    '现在可以发送文字、图片、文件和语音':
        'You can now send text, images, files, and voice messages.',
    '对方已同意，准备启动远程协助':
        'The other side accepted. Preparing remote assistance.',
    '远程协助准备完成': 'Remote assistance is ready',
    '远程协助会话已启动': 'Remote assistance session started',
    '远程协助请求已被拒绝':
        'The remote assistance request was declined',
    '远程协助会话已结束': 'Remote assistance session ended',
    '远程协助启动失败': 'Failed to start remote assistance',
    '日志': 'Logs',
    '滚动到底部': 'Scroll to bottom',
    '复制日志': 'Copy logs',
    '下载日志': 'Download logs',
    '清空日志': 'Clear logs',
    '重试': 'Retry',
    '暂无日志': 'No logs',
    '日志文件为空或尚未产生日志。':
        'The log file is empty or no logs have been generated yet.',
    '复制选中': 'Copy selected',
    '复制全部': 'Copy all',
    '复制此行': 'Copy this line',
    '复制所有日志': 'Copy all logs',
    '清空': 'Clear',
    '确定要清空所有日志文件吗？\n\n注意：日志文件内容将被清空，但文件会保留在logs目录。':
        'Clear all log files?\n\nThe log contents will be removed, but the files will remain in the logs directory.',
    '实时监听中 - 新日志将自动显示':
        'Live monitoring enabled - new logs will appear automatically',
    '组网参数配置': 'Network Config',
    '配置名称': 'Config name',
    '(方便在首页区分不同的组网配置选项，可填任意字符)':
        '(Used to distinguish network configs on the home screen. Any text is allowed.)',
    '基本参数': 'Basic Parameters',
    '组网token': 'Network token',
    '(相同的token和服务器才能组建一个虚拟局域网)':
        '(The same token and server are required to join the same virtual LAN.)',
    '请输入token': 'Please enter a token',
    '设备名称': 'Device name',
    '请输入设备名称': 'Please enter a device name',
    '虚拟IPv4': 'Virtual IPv4',
    '(不输入则由VNTS分配虚拟IPv4)':
        '(Leave empty to let VNTS assign the virtual IPv4 address.)',
    '请输入有效的 IPv4 地址': 'Please enter a valid IPv4 address',
    '服务器地址': 'Server address',
    '(VNTS 2.0 地址，支持 quic://、tcp://、wss://、dynamic://。兼容旧 udp:// 输入并会自动按 QUIC 处理)':
        '(VNTS 2.0 address. Supports quic://, tcp://, wss://, and dynamic://. Legacy udp:// input is accepted and treated as QUIC automatically.)',
    '地址不能为空': 'Address cannot be empty',
    '连接服务器协议': 'Server transport protocol',
    '压缩': 'Compression',
    '压缩级别': 'Compression level',
    '允许WireGuard客户端访问': 'Allow WireGuard clients',
    '允许': 'Allow',
    '不允许': 'Disallow',
    '子网代理&端口映射': 'Subnet Proxy & Port Mapping',
    '传输安全': 'Transport Security',
    '组网密码': 'Network password',
    '加密算法': 'Encryption algorithm',
    '服务端加密': 'Server encryption',
    '开启': 'Enabled',
    '关闭': 'Disabled',
    '数据指纹校验': 'Packet fingerprint verification',
    '更多参数': 'More Parameters',
    '设备ID': 'Device ID',
    '本地物理网卡': 'Local physical NIC',
    '禁用客户端中继': 'Disable client relay',
    '禁用后此客户端将不再为其他客户端提供中继转发功能':
        'When disabled, this client will no longer relay traffic for other clients.',
    '虚拟网卡名称': 'Virtual adapter name',
    '虚拟网卡mtu': 'Virtual adapter MTU',
    '请输入有效的正整数': 'Please enter a valid positive integer',
    '打洞模式': 'Punching mode',
    '使用Ipv4': 'Use IPv4',
    '使用Ipv6': 'Use IPv6',
    '传输模式': 'Transport mode',
    '仅中继': 'Relay only',
    '仅直连': 'Direct only',
    '打洞端口': 'Punching port',
    '请输入0到65535之间的数字':
        'Please enter a number between 0 and 65535',
    '路径模式': 'Routing mode',
    'P2P优先': 'Prefer P2P',
    '低延迟优先': 'Prefer low latency',
    '内置IP代理': 'Built-in IP proxy',
    '自定义dns服务器': 'Custom DNS servers',
    '模拟丢包率': 'Simulated packet loss',
    '请输入0到1之间的小数':
        'Please enter a decimal number between 0 and 1',
    '模拟延迟': 'Simulated latency',
    '请输入有效的整数': 'Please enter a valid integer',
    'stun服务器': 'STUN servers',
    '隐藏更多参数': 'Hide more parameters',
    '显示更多参数': 'Show more parameters',
    '至少勾选一个选项': 'Select at least one option',
    '项目开源地址': 'Open-source project',
    '功能特性': 'Features',
    '联系我们': 'Contact',
    '问题反馈': 'Issue tracker',
    '官方文档': 'Official documentation',
    'QQ群': 'QQ group',
    '应用信息与帮助': 'App information and help',
    '一个简单、高效、能快速组建虚拟局域网的工具':
        'A simple and efficient tool for quickly building a virtual LAN',
    '主题颜色': 'Theme color',
    '自定义应用主题颜色': 'Customize the application theme color',
    '主题颜色已更新': 'Theme color updated',
    '选择主题颜色': 'Choose theme color',
    '预设颜色': 'Preset Colors',
    '颜色预览效果': 'Color preview',
    '颜色值': 'Color values',
    '虚拟组网': 'Virtual networking',
    '轻松创建安全的虚拟局域网': 'Create a secure virtual LAN with ease',
    '高性能': 'High performance',
    '基于 Rust 构建，性能卓越': 'Built with Rust for strong performance',
    '跨平台': 'Cross-platform',
    '支持 Windows、macOS、Linux、ios':
        'Supports Windows, macOS, Linux, and iOS',
    '安全加密': 'Secure encryption',
    '端到端加密，保护数据安全':
        'End-to-end encryption to protect your data',
    '仪表盘：连接状态、流量、延迟、设备概览':
        'Dashboard: status, traffic, latency, and device overview',
  };
}

extension TranslatedStringExtension on String {
  String tr([Map<String, Object?> args = const {}]) {
    return AppI18n.translate(this, args);
  }
}
