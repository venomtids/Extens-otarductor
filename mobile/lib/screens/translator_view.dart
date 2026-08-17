import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/share_handler.dart';
import '../services/translation_engine.dart';

/// Tela principal: recebe a imagem compartilhada pelo navegador, executa
/// OCR + traducao e sobrepoe o texto traduzido sobre a imagem.
class TranslatorView extends StatefulWidget {
  const TranslatorView({
    super.key,
    required this.payload,
    required this.engine,
  });

  final SharedImagePayload payload;
  final TranslationEngine engine;

  @override
  State<TranslatorView> createState() => _TranslatorViewState();
}

class _TranslatorViewState extends State<TranslatorView> {
  static const String _prefLinguaDestino = 'idioma_destino';
  static const String _prefLinguaOrigem = 'idioma_origem';

  static const Map<String, String> idiomas = <String, String>{
    'pt': 'Portugues',
    'en': 'Ingles',
    'es': 'Espanhol',
    'fr': 'Frances',
    'de': 'Alemao',
    'it': 'Italiano',
    'ja': 'Japones',
    'ru': 'Russo',
  };

  String _idiomaDestino = 'pt';
  String _idiomaOrigem = 'auto';
  bool _processando = true;
  String? _erro;
  String _textoTraduzido = '';
  OcrResult? _ocr;
  List<TextBox> _caixasTraduzidas = const <TextBox>[];

  // Dimensoes reais da imagem, descobertas via ImageStream quando o OCR nao
  // as informa (ex.: content://).
  Size? _tamanhoImagem;
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;

  @override
  void initState() {
    super.initState();
    _carregarPreferencias().then((_) => _processar());
  }

  @override
  void dispose() {
    if (_imageStream != null && _imageListener != null) {
      _imageStream!.removeListener(_imageListener!);
    }
    super.dispose();
  }

  Future<void> _carregarPreferencias() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _idiomaDestino = prefs.getString(_prefLinguaDestino) ?? 'pt';
      _idiomaOrigem = prefs.getString(_prefLinguaOrigem) ?? 'auto';
    });
  }

  Future<void> _salvarIdiomaDestino(String codigo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefLinguaDestino, codigo);
    if (!mounted) return;
    setState(() => _idiomaDestino = codigo);
  }

  Future<void> _salvarIdiomaOrigem(String codigo) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefLinguaOrigem, codigo);
    if (!mounted) return;
    setState(() => _idiomaOrigem = codigo);
  }

  Future<void> _processar() async {
    setState(() {
      _processando = true;
      _erro = null;
      _textoTraduzido = '';
      _caixasTraduzidas = const <TextBox>[];
    });

    try {
      final String entrada =
          widget.payload.imagePath ?? widget.payload.imageUrl ?? '';

      // 1) OCR local.
      final OcrResult ocr = await widget.engine.extrairTexto(entrada);
      if (ocr.isEmpty) {
        if (!mounted) return;
        setState(() {
          _ocr = ocr;
          _processando = false;
          _erro = 'Nenhum texto foi detectado nesta imagem.';
        });
        return;
      }

      // 2) Traducao corrida (rapida, para o rodape).
      final String traducaoCompleta = await widget.engine.traduzirTexto(
        ocr.text,
        _idiomaDestino,
        idiomaOrigem: _idiomaOrigem,
      );

      // 3) Traducao por caixa (para a sobreposicao exata).
      //    Limitamos o numero de chamadas para nao estourar o rate limit
      //    anonimo da API. Textos longos usam apenas a traducao completa.
      List<TextBox> caixas = const <TextBox>[];
      if (ocr.boxes.length <= 60) {
        try {
          caixas = await widget.engine.traduzirCaixas(
            ocr.boxes,
            _idiomaDestino,
            idiomaOrigem: _idiomaOrigem,
          );
        } catch (_) {
          // Se a traducao por caixa falhar, mantem so a completa no rodape.
          caixas = const <TextBox>[];
        }
      }

      if (!mounted) return;
      setState(() {
        _ocr = ocr;
        _textoTraduzido = traducaoCompleta;
        _caixasTraduzidas = caixas;
        _processando = false;
      });
    } on TranslationEngineException catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = e.message;
        _processando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _erro = 'Erro inesperado: $e';
        _processando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Traducao da imagem'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Reprocessar',
            icon: const Icon(Icons.refresh),
            onPressed: _processando ? null : _processar,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(child: _buildAreaVisualizacao()),
          _buildRodape(),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _processando ? null : _abrirSeletorIdioma,
        icon: const Icon(Icons.translate),
        label: Text(
          idiomas[_idiomaDestino] ?? _idiomaDestino,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Area de visualizacao: imagem + camada de sobreposicao
  // ---------------------------------------------------------------------------

  Widget _buildAreaVisualizacao() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double maxW = constraints.maxWidth;
        final double maxH = constraints.maxHeight;

        return Container(
          color: Colors.black87,
          alignment: Alignment.center,
          child: _buildImageStack(maxW, maxH),
        );
      },
    );
  }

  Widget _buildImageStack(double maxW, double maxH) {
    final ImageProvider provider = _obterImageProvider();
    _escutarDimensoes(provider);

    // Dimensoes reais da imagem: prioriza o que o OCR descobriu; se faltar,
    // usa o tamanho medido via ImageStream.
    final double? w0 = (_ocr?.imageWidth ?? 0) > 0
        ? _ocr!.imageWidth
        : _tamanhoImagem?.width;
    final double? h0 = (_ocr?.imageHeight ?? 0) > 0
        ? _ocr!.imageHeight
        : _tamanhoImagem?.height;

    final Widget imagem = _construirImagem(provider);

    double displayW = maxW;
    double displayH = maxH;
    if (w0 != null && w0 > 0 && h0 != null && h0 > 0) {
      final double escala = math.min(maxW / w0, maxH / h0);
      displayW = w0 * escala;
      displayH = h0 * escala;
    }

    return SizedBox(
      width: displayW,
      height: displayH,
      child: Stack(
        key: _imageKey,
        fit: StackFit.expand,
        children: <Widget>[
          // Imagem base.
          ClipRect(child: imagem),

          // Camada semi-transparente que escurece a imagem para o texto
          // traduzido ter contraste.
          if (!_processando && _erro == null)
            Positioned.fill(
              child: Container(color: Colors.black.withOpacity(0.35)),
            ),

          // Caixas traduzidas posicionadas sobre o texto original.
          if (!_processando && _caixasTraduzidas.isNotEmpty)
            ..._buildCaixasSobrepostas(displayW, displayH),

          // Indicador de progresso.
          if (_processando)
            Container(
              color: Colors.black.withOpacity(0.55),
              alignment: Alignment.center,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: 42,
                    height: 42,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  SizedBox(height: 14),
                  Text(
                    'Lendo e traduzindo a imagem...',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ],
              ),
            ),

          // Mensagem de erro.
          if (_erro != null)
            _buildErroOverlay(),
        ],
      ),
    );
  }

  ImageProvider _obterImageProvider() {
    if (widget.payload.isRemoteUrl) {
      return CachedNetworkImageProvider(widget.payload.imageUrl!);
    }
    final String? path = widget.payload.imagePath;
    if (path != null) {
      if (path.startsWith('content://')) {
        return FileImage(File.fromUri(Uri.parse(path)));
      }
      return FileImage(File(path));
    }
    // Fallback: um provider transparente para nao quebrar o Stack.
    return const MemoryImage(<int>[]);
  }

  void _escutarDimensoes(ImageProvider provider) {
    _imageStream?.removeListener(_imageListener!);
    _imageListener = ImageStreamListener(
      (ImageInfo info, bool _) {
        final ui.Image img = info.image;
        final Size novo = Size(
          img.width.toDouble(),
          img.height.toDouble(),
        );
        if (_tamanhoImagem != novo && mounted) {
          setState(() => _tamanhoImagem = novo);
        }
      },
      onError: (Object _, StackTrace? __) {},
    );
    _imageStream = provider.resolve(ImageConfiguration.empty);
    _imageStream!.addListener(_imageListener!);
  }

  Widget _construirImagem(ImageProvider provider) {
    if (widget.payload.isRemoteUrl) {
      return Image(
        image: provider,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _buildImagemRemotaIndisponivel(),
      );
    }
    if (widget.payload.imagePath != null) {
      return Image(
        image: provider,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => _buildImagemRemotaIndisponivel(),
      );
    }
    return _buildImagemRemotaIndisponivel();
  }

  Widget _buildImagemRemotaIndisponivel() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Nao foi possivel exibir a imagem compartilhada.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }

  List<Widget> _buildCaixasSobrepostas(double displayW, double displayH) {
    final OcrResult? ocr = _ocr;
    if (ocr == null || ocr.imageWidth == 0 || ocr.imageHeight == 0) {
      return const <Widget>[];
    }

    final double escalaX = displayW / ocr.imageWidth;
    final double escalaY = displayH / ocr.imageHeight;

    return _caixasTraduzidas.map((TextBox caixa) {
      final double left = caixa.left * escalaX;
      final double top = caixa.top * escalaY;
      final double width = caixa.width * escalaX;
      final double height = caixa.height * escalaY;

      // Fonte adaptativa: quanto menor a caixa, menor o texto, mas com um
      // piso legivel em telas de alta densidade.
      final double tamanhoFonte = math.max(8.0, height * 0.5);

      return Positioned(
        left: left,
        top: top,
        width: width,
        height: height,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          alignment: Alignment.center,
          color: const Color(0xCC000000),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              caixa.text,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: tamanhoFonte,
                fontWeight: FontWeight.w600,
                height: 1.0,
                shadows: const <Shadow>[
                  Shadow(color: Colors.black, blurRadius: 2),
                ],
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildErroOverlay() {
    return Positioned.fill(
      child: Container(
        color: const Color(0xCC5A0C0C),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, color: Colors.white, size: 34),
            const SizedBox(height: 10),
            Text(
              _erro!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Rodape com a traducao corrida (scrollavel)
  // ---------------------------------------------------------------------------

  Widget _buildRodape() {
    if (_processando || _erro != null) {
      return const SizedBox.shrink();
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, -2)),
        ],
      ),
      child: SingleChildScrollView(
        child: Text(
          _textoTraduzido,
          style: const TextStyle(fontSize: 15, height: 1.4),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Seletor de idioma
  // ---------------------------------------------------------------------------

  Future<void> _abrirSeletorIdioma() async {
    String? destino = _idiomaDestino;
    String? origem = _idiomaOrigem;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheet) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Idioma de traducao',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('Traduzir de:'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: <Widget>[
                        ChoiceChip(
                          label: const Text('Detectar'),
                          selected: origem == 'auto',
                          onSelected: (_) => setSheet(() => origem = 'auto'),
                        ),
                        for (final entry in idiomas.entries)
                          ChoiceChip(
                            label: Text(entry.value),
                            selected: origem == entry.key,
                            onSelected: (_) =>
                                setSheet(() => origem = entry.key),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text('Para:'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: <Widget>[
                        for (final entry in idiomas.entries)
                          ChoiceChip(
                            label: Text(entry.value),
                            selected: destino == entry.key,
                            onSelected: (_) =>
                                setSheet(() => destino = entry.key),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Aplicar'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (destino != null && destino != _idiomaDestino) {
      await _salvarIdiomaDestino(destino);
    }
    if (origem != null && origem != _idiomaOrigem) {
      await _salvarIdiomaOrigem(origem);
    }
    if ((destino != null && destino != _idiomaDestino) ||
        (origem != null && origem != _idiomaOrigem)) {
      await _processar();
    }
  }
}
