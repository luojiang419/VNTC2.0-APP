import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/networking/api_exception.dart';
import '../data/dashboard_repository.dart';
import '../domain/dashboard_snapshot.dart';
import '../domain/traffic_sample.dart';

enum DashboardLoadState { idle, loading, ready, authenticationRequired, error }

class DashboardController extends ChangeNotifier {
  DashboardController({
    required DashboardRepositoryContract repository,
    this.pollInterval = const Duration(seconds: 1),
  }) : _repository = repository;

  static const trendCapacity = 15 * 60;

  final DashboardRepositoryContract _repository;
  final Duration pollInterval;
  final FixedRingBuffer<TrafficSample> _traffic = FixedRingBuffer(
    trendCapacity,
  );

  DashboardLoadState _state = DashboardLoadState.idle;
  DashboardSnapshot? _snapshot;
  DashboardSnapshot? _previousSnapshot;
  String? _errorMessage;
  Timer? _timer;
  bool _refreshing = false;
  bool _visible = false;
  double? _txBytesPerSecond;
  double? _rxBytesPerSecond;

  DashboardLoadState get state => _state;
  DashboardSnapshot? get snapshot => _snapshot;
  String? get errorMessage => _errorMessage;
  bool get isPolling => _timer?.isActive == true;
  bool get hasStaleData =>
      _state == DashboardLoadState.error && _snapshot != null;
  double? get txBytesPerSecond => _txBytesPerSecond;
  double? get rxBytesPerSecond => _rxBytesPerSecond;
  List<TrafficSample> get traffic15Minutes => _traffic.values;
  List<TrafficSample> get traffic5Minutes => _traffic.last(5 * 60);

  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    if (visible) {
      _timer?.cancel();
      _timer = Timer.periodic(pollInterval, (_) => unawaited(refresh()));
      unawaited(refresh());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> refresh() async {
    if (!_visible || _refreshing) return;
    _refreshing = true;
    if (_snapshot == null) {
      _state = DashboardLoadState.loading;
      notifyListeners();
    }
    try {
      final next = await _repository.fetchSnapshot();
      _updateTraffic(next);
      _previousSnapshot = next;
      _snapshot = next;
      _state = DashboardLoadState.ready;
      _errorMessage = null;
    } on ApiException catch (error) {
      _state = error.requiresAuthentication
          ? DashboardLoadState.authenticationRequired
          : DashboardLoadState.error;
      _errorMessage = error.message;
    } on FormatException catch (error) {
      _state = DashboardLoadState.error;
      _errorMessage = error.message;
    } catch (_) {
      _state = DashboardLoadState.error;
      _errorMessage = '读取仪表盘数据失败';
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  void _updateTraffic(DashboardSnapshot next) {
    final previous = _previousSnapshot;
    if (previous == null ||
        next.traffic.txBytesTotal < previous.traffic.txBytesTotal ||
        next.traffic.rxBytesTotal < previous.traffic.rxBytesTotal) {
      _txBytesPerSecond = null;
      _rxBytesPerSecond = null;
      _traffic.clear();
      return;
    }
    final elapsed =
        next.sampledAt.difference(previous.sampledAt).inMilliseconds / 1000;
    if (elapsed <= 0) return;
    _txBytesPerSecond =
        (next.traffic.txBytesTotal - previous.traffic.txBytesTotal) / elapsed;
    _rxBytesPerSecond =
        (next.traffic.rxBytesTotal - previous.traffic.rxBytesTotal) / elapsed;
    _traffic.add(
      TrafficSample(
        sampledAt: next.sampledAt,
        txBytesPerSecond: _txBytesPerSecond!,
        rxBytesPerSecond: _rxBytesPerSecond!,
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
