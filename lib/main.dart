import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqlite3/sqlite3.dart' hide Row;
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'rag_service.dart';

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

      final docDir = await getApplicationDocumentsDirectory();
      final modelPath = p.join(docDir.path, 'qwen2.5-1.5b-instruct-q5_k_m.gguf');
      final modelFile = File(modelPath);

      const totalSize = 1285494304;

      int currentSize = 0;
      if (await modelFile.exists()) {
        currentSize = await modelFile.length();
      }

      if (currentSize != totalSize) {
        if (await modelFile.exists()) {
          await modelFile.delete();
        }

        final sink = modelFile.openWrite();

        // Часть 1
        setState(() => _llmStatus = 'Часть 1/2 (600 МБ)...');
        final p1 = await rootBundle.load('assets/models/part1.bin');
        final b1 = p1.buffer.asUint8List();
        sink.add(b1);
        await sink.flush();
        final pct1 = (b1.length / totalSize * 100).toStringAsFixed(1);
        setState(() {
          _llmProgress = b1.length / totalSize;
          _llmStatus = 'Часть 1/2 готова: ' + pct1 + '%';
        });
        await Future.delayed(const Duration(milliseconds: 100));

        // Часть 2
        setState(() => _llmStatus = 'Часть 2/2 (626 МБ)...');
        final p2 = await rootBundle.load('assets/models/part2.bin');
        final b2 = p2.buffer.asUint8List();
        sink.add(b2);
        await sink.flush();
        await sink.close();
        final pct2 = ((b1.length + b2.length) / totalSize * 100).toStringAsFixed(1);
        setState(() {
          _llmProgress = 1.0;
          _llmStatus = 'Распаковка завершена: ' + pct2 + '%';
        });
      }

      final finalSize = await modelFile.length();
      if (finalSize != totalSize) {
        throw Exception('Файл неполный: ' + finalSize.toString() + ' / ' + totalSize.toString());
      }

      setState(() {
        _llmStatus = 'Загрузка модели в память...';
        _llmProgress = 1.0;
      });

      await _llm.loadModel(
        modelPath: modelPath,
        threads: 4,
        contextSize: 1536,
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
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  List<String> _messages = [];
  bool _isTyping = false;
  bool _isGenerating = false;
  String _llmStatus = 'LLM готова (Qwen 1.5B Q5)';
  StreamSubscription<String>? _llmSub;
  String _llmBuffer = '';
  int _userMessageCount = 0;

  LlamaController get _llm => widget.llm;
  RagService? _rag;

  @override
  void initState() {
    super.initState();
    _initRag();
    _init();
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

    var systemPrompt = 'Ты — тёплый ассистент приложения «Пространство». '
        'Пользователя зовут $name${city.isNotEmpty ? ', он из $city' : ''}. '
        'Обращайся на «ты», по имени. НЕ выкай. НЕ извиняйся. '
        'Пиши 2-3 предложения.';

    // === RAG: добавляем контекст ===
    if (_rag != null && _rag!.isReady) {
      try {
        final ctx = await _rag!.buildContext(userText, k: 5);
        if (ctx.isNotEmpty) {
          systemPrompt += '\n\nНиже — реальные фрагменты из базы психологических консультаций. '
              'Используй их, если они релевантны вопросу, но НЕ цитируй дословно. '
              'Отвечай своими словами, опираясь на эти знания:\n\n$ctx';
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
      if (m.startsWith('⚠️') || m.startsWith('[Ассистент]')) continue;
      filtered.add(m);
    }
    final recent = filtered.length > 4 ? filtered.sublist(filtered.length - 4) : filtered;
    for (var i = 0; i < recent.length; i++) {
      final role = (i % 2 == 0) ? 'user' : 'assistant';
      result.add(ChatMessage(role: role, content: recent[i]));
    }

    result.add(ChatMessage(role: 'user', content: userText));
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

  Future<void> _generateReply(String userText) async {
    setState(() {
      _llmBuffer = '';
      _isTyping = true;
    });

    try {
      final history = await _buildChatHistory(userText);
      _llmSub?.cancel();

      int assistantIndex = -1;
      _isGenerating = true;
      _llmSub = _llm
          .generateChat(
            messages: history,
            maxTokens: 200,
            temperature: 0.85,
            topP: 0.92,
            topK: 50,
            repeatPenalty: 1.15,
          )
          .listen(
        (token) {
          if (!mounted) return;
          _llmBuffer += token;
          setState(() {
            if (assistantIndex == -1) {
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
                    if (_isTyping)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFE6C9A8))),
                            SizedBox(width: 8),
                            Text('ИИ печатает...', style: TextStyle(color: Colors.white54, fontSize: 12)),
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
