# Otarductor — App Flutter (Share Target)

Receptor global de compartilhamento do Android. Ao segurar uma imagem em
qualquer navegador e tocar em **"Compartilhar via Otarductor"**, o app recebe
a URL ou o arquivo temporario, faz OCR local (Google ML Kit), traduz o texto
(MyMemory, sem chave) e sobrepoe a traducao sobre a imagem.

## Estrutura

```
android/app/src/main/AndroidManifest.xml   # Intent filters SEND image/* e text/plain
pubspec.yaml                               # Dependencias
lib/
  main.dart                                # Bootstrap + ShareHandler -> TranslatorView
  services/share_handler.dart              # Recepcao de intents (streams + inicial)
  services/translation_engine.dart         # Download/OCR (com bounding boxes)/Traducao
  screens/translator_view.dart             # Stack com caixas posicionadas e FAB de idioma
```

## Como rodar

```bash
cd mobile
flutter pub get
flutter run --release
```

> O Android Studio/Flutter gera automaticamente os demais arquivos de
> plataforma (Gradle wrapper, icones de lançamento). Os arquivos entregues aqui
> sao o nucleo pronto para ser aberto num projeto Flutter padrao (`flutter create .`).

## Fluxo

1. O navegador dispara `ACTION_SEND` com `image/*` (arquivo) ou `text/plain`
   (URL da imagem).
2. `ShareHandler` normaliza para `SharedImagePayload { imagePath | imageUrl }`.
3. `TranslationEngine.extrairTexto` baixa a URL (se necessario) e roda o ML Kit,
   devolvendo `OcrResult { text, boxes, imageWidth, imageHeight }`.
4. `traduzirTexto` chama a API MyMemory; `traduzirCaixas` traduz cada bloco.
5. `TranslatorView` empilha a imagem e cada `Positioned` sobre a regiao do texto
   original, usando a escala entre pixels da imagem e pixels exibidos.
