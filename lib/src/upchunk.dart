import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:mime/mime.dart';

class Upchunk with Resumable {
  Upchunk({
    required this.endPoint,
    required this.file,
    this.maxRetries = 5,
    int preferredChunkSize = 5,
    this.onError,
    this.onSuccess,
  }) : preferredChunkSize = preferredChunkSize * 1024 * 1024;

  final Uri endPoint;
  final XFile file;
  final int preferredChunkSize;
  final int maxRetries;

  late final Dio dio;
  late final int fileSize;
  late final int numberOfChunks;
  late final String? mimeType;
  CancelToken? cancelToken;

  final List<Chunk> chunks = [];

  final void Function(dynamic error, dynamic trace)? onError;
  final VoidCallback? onSuccess;

  Future<void> _initializeValues() async {
    fileSize = await file.length();
    numberOfChunks = (fileSize / preferredChunkSize).ceil();
  }

  Future<void> _initializeMimeType() async {
    try {
      mimeType = await lookupMimeType(file.path);
    } catch (_) {
      mimeType = null;
    }
  }

  void _initializeChunks() {
    for (int i = 0; i < numberOfChunks; i++) {
      final start = i * preferredChunkSize;
      final end =
          (start + preferredChunkSize <= fileSize)
              ? start + preferredChunkSize
              : fileSize;

      chunks.add(Chunk(this, start: start, end: end));
    }
  }

  void _initializeDio() {
    cancelToken = CancelToken();

    dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 5),
      ),
    );
  }

  void _initializeNetworkChecker() {
    InternetConnection().onStatusChange.listen((status) {
      if (status == InternetStatus.connected) {
        resume();
      } else {
        pause();
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
    if (isPaused) return;

    while (chunks.isNotEmpty) {
      try {
        final res = await dio.putUri<void>(
          endPoint,
          data: chunks.first.data,
          options: Options(
            headers: {
              Headers.contentLengthHeader: chunks.first.size,
              Headers.contentTypeHeader: mimeType ?? Helpers.defaultContentType,
              Helpers.contentRangeHeader:
                  'bytes ${chunks.first.start}-${chunks.first.end - 1}/$fileSize',
            },
          ),
          cancelToken: cancelToken,
        );
        if (Helpers.successCodes.contains(res.statusCode)) {
          chunks.removeAt(0);
        } else {
          throw res;
        }
      } catch (error, stackTrace) {
        if (error is DioException && error.type == DioExceptionType.cancel) {
          return;
        }

        if (!chunks.first.isDirty) {
          await chunks.first.setupRetry();
        } else {
          _handleError(error, stackTrace);
        }
      }
    }

    if (chunks.isEmpty) onSuccess?.call();
  }

  void _handleError(dynamic error, dynamic stack) {
    if (onError != null) {
      onError!(error, stack);
    } else {
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  void pause() {
    super.pause();

    cancelToken?.cancel();
    cancelToken = null;
  }

  @override
  void resume() {
    super.resume();

    cancelToken = CancelToken();
    startUpload();
  }
}

class Chunk {
  Chunk(this.root, {required this.start, required this.end});

  final int start;
  final int end;
  final Upchunk root;

  int get size => end - start;
  Stream<Uint8List> get data => root.file.openRead(start, end);

  int retry = 0;
  bool get isDirty => retry >= root.maxRetries;

  Future<void> setupRetry() {
    retry++;

    return Future.delayed(Duration(seconds: (retry * 2).clamp(2, 10)));
  }
}

class Helpers {
  Helpers._();

  static const successCodes = [200, 201, 202, 204, 308];
  static const defaultContentType = 'application/octet-stream';
  static const contentRangeHeader = 'content-range';
}

mixin Resumable {
  bool isPaused = false;

  @mustCallSuper
  void pause() {
    if (isPaused) return;

    isPaused = true;
  }

  @mustCallSuper
  void resume() {
    if (!isPaused) return;

    isPaused = false;
  }
}
