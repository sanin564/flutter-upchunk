import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';

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
  final List<Chunk> chunks = [];

  void _initializeDio() {
    dio = Dio();
  }

  Future<void> _initializeValues() async {
    fileSize = await file.length();
    numberOfChunks = (fileSize / preferredChunkSize).ceil();
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

  Future<void> initialize() async {
    _initializeDio();
    await _initializeValues();
    _initializeChunks();
  }

  Future<void> startUpload() async {
    while (chunks.isNotEmpty) {
      if (chunks.first.isDirty) {
        break;
      }

      try {
        final res = await dio.putUri<void>(endPoint, data: chunks.first.data);
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
  static const successCodes = [200, 201, 202, 204, 308];
}
