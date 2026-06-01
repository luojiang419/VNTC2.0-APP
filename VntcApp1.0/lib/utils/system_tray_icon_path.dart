String resolveSystemTrayIconAssetPath({
  required bool isWindows,
}) {
  return isWindows ? 'assets/app_icon.ico' : 'assets/app_icon.png';
}
