class TrafficSample {
  const TrafficSample({
    required this.sampledAt,
    required this.txBytesPerSecond,
    required this.rxBytesPerSecond,
  });

  final DateTime sampledAt;
  final double txBytesPerSecond;
  final double rxBytesPerSecond;
}

class FixedRingBuffer<T> {
  FixedRingBuffer(this.capacity) : assert(capacity > 0);

  final int capacity;
  final List<T> _items = [];

  int get length => _items.length;
  List<T> get values => List.unmodifiable(_items);

  void add(T value) {
    if (_items.length == capacity) {
      _items.removeAt(0);
    }
    _items.add(value);
  }

  List<T> last(int count) {
    final start = (_items.length - count).clamp(0, _items.length);
    return List.unmodifiable(_items.sublist(start));
  }

  void clear() => _items.clear();
}
