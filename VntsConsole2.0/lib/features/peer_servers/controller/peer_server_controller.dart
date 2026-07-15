import '../../../core/networking/api_exception.dart';
import '../../../shared/foundation/safe_change_notifier.dart';
import '../data/peer_server_repository.dart';
import '../domain/peer_server_models.dart';

class PeerServerController extends SafeChangeNotifier {
  PeerServerController(this._repository);

  final PeerServerRepository? _repository;
  PeerServerSnapshot snapshot = const PeerServerSnapshot(
    outbound: [],
    inbound: [],
  );
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
      snapshot = await repository.list();
    } on ApiException catch (exception) {
      error = exception.message;
    } catch (_) {
      error = '互联服务器数据格式无效';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> add(String address) async {
    await _mutate(() => _repository!.add(address));
  }

  Future<void> delete(String address) async {
    await _mutate(() => _repository!.delete(address));
  }

  Future<void> _mutate(Future<void> Function() operation) async {
    if (_repository == null) return;
    mutating = true;
    error = null;
    notifyListeners();
    try {
      await operation();
      snapshot = await _repository.list();
    } on ApiException catch (exception) {
      error = exception.message;
      rethrow;
    } finally {
      mutating = false;
      notifyListeners();
    }
  }
}
