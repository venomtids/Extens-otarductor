/**
 * options.js — Persistencia de preferencias em browser.storage.local
 */

"use strict";

const PADRAO = Object.freeze({
  idiomaOCR: "eng",
  idiomaOrigem: "en",
  idiomaDestino: "pt"
});

const els = {
  form: document.getElementById("form-opcoes"),
  idiomaOCR: document.getElementById("idioma-ocr"),
  idiomaOrigem: document.getElementById("idioma-origem"),
  idiomaDestino: document.getElementById("idioma-destino"),
  restaurar: document.getElementById("restaurar"),
  status: document.getElementById("status")
};

/* ------------------------------------------------------------------ */
/* Carregamento                                                       */
/* ------------------------------------------------------------------ */

async function carregar() {
  let valores = { ...PADRAO };
  try {
    const salvo = await browser.storage.local.get(PADRAO);
    valores = { ...PADRAO, ...salvo };
  } catch (err) {
    mostrarStatus("Nao foi possivel ler as preferencias: " + err.message, true);
  }
  preencher(valores);
}

function preencher(valores) {
  selecionar(els.idiomaOCR, valores.idiomaOCR, PADRAO.idiomaOCR);
  selecionar(els.idiomaOrigem, valores.idiomaOrigem, PADRAO.idiomaOrigem);
  selecionar(els.idiomaDestino, valores.idiomaDestino, PADRAO.idiomaDestino);
}

function selecionar(select, valor, padrao) {
  const alvo = valor || padrao;
  const opcao = Array.from(select.options).find((o) => o.value === alvo);
  select.value = opcao ? alvo : padrao;
}

/* ------------------------------------------------------------------ */
/* Salvamento                                                         */
/* ------------------------------------------------------------------ */

async function salvar(event) {
  if (event) event.preventDefault();

  const valores = {
    idiomaOCR: els.idiomaOCR.value,
    idiomaOrigem: els.idiomaOrigem.value,
    idiomaDestino: els.idiomaDestino.value
  };

  try {
    await browser.storage.local.set(valores);
    mostrarStatus("Preferencias salvas.");
  } catch (err) {
    mostrarStatus("Falha ao salvar: " + err.message, true);
  }
}

function restaurar() {
  preencher(PADRAO);
  browser.storage.local
    .set({ ...PADRAO })
    .then(() => mostrarStatus("Preferencias restauradas."))
    .catch((err) =>
      mostrarStatus("Falha ao restaurar: " + err.message, true)
    );
}

/* ------------------------------------------------------------------ */
/* Utilitarios                                                        */
/* ------------------------------------------------------------------ */

let timerStatus = null;
function mostrarStatus(texto, isErro) {
  els.status.textContent = texto;
  els.status.classList.toggle("erro", !!isErro);
  if (timerStatus) clearTimeout(timerStatus);
  timerStatus = setTimeout(() => {
    els.status.textContent = "";
    els.status.classList.remove("erro");
  }, 3500);
}

/* ------------------------------------------------------------------ */
/* Eventos                                                            */
/* ------------------------------------------------------------------ */

els.form.addEventListener("submit", salvar);
els.restaurar.addEventListener("click", restaurar);

document.addEventListener("DOMContentLoaded", carregar);
