/**
 * content.js — Motor de injecao visual mobile (Firefox Android / GeckoView)
 *
 * - Aguarda o comando TRADUZIR_IMAGEM vindo do service worker.
 * - Localiza o <img> correspondente ao srcUrl.
 * - enviaParaAPI() faz a ponte assincrona com o background (que possui
 *   privilegios de rede e dribla CSP/CORS de content scripts).
 * - Cria um botao flutuante (FAB) como gatilho touch alternativo.
 * - Sobrepõe um <div> absoluto sobre a imagem com o texto traduzido,
 *   usando getBoundingClientRect() e CSS responsivo para telas moveis.
 */

"use strict";

if (window.__otarductorInjetado) {
  // Evita duplicacao apos reinjecao programatica (scripting.executeScript).
} else {
  window.__otarductorInjetado = true;
  inicializar();
}

function inicializar() {
  const ESTADO = {
    overlay: null,
    fab: null,
    fabAlvo: null,
    processando: false,
    pointerAlvo: null
  };

  /* ---------------------------------------------------------------- */
  /* Escuta de comandos do service worker                             */
  /* ---------------------------------------------------------------- */

  browser.runtime.onMessage.addListener((msg) => {
    if (!msg) return;
    if (msg.command === "TRADUZIR_IMAGEM") {
      esconderFab(ESTADO);
      tratarImagem(ESTADO, msg.srcUrl, null);
    }
  });

  /* ---------------------------------------------------------------- */
  /* Botao flutuante touch (gatilho alternativo ao toque longo)       */
  /* ---------------------------------------------------------------- */

  document.addEventListener("pointerdown", (e) => {
    const img = e.target && e.target.closest && e.target.closest("img");
    if (img) {
      ESTADO.pointerAlvo = img;
    } else if (
      ESTADO.fab &&
      e.target !== ESTADO.fab &&
      !ESTADO.fab.contains(e.target) &&
      !(ESTADO.overlay && ESTADO.overlay.contains(e.target))
    ) {
      esconderFab(ESTADO);
    }
  }, true);

  document.addEventListener("pointerup", () => {
    if (ESTADO.pointerAlvo) {
      mostrarFab(ESTADO, ESTADO.pointerAlvo);
      ESTADO.pointerAlvo = null;
    }
  }, true);

  window.addEventListener("scroll", () => {
    if (ESTADO.overlay) removerOverlay(ESTADO);
    if (ESTADO.fab) esconderFab(ESTADO);
  }, true);

  window.addEventListener("resize", () => {
    if (ESTADO.overlay) removerOverlay(ESTADO);
    if (ESTADO.fab) esconderFab(ESTADO);
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      removerOverlay(ESTADO);
      esconderFab(ESTADO);
    }
  });

  /* ---------------------------------------------------------------- */
  /* Fluxo principal                                                   */
  /* ---------------------------------------------------------------- */

  async function tratarImagem(estado, srcUrl, imgEl) {
    if (estado.processando) return;

    const alvo = imgEl || encontrarImagemPorSrc(srcUrl);
    const urlFinal =
      (alvo && (alvo.currentSrc || alvo.src)) || srcUrl || null;

    if (!alvo) {
      console.warn("[Otarductor] Elemento <img> nao encontrado no DOM.");
      return;
    }
    if (!urlFinal) {
      console.warn("[Otarductor] Imagem sem URL utilizavel.");
      return;
    }

    estado.processando = true;
    mostrarCarregando(estado, alvo);

    try {
      const opcoes = await carregarOpcoes();

      // Tenta capturar os bytes da imagem no contexto do navegador (que ja
      // possui cookies e Referer da sessao), contornando hotlink protection.
      let imagemCapturada = null;
      try {
        imagemCapturada = await capturarImagem(alvo, urlFinal);
      } catch (capErr) {
        console.warn("[Otarductor] Captura local falhou:", capErr);
      }

      const resultado = await enviarParaAPI(
        urlFinal,
        opcoes,
        imagemCapturada
      );
      mostrarOverlay(estado, alvo, resultado.traduzido, resultado.original);
    } catch (err) {
      const mensagem = err && err.message ? err.message : String(err);
      console.error("[Otarductor] Falha:", mensagem);
      mostrarOverlay(
        estado,
        alvo,
        "Nao foi possivel traduzir esta imagem.\n" + mensagem,
        null,
        true
      );
    } finally {
      estado.processando = false;
    }
  }

  /* ---------------------------------------------------------------- */
  /* Captura anti-hotlink                                             */
  /* ---------------------------------------------------------------- */

  /**
   * Retorna { dataUrl, mimeType } com os bytes da imagem, ou null se nenhuma
   * estrategia local funcionar (nesse caso o worker usara a URL remota).
   *
   * Estrategias, em ordem de confianca:
   *  1. Canvas a partir do <img> ja carregado (reaproveita pixels em tela).
   *  2. cloneNode do <img> com crossOrigin="anonymous" + canvas (tenta obter
   *     um canvas nao-contaminado quando o servidor envia CORS).
   *  3. fetch() do content script com credentials:"include" (reusa cookies).
   *  4. fetch() via background (privilegios de extensao, cookies do browser).
   */
  async function capturarImagem(imgEl, url) {
    if (!url) return null;

    // 1 e 2: canvas
    const viaCanvas = await tentarCanvas(imgEl, url);
    if (viaCanvas) return viaCanvas;

    // 3: fetch com credenciais no contexto da pagina
    const viaFetchPagina = await tentarFetchPagina(url);
    if (viaFetchPagina) return viaFetchPagina;

    // 4: fetch via background
    const viaFetchWorker = await tentarFetchWorker(url);
    if (viaFetchWorker) return viaFetchWorker;

    return null;
  }

  async function tentarCanvas(imgEl, url) {
    const largura =
      imgEl.naturalWidth || imgEl.width ||
      (imgEl.getBoundingClientRect && imgEl.getBoundingClientRect().width) || 0;
    const altura =
      imgEl.naturalHeight || imgEl.height ||
      (imgEl.getBoundingClientRect && imgEl.getBoundingClientRect().height) || 0;

    if (largura < 4 || altura < 4) return null;

    // Tenta primeiro com o elemento original (canvas pode ficar contaminado,
    // mas os bytes ainda sao extraiveis via toDataURL antes da excecao...
    // na verdade toDataURL lanca em canvas contaminado, por isso o try).
    const desenhos = [
      () => desenharEmCanvas(imgEl, largura, altura),
      () => desenharCloneCORS(url, largura, altura)
    ];

    for (const desenhar of desenhos) {
      try {
        const canvas = await desenhar();
        if (!canvas) continue;
        const mimeType = detectarMime(url, "image/png");
        const dataUrl = canvas.toDataURL(mimeType, 0.92);
        if (dataUrl && dataUrl.length > 100) {
          return { dataUrl, mimeType };
        }
      } catch (err) {
        // Canvas contaminado (CORS) — tenta a proxima estrategia.
        continue;
      }
    }
    return null;
  }

  function desenharEmCanvas(imgEl, largura, altura) {
    return new Promise((resolve) => {
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(largura);
      canvas.height = Math.round(altura);
      const ctx = canvas.getContext("2d");
      if (!ctx) return resolve(null);
      try {
        ctx.drawImage(imgEl, 0, 0, canvas.width, canvas.height);
        // Forca a deteccao de contaminacao:
        ctx.getImageData(0, 0, 1, 1);
        resolve(canvas);
      } catch (_) {
        resolve(null);
      }
    });
  }

  function desenharCloneCORS(url, largura, altura) {
    return new Promise((resolve) => {
      const img = new Image();
      img.crossOrigin = "anonymous";
      img.decoding = "async";
      let timer = setTimeout(() => {
        img.onload = img.onerror = null;
        resolve(null);
      }, 15000);

      img.onload = () => {
        clearTimeout(timer);
        try {
          const canvas = document.createElement("canvas");
          canvas.width = Math.round(largura);
          canvas.height = Math.round(altura);
          const ctx = canvas.getContext("2d");
          if (!ctx) return resolve(null);
          ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
          ctx.getImageData(0, 0, 1, 1);
          resolve(canvas);
        } catch (_) {
          resolve(null);
        }
      };
      img.onerror = () => {
        clearTimeout(timer);
        resolve(null);
      };
      img.src = url;
    });
  }

  async function tentarFetchPagina(url) {
    if (url.startsWith("data:") || url.startsWith("blob:")) {
      return blobParaDataUrl(await fetchComTempo(url, {}, 30000).then((r) => {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.blob();
      }));
    }
    try {
      const resp = await fetchComTempo(
        url,
        { credentials: "include", mode: "cors" },
        30000
      );
      if (!resp.ok) return null;
      const blob = await resp.blob();
      if (!blob || blob.size === 0) return null;
      return blobParaDataUrl(blob);
    } catch (_) {
      return null;
    }
  }

  async function tentarFetchWorker(url) {
    try {
      const resp = await browser.runtime.sendMessage({
        type: "BAIXAR_IMAGEM",
        url
      });
      if (resp && resp.ok && resp.dataUrl) {
        return { dataUrl: resp.dataUrl, mimeType: resp.mimeType || "image/png" };
      }
    } catch (_) {
      /* segue para o fallback de URL */
    }
    return null;
  }

  function blobParaDataUrl(blob) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve({
        dataUrl: reader.result,
        mimeType: blob.type || "image/png"
      });
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(blob);
    });
  }

  function detectarMime(url, padrao) {
    const limpa = (url || "").split("?")[0].split("#")[0].toLowerCase();
    if (limpa.endsWith(".jpg") || limpa.endsWith(".jpeg")) return "image/jpeg";
    if (limpa.endsWith(".png")) return "image/png";
    if (limpa.endsWith(".webp")) return "image/webp";
    if (limpa.endsWith(".gif")) return "image/gif";
    if (limpa.startsWith("data:")) {
      const m = /^data:([^;,]+)/.exec(url);
      if (m) return m[1];
    }
    return padrao;
  }

  async function fetchComTempo(url, opcoes, ms) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), ms);
    try {
      return await fetch(url, { ...opcoes, signal: ctrl.signal });
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Ponte assincrona com o service worker. O fetch real ocorre em
   * background.js, que possui host_permissions e nao esta sujeito a CSP
   * da pagina. Retorna { original, traduzido }.
   */
  async function enviarParaAPI(imgUrl, opcoes, imagemCapturada) {
    let resposta;
    try {
      resposta = await browser.runtime.sendMessage({
        type: "PROCESS_IMAGE",
        imgUrl,
        opcoes,
        // { dataUrl, mimeType } ou null. Quando presente, o worker envia o
        // arquivo diretamente ao OCR, evitando que o servidor baixe a URL.
        imagem: imagemCapturada || null
      });
    } catch (err) {
      throw new Error(
        "Falha de comunicacao com o extensao: " +
          (err && err.message ? err.message : String(err))
      );
    }

    if (!resposta || typeof resposta !== "object") {
      throw new Error("Nenhuma resposta do motor de OCR/traducao.");
    }
    if (!resposta.ok) {
      throw new Error(resposta.erro || "Erro desconhecido no processamento.");
    }
    return {
      original: resposta.original || "",
      traduzido: resposta.traduzido || ""
    };
  }

  async function carregarOpcoes() {
    const padrao = {
      idiomaOCR: "eng",
      idiomaOrigem: "en",
      idiomaDestino: "pt"
    };
    try {
      const salvo = await browser.storage.local.get(padrao);
      return { ...padrao, ...salvo };
    } catch (err) {
      console.warn("[Otarductor] Usando opcoes padrao:", err);
      return padrao;
    }
  }

  /* ---------------------------------------------------------------- */
  /* Localizacao do <img>                                             */
  /* ---------------------------------------------------------------- */

  function encontrarImagemPorSrc(srcUrl) {
    if (!srcUrl) return null;
    const imgs = document.querySelectorAll("img");
    for (const img of imgs) {
      if (img.currentSrc === srcUrl || img.src === srcUrl) return img;
    }
    // Fallback: compara o final do caminho (cobre URLs relativas/absolutas).
    let alvo = srcUrl.split("#")[0].split("?")[0];
    try {
      alvo = decodeURIComponent(alvo);
    } catch (_) {
      /* ignora URIs malformadas */
    }
    const parte = alvo.substring(alvo.lastIndexOf("/") + 1);
    if (!parte) return null;
    for (const img of imgs) {
      let cand = (img.currentSrc || img.src || "").split("#")[0].split("?")[0];
      try {
        cand = decodeURIComponent(cand);
      } catch (_) {
        /* ignora */
      }
      if (cand.endsWith(parte)) return img;
    }
    return null;
  }

  /* ---------------------------------------------------------------- */
  /* Overlay responsivo sobre a imagem                                */
  /* ---------------------------------------------------------------- */

  function construirSobreposicao(estado, imgEl, conteudo, isErro) {
    removerOverlay(estado);

    const rect = imgEl.getBoundingClientRect();
    const overlay = document.createElement("div");
    overlay.className = "otarductor-overlay";
    overlay.setAttribute("role", "dialog");
    overlay.setAttribute("aria-modal", "true");
    overlay.setAttribute("aria-label", "Traducao da imagem");

    // Posicionamento fixo baseado em getBoundingClientRect().
    const left = Math.max(0, rect.left);
    const top = Math.max(0, rect.top);
    const width = Math.max(rect.width, 120);
    const height = Math.max(rect.height, 60);

    Object.assign(overlay.style, {
      position: "fixed",
      left: left + "px",
      top: top + "px",
      width: width + "px",
      minHeight: height + "px",
      maxHeight: "85vh",
      overflowY: "auto",
      margin: "0",
      padding: "14px",
      boxSizing: "border-box",
      background: isErro
        ? "rgba(90, 12, 12, 0.86)"
        : "rgba(8, 10, 18, 0.82)",
      color: "#ffffff",
      zIndex: "2147483647",
      display: "flex",
      flexDirection: "column",
      alignItems: "center",
      justifyContent: "center",
      textAlign: "center",
      fontFamily:
        "system-ui, -apple-system, 'Roboto', 'Segoe UI', sans-serif",
      fontSize: "clamp(13px, 3.6vw, 18px)",
      lineHeight: "1.45",
      letterSpacing: "0.1px",
      textShadow: "0 1px 3px rgba(0,0,0,0.7)",
      borderRadius: "8px",
      boxShadow:
        "0 8px 28px rgba(0,0,0,0.45), inset 0 0 0 1px rgba(255,255,255,0.12)",
      cursor: "pointer",
      WebkitTapHighlightColor: "transparent",
      touchAction: "manipulation",
      wordBreak: "break-word",
      overflowWrap: "anywhere"
    });

    const texto = document.createElement("div");
    texto.className = "otarductor-texto";
    texto.textContent = conteudo;
    overlay.appendChild(texto);

    const dica = document.createElement("div");
    dica.className = "otarductor-dica";
    dica.textContent = isErro ? "Toque para fechar" : "Toque para fechar";
    overlay.appendChild(dica);

    overlay.addEventListener(
      "click",
      () => removerOverlay(estado),
      true
    );

    document.documentElement.appendChild(overlay);
    estado.overlay = overlay;
    return overlay;
  }

  function mostrarOverlay(estado, imgEl, texto, _original, isErro) {
    return construirSobreposicao(estado, imgEl, texto, !!isErro);
  }

  function mostrarCarregando(estado, imgEl) {
    const overlay = construirSobreposicao(
      estado,
      imgEl,
      "Processando imagem...",
      false
    );
    const spinner = document.createElement("div");
    spinner.className = "otarductor-spinner";
    spinner.setAttribute("aria-hidden", "true");
    overlay.insertBefore(spinner, overlay.firstChild);
  }

  function removerOverlay(estado) {
    if (estado.overlay && estado.overlay.parentNode) {
      estado.overlay.parentNode.removeChild(estado.overlay);
    }
    estado.overlay = null;
  }

  /* ---------------------------------------------------------------- */
  /* Botao flutuante (FAB)                                            */
  /* ---------------------------------------------------------------- */

  function criarFab(estado) {
    const fab = document.createElement("button");
    fab.type = "button";
    fab.className = "otarductor-fab";
    fab.textContent = "Traduzir";
    fab.setAttribute("aria-label", "Traduzir texto desta imagem");

    Object.assign(fab.style, {
      position: "fixed",
      display: "none",
      zIndex: "2147483646",
      padding: "8px 14px",
      margin: "0",
      border: "none",
      borderRadius: "999px",
      background: "linear-gradient(135deg, #2d7ff9, #1357c6)",
      color: "#fff",
      fontFamily:
        "system-ui, -apple-system, 'Roboto', 'Segoe UI', sans-serif",
      fontSize: "13px",
      fontWeight: "600",
      lineHeight: "1.2",
      boxShadow: "0 4px 14px rgba(0,0,0,0.35)",
      cursor: "pointer",
      WebkitTapHighlightColor: "transparent",
      touchAction: "manipulation",
      userSelect: "none"
    });

    fab.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const img = estado.fabAlvo;
      esconderFab(estado);
      if (img) {
        tratarImagem(estado, img.currentSrc || img.src, img);
      }
    });

    document.documentElement.appendChild(fab);
    estado.fab = fab;
    return fab;
  }

  function mostrarFab(estado, imgEl) {
    if (!imgEl || !imgEl.getBoundingClientRect) return;
    const fab = estado.fab || criarFab(estado);
    const rect = imgEl.getBoundingClientRect();
    const largura = 110;
    const margem = 8;
    const left = Math.min(
      Math.max(margem, rect.right - largura - margem),
      window.innerWidth - largura - margem
    );
    const top = Math.max(margem, rect.top + margem);

    fab.style.left = left + "px";
    fab.style.top = top + "px";
    fab.style.display = "inline-flex";
    estado.fabAlvo = imgEl;
  }

  function esconderFab(estado) {
    if (estado.fab) estado.fab.style.display = "none";
    estado.fabAlvo = null;
  }
}
