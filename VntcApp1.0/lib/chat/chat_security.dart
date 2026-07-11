import 'dart:io';

bool isChatRemoteAddressConsistent({
  required String remoteAddress,
  required String declaredVirtualIp,
}) {
  final remote = remoteAddress.trim();
  final declared = declaredVirtualIp.trim();
  if (remote.isEmpty || declared.isEmpty) {
    return false;
  }
  if (remote == declared) {
    return true;
  }

  final remoteParsed = InternetAddress.tryParse(remote);
  final declaredParsed = InternetAddress.tryParse(declared);
  if (remoteParsed == null || declaredParsed == null) {
    return false;
  }
  return remoteParsed.address == declaredParsed.address;
}
