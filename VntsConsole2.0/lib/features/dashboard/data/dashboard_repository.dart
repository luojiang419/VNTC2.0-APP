import '../../../core/networking/api_client.dart';
import '../domain/dashboard_snapshot.dart';

abstract interface class DashboardRepositoryContract {
  Future<DashboardSnapshot> fetchSnapshot();
}

class DashboardRepository implements DashboardRepositoryContract {
  const DashboardRepository(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<DashboardSnapshot> fetchSnapshot() async {
    final data = await _apiClient.getData('dashboard/snapshot');
    try {
      return DashboardSnapshot.fromJson(data);
    } on FormatException catch (error) {
      throw FormatException('Dashboard 数据格式无效：${error.message}');
    }
  }
}
