import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const String kModelFileName = 'qwen2.5-1.5b-instruct-q4_k_m.gguf';
const String kModelUrl =
    'https://github.com/Anton-pinochet/prostranstvo/releases/download/v1.0-model/qwen2.5-1.5b-instruct-q4_k_m.gguf';
const String kModelSha256 =
    '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e';
const int kModelSize = 1117320736;

Future<String> ensureModel({
  void Function(int received, int total)? onProgress,
}) async {
  final docDir = await getApplicationDocumentsDirectory();
  final modelPath = p.join(docDir.path, kModelFileName);

  final file = File(modelPath);
  if (await file.exists() && await file.length() == kModelSize) {
    return modelPath;
  }
  if (await file.exists()) {
    await file.delete();
  }

  await _download(kModelUrl, modelPath, onProgress: onProgress);

  final digest = await _sha256OfFile(modelPath);
  if (digest != kModelSha256) {
    await File(modelPath).delete();
    throw Exception('SHA256 mismatch: got $digest, expected $kModelSha256');
  }
  return modelPath;
}

Future<void> _download(
  String url,
  String savePath, {
  void Function(int received, int total)? onProgress,
}) async {
  final client = http.Client();
  try {
    final request = http.Request('GET', Uri.parse(url));
    final response = await client.send(request);
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final total = response.contentLength ?? -1;
    final tmpPath = '$savePath.part';
    final tmpFile = File(tmpPath);
    final sink = tmpFile.openWrite();

    int received = 0;
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.flush();
    await sink.close();
    await tmpFile.rename(savePath);
  } finally {
    client.close();
  }
}

Future<String> _sha256OfFile(String path) async {
  final file = File(path);
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}
