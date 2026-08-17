# Extens Otarductor v2 — OCR no dispositivo

Extensao para **Firefox Android (GeckoView)** em **Manifest V3** que:

1. Adiciona **"Traduzir Texto da Imagem"** ao menu de toque longo sobre `<img>`.
2. Exibe um **botao flutuante (FAB)** "Traduzir" apos tocar numa imagem.
3. Faz OCR **100% no aparelho** via **Tesseract.js (WASM)** — sem chave, sem
   cadastro e sem enviar imagens a servidores externos.
4. Traduz o texto via **MyMemory** (sem chave).
5. **Sobrepõe um `<div>` responsivo** sobre a imagem com a traducao, fechando
   por toque.

## Arquitetura

- **Firefox MV3** usa *event pages* (com DOM, Web Workers e WASM), nao service
  workers puros. O `manifest.json` declara `background.scripts` contendo o
  `vendor/tesseract/tesseract.min.js` antes de `background.js`, e CSP com
  `wasm-unsafe-eval` + `worker-src 'self'`.
- O **Tesseract** cria um Web Worker no background, carrega o core WASM e os
  dados de idioma empacotados em `vendor/tesseract/`. O worker e cacheado por
  idioma e recriado se a event page for encerrada.
- As **imagens** sao capturadas no content script (canvas / fetch com cookies)
  para contornar *hotlink protection*, e enviadas ao background como data URL.

## Estrutura

```
manifest.json
background.js            # Event page: menu + Tesseract OCR + MyMemory
content.js               # Injetor visual: listener, FAB, captura, overlay
content.css              # Animacoes
options.html / options.js# Preferencias (idiomas, sem chave)
vendor/tesseract/
├── tesseract.min.js     # Biblioteca Tesseract.js v5.1.1
├── worker.min.js        # Web Worker do Tesseract
├── tesseract-core-lstm.wasm(.js)  # Core WASM (var. nao-SIMD, universal)
└── lang-data/
    ├── eng.traineddata.gz
    └── por.traineddata.gz
```

## Idiomas

Vem embarcado **Ingles** e **Portugues**. Para adicionar outro idioma, baixe o
`<cod>.traineddata.gz` (de `@tesseract.js-data/<cod>/4.0.0/`) para
`vendor/tesseract/lang-data/` e adicione o `<option>` no `options.html`.

## Limitacoes honestas

- O core e a variante **nao-SIMD** (~6,8 MB) para funcionar em qualquer
  dispositivo; e um pouco mais lento que a versao SIMD em aparelhos modernos.
- O primeiro OCR apos a event page iniciar demora mais (carrega WASM + idioma).
  Os seguintes reutilizam o worker cacheado.
- Tesseract e menos preciso que OCR comercial em imagens ruidosas; ajuste a
  linguagem do OCR nas opcoes.
