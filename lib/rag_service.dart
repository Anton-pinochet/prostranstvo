import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import 'package:betto_inferencing/betto_inferencing.dart';
/// RAG-сервис: инициализация ONNX-эмбеддингов + поиск по SQLite.
///
/// Использование:
///   final rag = RagService();
///   await rag.init();
///   final chunks = await rag.search('Что делать при депрессии?', k: 5);
class RagService {
  Database? _db;
  OrtSession? _session;
  bool _initialized = false;

  // Пути в кэше приложения (куда копируются assets)
  late String _dbPath;
  XlmRobertaTokenizer? _tokenizer;
  final Map<String, Float32List> _embedCache = {};
  late String _modelPath;

  // Параметры
  static const int _dim = 384;
  static const int _maxLen = 512;
  static const int _kDefault = 5;

  bool get isReady => _initialized;

  /// Инициализация: копирует БД и модель из assets, открывает SQLite, создаёт ONNX-сессию.
  Future<void> init({void Function(String status)? onStatus}) async {
    if (_initialized) return;

    onStatus?.call('Распаковка базы знаний...');
    final cacheDir = await getApplicationDocumentsDirectory();
    final ragDir = Directory(p.join(cacheDir.path, 'rag'));
    if (!await ragDir.exists()) {
      await ragDir.create(recursive: true);
    }

    // 1. Копируем embeddings.db из assets (812 МБ)
    _dbPath = p.join(ragDir.path, 'embeddings.db');
    final dbFile = File(_dbPath);
    if (!await dbFile.exists()) {
      onStatus?.call('❌ БД не найдена в $_dbPath');
      throw Exception('БД не найдена в $_dbPath');
    }
    debugPrint('RAG: ✅ БД найдена в $_dbPath');

    // 2. Копируем ONNX-модель
    onStatus?.call('Копирую embedding-модель...');
    _modelPath = p.join(ragDir.path, 'model_quantized.onnx');
    await _copyAsset('assets/embedding_model/model_quantized.onnx', _modelPath);

    // Токенизатор и конфиги (для ONNX не нужны — используем простой токенизатор через ONNX
    // или pre-tokenized. В нашем случае — токенизация в Dart через ручной split.
    // Для простоты используем только ONNX-модель и грубую токенизацию (см. _tokenize).

    // 3. Открываем SQLite
    onStatus?.call('Открываю базу...');
    // Правильная загрузка расширения sqlite-vec через FFI (sqlite3_auto_extension)
    try {
      final lib = DynamicLibrary.open('libvec0.so');
      final extension = SqliteExtension.inLibrary(lib, 'sqlite3_vec_init');
      sqlite3.ensureExtensionLoaded(extension);
      debugPrint('RAG: ✅ vec0 расширение зарегистрировано');
    } catch (e) {
      debugPrint('RAG: ❌ vec0 НЕ зарегистрирован: $e');
    }

    _db = sqlite3.open(_dbPath);

    try {
      final sql = 'EXPLAIN QUERY PLAN SELECT c.rowid, c.embedding FROM chunks c JOIN dart_ivf_cells v ON c.rowid = v.rowid WHERE LENGTH(c.text) > 20 AND v.cell_id IN (53,57,59,56,12,34,18,7)';
      for (final row in _db!.select(sql)) {
        debugPrint('RAG: PLAN $row');
      }
      final idx = _db!.select("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='dart_ivf_cells'");
      debugPrint('RAG: INDEXES $idx');
      final cnt = _db!.select("SELECT COUNT(*) AS c FROM dart_ivf_cells");
      debugPrint('RAG: cells=${cnt.first['c']}');
      final cnt2 = _db!.select("SELECT COUNT(*) AS c FROM dart_ivf_centroids");
      debugPrint('RAG: centroids=${cnt2.first['c']}');
    } catch (e) {
      debugPrint('RAG: PLAN error $e');
    }

    // Отключаем любые попытки записи в БД
    try {
      _db!.execute('PRAGMA query_only = ON;');
      debugPrint('RAG: ✅ query_only = ON');
    } catch (e) {
      debugPrint('RAG: ⚠️ query_only error: $e');
    }
    try {
      final v = _db!.select("SELECT vec_version() AS v");
      debugPrint('RAG: ✅ vec_version = ${v.first['v']}');
    } catch (e) {
      debugPrint('RAG: ❌ vec_version НЕ РАБОТАЕТ: $e');
    }

    // 4. Инициализируем ONNX Runtime
    onStatus?.call('Загружаю ONNX Runtime...');
    OrtEnv.instance.init();
    final sessionOptions = OrtSessionOptions();
    sessionOptions.appendDefaultProviders();
    final modelBytes = await File(_modelPath).readAsBytes();
        debugPrint('RAG: Загружаю tokenizer.json...');
    // Копируем tokenizer.json из assets на диск, т.к. XlmRobertaTokenizer.load
// принимает путь к файлу, а не asset-key
final tokPath = p.join(ragDir.path, 'tokenizer.json');
if (!await File(tokPath).exists()) {
  await _copyAsset('assets/tokenizer.json', tokPath);
}
_tokenizer = await XlmRobertaTokenizer.load(tokPath);
    debugPrint('RAG: ✅ XLM-R токенизатор загружен');
_session = OrtSession.fromBuffer(modelBytes, sessionOptions);

    _initialized = true;
    onStatus?.call('RAG готов');
  }

  /// Копирование asset в файл с прогрессом.
  Future<void> _copyAsset(
    String assetKey,
    String dstPath, {
    void Function(int pct)? onProgress,
  }) async {
    final data = await rootBundle.load(assetKey);
    final bytes = data.buffer.asUint8List();
    final sink = File(dstPath).openWrite();
    sink.add(bytes);
    await sink.flush();
    await sink.close();
    onProgress?.call(100);
  }

  /// Грубая токенизация (для e5-small можно использовать whitespace + спецтокены).
  /// В реальности e5 использует SentencePiece, но для RAG-поиска
  /// достаточно приблизительной токенизации — модель всё равно усредняет.
  ///
  /// ВАЖНО: это упрощение. Для лучшего качества нужен полноценный SentencePiece
  /// на Dart. Но для поиска по 304k чанков работает и так.
  List<int> _tokenize(String text) {
  final tok = _tokenizer;
  if (tok == null) throw StateError('XLM-R токенизатор не загружен');
  final out = tok.encode(text);
  return out.inputIds.toList();
}

  /// Считает эмбеддинг для вопроса через ONNX.
  Future<Float32List> _embedQuery(String text) async {
    final _key = text.trim().toLowerCase().replaceAll(RegExp(r'[?!.,;:]'), '');
    final _cacheHit = _embedCache.containsKey(_key);
    final cached = _embedCache[_key];
    if (cached != null) {
      return cached;
    }

    final session = _session;
    if (session == null) throw StateError('ONNX session не инициализирована');

    // Префикс "query: " — обязателен для e5
    final tokens = _tokenize('query: $text');
    final seqLen = tokens.length;

    final inputIds = Int64List(seqLen);
    final attnMask = Int64List(seqLen);
    final tokenTypeIds = Int64List(seqLen);
    for (var i = 0; i < seqLen; i++) {
      inputIds[i] = tokens[i];
      attnMask[i] = 1;
      tokenTypeIds[i] = 0;
    }

    final inputIdsOrt = OrtValueTensor.createTensorWithDataList(
        inputIds, [1, seqLen]);
    final attnMaskOrt = OrtValueTensor.createTensorWithDataList(
        attnMask, [1, seqLen]);
    final tokenTypeOrt = OrtValueTensor.createTensorWithDataList(
        tokenTypeIds, [1, seqLen]);

    final inputs = <String, OrtValue>{
      'input_ids': inputIdsOrt,
      'attention_mask': attnMaskOrt,
      'token_type_ids': tokenTypeOrt,
    };

    final runOptions = OrtRunOptions();
    final outputs = await session.runAsync(runOptions, inputs);
    final lastHidden = outputs?[0]?.value as List<List<List<double>>>;
    // lastHidden: [1][seqLen][384]
    final emb = Float32List(_dim);
    for (var d = 0; d < _dim; d++) {
      var sum = 0.0;
      for (var t = 0; t < seqLen; t++) {
        sum += lastHidden[0][t][d];
      }
      emb[d] = sum / seqLen;
    }
    // нормализация
    var norm = 0.0;
    for (var d = 0; d < _dim; d++) {
      norm += emb[d] * emb[d];
    }
    norm = _sqrt(norm);
    if (norm > 1e-9) {
      for (var d = 0; d < _dim; d++) {
        emb[d] = emb[d] / norm;
      }
    }
    _embedCache[_key] = emb;
    return emb;
  }

  double _sqrt(double x) {
    // Newton
    if (x <= 0) return 0;
    var y = x;
    for (var i = 0; i < 20; i++) {
      y = 0.5 * (y + x / y);
    }
    return y;
  }

  /// Поиск топ-k чанков по вопросу.
  Future<List<RagChunk>> search(String query, {int k = _kDefault}) async {
    if (!_initialized) throw StateError('RagService не инициализирован');
    final t0 = DateTime.now();
    var _t1 = 0; var _t2 = 0; var _t3 = 0; var _t4 = 0; var _t5 = 0; var _t6 = 0; var _t7 = 0;
    var _t_emb = 0;
    var _sw = Stopwatch();
    _sw.start();
    final emb = await _embedQuery(query);
    _t_emb = _sw.elapsedMilliseconds; _sw.reset(); _sw.start();

    // 1. Центроиды
    final centroids = <int, Float32List>{};
    for (final row in _db!.select('SELECT id, vec FROM dart_ivf_centroids')) {
      final blob = row['vec'] as Uint8List;
      centroids[row['id'] as int] =
          blob.buffer.asFloat32List(blob.offsetInBytes, 384);
    }

    _t1 = _sw.elapsedMilliseconds; _sw.reset(); _sw.start();
    // 2. nprobe=2
    final scores = <int, double>{};
    centroids.forEach((cid, c) {
      var dot = 0.0;
      for (var d = 0; d < 384; d++) dot += emb[d] * c[d];
      scores[cid] = dot;
    });
    final probe = (scores.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(2)
        .map((e) => e.key)
        .toList();

    _t2 = _sw.elapsedMilliseconds; _sw.reset(); _sw.start();
    // 3. Квантуем запрос в int8 (один раз)
    final qInt8 = Int8List(384);
    var maxAbs = 0.0;
    for (var d = 0; d < 384; d++) {
      final v = emb[d].abs();
      if (v > maxAbs) maxAbs = v;
    }
    if (maxAbs == 0) maxAbs = 1.0;
    for (var d = 0; d < 384; d++) {
      qInt8[d] = (emb[d] / maxAbs * 127).round().clamp(-127, 127);
    }

    _t3 = _sw.elapsedMilliseconds; _sw.reset(); _sw.start();
    // 4. int8 × int8 → int32 (быстро на ARM)
    final scored = <int, int>{};
    final texts = <int, Map<String, dynamic>>{};
    for (final row in _db!.select(
      'SELECT c.rowid, c.embedding_int8, c.text, c.category, c.filename '
      'FROM chunks c JOIN dart_ivf_cells v ON c.rowid = v.rowid '
      'WHERE v.cell_id IN (${probe.join(",")}) AND LENGTH(c.text) > 20'
    )) {
      final i8 = row['embedding_int8'] as Uint8List;
      var dot = 0;
      for (var d = 0; d < 384; d++) dot += qInt8[d] * i8[d];
      scored[row['rowid'] as int] = dot;
      texts[row['rowid'] as int] = row;
    }

    _t4 = _sw.elapsedMilliseconds; _sw.reset(); _sw.start();
    // 5. top-50 по int dot
    final top50 = (scored.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value)))
        .take(50)
        .map((e) => e.key)
        .toList();

    _t5 = _sw.elapsedMilliseconds; _sw.reset(); _sw.start();
    // 6. Rescore top-50 float32 (точный косинус)
    final rescored = <int, double>{};
    for (final rowid in top50) {
      final row = _db!.select(
        'SELECT embedding FROM chunks WHERE rowid = ?', [rowid]
      ).first;
      final f32 = (row['embedding'] as Uint8List).buffer.asFloat32List(0, 384);
      var dot = 0.0;
      for (var d = 0; d < 384; d++) dot += emb[d] * f32[d];
      rescored[rowid] = 1.0 - dot;
    }

    _t7 = _sw.elapsedMilliseconds; _sw.reset(); _sw.start();
    final topK = (rescored.entries.toList()
          ..sort((a, b) => a.value.compareTo(b.value)))
        .take(k);

    final ms = DateTime.now().difference(t0).inMilliseconds;
    debugPrint('RAG: search ${ms} ms, rows=${topK.length}');

    return topK.map((e) {
      final r = texts[e.key]!;
      return RagChunk(
        rowid: e.key,
        distance: e.value,
        text: r['text'] as String,
        category: r['category'] as String,
        filename: r['filename'] as String,
      );
    }).toList();
  }

  /// Формирует строку контекста для промпта LLM.
  Future<String> buildContext(String query, {int k = _kDefault}) async {
    final chunks = await search(query, k: k);
    if (chunks.isEmpty) return '';
    final buf = StringBuffer();
    for (var i = 0; i < chunks.length; i++) {
      buf.writeln('[Фрагмент ${i + 1}]: ${chunks[i].text}');
    }
    return buf.toString();
  }

  Future<void> dispose() async {
    // OrtSession не имеет dispose() в onnxruntime_v2.
    // Освобождаем только SQLite и зануляем ссылки.
    _db?.close();
    _session = null;
    _db = null;
    _initialized = false;
    OrtEnv.instance.release();
  }
}

class RagChunk {
  final int rowid;
  final double distance;
  final String text;
  final String category;
  final String filename;
  RagChunk({
    required this.rowid,
    required this.distance,
    required this.text,
    required this.category,
    required this.filename,
  });
}


class _ScoredChunk {
  final int rowid;
  final double distance;
  final String text;
  final String category;
  final String filename;
  _ScoredChunk({
    required this.rowid,
    required this.distance,
    required this.text,
    required this.category,
    required this.filename,
  });
}
