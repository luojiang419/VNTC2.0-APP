import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/features/dashboard/controller/dashboard_controller.dart';
import 'package:vnts_console/features/dashboard/data/dashboard_repository.dart';
import 'package:vnts_console/features/dashboard/domain/dashboard_snapshot.dart';
import 'package:vnts_console/features/dashboard/view/dashboard_placeholder_page.dart';

import 'dashboard_test_data.dart';

void main() {
  testWidgets('仪表盘显示真实快照并在第二个样本绘制趋势', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _QueueRepository([
      dashboardSnapshot(sampledAtMs: 1000, txBytes: 1000, rxBytes: 2000),
      dashboardSnapshot(sampledAtMs: 2000, txBytes: 3000, rxBytes: 5000),
    ]);
    final controller = DashboardController(
      repository: repository,
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: DashboardPlaceholderPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dashboard-ready')), findsOneWidget);
    expect(find.text('4'), findsWidgets);
    expect(find.textContaining('累计发送'), findsOneWidget);

    await controller.refresh();
    await tester.pump();
    expect(find.byKey(const Key('traffic-trend-chart')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(controller.isPolling, isFalse);
  });
}

class _QueueRepository implements DashboardRepositoryContract {
  _QueueRepository(Iterable<DashboardSnapshot> snapshots)
    : _snapshots = Queue.of(snapshots);

  final Queue<DashboardSnapshot> _snapshots;

  @override
  Future<DashboardSnapshot> fetchSnapshot() async => _snapshots.removeFirst();
}
