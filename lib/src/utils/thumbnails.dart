import 'dart:io';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_editor/src/controller.dart';
import 'package:video_editor/src/models/cover_data.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

Stream<List<Uint8List>> generateTrimThumbnails(
  VideoEditorController controller, {
  required int quantity,
}) async* {
  final String path = controller.file.path;
  final double eachPart = controller.videoDuration.inMilliseconds / quantity;
  List<Uint8List> byteList = [];

  bool useFFmpegFallback = false;
  Directory? tempDir;

  for (int i = 1; i <= quantity; i++) {
    try {
      final timeMs = (eachPart * i).toInt();
      Uint8List? bytes;

      if (!useFFmpegFallback) {
        try {
          bytes = await VideoThumbnail.thumbnailData(
            imageFormat: ImageFormat.JPEG,
            video: path,
            timeMs: timeMs,
            quality: controller.trimThumbnailsQuality,
          );
        } catch (e) {
          debugPrint('VideoThumbnail failed, switching to FFmpeg: $e');
          useFFmpegFallback = true;
        }
      }

      if (useFFmpegFallback) {
        tempDir ??= await getTemporaryDirectory();
        bytes = await _extractThumbnailWithFFmpeg(
          videoPath: path,
          timeMs: timeMs,
          quality: controller.trimThumbnailsQuality,
          tempDir: tempDir,
        );
      }

      if (bytes != null) {
        byteList.add(bytes);
      }
    } catch (e) {
      debugPrint(e.toString());
    }

    yield byteList;
  }
}

Stream<List<CoverData>> generateCoverThumbnails(
  VideoEditorController controller, {
  required int quantity,
}) async* {
  final int duration = controller.isTrimmed
      ? controller.trimmedDuration.inMilliseconds
      : controller.videoDuration.inMilliseconds;
  final double eachPart = duration / quantity;
  List<CoverData> byteList = [];

  for (int i = 0; i < quantity; i++) {
    try {
      final CoverData bytes = await generateSingleCoverThumbnail(
        controller.file.path,
        timeMs: (controller.isTrimmed
                ? (eachPart * i) + controller.startTrim.inMilliseconds
                : (eachPart * i))
            .toInt(),
        quality: controller.coverThumbnailsQuality,
      );

      if (bytes.thumbData != null) {
        byteList.add(bytes);
      }
    } catch (e) {
      debugPrint(e.toString());
    }

    yield byteList;
  }
}

/// Generate a cover at [timeMs] in video
///
/// Returns a [CoverData] depending on [timeMs] milliseconds
Future<CoverData> generateSingleCoverThumbnail(
  String filePath, {
  int timeMs = 0,
  int quality = 10,
}) async {
  Uint8List? thumbData;

  try {
    thumbData = await VideoThumbnail.thumbnailData(
      imageFormat: ImageFormat.JPEG,
      video: filePath,
      timeMs: timeMs,
      quality: quality,
    );
  } catch (e) {
    debugPrint('VideoThumbnail failed, using FFmpeg fallback: $e');
    final tempDir = await getTemporaryDirectory();
    thumbData = await _extractThumbnailWithFFmpeg(
      videoPath: filePath,
      timeMs: timeMs,
      quality: quality,
      tempDir: tempDir,
    );
  }

  return CoverData(thumbData: thumbData, timeMs: timeMs);
}

/// Extracts a thumbnail from video at specified time using FFmpeg
Future<Uint8List?> _extractThumbnailWithFFmpeg({
  required String videoPath,
  required int timeMs,
  required int quality,
  required Directory tempDir,
}) async {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final outputPath = '${tempDir.path}/thumb_${timestamp}_$timeMs.jpg';

  // Convert milliseconds to FFmpeg time format (HH:MM:SS.mmm)
  final seconds = timeMs / 1000;
  final hours = (seconds / 3600).floor();
  final minutes = ((seconds % 3600) / 60).floor();
  final secs = seconds % 60;
  final timeString =
      '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toStringAsFixed(3).padLeft(6, '0')}';

  // Quality mapping: input is 0-100, FFmpeg uses 2-31 (lower is better)
  final ffmpegQuality = (31 - (quality * 29 / 100)).round().clamp(2, 31);

  final command =
      '-ss $timeString -i "$videoPath" -vframes 1 -q:v $ffmpegQuality "$outputPath"';

  try {
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      final file = File(outputPath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        await file.delete();
        return bytes;
      }
    } else {
      final logs = await session.getAllLogsAsString();
      debugPrint('FFmpeg thumbnail extraction failed: $logs');
    }
  } catch (e) {
    debugPrint('FFmpeg error: $e');
  }

  return null;
}
