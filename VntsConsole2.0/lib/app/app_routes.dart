import 'package:flutter/material.dart';

enum AppRoute {
  dashboard,
  networks,
  devices,
  wireGuard,
  peerServers,
  serviceControl,
  logs,
  settings,
}

extension AppRoutePresentation on AppRoute {
  String get label => switch (this) {
    AppRoute.dashboard => '仪表盘',
    AppRoute.networks => '网络',
    AppRoute.devices => '设备',
    AppRoute.wireGuard => 'WireGuard',
    AppRoute.peerServers => '互联服务器',
    AppRoute.serviceControl => '服务运维',
    AppRoute.logs => '日志',
    AppRoute.settings => '设置',
  };

  String get description => switch (this) {
    AppRoute.dashboard => '服务健康、资源、流量和拓扑总览',
    AppRoute.networks => '创建和维护虚拟网络',
    AppRoute.devices => '查看节点状态与连接信息',
    AppRoute.wireGuard => '管理 Peer、IP 与客户端配置',
    AppRoute.peerServers => '管理跨服务端互联与延迟',
    AppRoute.serviceControl => '安装、更新和诊断 Windows 服务',
    AppRoute.logs => '筛选、复制和导出运行日志',
    AppRoute.settings => '主题、刷新策略与本地控制台设置',
  };

  IconData get icon => switch (this) {
    AppRoute.dashboard => Icons.space_dashboard_outlined,
    AppRoute.networks => Icons.hub_outlined,
    AppRoute.devices => Icons.devices_other_outlined,
    AppRoute.wireGuard => Icons.shield_outlined,
    AppRoute.peerServers => Icons.dns_outlined,
    AppRoute.serviceControl => Icons.settings_suggest_outlined,
    AppRoute.logs => Icons.receipt_long_outlined,
    AppRoute.settings => Icons.tune_outlined,
  };
}
