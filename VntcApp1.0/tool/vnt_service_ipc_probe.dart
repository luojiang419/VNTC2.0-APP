import 'package:vnt_app/services/vnt_service_client.dart';

Future<void> main() async {
  final client = VntServiceClient();
  await client.ping();
  final status = await client.getStatus();
  await client.reload();
  print(
    'IPC_OK service=${status.serviceState} connection=${status.connectionState}',
  );
}
