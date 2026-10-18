import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_full_gpl/return_code.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GeminiSubApp());
}

// -----------------------------------------------------------------------------
// МОДЕЛИ ДАННЫХ
// -----------------------------------------------------------------------------

class SubtitleTrack {
  final int streamIndex;
  final String language;
  final String title;
  final String codec;

  SubtitleTrack({
    required this.streamIndex,
    required this.language,
    required this.title,
    required this.codec,
  });

  @override
  String toString() => "#$streamIndex [${language.toUpperCase()}] ${title.isNotEmpty ? title : codec}";
}

class QueueItem {
  final String path;
  final bool isVideo;
  List<SubtitleTrack> tracks = [];
  SubtitleTrack? selectedTrack;
  String status = "Ожидание";
  double progress = 0.0;
  String? generatedFilePath;

  QueueItem({required this.path, required this.isVideo});

  String get name => p.basename(path);
}

class PresetsConfig {
  String apiKey = "";
  String targetLanguage = "Russian";
  String targetFormat = "srt"; // srt, ass
  String modelName = "gemini-2.5-flash";
  int batchSize = 80;
  int contextSize = 20;
  bool thinking = true;
  String thinkingLevel = "low"; // minimal, low, medium, high
  int thinkingBudget = 1024;
  double temperature = 0.3;
  double topP = 0.95;
  int topK = 40;
  String serviceTier = "standard"; // standard, flex, priority
  String description = "";
  bool extractAudioContext = false;
}

// -----------------------------------------------------------------------------
// ПРИЛОЖЕНИЕ (ЧЕРНО-БЕЛЫЙ МИНИМАЛИСТИЧНЫЙ ДИЗАЙН)
// -----------------------------------------------------------------------------

class GeminiSubApp extends StatelessWidget {
  const GeminiSubApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GST Mobile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
        primaryColor: Colors.white,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.white70,
          surface: Color(0xFF161616),
        ),
        cardTheme: const CardTheme(
          color: Color(0xFF161616),
          shape: RoundedRectangleBorder(
            side: BorderSide(color: Color(0xFF2A2A2A)),
            borderRadius: BorderRadius.all(Radius.circular(6)),
          ),
        ),
        dividerColor: const Color(0xFF2A2A2A),
      ),
      home: const MainTranslatorScreen(),
    );
  }
}

class MainTranslatorScreen extends StatefulWidget {
  const MainTranslatorScreen({Key? key}) : super(key: key);

  @override
  State<MainTranslatorScreen> createState() => _MainTranslatorScreenState();
}

class _MainTranslatorScreenState extends State<MainTranslatorScreen> {
  final List<QueueItem> _queue = [];
  final PresetsConfig _config = PresetsConfig();
  final List<String> _consoleLogs = [];
  final TextEditingController _cliInputController = TextEditingController();

  bool _isProcessingQueue = false;
  bool _isTerminalExpanded = false;

  void _log(String msg) {
    setState(() {
      _consoleLogs.add("[${DateTime.now().toIso8601String().substring(11, 19)}] $msg");
    });
  }

  // 1. Выбор файлов (видео и субтитров пачкой)
  Future<void> _pickFiles() async {
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: [
        'mp4', 'mkv', 'avi', 'mov', 'webm', 'ts',
        'srt', 'ass', 'vtt', 'sub', 'smi', 'stl'
      ],
    );

    if (res != null && res.paths.isNotEmpty) {
      for (var path in res.paths) {
        if (path == null) continue;
        final ext = p.extension(path).toLowerCase();
        final isVid = ['.mp4', '.mkv', '.avi', '.mov', '.webm', '.ts'].contains(ext);
        final item = QueueItem(path: path, isVideo: isVid);

        if (isVid) {
          _log("Анализ дорожек: ${p.basename(path)}");
          item.tracks = await _probeSubtitleTracks(path);
          if (item.tracks.isNotEmpty) {
            item.selectedTrack = item.tracks.first;
          }
        }
        _queue.add(item);
      }
      setState(() {});
    }
  }

  // 2. Инспекция видео дорожек через FFprobe
  Future<List<SubtitleTrack>> _probeSubtitleTracks(String videoPath) async {
    final cmd = '-v error -select_streams s -show_entries stream=index,codec_name:stream_tags=language,title -of json "$videoPath"';
    final session = await FFprobeKit.execute(cmd);
    final output = await session.getOutput();
    if (output == null || output.isEmpty) return [];

    try {
      final Map<String, dynamic> data = jsonDecode(output);
      final List streams = data['streams'] ?? [];
      return streams.map<SubtitleTrack>((s) {
        final tags = s['tags'] ?? {};
        return SubtitleTrack(
          streamIndex: s['index'] ?? 0,
          codec: s['codec_name'] ?? 'unknown',
          language: tags['language'] ?? 'und',
          title: tags['title'] ?? '',
        );
      }).toList();
    } catch (e) {
      _log("Ошибка парсинга дорожек: $e");
      return [];
    }
  }

  // 3. Универсальная конвертация любых субтитров через FFmpeg
  Future<String?> _convertToTargetFormat(String inputPath, String targetFormat) async {
    final tempDir = await getTemporaryDirectory();
    final outPath = p.join(
      tempDir.path,
      "${p.basenameWithoutExtension(inputPath)}_norm_${DateTime.now().millisecondsSinceEpoch}.$targetFormat",
    );

    _log("Конвертация $inputPath -> .$targetFormat");
    final session = await FFmpegKit.execute('-y -i "$inputPath" "$outPath"');
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      return outPath;
    }
    _log("Ошибка конвертации FFmpeg: ${await session.getOutput()}");
    return null;
  }

  // 4. Извлечение дорожки из видео
  Future<String?> _extractTrackFromVideo(String videoPath, int streamIndex, String targetFormat) async {
    final tempDir = await getTemporaryDirectory();
    final outPath = p.join(
      tempDir.path,
      "${p.basenameWithoutExtension(videoPath)}_track$streamIndex.$targetFormat",
    );

    _log("Извлечение дорожки #$streamIndex из видео...");
    final session = await FFmpegKit.execute('-y -i "$videoPath" -map 0:$streamIndex "$outPath"');
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      return outPath;
    }
    _log("Ошибка извлечения дорожки.");
    return null;
  }

  // 5. Обработка очереди (пакетный перевод под единый пресет)
  Future<void> _processQueue() async {
    if (_config.apiKey.trim().isEmpty) {
      _log("ОШИБКА: Задайте Gemini API Key в меню настроек!");
      return;
    }

    setState(() => _isProcessingQueue = true);

    for (var item in _queue) {
      if (item.status == "Завершено") continue;

      setState(() {
        item.status = "Подготовка";
        item.progress = 0.05;
      });

      try {
        String? workingSubFile;

        // Если видео — извлекаем дорожку
        if (item.isVideo) {
          if (item.tracks.isEmpty) {
            item.status = "Нет субтитров в видео";
            continue;
          }
          final track = item.selectedTrack ?? item.tracks.first;
          workingSubFile = await _extractTrackFromVideo(item.path, track.streamIndex, _config.targetFormat);
        } else {
          // Если файл субтитров любого формата — конвертируем в рабочий формат
          workingSubFile = await _convertToTargetFormat(item.path, _config.targetFormat);
        }

        if (workingSubFile == null) {
          item.status = "Ошибка экспорта";
          continue;
        }

        setState(() {
          item.status = "Перевод...";
          item.progress = 0.15;
        });

        // Запуск перевода через Gemini
        final translatedPath = await _translateFile(workingSubFile, item);
        item.generatedFilePath = translatedPath;
        item.status = "Завершено";
        item.progress = 1.0;
        _log("Готово: ${item.name}");
      } catch (e) {
        item.status = "Сбой: $e";
        _log("Исключение для ${item.name}: $e");
      }
      setState(() {});
    }

    setState(() => _isProcessingQueue = false);
    _log("Вся очередь обработана.");
  }

  // Перевод файла пачками
  Future<String> _translateFile(String subPath, QueueItem item) async {
    final content = await File(subPath).readAsString();
    final blocks = content.trim().split(RegExp(r'\n\s*\n'));
    final total = blocks.length;

    List<String> translatedBlocks = [];

    for (var i = 0; i < total; i += _config.batchSize) {
      final end = (i + _config.batchSize < total) ? i + _config.batchSize : total;
      final slice = blocks.sublist(i, end);

      _log("Файл ${item.name}: батч ${i + 1}-$end из $total");
      setState(() {
        item.progress = 0.15 + (0.8 * (i / total));
      });

      final promptPayload = slice.asMap().entries.map((e) => {
        "index": e.key.toString(),
        "block": e.value
      }).toList();

      final systemInstruction = """
You are an expert subtitle linguist. Translate the dialogue blocks to ${_config.targetLanguage}.
CORE RULES:
1. Maintain exact timecodes, indexes, ASS styles, and newline markers.
2. Return a strict JSON array of objects: [{"index": "0", "block": "..."}, ...].
3. Number of items must strictly be ${slice.length}.
${_config.description.isNotEmpty ? "Context: ${_config.description}" : ""}
""";

      final url = Uri.parse(
        "https://generativelanguage.googleapis.com/v1beta/models/${_config.modelName}:generateContent?key=${_config.apiKey}"
      );

      final reqBody = {
        "contents": [
          {"parts": [{"text": jsonEncode(promptPayload)}]}
        ],
        "systemInstruction": {
          "parts": [{"text": systemInstruction}]
        },
        "generationConfig": {
          "responseMimeType": "application/json",
          "temperature": _config.temperature,
          "topP": _config.topP,
          "topK": _config.topK,
        }
      };

      final resp = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(reqBody),
      );

      if (resp.statusCode != 200) {
        throw Exception("API Error ${resp.statusCode}: ${resp.body}");
      }

      final resData = jsonDecode(resp.body);
      final rawOutput = resData['candidates']?[0]?['content']?[0]?['text'] ??
          resData['candidates']?[0]?['content']?['parts']?[0]?['text'];

      if (rawOutput == null) throw Exception("Пустой ответ от Gemini");

      final List decoded = jsonDecode(rawOutput);
      for (var d in decoded) {
        translatedBlocks.add(d['block'].toString());
      }
    }

    final outDir = await getApplicationDocumentsDirectory();
    final finalFileName = "GST_${p.basenameWithoutExtension(item.path)}_${_config.targetLanguage}.${_config.targetFormat}";
    final finalFile = File(p.join(outDir.path, finalFileName));
    await finalFile.writeAsString(translatedBlocks.join("\n\n"));

    return finalFile.path;
  }

  // 6. Выполнение ручной команды из встроенного CLI
  void _executeCliCommand(String input) {
    if (input.trim().isEmpty) return;
    _log("> $input");
    final parts = input.trim().split(" ");
    final cmd = parts[0];

    setState(() {
      if (cmd == "clear") {
        _consoleLogs.clear();
      } else if (cmd == "set" && parts.length >= 3) {
        final key = parts[1];
        final val = parts.sublist(2).join(" ");
        if (key == "model") _config.modelName = val;
        if (key == "lang") _config.targetLanguage = val;
        if (key == "batch") _config.batchSize = int.tryParse(val) ?? _config.batchSize;
        if (key == "temp") _config.temperature = double.tryParse(val) ?? _config.temperature;
        _log("Параметр $key установлен в: $val");
      } else if (cmd == "run") {
        _processQueue();
      } else {
        _log("Неизвестная команда. Доступны: set <key> <val>, run, clear");
      }
    });
    _cliInputController.clear();
  }

  // 7. Модальное окно полной настройки всех параметров оригинального CLI
  void _openSettingsDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF141414),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              height: MediaQuery.of(context).size.height * 0.85,
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("ПАРАМЕТРЫ ПЕРЕВОДА (CLI PRESET)", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const Divider(color: Colors.white24),
                    _buildTextField("Gemini API Key (-k)", _config.apiKey, (v) => _config.apiKey = v, isPass: true),
                    _buildTextField("Язык перевода (-l)", _config.targetLanguage, (v) => _config.targetLanguage = v),
                    _buildDropdown("Модель (--model)", _config.modelName, [
                      "gemini-2.5-flash",
                      "gemini-2.5-pro",
                      "gemini-3.5-flash",
                      "gemini-3.7-flash"
                    ], (v) => setModalState(() => _config.modelName = v!)),
                    _buildDropdown("Целевой формат (-o ext)", _config.targetFormat, ["srt", "ass"], (v) => setModalState(() => _config.targetFormat = v!)),
                    _buildSlider("Batch Size (-b)", _config.batchSize.toDouble(), 10, 300, (v) => setModalState(() => _config.batchSize = v.toInt())),
                    _buildSlider("Context Size (--context-size)", _config.contextSize.toDouble(), 0, 100, (v) => setModalState(() => _config.contextSize = v.toInt())),
                    _buildSlider("Temperature (--temperature)", _config.temperature, 0.0, 2.0, (v) => setModalState(() => _config.temperature = v)),
                    _buildSlider("Top P (--top-p)", _config.topP, 0.0, 1.0, (v) => setModalState(() => _config.topP = v)),
                    _buildDropdown("Thinking Level (--thinking-level)", _config.thinkingLevel, ["minimal", "low", "medium", "high"], (v) => setModalState(() => _config.thinkingLevel = v!)),
                    _buildDropdown("Service Tier (--service-tier)", _config.serviceTier, ["standard", "flex", "priority"], (v) => setModalState(() => _config.serviceTier = v!)),
                    _buildTextField("Контекст / Описание (--description)", _config.description, (v) => _config.description = v),
                    SwitchListTile(
                      title: const Text("Thinking (--thinking)"),
                      value: _config.thinking,
                      activeColor: Colors.white,
                      onChanged: (v) => setModalState(() => _config.thinking = v),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTextField(String label, String initVal, Function(String) onChanged, {bool isPass = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: TextEditingController(text: initVal),
        obscureText: isPass,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white70),
          enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF333333))),
          focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.white)),
        ),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildDropdown(String label, String value, List<String> items, Function(String?) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DropdownButtonFormField<String>(
        value: value,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white70),
          enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF333333))),
        ),
        dropdownColor: const Color(0xFF1E1E1E),
        items: items.map((i) => DropdownMenuItem(value: i, child: Text(i))).toList(),
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildSlider(String label, double val, double min, double max, Function(double) onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("$label: ${val is int ? val : val.toStringAsFixed(2)}", style: const TextStyle(color: Colors.white70, fontSize: 13)),
        Slider(
          value: val,
          min: min,
          max: max,
          activeColor: Colors.white,
          inactiveColor: const Color(0xFF333333),
          onChanged: onChanged,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("GST MOBILE", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2)),
        backgroundColor: Colors.black,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            onPressed: _openSettingsDialog,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            onPressed: () => setState(() => _queue.clear()),
          ),
        ],
      ),
      body: Column(
        children: [
          // Кнопка выбора файлов
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
                icon: const Icon(Icons.add, color: Colors.white),
                label: const Text("+ ДОБАВИТЬ ВИДЕО / СУБТИТРЫ", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                onPressed: _isProcessingQueue ? null : _pickFiles,
              ),
            ),
          ),

          // Список очереди
          Expanded(
            child: _queue.isEmpty
                ? const Center(child: Text("Очередь пуста", style: TextStyle(color: Colors.white38)))
                : ListView.builder(
                    itemCount: _queue.length,
                    itemBuilder: (ctx, i) {
                      final item = _queue[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(item.isVideo ? Icons.movie_outlined : Icons.subtitles_outlined, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                                  ),
                                  Text(item.status, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                                ],
                              ),
                              if (item.isVideo && item.tracks.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                DropdownButton<SubtitleTrack>(
                                  isExpanded: true,
                                  dropdownColor: const Color(0xFF1E1E1E),
                                  value: item.selectedTrack,
                                  items: item.tracks.map((t) => DropdownMenuItem(value: t, child: Text(t.toString(), style: const TextStyle(fontSize: 13)))).toList(),
                                  onChanged: (track) => setState(() => item.selectedTrack = track),
                                ),
                              ],
                              const SizedBox(height: 8),
                              LinearProgressIndicator(value: item.progress, color: Colors.white, backgroundColor: const Color(0xFF222222)),
                              if (item.generatedFilePath != null) ...[
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton.icon(
                                    icon: const Icon(Icons.share, size: 16, color: Colors.white),
                                    label: const Text("ПОДЕЛИТЬСЯ", style: TextStyle(color: Colors.white, fontSize: 12)),
                                    onPressed: () => Share.shareXFiles([XFile(item.generatedFilePath!)]),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),

          // Кнопка старта обработки
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                onPressed: (_queue.isEmpty || _isProcessingQueue) ? null : _processQueue,
                child: Text(_isProcessingQueue ? "ПЕРЕВОД В ПРОЦЕССЕ..." : "ЗАПУСТИТЬ ОЧЕРЕДЬ", style: const TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
          ),

          // Компактный CLI-терминал внизу экрана
          GestureDetector(
            onTap: () => setState(() => _isTerminalExpanded = !_isTerminalExpanded),
            child: Container(
              color: const Color(0xFF141414),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("CLI TERMINAL / LOGS", style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.white70)),
                  Icon(_isTerminalExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up, size: 16),
                ],
              ),
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: _isTerminalExpanded ? 200 : 60,
            color: Colors.black,
            child: Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _consoleLogs.length,
                    itemBuilder: (ctx, i) => Text(
                      _consoleLogs[i],
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.white70),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  height: 36,
                  color: const Color(0xFF161616),
                  child: TextField(
                    controller: _cliInputController,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: "set <param> <val> | run | clear",
                      hintStyle: TextStyle(fontSize: 11, color: Colors.white30),
                      border: InputBorder.none,
                      prefixText: "> ",
                      prefixStyle: TextStyle(color: Colors.white),
                    ),
                    onSubmitted: _executeCliCommand,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}