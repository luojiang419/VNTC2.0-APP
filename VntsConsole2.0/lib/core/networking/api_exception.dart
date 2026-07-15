enum ApiErrorKind {
  unauthorized,
  forbidden,
  unavailable,
  invalidResponse,
  server,
}

class ApiException implements Exception {
  const ApiException(this.kind, this.message, {this.statusCode});

  final ApiErrorKind kind;
  final String message;
  final int? statusCode;

  bool get requiresAuthentication => kind == ApiErrorKind.unauthorized;

  @override
  String toString() => message;
}
