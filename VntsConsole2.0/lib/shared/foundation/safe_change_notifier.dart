import 'package:flutter/foundation.dart';

/// Ignores late notifications from asynchronous work after its owning view
/// has been disposed.
abstract class SafeChangeNotifier extends ChangeNotifier {
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
