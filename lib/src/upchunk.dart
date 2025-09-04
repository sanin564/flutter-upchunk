import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';

class Upchunk {
  Upchunk({
    required this.endPoint,
    required this.file,
    int preferredChunkSize = 5,
  }) : preferredChunkSize = preferredChunkSize * 1024 * 1024;

  final Uri endPoint;
  final XFile file;
  final int preferredChunkSize;

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

      chunks.add(Chunk(file, start: start, end: end));
    }
  }

  Future<void> initialize() async {
    _initializeDio();
    await _initializeValues();
    _initializeChunks();
  }

  Future<void> startUpload() async {}
}

class Chunk {
  Chunk(this.file, {required this.start, required this.end});

  final int start;
  final int end;
  final XFile file;

  int get size => end - start;

  Stream<Uint8List> get data => file.openRead(start, end);
}
