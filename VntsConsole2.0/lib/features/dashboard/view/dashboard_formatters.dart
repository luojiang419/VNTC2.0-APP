String formatBytes(num? bytes, {bool perSecond = false}) {
  if (bytes == null) return '不支持';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value.abs() >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value >= 100 || unit == 0
      ? 0
      : value >= 10
      ? 1
      : 2;
  return '${value.toStringAsFixed(digits)} ${units[unit]}${perSecond ? '/s' : ''}';
}

String formatPercent(double? value) {
  return value == null ? '采样中' : '${value.toStringAsFixed(1)}%';
}

String formatUptime(int seconds) {
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (days > 0) return '$days 天 $hours 小时';
  if (hours > 0) return '$hours 小时 $minutes 分';
  return '$minutes 分钟';
}
