# Como instalar e usar no celular

A extensao roda no **Firefox Android**. O OCR e local (Tesseract WASM): **nao
precisa de chave nem cadastro**.

## 1. Empacotar

Na pasta da extensao (onde esta o `manifest.json`):

```bash
zip -r ../otarductor.xpi . -x "*.git*" -x "README.md" -x "INSTALL.md"
```

> Inclua a pasta `vendor/` — ela contem o motor de OCR e os idiomas.

## 2. Instalar no Firefox Android

### Opcao A — Publicar na AMO (recomendado, funciona em qualquer Firefox)

1. Crie conta em https://addons.mozilla.org/developers.
2. **Enviar um novo complemento** → faca upload do `.xpi`.
3. Na distribuicao escolha **Nao listado (Unlisted)**. A AMO assina e devolve
   um `.xpi` assinado.
4. No celular, abra o link do arquivo assinado e confirme a instalacao.

### Opcao B — Firefox Nightly + colecao customizada

1. Instale o **Firefox Nightly** pela Play Store.
2. Toque 5x no logo em **Configuracoes → Sobre o Nightly** para liberar opcoes
   de desenvolvedor.
3. **Configuracoes → Colecao de complementos personalizada** e informe a sua
   colecao da AMO.
4. Instale a extensao pela lista de complementos.

### Testar antes (no computador)

No Firefox de mesa: `about:debugging#/runtime/this-firefox` → **Carregar
extensao temporaria** → selecione o `manifest.json`.

## 3. Usar

1. Abra uma pagina com imagens.
2. **Toque longo** na imagem → **Traduzir Texto da Imagem**.
   (Ou toque rapido e use o botao flutuante "Traduzir".)
3. Aguarde "Processando imagem...". No primeiro uso o OCR carrega o WASM; e
   normal demorar alguns segundos.
4. A traducao aparece sobre a imagem. Toque para fechar.
5. Ajuste os idiomas em **Extensoes → Extens Otarductor → Configuracoes**.

## Solucao de problemas

- **Primeira traducao demora**: o WASM e o pacote de idioma (~17 MB) sao
  carregos na primeira vez; depois ficam em cache enquanto a event page vive.
- **"Nenhum texto detectado"**: confira se a linguagem do OCR nas opcoes
  corresponde ao idioma do texto da imagem (Ingles/Portugues disponiveis).
- **Imagem de site protegido nao traduz**: a captura por canvas/fetch com
  cookies tenta contornar; se falhar, abra a imagem em nova aba e tente de la.
