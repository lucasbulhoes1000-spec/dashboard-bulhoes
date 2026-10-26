// @ts-nocheck
// ============================================================
// crm-rotinas — rotinas que rodavam no Apps Script, agora na Supabase
// 25/10/2026
//
// O miolo (abaixo de "CÓDIGO DO APPS SCRIPT") é o código original do Apps
// Script, gerado automaticamente a partir dele, com três adaptações:
//   1. chamadas externas esperam a resposta (await);
//   2. datas "meia-noite" no fuso de Brasília (o Apps Script roda no fuso da clínica);
//   3. gravações no CRM da clínica viram patch (só os clientes alterados) pela
//      mesma mesclagem segura da equipe (crm_salvar_patch), em vez de regravar
//      o CRM inteiro — assim uma rotina nunca apaga edição feita ao mesmo tempo.
// Modo "simular": nada é gravado; devolve o que seria gravado.
// ============================================================
const SB_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const CRM_KEY = "bulhoes-clinica-crm";
let SIMULAR = false;
let ESCRITAS = [];
let CRM_LIDO = null;

class Resp { constructor(s, t) { this.s = s; this.t = t; } getResponseCode() { return this.s; } getContentText() { return this.t; } }
function diffCRM(base, local) {
  const m = {}; const tem = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  for (const k of new Set([...Object.keys(base), ...Object.keys(local)])) {
    const tb = tem(base, k), tl = tem(local, k);
    if (tb && tl && JSON.stringify(base[k]) === JSON.stringify(local[k])) continue;
    m[k] = { temBase: tb, temLocal: tl, base: tb ? base[k] : null, local: tl ? local[k] : null };
  }
  return m;
}
async function gravarCRMPorPatch(novoTxt) {
  const base = CRM_LIDO ? JSON.parse(CRM_LIDO) : {};
  const local = JSON.parse(novoTxt);
  const mudancas = diffCRM(base, local);
  const n = Object.keys(mudancas).length;
  ESCRITAS.push({ tipo: "crm", clientes: n, chaves: Object.keys(mudancas).slice(0, 200), mudancas: SIMULAR ? mudancas : undefined });
  if (SIMULAR || !n) return new Resp(204, "");
  const r = await fetch(SB_URL + "/rest/v1/rpc/crm_salvar_patch", {
    method: "POST", headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + SERVICE_KEY, "Content-Type": "application/json" },
    body: JSON.stringify({ p_mudancas: mudancas }),
  });
  const t = await r.text();
  if (!r.ok) return new Resp(r.status, t);
  const j = JSON.parse(t);
  if (j.status !== "ok") return new Resp(500, t);
  CRM_LIDO = null;
  return new Resp(204, "");
}
const UrlFetchApp = {
  async fetch(url, o = {}) {
    const metodo = String(o.method || "get").toUpperCase();
    const ehBanco = String(url).indexOf(SB_URL + "/rest/v1/") === 0;
    if (ehBanco && metodo !== "GET") {
      let corpo = null; try { corpo = o.payload ? JSON.parse(o.payload) : null; } catch (_e) { /* */ }
      if (String(url).indexOf("crm_sessions") !== -1 && String(url).indexOf(encodeURIComponent(CRM_KEY)) !== -1 && corpo && corpo.crm_json !== undefined) {
        return await gravarCRMPorPatch(corpo.crm_json);
      }
      if (String(url).indexOf("crm_sessions") !== -1 && corpo && corpo.email_clinica === CRM_KEY && corpo.crm_json !== undefined) {
        return await gravarCRMPorPatch(corpo.crm_json);
      }
      if (SIMULAR) { ESCRITAS.push({ tipo: "banco", metodo, url: String(url).replace(SB_URL, "").slice(0, 160) }); return new Resp(204, ""); }
    }
    const h = Object.assign({}, o.headers || {});
    if (o.contentType) h["Content-Type"] = o.contentType;
    const r = await fetch(url, { method: metodo, headers: h, body: metodo === "GET" ? undefined : o.payload });
    const t = await r.text();
    if (ehBanco && metodo === "GET" && String(url).indexOf("crm_sessions") !== -1 && String(url).indexOf(encodeURIComponent(CRM_KEY)) !== -1 && r.ok) {
      try { const j = JSON.parse(t); if (j && j[0] && typeof j[0].crm_json === "string") CRM_LIDO = j[0].crm_json; } catch (_e) { /* */ }
    }
    if (!o.muteHttpExceptions && r.status >= 400) throw new Error("Request failed for " + String(url).split("?")[0] + " returned code " + r.status + ". " + t.slice(0, 200));
    return new Resp(r.status, t);
  },
  async fetchAll(reqs) { return Promise.all(reqs.map((q) => UrlFetchApp.fetch(q.url, q))); },
};
const PropertiesService = { getScriptProperties() { return { getProperty(k) { return k === "SUPABASE_SERVICE_KEY" ? SERVICE_KEY : (Deno.env.get(k) ?? null); } }; } };
const Session = { getScriptTimeZone() { return "America/Sao_Paulo"; } };
const Utilities = {
  base64Encode(s) { return btoa(unescape(encodeURIComponent(String(s)))); },
  formatDate(d, tz, fmt) {
    const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: tz || "America/Sao_Paulo", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" }).formatToParts(d).map((x) => [x.type, x.value]));
    return String(fmt).replace("yyyy", p.year).replace("MM", p.month).replace("dd", p.day).replace("HH", p.hour).replace("mm", p.minute).replace("ss", p.second);
  },
  sleep(ms) { /* sem espera */ },
};
const ContentService = { MimeType: { JSON: "json" }, createTextOutput(t) { return { t, setMimeType() { return this; }, getContent() { return this.t; } }; } };
const LockService = { getScriptLock() { return { tryLock() { return true; }, waitLock() {}, releaseLock() {} }; } };
const Logger = { log(...a) { console.log(...a); } };

// ===================== CÓDIGO DO APPS SCRIPT =====================
