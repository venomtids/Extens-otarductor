/**
 * background.js — Event Page do Firefox (Manifest V3)
 *
 * No Firefox, o background de MV3 roda como "event page" (pagina oculta com
 * DOM, Web Workers e WASM), nao como um service worker puro. Isso e o que
 * permite executar o Tesseract.js (que cria um Web Worker e carrega WASM).
 *
 * Responsabilidades:
 *  1. Registrar o menu de contexto "Traduzir Texto da Imagem".
 *  2. Re-registrar o menu a cada reativacao da event page.
 *  3. Ao disparar, enviar TRADUZIR_IMAGEM ao content script.
 *  4. Executar OCR 100% no dispositivo via Tesseract.js (sem chave, sem
 *     servidor externo) e traduzir via MyMemory (sem chave).
 */

"use strict";

const MENU_ID = "traduzir_img_mobile";

// Caminhos dos recursos empacotados (mesma origem da extensao).
const URL_BASE = browser.runtime.getURL("vendor/tesseract/");
const TESS = {
  workerPath: URL_BASE + "worker.min.js",
  corePath: URL_BASE + "tesseract-core-lstm.wasm.js",
  langPath: URL_BASE + "lang-data"
};

// Cache de workers do Tesseract por idioma. A event page pode ser
// encerrada a qualquer momento; nesse caso o cache e perdido e o worker
// e recriado na proxima requisicao (comportamento normal de MV3).
const workers = new Map();
let workersEmCriacao = new Map();

/* ------------------------------------------------------------------ */
/* Registro do menu de contexto                                       */
/* ------------------------------------------------------------------ */

function registrarMenu() {
  browser.contextMenus.removeAll(() => {
    browser.contextMenus.create({
      id: MENU_ID,
      title: "Traduzir Texto da Imagem",
      contexts: ["image"]
    });
  });
}

browser.runtime.onInstalled.addListener(registrarMenu);
if (browser.runtime.onStartup) {
  browser.runtime.onStartup.addListener(registrarMenu);
}
try {
  registrarMenu();
} catch (err) {
  console.warn("[Otarductor] Falha no registro inicial do menu:", err);
}

/* ------------------------------------------------------------------ */
/* Toque longo -> notifica o content script                           */
/* ------------------------------------------------------------------ */

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!info || info.menuItemId !== MENU_ID) return;
  if (!tab || typeof tab.id !== "number") return;

  const srcUrl = info.srcUrl;
  if (!srcUrl) return;

  try {
    await browser.tabs.sendMessage(tab.id, {
      command: "TRADUZIR_IMAGEM",
      srcUrl
    });
  } catch (_) {
    // Content script ainda nao injetado: injeta e reenvia.
    try {
      await browser.scripting.executeScript({
        target: { tabId: tab.id, allFrames: false },
        files: ["content.js"]
      });
      await browser.scripting.insertCSS({
        target: { tabId: tab.id, allFrames: false },
        files: ["content.css"]
      });
      await browser.tabs.sendMessage(tab.id, {
        command: "TRADUZIR_IMAGEM",
        srcUrl
      });
    } catch (err) {
      console.error("[Otarductor] Falha ao contatar a aba:", err);
    }
  }
});

/* ------------------------------------------------------------------ */
/* Ponte de mensagens                                                 */
/* ------------------------------------------------------------------ */

browser.runtime.onMessage.addListener((msg) => {
  if (!msg || typeof msg !== "object") return undefined;

  if (msg.type === "BAIXAR_IMAGEM") {
    return baixarImagemComoDataUrl(msg.url);
  }

  if (msg.type !== "PROCESS_IMAGE") return undefined;

  // Retornamos uma Promise para o sendMessage assincrono.
  return (async () => {
    try {
      const opcoes = msg.opcoes || (await carregarOpcoes());
      const resultado = await processarImagem(
        msg.imgUrl,
        opcoes,
        msg.imagem || null
      );
      return { ok: true, ...resultado };
    } catch (err) {
      const mensagem = err && err.message ? err.message : String(err);
      console.error("[Otarductor] Erro no processamento:", mensagem);
      return { ok: false, erro: mensagem };
    }
  })();
});

async function carregarOpcoes() {
  const padrao = {
    idiomaOCR: "eng",
    idiomaOrigem: "en",
    idiomaDestino: "pt"
  };
  const salvo = await browser.storage.local.get(padrao);
  return { ...padrao, ...salvo };
}

/* ------------------------------------------------------------------ */
/* Pipeline: imagem -> OCR (Tesseract WASM) -> traducao (MyMemory)    */
/* ------------------------------------------------------------------ */

async function processarImagem(imgUrl, opcoes, imagem) {
  if (!imgUrl && !imagem) {
    throw new Error("Imagem ausente.");
  }

  const linguaOCR = normalizarLinguaOCR(opcoes.idiomaOCR || "eng");

  const textoOriginal = await executarOCROnDevice(imagem, imgUrl, linguaOCR);

  const limpo = (textoOriginal || "").replace(/\s+/g, " ").trim();
  if (!limpo) {
    return {
      original: "",
      traduzido: "(Nenhum texto foi detectado nesta imagem.)"
    };
  }

  const traduzido = await traduzirTexto(
    limpo,
    opcoes.idiomaOrigem || "en",
    opcoes.idiomaDestino || "pt"
  );

  return { original: limpo, traduzido };
}

function normalizarLinguaOCR(codigo) {
  // O options.html salva codigos de 2 letras; Tesseract usa 3.
  const mapa = {
    en: "eng", pt: "por", es: "spa", fr: "fra", de: "deu",
    it: "ita", ja: "jpn", ru: "rus", zh: "chi_sim"
  };
  if (codigo && codigo.length === 3) return codigo;
  return mapa[codigo] || "eng";
}

/**
 * Executa OCR no dispositivo usando Tesseract.js.
 * - imagem: { dataUrl, mimeType } capturada pelo content script.
 * - imgUrl: URL de fallback caso a captura tenha falhado.
 */
async function executarOCROnDevice(imagem, imgUrl, lingua) {
  const worker = await obterWorker(lingua);
  const fonte =
    imagem && imagem.dataUrl ? imagem.dataUrl : imgUrl;

  if (!fonte) {
    throw new Error("Nao foi possivel obter a imagem para OCR.");
  }

  const { data } = await worker.recognize(fonte);
  return (data && data.text) || "";
}

async function obterWorker(lingua) {
  if (workers.has(lingua)) return workers.get(lingua);
  if (workersEmCriacao.has(lingua)) return workersEmCriacao.get(lingua);

  const promessa = (async () => {
    // Tesseract e carregado por vendor/tesseract/tesseract.min.js, listado
    // antes deste arquivo no background.scripts do manifesto.
    if (typeof Tesseract === "undefined") {
      throw new Error("Motor de OCR (Tesseract) nao foi carregado.");
    }

    const worker = await Tesseract.createWorker(lingua, 1, {
      workerPath: TESS.workerPath,
      corePath: TESS.corePath,
      langPath: TESS.langPath,
      workerBlobURL: false,
      gzip: true,
      logger: (m) => {
        if (m && m.status) {
          console.debug("[Otarductor] OCR:", m.status, m.progress || "");
        }
      }
    });

    workers.set(lingua, worker);
    return worker;
  })();

  workersEmCriacao.set(lingua, promessa);
  try {
    return await promessa;
  } finally {
    workersEmCriacao.delete(lingua);
  }
}

browser.runtime.onSuspend?.addListener?.(() => {
  // Limpeza antes da event page ser encerrada.
  for (const worker of workers.values()) {
    try { worker.terminate && worker.terminate(); } catch (_) {}
  }
  workers.clear();
});

/* ------------------------------------------------------------------ */
/* Traducao via MyMemory (sem chave)                                  */
/* ------------------------------------------------------------------ */

async function traduzirTexto(texto, de, para) {
  if (de === para) return texto;

  const TAMANHO_PEDACO = 480;
  const saidas = [];

  for (let i = 0; i < texto.length; i += TAMANHO_PEDACO) {
    const pedaco = texto.slice(i, i + TAMANHO_PEDACO);
    const url =
      "https://api.mymemory.translated.net/get?q=" +
      encodeURIComponent(pedaco) +
      "&langpair=" +
      encodeURIComponent(de) +
      "|" +
      encodeURIComponent(para);

    const resp = await fetchComTempo(url, { method: "GET" }, 30000);
    if (!resp.ok) {
      throw new Error("Servico de traducao respondeu HTTP " + resp.status + ".");
    }

    const dados = await resp.json();
    const t =
      dados &&
      dados.responseData &&
      typeof dados.responseData.translatedText === "string"
        ? dados.responseData.translatedText
        : "";

    if (!t) {
      throw new Error("Resposta de traducao em formato inesperado.");
    }
    saidas.push(t);
  }

  return saidas.join(" ");
}

/* ------------------------------------------------------------------ */
/* Download de imagem com privilegios de extensao (anti-hotlink)      */
/* ------------------------------------------------------------------ */

async function baixarImagemComoDataUrl(url) {
  if (!url) return { ok: false, erro: "URL ausente" };
  try {
    const resp = await fetchComTempo(
      url,
      { credentials: "include", mode: "cors" },
      30000
    );
    if (!resp.ok) return { ok: false, erro: "HTTP " + resp.status };
    const blob = await resp.blob();
    if (!blob || blob.size === 0) {
      return { ok: false, erro: "Imagem vazia" };
    }
    const dataUrl = await blobParaDataUrl(blob);
    return { ok: true, dataUrl, mimeType: blob.type || "image/png" };
  } catch (err) {
    return {
      ok: false,
      erro: err && err.message ? err.message : String(err)
    };
  }
}

function blobParaDataUrl(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

/* ------------------------------------------------------------------ */
/* Utilitarios                                                        */
/* ------------------------------------------------------------------ */

async function fetchComTempo(url, opcoes, ms) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    return await fetch(url, { ...opcoes, signal: ctrl.signal });
  } catch (err) {
    if (err && err.name === "AbortError") {
      throw new Error("Tempo limite esgotado ao contactar o servico.");
    }
    throw err;
  } finally {
    clearTimeout(timer);
  }
}
