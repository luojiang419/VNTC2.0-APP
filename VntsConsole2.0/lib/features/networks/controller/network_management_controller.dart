import '../../../core/networking/api_exception.dart';
import '../../../shared/foundation/safe_change_notifier.dart';
import '../data/network_repository.dart';
import '../domain/network_models.dart';

class NetworkManagementController extends SafeChangeNotifier {
  NetworkManagementController(this._repository);

  final NetworkRepository? _repository;
  List<NetworkInfo> networks = const [];
  bool loading = true;
  bool mutating = false;
  String? error;

  Future<void> load() async {
    final repository = _repository;
    if (repository == null) {
      loading = false;
      error = '管理接口尚未配置，请先在“服务运维”中登录。';
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      networks = await repository.listNetworks();
    } on ApiException catch (exception) {
      error = exception.message;
    } catch (_) {
      error = '网络数据格式无效';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> create({
    required String code,
    required String gateway,
    required int netmask,
    required int leaseDurationSeconds,
  }) async {
    final repository = _repository;
    if (repository == null) return;
    await _mutate(
      () => repository.createNetwork(
        code: code,
        gateway: gateway,
        netmask: netmask,
        leaseDurationSeconds: leaseDurationSeconds,
      ),
    );
  }

  Future<void> update({
    required String code,
    required String gateway,
    required int netmask,
    required int leaseDurationSeconds,
  }) async {
    final repository = _repository;
    if (repository == null) return;
    await _mutate(
      () => repository.updateNetwork(
        code: code,
        gateway: gateway,
        netmask: netmask,
        leaseDurationSeconds: leaseDurationSeconds,
      ),
    );
  }

  Future<void> delete(String code) async {
    final repository = _repository;
    if (repository == null) return;
    await _mutate(() => repository.deleteNetwork(code));
  }

  Future<void> _mutate(Future<void> Function() operation) async {
    mutating = true;
    error = null;
    notifyListeners();
    try {
      await operation();
      networks = await _repository!.listNetworks();
    } on ApiException catch (exception) {
      error = exception.message;
      rethrow;
    } finally {
      mutating = false;
      notifyListeners();
    }
  }
}

class DeviceManagementController extends SafeChangeNotifier {
  DeviceManagementController(this._repository);

  final NetworkRepository? _repository;
  List<NetworkInfo> networks = const [];
  List<DeviceInfo> devices = const [];
  String? selectedNetwork;
  bool loading = true;
  bool mutating = false;
  String? error;

  Future<void> load() async {
    final repository = _repository;
    if (repository == null) {
      loading = false;
      error = '管理接口尚未配置，请先在“服务运维”中登录。';
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      networks = await repository.listNetworks();
      if (networks.isEmpty) {
        selectedNetwork = null;
        devices = const [];
      } else {
        selectedNetwork ??= networks.first.code;
        if (!networks.any((item) => item.code == selectedNetwork)) {
          selectedNetwork = networks.first.code;
        }
        devices = await repository.listDevices(selectedNetwork!);
      }
    } on ApiException catch (exception) {
      error = exception.message;
    } catch (_) {
      error = '设备数据格式无效';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> selectNetwork(String code) async {
    if (selectedNetwork == code) return;
    selectedNetwork = code;
    await _loadDevices();
  }

  Future<void> deleteDevice(String deviceId) async {
    if (_repository == null || selectedNetwork == null) return;
    mutating = true;
    notifyListeners();
    try {
      await _repository.deleteDevice(selectedNetwork!, deviceId);
      devices = await _repository.listDevices(selectedNetwork!);
    } on ApiException catch (exception) {
      error = exception.message;
      rethrow;
    } finally {
      mutating = false;
      notifyListeners();
    }
  }

  Future<void> _loadDevices() async {
    if (_repository == null || selectedNetwork == null) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      devices = await _repository.listDevices(selectedNetwork!);
    } on ApiException catch (exception) {
      error = exception.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }
}
