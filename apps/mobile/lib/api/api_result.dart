/// Satu galat yang aman ditunjukkan ke pengguna.
///
/// `code` memakai daftar tertutup yang sama dengan `docs/API.md`
/// (VALIDATION_ERROR, NOT_FOUND, CONFLICT, RUNTIME_ERROR, dan
/// seterusnya). Kegagalan yang tidak berasal dari server, misalnya
/// jaringan mati atau badan balasan yang tidak bisa dibaca, dipetakan ke
/// RUNTIME_ERROR supaya pemanggil hanya menghadapi satu bentuk galat.
class ApiError {
  final String code;
  final String message;

  const ApiError(this.code, this.message);

  @override
  String toString() => '$code: $message';
}

/// Hasil satu panggilan API, sukses atau gagal, tanpa lemparan.
///
/// Sengaja meniru amplop yang sudah dipakai klien web
/// (`apps/web/src/lib/api.ts`): setiap pemanggil menghadapi satu tipe
/// hasil, dan tidak ada satu pun tempat di aplikasi yang perlu
/// try/catch sendiri.
class ApiResult<T> {
  final T? _data;
  final ApiError? _error;

  const ApiResult.success(T data)
      : _data = data,
        _error = null;

  const ApiResult.failure(ApiError error)
      : _data = null,
        _error = error;

  bool get isSuccess => _error == null;
  T? get dataOrNull => _data;
  ApiError? get errorOrNull => _error;

  static ApiResult<T> runtimeError<T>(String message) =>
      ApiResult<T>.failure(ApiError('RUNTIME_ERROR', message));

  /// Membaca amplop `{ success, data }` atau `{ success, error }`.
  ///
  /// Apa pun yang tidak berbentuk demikian, termasuk data yang gagal
  /// diurai oleh [parse], menjadi RUNTIME_ERROR. Fungsi ini tidak pernah
  /// melempar.
  static ApiResult<T> fromEnvelope<T>(
    Object? body,
    T Function(Map<String, dynamic> data) parse,
  ) {
    if (body is! Map<String, dynamic>) {
      return ApiResult.runtimeError<T>('Balasan API tidak bisa dibaca.');
    }

    final success = body['success'];

    if (success == true) {
      final data = body['data'];
      if (data is! Map<String, dynamic>) {
        return ApiResult.runtimeError<T>('Balasan API tidak sesuai bentuk yang diharapkan.');
      }
      try {
        return ApiResult<T>.success(parse(data));
      } catch (_) {
        return ApiResult.runtimeError<T>('Balasan API tidak sesuai bentuk yang diharapkan.');
      }
    }

    if (success == false) {
      final error = body['error'];
      if (error is Map<String, dynamic>) {
        final code = error['code'];
        final message = error['message'];
        return ApiResult<T>.failure(
          ApiError(
            code is String ? code : 'RUNTIME_ERROR',
            message is String ? message : 'Terjadi galat pada API.',
          ),
        );
      }
      return ApiResult.runtimeError<T>('Terjadi galat pada API.');
    }

    return ApiResult.runtimeError<T>('Balasan API tidak bisa dibaca.');
  }
}
