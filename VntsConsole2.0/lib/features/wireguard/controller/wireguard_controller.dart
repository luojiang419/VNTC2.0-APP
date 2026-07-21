import '../../../core/networking/api_exception.dart';
import '../../../shared/foundation/safe_change_notifier.dart';
import '../../networks/domain/network_models.dart';
import '../data/wireguard_repository.dart';
import '../domain/wireguard_models.dart';

class WireGuardController extends SafeChangeNotifier {
  WireGuardController(this._repository);

  final WireGuardRepository? _repository;
  List<NetworkInfo> networks = const [];
  List<WireGuardPeer> peers = const [];
  List<WireGuardPeerIp> allocations = const [];
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
        peers = const [];
        allocations = const [];
      } else {
        if (!networks.any((item) => item.code == selectedNetwork)) {
          selectedNetwork = networks.first.code;
        }
        await _refreshCurrent();
      }
    } on ApiException catch (exception) {
      error = exception.message;
    } catch (_) {
      error = 'WireGuard 数据格式无效';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> selectNetwork(String value) async {
    if (selectedNetwork == value) return;
    selectedNetwork = value;
    loading = true;
    error = null;
    notifyListeners();
    try {
      await _refreshCurrent();
    } on ApiException catch (exception) {
      error = exception.message;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> createPeer({
    required String peerId,
    required String publicKey,
    required WireGuardPeerProfile profile,
  }) async {
    await _mutate(
      () => _repository!.createPeer(
        networkCode: selectedNetwork!,
        peerId: peerId,
        publicKey: publicKey,
        enabled: true,
        profile: profile,
      ),
    );
  }

  Future<GeneratedWireGuardConfig> generatePeer(
    String peerId,
    WireGuardPeerProfile profile,
  ) async {
    mutating = true;
    error = null;
    notifyListeners();
    try {
      final generated = await _repository!.generatePeer(
        networkCode: selectedNetwork!,
        peerId: peerId,
        profile: profile,
      );
      await _refreshCurrent();
      return generated;
    } on ApiException catch (exception) {
      error = exception.message;
      rethrow;
    } finally {
      mutating = false;
      notifyListeners();
    }
  }

  Future<GeneratedWireGuardConfig> getPeerConfig(WireGuardPeer peer) async {
    mutating = true;
    error = null;
    notifyListeners();
    try {
      return await _repository!.getPeerConfig(
        networkCode: peer.networkCode,
        peerId: peer.peerId,
      );
    } on ApiException catch (exception) {
      error = exception.message;
      rethrow;
    } finally {
      mutating = false;
      notifyListeners();
    }
  }

  Future<void> updateProfile(
    WireGuardPeer peer,
    WireGuardPeerProfile profile,
  ) async {
    await _mutate(
      () => _repository!.updateProfile(
        networkCode: peer.networkCode,
        peerId: peer.peerId,
        profile: profile,
      ),
    );
  }

  Future<void> setEnabled(WireGuardPeer peer, bool enabled) async {
    await _mutate(
      () => _repository!.setEnabled(
        networkCode: peer.networkCode,
        peerId: peer.peerId,
        enabled: enabled,
      ),
    );
  }

  Future<void> deletePeer(WireGuardPeer peer) async {
    await _mutate(() => _repository!.deletePeer(peer.networkCode, peer.peerId));
  }

  Future<void> reserveIp(WireGuardPeer peer, String ip) async {
    await _mutate(
      () => _repository!.reserveIp(
        networkCode: peer.networkCode,
        peerId: peer.peerId,
        ip: ip,
      ),
    );
  }

  Future<void> releaseIp(WireGuardPeer peer) async {
    await _mutate(() => _repository!.releaseIp(peer.networkCode, peer.peerId));
  }

  Future<void> _mutate(Future<void> Function() operation) async {
    if (_repository == null || selectedNetwork == null) return;
    mutating = true;
    error = null;
    notifyListeners();
    try {
      await operation();
      await _refreshCurrent();
    } on ApiException catch (exception) {
      error = exception.message;
      rethrow;
    } finally {
      mutating = false;
      notifyListeners();
    }
  }

  Future<void> _refreshCurrent() async {
    final code = selectedNetwork;
    if (code == null || _repository == null) return;
    final results = await Future.wait<Object>([
      _repository.listPeers(code),
      _repository.listPeerIps(code),
    ]);
    peers = results[0] as List<WireGuardPeer>;
    allocations = results[1] as List<WireGuardPeerIp>;
  }
}
