import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Caixa delimitadora de um bloco de texto detectado pelo OCR.
///
/// As coordenadas sao expressas em **pixels da imagem original** (mesmo
/// espaco retornado pelo ML Kit), antes de qualquer redimensionamento na UI.
class TextBox {
  const TextBox({
    required this.text,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final String text;
  final double left;
  final double top;
  final double width;
  final double height;

  @override
  String toString() => 'TextBox($text @ ${left}x$top ${width}x$height)';
}

/// Resultado completo do OCR: texto corrido + blocos com coordenadas.
class OcrResult {
  const OcrResult({
    required this.text,
    required this.boxes,
    required this.imageWidth,
    required this.imageHeight,
  });

  final String text;
  final List<TextBox> boxes;
  final double imageWidth;
  final double imageHeight;

  bool get isEmpty => text.trim().isEmpty;
}

/// Motor assincrono que orquestra download da imagem, OCR local e traducao.
///
/// O OCR usa o [TextRecognizer] do ML Kit (script latino por padrao), que roda
/// 100% no dispositivo. A traducao usa a API publica MyMemory (sem chave).
class TranslationEngine {
  TranslationEngine({TextRecognizer? recognizer, http.Client? client})
      : _recognizer = recognizer ??
            TextRecognizer(script: TextRecognitionScript.latin),
        _client = client ?? http.Client();

  final TextRecognizer _recognizer;
  final http.Client _client;

  /// Extrai texto de uma imagem.
  ///
  /// [inputPathOrUrl] pode ser:
  ///  - caminho local (content://... ou /data/.../arquivo.jpg)
  ///  - URL remota (https://.../imagem.jpg), que sera baixada antes.
  ///
  /// Retorna um [OcrResult] com o texto bruto e os [TextBox] (coordenadas
  /// espaciais de cada bloco reconhecido).
  Future<OcrResult> extrairTexto(String inputPathOrUrl) async {
    if (inputPathOrUrl.trim().isEmpty) {
      throw const TranslationEngineException('Entrada vazia para o OCR.');
    }

    final File arquivo = await _garantirArquivoLocal(inputPathOrUrl);
    if (!arquivo.existsSync()) {
      throw TranslationEngineException(
        'Nao foi possivel obter o arquivo da imagem: $inputPathOrUrl',
      );
    }

    final String caminho = arquivo.path;
    final InputImage inputImage = InputImage.fromFilePath(caminho);

    final RecognizedText recognized;
    try {
      recognized = await _recognizer.processImage(inputImage);
    } catch (error) {
      throw TranslationEngineException('Falha no OCR: $error');
    }

    final List<TextBox> boxes = <TextBox>[];
    for (final block in recognized.blocks) {
      final Rect? rect = block.boundingBox;
      if (rect == null) continue;
      final String texto = block.text.trim();
      if (texto.isEmpty) continue;
      boxes.add(
        TextBox(
          text: texto,
          left: rect.left.toDouble(),
          top: rect.top.toDouble(),
          width: rect.width.toDouble(),
          height: rect.height.toDouble(),
        ),
      );
    }

    // Dimensoes da imagem original para escalar as caixas na UI.
    final dim = await _dimensoesImagem(arquivo);

    return OcrResult(
      text: recognized.text.trim(),
      boxes: boxes,
      imageWidth: dim?.width ?? 0,
      imageHeight: dim?.height ?? 0,
    );
  }

  /// Traduz [textoBruto] para [idiomaDestino] (ex.: "pt", "en", "es").
  ///
  /// Usa a API publica MyMemory. Textos longos sao fragmentados porque o
  /// endpoint anonimo limita ~500 caracteres por requisicao.
  Future<String> traduzirTexto(
    String textoBruto,
    String idiomaDestino, {
    String idiomaOrigem = 'auto',
  }) async {
    final String texto = textoBruto.trim();
    if (texto.isEmpty) return '';

    // Se origem e destino sao iguais, nao ha o que traduzir.
    final String de = idiomaOrigem == 'auto' ? 'autodetect' : idiomaOrigem;
    if (de == idiomaDestino) return texto;

    const int tamanhoPedaco = 450;
    final List<String> saidas = <String>[];

    for (int i = 0; i < texto.length; i += tamanhoPedaco) {
      final int fim = math.min(i + tamanhoPedaco, texto.length);
      final String pedaco = texto.substring(i, fim);

      final Uri uri = Uri.parse(
        'https://api.mymemory.translated.net/get',
      ).replace(
        queryParameters: <String, String>{
          'q': pedaco,
          'langpair': '$de|$idiomaDestino',
        },
      );

      final http.Response resposta;
      try {
        resposta = await _client
            .get(uri)
            .timeout(const Duration(seconds: 30));
      } catch (error) {
        throw TranslationEngineException(
          'Falha de rede na traducao: $error',
        );
      }

      if (resposta.statusCode != 200) {
        throw TranslationEngineException(
          'Servico de traducao respondeu HTTP ${resposta.statusCode}.',
        );
      }

      final String traduzido = _extrairTraducao(resposta.bodyBytes);
      if (traduzido.isEmpty) {
        throw const TranslationEngineException(
          'Resposta de traducao em formato inesperado.',
        );
      }
      saidas.add(traduzido);
    }

    return saidas.join(' ').trim();
  }

  /// Traduz cada caixa individualmente e devolve uma lista pareada.
  /// Util para sobrepor a traducao exatamente sobre cada bloco original.
  Future<List<TextBox>> traduzirCaixas(
    List<TextBox> caixas,
    String idiomaDestino, {
    String idiomaOrigem = 'auto',
  }) async {
    final List<TextBox> resultado = <TextBox>[];
    for (final caixa in caixas) {
      final String trad = await traduzirTexto(
        caixa.text,
        idiomaDestino,
        idiomaOrigem: idiomaOrigem,
      );
      resultado.add(
        TextBox(
          text: trad,
          left: caixa.left,
          top: caixa.top,
          width: caixa.width,
          height: caixa.height,
        ),
      );
    }
    return resultado;
  }

  /// Libera os recursos nativos do recognizer.
  Future<void> close() async {
    await _recognizer.close();
    _client.close();
  }

  // -------------------------------------------------------------------
  // Internos
  // -------------------------------------------------------------------

  /// Se [caminhoOuUrl] for uma URL remota, baixa para um arquivo temporario.
  /// Se ja for um caminho local, devolve um [File] apontando para ele.
  Future<File> _garantirArquivoLocal(String caminhoOuUrl) async {
    final bool ehRemoto = caminhoOuUrl.startsWith('http://') ||
        caminhoOuUrl.startsWith('https://');

    if (!ehRemoto) {
      // InputImage.fromFilePath aceita tanto caminhos de arquivo quanto URIs
      // content://; retornamos um File cujo .path repassa essa string.
      return File(caminhoOuUrl);
    }

    final Directory temp = await getTemporaryDirectory();
    final String nome =
        'img_${DateTime.now().millisecondsSinceEpoch}_${caminhoOuUrl.hashCode}.img';
    final File destino = File('${temp.path}/$nome');

    final http.Response resposta;
    try {
      resposta = await _client
          .get(Uri.parse(caminhoOuUrl))
          .timeout(const Duration(seconds: 30));
    } catch (error) {
      throw TranslationEngineException(
        'Falha ao baixar a imagem: $error',
      );
    }

    if (resposta.statusCode != 200) {
      throw TranslationEngineException(
        'Servidor da imagem respondeu HTTP ${resposta.statusCode}.',
      );
    }
    if (resposta.bodyBytes.isEmpty) {
      throw const TranslationEngineException('Imagem remota vazia.');
    }

    await destino.writeAsBytes(resposta.bodyBytes, flush: true);
    return destino;
  }

  /// Le o cabecalho PNG/JPEG para descobrir as dimensoes reais da imagem.
  /// Usado para escalar as caixas do OCR na Stack de sobreposicao.
  ///
  /// Para URIs content://, a leitura direta de bytes pode nao funcionar;
  /// nesse caso retornamos null e a UI descobre o tamanho via ImageStream.
  Future<({double width, double height})?> _dimensoesImagem(
    File arquivo,
  ) async {
    final String caminho = arquivo.path;
    if (caminho.startsWith('content://')) return null;
    try {
      final Uint8List bytes = await arquivo.readAsBytes();
      return _decodificarDimensoes(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Decodificacao minimalista de cabecalhos PNG/JPEG (sem dependencias).
  ({double width, double height})? _decodificarDimensoes(Uint8List bytes) {
    const int length = 0x200;
    final int header = bytes.length >= 24 ? 24 : bytes.length;
    if (header < 24) return null;

    // PNG: "89 50 4E 47 0D 0A 1A 0A"
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      final int w = (bytes[16] << 24) |
          (bytes[17] << 16) |
          (bytes[18] << 8) |
          bytes[19];
      final int h = (bytes[20] << 24) |
          (bytes[21] << 16) |
          (bytes[22] << 8) |
          bytes[23];
      return (width: w.toDouble(), height: h.toDouble());
    }

    // JPEG: varre os marcadores SOFn.
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      int i = 2;
      while (i < bytes.length - 9) {
        if (bytes[i] != 0xFF) {
          i++;
          continue;
        }
        final int marker = bytes[i + 1];
        // SOF0..SOF15 (exceto DHT=0xC4, DAC=0xCC, e os de reinicio 0xD0-0xD9)
        final bool sof = marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC;
        if (sof) {
          final int h = (bytes[i + 5] << 8) | bytes[i + 6];
          final int w = (bytes[i + 7] << 8) | bytes[i + 8];
          return (width: w.toDouble(), height: h.toDouble());
        }
        final int segLen = (bytes[i + 2] << 8) | bytes[i + 3];
        i += 2 + segLen;
      }
    }
    // WebP simples (VP8/VP8L/VP8X) nao e decodificado aqui; as caixas ainda
    // funcionarao, apenas a escala exata pode ficar levemente errada.
    return null;
  }

  /// Extrai o texto traduzido do JSON do MyMemory a partir de bytes puros
  /// (evita importar dart:convert desnecessariamente, mas e equivalente).
  String _extrairTraducao(Uint8List bytes) {
    // Usamos uma decodificacao manual simples e robusta para o campo
    // responseData.translatedText, suficiente para a API do MyMemory.
    final String body = String.fromCharCodes(bytes);

    // Procura pelo padrao JSON: "translatedText":"..."
    final RegExp regex = RegExp(
      r'"translatedText"\s*:\s*"((?:\\.|[^"\\])*)"',
    );
    final Match? match = regex.firstMatch(body);
    if (match == null) return '';

    String valor = match.group(1)!;
    // Reverte as escapes JSON mais comuns.
    valor = valor
        .replaceAll(r'\"', '"')
        .replaceAll(r'\\', r'\')
        .replaceAll(r'\/', '/')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\t', '\t')
        .replaceAllMapped(
          RegExp(r'\\u([0-9a-fA-F]{4})'),
          (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
        );
    return valor.trim();
  }
}

/// Excecao de dominio do [TranslationEngine].
class TranslationEngineException implements Exception {
  const TranslationEngineException(this.message);
  final String message;

  @override
  String toString() => message;
}
