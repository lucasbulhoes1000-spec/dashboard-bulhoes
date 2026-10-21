// ============================================================
// whatsapp-webhook — recebe os avisos da Meta (WhatsApp Cloud API)
// CRM Bulhões, 21/10/2026
//
// • GET: verificação do webhook (a Meta confere o WA_VERIFY_TOKEN).
// • POST: confere a assinatura da Meta (X-Hub-Signature-256 com o segredo do
//   app), guarda o aviso bruto, entrega ao banco (wa_processar) e responde 200.
//   Fotos, áudios e documentos são baixados em segundo plano para a pasta
//   privada "whatsapp-midia".
//
// Segredos (Supabase → Edge Functions → Secrets):
//   WA_TOKEN         chave permanente do usuário do sistema (crmmaluco)
//   WA_APP_SECRET    "Chave secreta do app" (app Bulhões CRM → Configurações → Básico)
//   WA_VERIFY_TOKEN  frase combinada com a Meta na configuração do webhook
//
// Na Supabase, esta função precisa da opção "Verify JWT" DESLIGADA
// (a Meta não manda login da Supabase; quem protege é a assinatura).
// ============================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WA_TOKEN = Deno.env.get("WA_TOKEN") ?? "";
const WA_APP_SECRET = Deno.env.get("WA_APP_SECRET") ?? "";
const WA_VERIFY_TOKEN = Deno.env.get("WA_VERIFY_TOKEN") ?? "";
const GRAPH = "https://graph.facebook.com/" + (Deno.env.get("WA_GRAPH_VERSION") ?? "v23.0");

const enc = new TextEncoder();

function hex(buf: ArrayBuffer): string {
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function iguais(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

export async function assinaturaValida(corpo: string, cabecalho: string | null, segredo = WA_APP_SECRET): Promise<boolean> {
  if (!segredo || !cabecalho || !cabecalho.startsWith("sha256=")) return false;
  const chave = await crypto.subtle.importKey("raw", enc.encode(segredo), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const esperado = hex(await crypto.subtle.sign("HMAC", chave, enc.encode(corpo)));
  return iguais(esperado, cabecalho.slice(7).toLowerCase());
}

function banco(caminho: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers ?? {});
  headers.set("apikey", SERVICE_KEY);
  headers.set("Authorization", "Bearer " + SERVICE_KEY);
  if (!headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  return fetch(SUPABASE_URL + caminho, { ...init, headers });
}

const EXTENSOES: Record<string, string> = {
  "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "audio/ogg": "ogg", "audio/mpeg": "mp3",
  "audio/mp4": "m4a", "audio/aac": "aac", "video/mp4": "mp4", "video/3gpp": "3gp", "application/pdf": "pdf",
};

type Midia = { mensagem_id: string; conversa_id: string; midia_id: string; mime?: string; nome?: string };

// Números conectados pelo celular têm chave própria
const _tokens = new Map<string, string>();
async function tokenDaConversa(conversaId: string): Promise<string> {
  if (_tokens.has(conversaId)) return _tokens.get(conversaId)!;
  let t = WA_TOKEN;
  try {
    const c = await (await banco(`/rest/v1/conversas?id=eq.${conversaId}&select=numero_clinica_id`)).json();
    const n = c?.[0]?.numero_clinica_id;
    if (n) {
      const r = await (await banco(`/rest/v1/whatsapp_numeros?phone_number_id=eq.${encodeURIComponent(n)}&select=token`)).json();
      if (Array.isArray(r) && r[0]?.token) t = r[0].token;
    }
  } catch (_) { /* usa a chave padrão */ }
  _tokens.set(conversaId, t);
  return t;
}

export async function baixarMidia(m: Midia): Promise<void> {
  try {
    const tk = await tokenDaConversa(m.conversa_id);
    const info = await fetch(`${GRAPH}/${m.midia_id}`, { headers: { Authorization: "Bearer " + tk } });
    if (!info.ok) throw new Error("Meta (dados da mídia) " + info.status + " " + (await info.text()).slice(0, 200));
    const dados = await info.json();
    const arquivo = await fetch(dados.url, { headers: { Authorization: "Bearer " + tk } });
    if (!arquivo.ok) throw new Error("Meta (download) " + arquivo.status);
    const mime = (dados.mime_type || m.mime || "application/octet-stream").split(";")[0].trim();
    const ext = EXTENSOES[mime] ?? (m.nome?.split(".").pop() || "bin");
    const caminho = `${m.conversa_id}/${m.mensagem_id}.${ext}`;
    const up = await banco(`/storage/v1/object/whatsapp-midia/${caminho}`, {
      method: "POST",
      headers: { "Content-Type": mime, "x-upsert": "true" },
      body: await arquivo.arrayBuffer(),
    });
    if (!up.ok) throw new Error("Storage " + up.status + " " + (await up.text()).slice(0, 200));
    await banco(`/rest/v1/mensagens?id=eq.${m.mensagem_id}`, {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ midia_caminho: caminho, midia_tipo: mime, atualizada_em: new Date().toISOString() }),
    });
  } catch (e) {
    console.error("[whatsapp-webhook] mídia", m.midia_id, String(e));
    await banco(`/rest/v1/mensagens?id=eq.${m.mensagem_id}`, {
      method: "PATCH",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ erro: "Não foi possível baixar a mídia: " + String(e).slice(0, 200) }),
    }).catch(() => {});
  }
}

function emSegundoPlano(p: Promise<unknown>) {
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt && typeof rt.waitUntil === "function") rt.waitUntil(p);
  else p.catch(() => {});
}

export async function handler(req: Request): Promise<Response> {
  const url = new URL(req.url);

  if (req.method === "GET") {
    const ok = url.searchParams.get("hub.mode") === "subscribe" && WA_VERIFY_TOKEN !== "" &&
      url.searchParams.get("hub.verify_token") === WA_VERIFY_TOKEN;
    return ok ? new Response(url.searchParams.get("hub.challenge") ?? "", { status: 200 })
              : new Response("verificação recusada", { status: 403 });
  }
  if (req.method !== "POST") return new Response("método não permitido", { status: 405 });

  const corpoTexto = await req.text();
  if (!(await assinaturaValida(corpoTexto, req.headers.get("x-hub-signature-256")))) {
    console.warn("[whatsapp-webhook] assinatura inválida — aviso ignorado");
    return new Response("assinatura inválida", { status: 401 });
  }

  let corpo: unknown;
  try { corpo = JSON.parse(corpoTexto); } catch { return new Response("json inválido", { status: 400 }); }

  // guarda o aviso bruto (ajuda a investigar qualquer problema)
  await banco("/rest/v1/whatsapp_eventos_brutos", {
    method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ corpo }),
  }).catch((e) => console.error("[whatsapp-webhook] bruto", String(e)));

  const r = await banco("/rest/v1/rpc/wa_processar", { method: "POST", body: JSON.stringify({ corpo }) });
  if (!r.ok) {
    const erro = (await r.text()).slice(0, 500);
    console.error("[whatsapp-webhook] banco", r.status, erro);
    // 500 faz a Meta tentar de novo mais tarde (nada se perde)
    return new Response("erro ao gravar", { status: 500 });
  }
  const resultado = await r.json();
  const midias: Midia[] = Array.isArray(resultado?.midias) ? resultado.midias : [];
  if (midias.length) emSegundoPlano(Promise.allSettled(midias.map(baixarMidia)));

  return new Response("ok", { status: 200 });
}

if (!Deno.env.get("WA_TESTE")) Deno.serve(handler);
