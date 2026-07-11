enum SilentStartWindowAction {
  showNormally,
  keepHidden,
  showTrayFailureFallback,
}

SilentStartWindowAction resolveSilentStartWindowAction({
  required bool silentStart,
  required bool trayInitialized,
}) {
  if (!silentStart) {
    return SilentStartWindowAction.showNormally;
  }
  return trayInitialized
      ? SilentStartWindowAction.keepHidden
      : SilentStartWindowAction.showTrayFailureFallback;
}
