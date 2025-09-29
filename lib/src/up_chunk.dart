import 'dart:async';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:mime/mime.dart';

class UpChunk {
  UpChunk({
    required this.endPoint,
    required this.file,
    this.maxRetries = 5,
    int preferredChunkSize = 2,
    this.onError,
    this.onSuccess,
    this.onProgress,
    this.onRetrying,
  }) : preferredChunkSize = preferredChunkSize * 1024 * 1024;

  final Uri endPoint;
  final XFile file;
  final int preferredChunkSize;
  final int maxRetries;

  late final Dio _dio;
  late final int _fileSize;
  late final int _numberOfChunks;
  late final String? _mimeType;
  CancelToken? _cancelToken;

  final List<Chunk> _chunks = [];

  StreamSubscription<InternetStatus>? _netSub;
  bool _isPaused = false;

  final void Function(Object error, StackTrace trace)? onError;
  final VoidCallback? onSuccess;
  final ValueChanged<double>? onProgress;
  final void Function(bool waitingForNetwork)? onRetrying;

  Future<void> _initializeValues() async {
    _fileSize = await file.length();
    _numberOfChunks = (_fileSize / preferredChunkSize).ceil();
  }

  Future<void> _initializeMimeType() async {
    try {
      _mimeType = lookupMimeType(file.path);
    } catch (_) {
      _mimeType = null;
    }
  }

  void _initializeChunks() {
    for (int i = 0; i < _numberOfChunks; i++) {
      final start = i * preferredChunkSize;
      final end =
          (start + preferredChunkSize <= _fileSize)
              ? start + preferredChunkSize
              : _fileSize;

      _chunks.add(Chunk(this, start: start, end: end));
    }
  }

  void _initializeDio() {
    _cancelToken = CancelToken();

    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
        validateStatus: (_) => true,
        followRedirects: false,
      ),
    );
  }

  void _initializeNetworkChecker() {
    _netSub = InternetConnection().onStatusChange.listen((status) {
      if (status == InternetStatus.connected) {
        resume();
        onRetrying?.call(false);
      } else {
        pause();
        onRetrying?.call(true);
      }
    });
  }

  Future<void> initialize() async {
    await _initializeValues();
    await _initializeMimeType();
    _initializeChunks();
    _initializeDio();
    _initializeNetworkChecker();
  }

  Future<void> startUpload() async {
    while (_chunks.isNotEmpty) {
      if (_isPaused) break;
      try {
        final res = await _dio.putUri<void>(
          endPoint,
          data: _chunks.first.data,
          options: Options(
            headers: {
              Headers.contentLengthHeader: _chunks.first.size,
              Headers.contentTypeHeader:
                  _mimeType ?? Helpers.defaultContentType,
              Helpers.contentRangeHeader:
                  'bytes ${_chunks.first.start}-${_chunks.first.end - 1}/$_fileSize',
            },
          ),
          onSendProgress: (sent, _) {
            final pending = _chunks.map((e) => e.size).fold(0, (i, e) => i + e);
            final progress = 1 - ((pending - sent) / _fileSize);
            onProgress?.call(progress * 100);
          },
          cancelToken: _cancelToken,
        );
        if (Helpers.successCodes.contains(res.statusCode)) {
          _chunks.removeAt(0);
        } else {
          throw res;
        }
      } catch (error, stackTrace) {
        final isCancel = error is DioException && CancelToken.isCancel(error);
        if (isCancel) return;

        final failed =
            error is Response &&
            !Helpers.tempErrorCodes.contains(error.statusCode);

        if (_chunks.first.isDirty || failed) {
          _handleError(error, stackTrace);
          return;
        }

        onRetrying?.call(false);
        await _chunks.first.setupRetry();
      }
    }

    if (_chunks.isEmpty) onSuccess?.call();
  }

  void _handleError(Object error, StackTrace stack) {
    if (onError != null) {
      onError!(error, stack);
    } else {
      Error.throwWithStackTrace(error, stack);
    }
  }

  void pause() {
    if (_isPaused) return;

    _isPaused = true;
    _cancelToken?.cancel();
    _cancelToken = null;
  }

  void resume() {
    if (!_isPaused) return;

    _isPaused = false;
    _cancelToken = CancelToken();
    startUpload();
  }

  void dispose() {
    pause();

    try {
      _dio.close(force: true);
      _netSub?.cancel();
      _netSub = null;
    } catch (_) {}
  }

  void cancel() {
    dispose();
    _handleError(CancelledByUser(), StackTrace.current);
  }
}

class Chunk {
  Chunk(this.root, {required this.start, required this.end});

  final int start;
  final int end;
  final UpChunk root;

  int get size => end - start;
  Stream<Uint8List> get data => root.file.openRead(start, end);

  int retry = 0;
  bool get isDirty => retry >= root.maxRetries;

  Future<void> setupRetry() {
    retry++;

    return Future.delayed(const Duration(seconds: 1));
  }
}

class Helpers {
  Helpers._();

  static const successCodes = [200, 201, 202, 204, 308];
  static const tempErrorCodes = [408, 502, 503, 504];

  static const defaultContentType = 'application/octet-stream';
  static const contentRangeHeader = 'content-range';
}

class CancelledByUser implements Exception {}
