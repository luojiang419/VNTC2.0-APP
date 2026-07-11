/// 将网关路由 RTT 转换为可用于丢包率统计的连通性样本。
///
/// 返回值含义：
/// - `true`：有有效 RTT，视为连通。
/// - `false`：RTT 达到超时哨兵值，视为失败。
/// - `null`：没有有效 RTT 样本，不纳入丢包率统计。
bool? gatewayConnectivitySampleFromRt(int? rt) {
  if (rt == null || rt <= 0) {
    return null;
  }
  if (rt >= 9999) {
    return false;
  }
  return true;
}

/// 综合在线对端与虚拟网关 RTT，生成一次可用于丢包统计的样本。
///
/// 网关的超时哨兵不能单独证明链路丢包，因为部分核心状态下网关没有
/// 独立 RTT；只有全部在线对端都返回明确超时才判定本轮失败。
bool? networkConnectivitySampleFromRoutes({
  required Iterable<int?> onlinePeerRts,
  required int? gatewayRt,
}) {
  final peerRts = onlinePeerRts.toList(growable: false);
  final peerSamples =
      peerRts.map(gatewayConnectivitySampleFromRt).toList(growable: false);
  if (peerSamples.any((sample) => sample == true)) {
    return true;
  }
  if (peerSamples.isNotEmpty &&
      peerSamples.every((sample) => sample == false)) {
    return false;
  }
  if (gatewayConnectivitySampleFromRt(gatewayRt) == true) {
    return true;
  }
  return null;
}

class PacketLossWindow {
  PacketLossWindow({
    this.maxSamples = 50,
    this.consecutiveFailureThreshold = 3,
  })  : assert(maxSamples > 0),
        assert(consecutiveFailureThreshold > 0);

  final int maxSamples;
  final int consecutiveFailureThreshold;
  final List<bool> _samples = <bool>[];
  int _consecutiveFailures = 0;

  bool get hasSamples => _samples.isNotEmpty;
  List<bool> get samples => List<bool>.unmodifiable(_samples);
  double get lossRate {
    if (_samples.isEmpty) {
      return 0;
    }
    final failed = _samples.where((sample) => !sample).length;
    return failed * 100 / _samples.length;
  }

  /// 记录原始探测结果。返回非空值时表示该样本已进入统计窗口。
  bool? record(bool? sample) {
    if (sample == null) {
      return null;
    }
    if (sample) {
      _consecutiveFailures = 0;
      _append(true);
      return true;
    }
    _consecutiveFailures++;
    if (_consecutiveFailures < consecutiveFailureThreshold) {
      return null;
    }
    _append(false);
    return false;
  }

  void clear() {
    _samples.clear();
    _consecutiveFailures = 0;
  }

  void _append(bool sample) {
    _samples.add(sample);
    if (_samples.length > maxSamples) {
      _samples.removeAt(0);
    }
  }
}
