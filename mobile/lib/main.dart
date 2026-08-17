import 'package:flutter/material.dart';

import 'screens/translator_view.dart';
import 'services/share_handler.dart';
import 'services/translation_engine.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OtarductorApp());
}

class OtarductorApp extends StatefulWidget {
  const OtarductorApp({super.key});

  @override
  State<OtarductorApp> createState() => _OtarductorAppState();
}

class _OtarductorAppState extends State<OtarductorApp> {
  final ShareHandler _shareHandler = ShareHandler();
  final TranslationEngine _engine = TranslationEngine();

  SharedImagePayload? _payload;
  String? _erroInicial;

  @override
  void initState() {
    super.initState();

    // Compartilhamentos que chegam com o app ja aberto.
    _shareHandler.initialize();
    _shareHandler.stream.listen(
      (SharedImagePayload payload) {
        if (!mounted) return;
        setState(() {
          _payload = payload;
          _erroInicial = null;
        });
      },
      onError: (Object erro) {
        if (!mounted) return;
        setState(() => _erroInicial = erro.toString());
      },
    );

    // Compartilhamento que abriu o app (estava fechado).
    _shareHandler.initial().then((SharedImagePayload? payload) {
      if (!mounted || payload == null) return;
      setState(() {
        _payload = payload;
        _erroInicial = null;
      });
    }).catchError((Object erro) {
      if (!mounted) return;
      setState(() => _erroInicial = erro.toString());
    });
  }

  @override
  void dispose() {
    _shareHandler.dispose();
    _engine.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Otarductor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2D7FF9),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2D7FF9),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: _paginaAtual(),
    );
  }

  Widget _paginaAtual() {
    if (_erroInicial != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Otarductor')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _erroInicial!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ),
      );
    }

    if (_payload == null) {
      return const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.touch_app, size: 56, color: Colors.blueAccent),
                SizedBox(height: 16),
                Text(
                  'Compartilhe uma imagem\nem qualquer navegador',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 8),
                Text(
                  'Segure uma imagem no navegador e escolha\n'
                  '"Compartilhar via Otarductor".',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return TranslatorView(
      key: ValueKey<String>(_payload!.id),
      payload: _payload!,
      engine: _engine,
    );
  }
}
