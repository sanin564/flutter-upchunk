import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:dio/dio.dart';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:mime/mime.dart';

class UpChunk {
  final Dio _dio;

  /// HTTP response codes implying the PUT method has been successful
  final successfulChunkUploadCodes = const [200, 201, 202, 204, 308];

  /// Upload url as [String], required
  final String endPoint;

  /// [XFile] to upload, required
  final XFile file;

  /// The size in kb of the chunks to split the file into,
  /// with the exception of the final chunk which may be smaller.
  /// This parameter should be in multiples of 64
  final int chunkSize;

  /// The number of times to retry any given chunk.
  final int attempts;

  /// Number of seconds to wait before a retry is fired
  final int delayBeforeAttempt;

  /// Fired when a chunk has reached the max number of retries or the response code is fatal and implies that retries should not be attempted.
  final void Function(String message, int chunk, int attempts)? onError;

  /// Fired when the upload is finished successfully.
  final void Function()? onSuccess;

  /// Fired continuously with incremental upload progress. This returns the current percentage of the file that's been uploaded.
  ///
  /// [progress] a number from 0 to 100 representing the percentage of the file uploaded
  final void Function(double progress)? onProgress;

  Stream<List<int>> _chunk = const Stream.empty();
  int _chunkLength = 0;
  int _fileSize = 0;
  int _chunkCount = 0;
  int _chunkByteSize = 0;
  String? _fileMimeType;
  int _totalChunks = 0;
  bool _offline = false;
  bool _uploadFailed = false;

  /// flutter_connectivity object
  late InternetConnection _internetConnection;

  /// Internal constructor used by [createUpload]
  UpChunk({
    required this.endPoint,
    required this.file,
    this.chunkSize = 2048,
    this.attempts = 5,
    this.delayBeforeAttempt = 1,
    this.onError,
    this.onSuccess,
    this.onProgress,
  }) : _dio = Dio(
         BaseOptions(
           connectTimeout: const Duration(seconds: 10),
           receiveTimeout: const Duration(seconds: 5),
         ),
       ) {
    _validateOptions();

    _chunkByteSize = chunkSize * 1024;

    _internetConnection = InternetConnection();
    _internetConnection.onStatusChange.listen(_connectionChanged);

    _initialize();
  }

  Future<void> _initialize() async {
    _fileSize = await file.length();
    _totalChunks = (_fileSize / _chunkByteSize).ceil();

    _fileMimeType = lookupMimeType(file.path);
    _sendChunks();
  }

  /// It validates the passed options
  void _validateOptions() {
    if (chunkSize <= 0 || chunkSize % 64 != 0) {
      throw Exception('chunkSize must be a positive number in multiples of 64');
    }

    if (attempts <= 0) throw Exception('retries must be a positive number');
  }

  /// Gets [Uri] from [endPoint]
  Uri get _endPointUri => Uri.parse(endPoint);

  /// Callback for [ConnectionStatusSingleton] to notify connection changes
  ///
  /// if the connection drops [_offline] is marked as true and upload us paused,
  /// if connection is restore [_offline] is marked as false and resumes the upload
  void _connectionChanged(InternetStatus status) {
    final hasConnection = status == InternetStatus.connected;

    if (hasConnection) {
      if (!_offline || _uploadFailed) return;
      _offline = false;
      _sendChunks();
    } else {
      _offline = true;
    }
  }

  /// Sends [_chunk] of the file with appropriate headers
  Future<Response<T>> _sendChunk<T>() {
    final rangeStart = _chunkCount * _chunkByteSize;
    final rangeEnd = rangeStart + _chunkLength - 1;

    final Map<String, dynamic> putHeaders = {
      'content-range': 'bytes $rangeStart-$rangeEnd/$_fileSize',
      Headers.contentLengthHeader: _chunkLength,
      Headers.contentTypeHeader: _fileMimeType ?? 'application/octet-stream',
    };

    // returns future with http response
    return _dio.putUri<T>(
      _endPointUri,
      options: Options(
        headers: putHeaders,
        followRedirects: false,
        validateStatus: (status) {
          return true;
        },
      ),
      data: _chunk,
      onSendProgress: (int sent, int total) {
        if (onProgress != null) {
          final bytesSent = _chunkCount * _chunkByteSize;
          final percentProgress = (bytesSent + sent) * 100.0 / _fileSize;

          if (percentProgress < 100.0) onProgress!(percentProgress);
        }
      },
    );
  }

  /// Gets [_chunk] and [_chunkLength] for the portion of the file of x bytes corresponding to [_chunkByteSize]
  void _getChunk() {
    final length = _totalChunks == 1 ? _fileSize : _chunkByteSize;
    final start = length * _chunkCount;

    _chunk = file.openRead(start, start + length);
    if (start + length <= _fileSize) {
      _chunkLength = length;
    } else {
      _chunkLength = _fileSize - start;
    }
  }

  /// Manages the whole upload by calling [_getChunk] and [_sendChunk]
  void _sendChunks() {
    if (_uploadFailed || _offline) return;

    _getChunk();
    _sendChunk<dynamic>().then((res) {
      if (successfulChunkUploadCodes.contains(res.statusCode)) {
        _chunkCount++;
        if (_chunkCount < _totalChunks) {
          _sendChunks();
        } else {
          onSuccess?.call();
        }

        if (onProgress != null) {
          double percentProgress = 100.0;
          if (_chunkCount < _totalChunks) {
            final bytesSent = _chunkCount * _chunkByteSize;
            percentProgress = bytesSent * 100.0 / _fileSize;
          }
          onProgress!(percentProgress);
        }
      }
    });
  }
}
