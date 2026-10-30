import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'rag_service.dart';
import 'model_downloader.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ПРОСТРАНСТВО',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF1A1B1E),
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFFE6C9A8),
          onPrimary: const Color(0xFF1A1B1E),
        ),
        useMaterial3: true,
      ),
      home: const OnboardingScreen(),
    );
  }
}

class DeviceProfile {
  final int ramMB;
  final int cpuCores;
  final String abi;
  final String model;
  final String androidVersion;

  DeviceProfile({
    required this.ramMB,
    required this.cpuCores,
    required this.abi,
    required this.model,
    required this.androidVersion,
  });
}

class DeviceMonitor {
  static Future<DeviceProfile> scan() async {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;

    int ramMB = 0;
    try {
      final meminfo = await File('/proc/meminfo').readAsString();
      final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(meminfo);
      if (match != null) {
        ramMB = (int.parse(match.group(1)!) / 1024).round();
      }
    } catch (_) {}

    return DeviceProfile(
      ramMB: ramMB,
      cpuCores: Platform.numberOfProcessors,
      abi: androidInfo.supportedAbis.isNotEmpty ? androidInfo.supportedAbis.first : 'unknown',
      model: androidInfo.model,
      androidVersion: androidInfo.version.release,
    );
  }
}

// ─────────────────────────────────────────────
// ONBOARDING (Экран 1)
// ─────────────────────────────────────────────
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _isAgreed = false;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _cityController = TextEditingController();

  // LLM
  late LlamaController _llm;
  bool _llmReady = false;
  String _llmStatus = 'Подготовка...';
  double _llmProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _llm = LlamaController();
    _initLLM();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _cityController.dispose();
        super.dispose();
  }

  Future<void> _initLLM() async {
    try {
      setState(() {
        _llmStatus = 'Распаковка модели...';
        _llmProgress = 0.0;
      });

      final modelPath = await ensureModel(
        onProgress: (received, total) {
          final pct = total > 0 ? (received / total * 100).toStringAsFixed(1) : '?';
          debugPrint('Модель: $received / $total ($pct%)');
          if (mounted) {
            setState(() {
              _llmProgress = total > 0 ? received / total : 0.0;
              _llmStatus = 'Скачивание модели: $pct%';
            });
          }
        },
      );
      setState(() {
        _llmStatus = 'Загрузка модели в память...';
        _llmProgress = 1.0;
      });

      await _llm.loadModel(
        modelPath: modelPath,
        threads: 2,
        nThreadsBatch: 2,
        contextSize: 1536,
        gpuLayers: 0,
      );

      if (!mounted) return;
      setState(() {
        _llmReady = true;
        _llmStatus = 'Модель готова';
      });
    } catch (e, st) {
      debugPrint('LLM init error: ' + e.toString());
      if (!mounted) return;
      setState(() => _llmStatus = 'Ошибка: ' + e.toString());
    }
  }

  void _enterSpace() {
    if (_isAgreed && _nameController.text.isNotEmpty && _cityController.text.isNotEmpty) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => SpaceScreen(
          name: _nameController.text.trim(),
          city: _cityController.text.trim(),
          llm: _llm,
        )),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                const Text('Честное правило\nтрёх пунктов',
                    style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w300, height: 1.2)),
                const SizedBox(height: 40),
                _buildRule('1', 'Твоё Пространство живёт только в твоём телефоне.'),
                const SizedBox(height: 20),
                _buildRule('2', 'Мы не видим того, что ты пишешь.'),
                const SizedBox(height: 20),
                _buildRule('3', 'Ты можешь стереть всё одной кнопкой.'),
                const SizedBox(height: 32),

                // ─── Блок готовности LLM ───
                if (!_llmReady) ...[
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: const Color(0xFFE6C9A8),
                                value: _llmProgress > 0 ? _llmProgress : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Text('Подготовка ИИ',
                                style: TextStyle(color: Color(0xFFE6C9A8), fontSize: 14, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(_llmStatus,
                            style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13)),
                      ],
                    ),
                  ),
                ] else ...[
                  // ─── Поля имени и города — появляются после готовности LLM ───
                  TextField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Как тебя зовут?',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _cityController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Из какого ты города?',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Checkbox(
                        value: _isAgreed,
                        activeColor: const Color(0xFFE6C9A8),
                        onChanged: (v) => setState(() => _isAgreed = v ?? false),
                      ),
                      Expanded(child: Text('Я принимаю эти правила',
                          style: TextStyle(color: Colors.white.withOpacity(0.7)))),
                    ],
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: (_isAgreed &&
                              _nameController.text.isNotEmpty &&
                              _cityController.text.isNotEmpty)
                          ? _enterSpace
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE6C9A8),
                        foregroundColor: const Color(0xFF1A1B1E),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('Войти в Пространство',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRule(String number, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$number.',
            style: const TextStyle(color: Color(0xFFE6C9A8), fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(width: 12),
        Expanded(
            child: Text(text,
                style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16, height: 1.4))),
      ],
    );
  }
}

// ─────────────────────────────────────────────
// SPACE SCREEN (Экран 2 — чат)
// ─────────────────────────────────────────────
class SpaceScreen extends StatefulWidget {
  final String name;
  final String city;
  final LlamaController llm;
  const SpaceScreen({super.key, required this.name, required this.city, required this.llm});
  @override
  State<SpaceScreen> createState() => _SpaceScreenState();
}

class _SpaceScreenState extends State<SpaceScreen> {
  String? _kvCachePath;
  String? _kvCacheHash;
  static const String _kvHashPrefKey = 'kv_prefix_hash';
  static const String _kvNameCityKey = 'kv_name_city';
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<String> _messages = [];
  bool _isTyping = false;
  bool _isGenerating = false;
  bool _isThinking = false;
  int _dotsCount = 0;
  Timer? _dotsTimer;
  String _llmStatus = 'LLM готова (Qwen 1.5B Q4_K_M)';
  StreamSubscription<String>? _llmSub;
  String _llmBuffer = '';
  int _userMessageCount = 0;

  LlamaController get _llm => widget.llm;
  RagService? _rag;

  @override
  void initState() {
    super.initState();

    // Инвалидация KV-кэша при смене имени/города (этап 5)
    () async {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_kvNameCityKey);
      final current = '${widget.name}|${widget.city}';
      if (saved != current) {
        await _invalidateKvCache();
        await prefs.setString(_kvNameCityKey, current);
      }
    }();
    _initRag();
    _init();
    _dotsTimer = Timer.periodic(const Duration(milliseconds: 400), (t) {
      if (!mounted) return;
      setState(() {
        _dotsCount = (_dotsCount + 1) % 4;
      });
    });
  }

  Future<void> _initRag() async {
    try {
      final rag = RagService();
      await rag.init(onStatus: (s) {
        debugPrint('RAG: $s');
      });
      if (mounted) setState(() => _rag = rag);
      debugPrint('✅ RAG готов');
    } catch (e, st) {
      debugPrint('❌ RAG init error: $e\n$st');
    }
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_name', widget.name);
    await prefs.setString('user_city', widget.city);
    await _loadMessages();
  }

  @override
  void dispose() {
    _llmSub?.cancel();
    _dotsTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      Future.delayed(const Duration(milliseconds: 100), () {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }
  }

  Future<void> _loadMessages() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('chat_history');
    if (saved != null) {
      setState(() => _messages = saved);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  Future<void> _saveMessages() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('chat_history', _messages);
  }

  Future<void> _clearAll() async {
    _llmSub?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('chat_history');
    setState(() {
      _messages = [];
      _llmBuffer = '';
      _isTyping = false;
      _userMessageCount = 0;
    });
  }

  Future<List<ChatMessage>> _buildChatHistory(String userText) async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('user_name') ?? 'друг';
    final city = prefs.getString('user_city') ?? '';

    var systemPrompt = 'Ты — тёплый собеседник «Пространство». '
        'Пользователя зовут $name${city.isNotEmpty ? ', он из $city' : ''}. '
        'На «ты». Это место, где можно выговориться.\n\n'
        'Твоя задача:\n'
        '- Отразить чувство пользователя.\n'
        '- Показать, что ты рядом и не осуждаешь.\n'
        '- Если пользователь ПРЯМО просит совет ("как справиться", "что делать") — '
        'дай 1-2 конкретных шага мягко, без давления.\n'
        '- Если не просит — не давай советов, просто будь рядом и задай открытый вопрос.\n'
        '- 2-4 предложения. Закончи мысль полностью, не обрывай на полуслове.';

    // === RAG: добавляем контекст ===
    if (_rag != null && _rag!.isReady) {
      try {
        final rawCtx = await _rag!.buildContext(userText, k: 2);
        // Обрезка каждого фрагмента до ~200 символов, чтобы не раздувать промпт
        final ctx = rawCtx
            .split('\n\n')
            .map((f) => f.length > 200 ? '${f.substring(0, 200)}…' : f)
            .join('\n\n');
        if (ctx.isNotEmpty) {
          systemPrompt += '\n\nПримеры того, как профессиональные психологи отвечали на похожие переживания. НЕ цитируй их дословно, используй как образец тона и структуры:\n\n$ctx';
          debugPrint('RAG: добавлено ${ctx.length} символов контекста');
        }
      } catch (e) {
        debugPrint('RAG search error: $e');
      }
    }

    final result = <ChatMessage>[
      ChatMessage(role: 'system', content: systemPrompt),
    ];

    final filtered = <String>[];
    for (final m in _messages) {
      if (m.startsWith('⚠️')) continue;
      filtered.add(m);
    }
    // История: только последние 2 пары (4 сообщения), чтобы не раздувать промпт
    final recent = filtered.length > 4 ? filtered.sublist(filtered.length - 4) : filtered;
    for (final m in recent) {
      if (m.startsWith('[Ассистент] ')) {
        result.add(ChatMessage(role: 'assistant', content: m.substring('[Ассистент] '.length)));
      } else {
        result.add(ChatMessage(role: 'user', content: m));
      }
    }
    if (result.length == 1) {
      result.add(ChatMessage(role: 'user', content: userText));
    }
    return result;
  }

  String _filterAnswer(String text) {
    text = text.replaceAll(RegExp(r'[Ии]звините[^.!?]*[.!?]\s*'), '');
    text = text.replaceAll(RegExp(r'[Пп]ростите[^.!?]*[.!?]\s*'), '');
    text = text.replaceAll(RegExp(r'[Сс]ожалею[^.!?]*[.!?]\s*'), '');
    text = text.replaceAll('Вы ', 'ты ');
    text = text.replaceAll('вы ', 'ты ');
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    return text.trim();
  }

  Future<(List<ChatMessage>, bool)> _prepareKvCache(String userText) async {
    final prefs = await SharedPreferences.getInstance();
    final docDir = await getApplicationDocumentsDirectory();
    final kvPath = '${docDir.path}/kv_prefix.bin';

    final name = prefs.getString('user_name') ?? 'друг';
    final city = prefs.getString('user_city') ?? '';
    var prefix = 'name=$name|city=$city';
    if (_rag != null && _rag!.isReady) {
      try {
        final rawCtx = await _rag!.buildContext(userText, k: 2);
        final ctx = rawCtx
            .split('\n\n')
            .map((f) => f.length > 200 ? '${f.substring(0, 200)}…' : f)
            .join('\n\n');
        prefix += '|rag=$ctx';
      } catch (_) {}
    }
    final hash = sha256.convert(utf8.encode(prefix)).toString();

    final savedHash = prefs.getString(_kvHashPrefKey);
    final kvExists = await File(kvPath).exists();

    if (savedHash == hash && kvExists) {
      final ok = await _llm.loadKvState(0, kvPath);
      if (ok) {
        _kvCachePath = kvPath;
        _kvCacheHash = hash;
        debugPrint('[KV] restored, sending only new user message');
        return (<ChatMessage>[ChatMessage(role: 'user', content: userText)], false);
      }
      debugPrint('[KV] loadKvState failed, falling back to full prefill');
    }

    await _llm.clearContext();
    final fullHistory = await _buildChatHistory(userText);
    _kvCachePath = kvPath;
    _kvCacheHash = hash;
    return (fullHistory, true);
  }

  Future<void> _invalidateKvCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kvHashPrefKey);
    await prefs.remove(_kvNameCityKey);
    final docDir = await getApplicationDocumentsDirectory();
    final f = File('${docDir.path}/kv_prefix.bin');
    if (await f.exists()) await f.delete();
    _kvCachePath = null;
    _kvCacheHash = null;
    debugPrint('[KV] cache invalidated');
  }

  Future<void> _generateReply(String userText) async {
    setState(() {
      _llmBuffer = '';
      _isThinking = true;
      _isTyping = false;
    });

    try {
      final (messages, needSaveKv) = await _prepareKvCache(userText);
      _llmSub?.cancel();

      int assistantIndex = -1;
      _isGenerating = true;
      _llmSub = _llm
          .generateChat(
            messages: messages,
            template: 'chatml',
            maxTokens: 250,
            temperature: 0.75,
            topP: 0.92,
            topK: 50,
            repeatPenalty: 1.35,
          )
          .listen(
        (token) {
          if (!mounted) return;
          _llmBuffer += token;
          setState(() {
            if (assistantIndex == -1) {
              _isThinking = false;
              _isTyping = true;
              debugPrint('AI: $_llmBuffer');
              _messages.add('[Ассистент] $_llmBuffer');
              assistantIndex = _messages.length - 1;
            } else {
              _messages[assistantIndex] = '[Ассистент] $_llmBuffer';
            }
          });
          _scrollToBottom();
        },
        onDone: () async {
          if (!mounted) return;
          _isThinking = false;
          _isTyping = false;
          setState(() {});
          await Future.delayed(const Duration(milliseconds: 300));
          _isGenerating = false;
          if (!mounted) return;
          final cleaned = _filterAnswer(_llmBuffer);
          for (var i = _messages.length - 1; i >= 0; i--) {
            if (_messages[i].startsWith('[Ассистент]')) {
              _messages[i] = '[Ассистент] ' + cleaned;
              break;
            }
          }
          setState(() => _isTyping = false);
                    if (needSaveKv && _kvCachePath != null && _kvCacheHash != null) {
            try {
              final ok = await _llm.saveKvState(0, _kvCachePath!);
              if (ok) {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString(_kvHashPrefKey, _kvCacheHash!);
                await prefs.setString(_kvNameCityKey,
                    '${widget.name}|${widget.city}');
                debugPrint('[KV] saved prefix to ${_kvCachePath!}');
              } else {
                debugPrint('[KV] saveKvState returned false');
              }
            } catch (e) {
              debugPrint('[KV] saveKvState error: $e');
            }
          }
          _saveMessages();
        },
        onError: (e) {
          if (!mounted) return;
          setState(() {
            _messages.add('⚠️ Ошибка генерации: $e');
            _isTyping = false;
          });
          _saveMessages();
        },
      );
    } catch (e, st) {
      debugPrint('generateChat error: $e\n$st');
      setState(() {
        _messages.add('⚠️ Ошибка: $e');
        _isTyping = false;
      });
      _saveMessages();
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isTyping || _isGenerating) return;

    debugPrint('USER: $text');
    setState(() {
      _messages.add(text);
      _messageController.clear();
      _isTyping = true;
      _userMessageCount++;
    });
    _saveMessages();
    _scrollToBottom();

    await _generateReply(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1B1E),
        title: Text(
          'ИИ: Qwen 1.5B Q5',
          style: const TextStyle(color: Color(0xFFE6C9A8), fontSize: 12),
          maxLines: 2,
        ),
        actions: [
          IconButton(icon: const Icon(Icons.delete_forever, color: Color(0xFFE6C9A8)), onPressed: _clearAll),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              flex: 2,
              child: Container(
                color: Colors.blueAccent.withOpacity(0.2),
                child: const Center(child: Text('Rive анимация', style: TextStyle(color: Colors.white))),
              ),
            ),
            Expanded(
              flex: 3,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  children: [
                    Expanded(
                      child: _messages.isEmpty
                          ? const Center(child: Text('Напиши что-нибудь...', style: TextStyle(color: Colors.white54)))
                          : ListView.builder(
                              controller: _scrollController,
                              itemCount: _messages.length,
                              itemBuilder: (context, index) {
                                final isUser = !_messages[index].startsWith('[Ассистент]');
                                return Align(
                                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(vertical: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                    decoration: BoxDecoration(
                                      color: isUser ? Colors.white.withOpacity(0.1) : Colors.transparent,
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Text(
                                      _messages[index].replaceFirst('[Ассистент] ', ''),
                                      style: TextStyle(color: isUser ? Colors.white : const Color(0xFFE6C9A8), fontSize: 16),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                    if (_isThinking || _isTyping)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              _isThinking ? 'ИИ думает' : 'ИИ печатает',
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                            const SizedBox(width: 4),
                            SizedBox(
                              width: 32,
                              child: Text(
                                '.' * _dotsCount,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.clip,
                                style: const TextStyle(color: Color(0xFFE6C9A8), fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 1),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            enabled: !(_isTyping || _isGenerating),
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: 'Как ты себя чувствуешь?',
                              hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.05),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                            ),
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: (_isTyping || _isGenerating) ? null : _sendMessage,
                          icon: const Icon(Icons.arrow_upward, color: Color(0xFFE6C9A8)),
                          style: IconButton.styleFrom(backgroundColor: Colors.white.withOpacity(0.05)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
