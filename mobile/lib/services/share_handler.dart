import 'dart:async';
import 'dart:io';

import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Resultado normalizado de um compartilhamento recebido de um navegador
/// ou de qualquer outro app.
///
/// Sempre exatamente um dos campos [imagePath] ou [imageUrl] serao
/// preenchidos. Se ambos forem nulos, o compartilhamento nao era uma imagem
/// nem uma URL de imagem utilizavel.
class SharedImagePayload {
  const SharedImagePayload({
    this.imagePath,
    this.imageUrl,
    this.rawText,
  });

  /// Caminho absoluto para o arquivo de imagem temporario (content:// ou
  /// file:// ja resolvido pelo plugin). Pode ser exibido com [File].
  final String? imagePath;

  /// URL remota da imagem (https://...), usada quando o navegador
  /// compartilha apenas o link.
  final String? imageUrl;

  /// Texto bruto recebido, util para depuracao e para links que nao sao
  /// diretamente imagens.
  final String? rawText;

  bool get isLocalFile => imagePath != null;
  bool get isRemoteUrl => imageUrl != null;
  bool get isValid => imagePath != null || imageUrl != null;

  /// Identificador estavel para a UI (usado como ValueKey).
  String get id => imagePath ?? imageUrl ?? rawText ?? '';

  @override
  String toString() =>
      'SharedImagePayload(path: $imagePath, url: $imageUrl, text: $rawText)';
}

/// Servico responsavel por interceptar intents de compartilhamento do
/// sistema operacional e transforma-los em [SharedImagePayload].
///
/// Cobre dois ciclos de vida:
///  - App fechado: [initial] le o intent que abriu o app.
///  - App em memoria: [stream] entrega novos compartilhamentos a quente.
class ShareHandler {
  ShareHandler();

  final ReceiveSharingIntent _intent = ReceiveSharingIntent.instance;
  StreamSubscription<List<SharedMediaFile>>? _subscription;

  final StreamController<SharedImagePayload> _controller =
      StreamController<SharedImagePayload>.broadcast();

  /// Stream de imagens compartilhadas enquanto o app esta em memoria.
  Stream<SharedImagePayload> get stream => _controller.stream;

  /// Inicializa os listeners. Deve ser chamado uma unica vez no bootstrap
  /// do app (geralmente em `main()` ou no `initState` do widget raiz).
  void initialize() {
    _subscription = _intent.getMediaStream().listen(
      (List<SharedMediaFile> files) {
        final payload = _parse(files);
        if (payload != null) _controller.add(payload);
      },
      onError: (Object error) {
        _controller.addError(
          ShareHandlerException('Falha ao receber compartilhamento: $error'),
        );
      },
    );
  }

  /// Le o compartilhamento que abriu o app quando ele estava fechado.
  /// Retorna null se o app foi aberto normalmente pelo launcher.
  Future<SharedImagePayload?> initial() async {
    try {
      final files = await _intent.getInitialMedia();
      final payload = _parse(files);
      if (payload != null) {
        // Informa ao plugin que o intent ja foi consumido.
        await _intent.reset();
      }
      return payload;
    } catch (error) {
      throw ShareHandlerException(
        'Falha ao ler compartilhamento inicial: $error',
      );
    }
  }

  SharedImagePayload? _parse(List<SharedMediaFile>? files) {
    if (files == null || files.isEmpty) return null;

    for (final SharedMediaFile file in files) {
      final String? path = file.path;
      final String mime = (file.mimeType ?? '').toLowerCase();
      final String type = file.type.name.toLowerCase();

      // 1) Arquivo de imagem entregue pelo SO.
      final bool isImageType =
          mime.startsWith('image/') || type == 'image';
      if (isImageType && path.isNotEmpty) {
        return SharedImagePayload(
          imagePath: path,
          rawText: path,
        );
      }

      // 2) Texto/URL compartilhado pelo navegador.
      final String text = path.trim();
      if (text.isEmpty) continue;

      final Uri? uri = Uri.tryParse(text);
      if (uri != null && uri.hasScheme) {
        // URL direta de imagem pela extensao.
        if (_isDirectImageUrl(uri)) {
          return SharedImagePayload(imageUrl: text, rawText: text);
        }
        // URL de pagina: tenta extrair uma imagem da query string (ex.:
        // google.com/imgres?imgurl=...).
        final String? extraida = _extractImageFromQuery(uri);
        if (extraida != null) {
          return SharedImagePayload(imageUrl: extraida, rawText: text);
        }
        // Como ultimo recurso, devolve como URL remota; o motor tenta
        // baixar e o OCR falhara com erro amigavel se nao for imagem.
        if (uri.scheme == 'http' || uri.scheme == 'https') {
          return SharedImagePayload(imageUrl: text, rawText: text);
        }
      }
    }

    return null;
  }

  bool _isDirectImageUrl(Uri uri) {
    final String path = uri.path.toLowerCase();
    const extensions = <String>[
      '.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp', '.heic', '.heif',
    ];
    return extensions.any((ext) => path.endsWith(ext));
  }

  String? _extractImageFromQuery(Uri uri) {
    for (final key in const <String>['imgurl', 'mediaurl', 'url', 'image', 'src']) {
      final value = uri.queryParameters[key];
      if (value != null && value.isNotEmpty) {
        final decoded = Uri.decodeFull(value);
        final candidate = Uri.tryParse(decoded);
        if (candidate != null &&
            (candidate.scheme == 'http' || candidate.scheme == 'https')) {
          return decoded;
        }
      }
    }
    return null;
  }

  /// Libera recursos. Chamado no dispose do widget raiz.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _controller.close();
  }
}

/// Excecao de dominio lancada por [ShareHandler].
class ShareHandlerException implements Exception {
  ShareHandlerException(this.message);
  final String message;

  @override
  String toString() => message;
}
