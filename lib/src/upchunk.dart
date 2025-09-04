import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:mime/mime.dart';

class Upchunk {
  Upchunk({
    required this.endPoint,
    required this.file,
    this.maxRetries = 5,
    int preferredChunkSize = 5,
  }) : preferredChunkSize = preferredChunkSize * 1024 * 1024;

  final Uri endPoint;
  final XFile file;
  final int preferredChunkSize;
  final int maxRetries;

  late final Dio dio;
  late final int fileSize;
  late final int numberOfChunks;
  late final String? mimeType;

  final List<Chunk> chunks = [];

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
    dio = Dio(BaseOptions(receiveTimeout: const Duration(seconds: 5)));
  }

  Future<void> initialize() async {
    await _initializeValues();
    await _initializeMimeType();
    _initializeChunks();
    _initializeDio();
  }

  Future<void> startUpload() async {
    while (chunks.isNotEmpty) {
      if (chunks.first.isDirty) {
        break;
      }

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
        );
        if (Helpers.successCodes.contains(res.statusCode)) {
          chunks.removeAt(0);
        } else {
          chunks.first.setupRetry();
        }
      } catch (_) {
        chunks.first.setupRetry();
      }
    }
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
  void setupRetry() => retry++;
  bool get isDirty => retry == root.maxRetries;
}

class Helpers {
  Helpers._();

  static const successCodes = [200, 201, 202, 204, 308];
  static const defaultContentType = 'application/octet-stream';
  static const contentRangeHeader = 'content-range';
}
