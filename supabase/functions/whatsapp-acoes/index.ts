// ============================================================
// whatsapp-acoes — o que o CRM faz no WhatsApp em nome da equipe
// CRM Bulhões, 21/10/2026
//
// Ações (POST JSON { acao, ... }), só para quem está logado no CRM e é da
// equipe com papel gestão, avaliação ou comercial:
//   enviar_texto   { conversa_id | telefone, texto }
//   enviar_modelo  { conversa_id | telefone, nome, idioma, variaveis: [] }
//   modelos        {}  → modelos aprovados da conta
//   marcar_lida    { conversa_id } → avisa a Meta (dois tiques azuis) e zera não lidas
//
// Regra da Meta: texto livre só até 24 h depois da última mensagem do paciente
// (ou na janela grátis de anúncio). Fora disso, só modelo aprovado.
//
// Segredos: WA_TOKEN, WA_PHONE_NUMBER_ID (número da clínica), WA_WABA_ID.
// "Verify JWT" pode ficar LIGADO nesta função.
// ============================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WA_TOKEN = Deno.env.get("WA_TOKEN") ?? "";
const WA_PHONE_NUMBER_ID = Deno.env.get("WA_PHONE_NUMBER_ID") ?? "";
const WA_WABA_ID = Deno.env.get("WA_WABA_ID") ?? "";
const GRAPH = "https://graph.facebook.com/" + (Deno.env.get("WA_GRAPH_VERSION") ?? "v23.0");
const ORIGENS = (Deno.env.get("CRM_ORIGENS") ?? "https://dashboard-bulhoes.vercel.app").split(",").map((s) => s.trim());

const PAPEIS_ATENDIMENTO = ["gestao", "avaliacao", "comercial"];
const JANELA_MS = 24 * 60 * 60 * 1000;

function cors(req: Request): Record<string, string> {
  const origem = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGENS.includes(origem) ? origem : ORIGENS[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function resposta(req: Request, corpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(corpo), { status, headers: { ...cors(req), "Content-Type": "application/json" } });
}

function banco(caminho: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers ?? {});
  headers.set("apikey", SERVICE_KEY);
  headers.set("Authorization", "Bearer " + SERVICE_KEY);
  if (!headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  return fetch(SUPABASE_URL + caminho, { ...init, headers });
}

async function bancoJson(caminho: string, init: RequestInit = {}) {
  const r = await banco(caminho, init);
  const t = await r.text();
  if (!r.ok) throw new Error(`banco ${r.status}: ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}

async function meta(caminho: string, corpo?: unknown) {
  const r = await fetch(GRAPH + caminho, {
    method: corpo === undefined ? "GET" : "POST",
    headers: { Authorization: "Bearer " + WA_TOKEN, "Content-Type": "application/json" },
    body: corpo === undefined ? undefined : JSON.stringify(corpo),
  });
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, j };
}

function erroMeta(j: any): string {
  const e = j?.error ?? {};
  return [e.message, e.error_data?.details].filter(Boolean).join(" — ") || "erro desconhecido da Meta";
}

// Quem está pedindo: login da Supabase + papel na tabela equipe
async function usuario(req: Request): Promise<{ email: string; papel: string } | null> {
  const auth = req.headers.get("authorization") ?? "";
  if (!auth.toLowerCase().startsWith("bearer ")) return null;
  const r = await fetch(SUPABASE_URL + "/auth/v1/user", { headers: { apikey: SERVICE_KEY, Authorization: auth } });
  if (!r.ok) return null;
  const email = String((await r.json())?.email ?? "").toLowerCase();
  if (!email) return null;
  const eq = await bancoJson(`/rest/v1/equipe?email=eq.${encodeURIComponent(email)}&ativo=is.true&select=papel`);
  const papel = eq?.[0]?.papel;
  return papel ? { email, papel } : null;
}

async function conversa(dados: any) {
  let id = dados.conversa_id;
  if (!id && dados.telefone) {
    const tel = String(dados.telefone).replace(/\D/g, "");
    id = await bancoJson("/rest/v1/rpc/wa_conversa", {
      method: "POST",
      body: JSON.stringify({ p_numero: WA_PHONE_NUMBER_ID, p_wa_id: tel.startsWith("55") ? tel : "55" + tel }),
    });
  }
  if (!id) throw new Error("informe conversa_id ou telefone");
  const c = await bancoJson(`/rest/v1/conversas?id=eq.${id}&select=*`);
  if (!c?.[0]) throw new Error("conversa não encontrada");
  return c[0];
}

export function janelaAberta(c: { ultima_recebida_em?: string | null; janela_gratis_ate?: string | null }, agora = Date.now()): boolean {
  const ultima = c.ultima_recebida_em ? Date.parse(c.ultima_recebida_em) : 0;
  const gratis = c.janela_gratis_ate ? Date.parse(c.janela_gratis_ate) : 0;
  return agora - ultima < JANELA_MS || gratis > agora;
}

async function registrar(c: any, waId: string | null, tipo: string, texto: string, autor: string, status: string, erro: string | null, bruto: unknown) {
  return await bancoJson("/rest/v1/rpc/wa_registrar_enviada", {
    method: "POST",
    body: JSON.stringify({
      p_conversa: c.id, p_wa_message_id: waId, p_tipo: tipo, p_texto: texto, p_autor: autor,
      p_status: status, p_erro: erro, p_bruto: bruto,
    }),
  });
}

async function enviar(req: Request, quem: { email: string }, c: any, corpoMeta: any, tipo: string, textoRegistro: string) {
  const r = await meta(`/${c.numero_clinica_id}/messages`, { messaging_product: "whatsapp", recipient_type: "individual", to: c.wa_id, ...corpoMeta });
  if (!r.ok) {
    const erro = erroMeta(r.j);
    await registrar(c, null, tipo, textoRegistro, quem.email, "falhou", erro, r.j);
    return resposta(req, { ok: false, erro }, 502);
  }
  const waId = r.j?.messages?.[0]?.id ?? null;
  const id = await registrar(c, waId, tipo, textoRegistro, quem.email, "enviada", null, r.j);
  return resposta(req, { ok: true, mensagem_id: id, wa_message_id: waId });
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return resposta(req, { ok: false, erro: "use POST" }, 405);

  const quem = await usuario(req);
  if (!quem) return resposta(req, { ok: false, erro: "Entre no CRM com sua conta da equipe." }, 401);
  if (!PAPEIS_ATENDIMENTO.includes(quem.papel)) return resposta(req, { ok: false, erro: "Seu acesso não inclui o WhatsApp." }, 403);

  let dados: any;
  try { dados = await req.json(); } catch { return resposta(req, { ok: false, erro: "pedido inválido" }, 400); }

  try {
    switch (dados.acao) {
      case "enviar_texto": {
        const texto = String(dados.texto ?? "").trim();
        if (!texto) return resposta(req, { ok: false, erro: "mensagem vazia" }, 400);
        if (texto.length > 4096) return resposta(req, { ok: false, erro: "mensagem acima de 4.096 caracteres" }, 400);
        const c = await conversa(dados);
        if (!janelaAberta(c)) {
          return resposta(req, { ok: false, erro: "janela_fechada", detalhe: "Passaram mais de 24 h desde a última mensagem do paciente. Use um modelo aprovado." }, 409);
        }
        return await enviar(req, quem, c, { type: "text", text: { body: texto, preview_url: true } }, "text", texto);
      }
      case "enviar_modelo": {
        const nome = String(dados.nome ?? "").trim();
        if (!nome) return resposta(req, { ok: false, erro: "escolha um modelo" }, 400);
        const variaveis: string[] = Array.isArray(dados.variaveis) ? dados.variaveis.map(String) : [];
        const campos: string[] = Array.isArray(dados.campos) ? dados.campos.map(String) : [];
        const nomeado = dados.formato === "NAMED";
        const c = await conversa(dados);
        const template: any = { name: nome, language: { code: String(dados.idioma ?? "pt_BR") } };
        const components: any[] = [];
        // cabeçalho com foto, vídeo ou documento: a Meta exige mandar a mídia junto
        const cab = dados.cabecalho;
        if (cab && ["IMAGE", "VIDEO", "DOCUMENT"].includes(cab.formato) && cab.link) {
          const tipo = String(cab.formato).toLowerCase();
          components.push({ type: "header", parameters: [{ type: tipo, [tipo]: { link: String(cab.link) } }] });
        }
        if (variaveis.length) {
          components.push({
            type: "body",
            parameters: variaveis.map((t, i) => nomeado ? { type: "text", parameter_name: campos[i], text: t } : { type: "text", text: t }),
          });
        }
        if (components.length) template.components = components;
        const registro = String(dados.texto_preview ?? `[modelo ${nome}]`);
        return await enviar(req, quem, c, { type: "template", template }, "template", registro);
      }
      case "modelos": {
        if (!WA_WABA_ID) return resposta(req, { ok: false, erro: "WA_WABA_ID não configurado" }, 500);
        const r = await meta(`/${WA_WABA_ID}/message_templates?status=APPROVED&limit=200&fields=name,language,category,components,parameter_format`);
        if (!r.ok) return resposta(req, { ok: false, erro: erroMeta(r.j) }, 502);
        const modelos = (r.j?.data ?? []).map((t: any) => {
          const comps = t.components ?? [];
          const corpo = comps.find((x: any) => x.type === "BODY")?.text ?? "";
          const cab = comps.find((x: any) => x.type === "HEADER");
          const nomes = [...new Set((corpo.match(/\{\{\s*([a-z0-9_]+)\s*\}\}/gi) ?? []).map((v: string) => v.replace(/[{}\s]/g, "")))];
          return {
            nome: t.name, idioma: t.language, categoria: t.category, texto: corpo,
            formato: t.parameter_format ?? "POSITIONAL",
            campos: nomes, variaveis: nomes.length,
            cabecalho: cab ? { formato: cab.format, texto: cab.text ?? null, exemplo: cab.example?.header_handle?.[0] ?? null } : null,
            rodape: comps.find((x: any) => x.type === "FOOTER")?.text ?? null,
            botoes: (comps.find((x: any) => x.type === "BUTTONS")?.buttons ?? []).map((b: any) => ({ tipo: b.type, texto: b.text, url: b.url ?? null })),
          };
        });
        return resposta(req, { ok: true, modelos });
      }
      case "marcar_lida": {
        const c = await conversa(dados);
        const ult = await bancoJson(`/rest/v1/mensagens?conversa_id=eq.${c.id}&direcao=eq.recebida&select=wa_message_id&order=enviada_em.desc&limit=1`);
        const wamid = ult?.[0]?.wa_message_id;
        if (wamid) await meta(`/${c.numero_clinica_id}/messages`, { messaging_product: "whatsapp", status: "read", message_id: wamid });
        await banco(`/rest/v1/conversas?id=eq.${c.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ nao_lidas: 0 }) });
        return resposta(req, { ok: true });
      }
      case "configurar": {
        // Só gestão: liga o app à conta do WhatsApp e mostra os números (com o ID de cada um).
        if (quem.papel !== "gestao") return resposta(req, { ok: false, erro: "só a gestão configura o WhatsApp" }, 403);
        if (!WA_WABA_ID || !WA_TOKEN) return resposta(req, { ok: false, erro: "faltam os segredos WA_WABA_ID ou WA_TOKEN" }, 500);
        const assinar = await meta(`/${WA_WABA_ID}/subscribed_apps`, {});
        const nums = await meta(`/${WA_WABA_ID}/phone_numbers?fields=id,display_phone_number,verified_name,quality_rating,platform_type,status`);
        const apps = await meta(`/${WA_WABA_ID}/subscribed_apps`);
        return resposta(req, {
          ok: assinar.ok && nums.ok,
          app_assinado: assinar.ok ? true : erroMeta(assinar.j),
          numeros: nums.ok ? nums.j?.data ?? [] : erroMeta(nums.j),
          apps_assinados: apps.ok ? (apps.j?.data ?? []).map((a: any) => a?.whatsapp_business_api_data?.name ?? a?.whatsapp_business_api_data?.id) : erroMeta(apps.j),
          numero_configurado: WA_PHONE_NUMBER_ID || null,
        });
      }
      default:
        return resposta(req, { ok: false, erro: "ação desconhecida" }, 400);
    }
  } catch (e) {
    console.error("[whatsapp-acoes]", dados?.acao, String(e));
    return resposta(req, { ok: false, erro: "Erro interno: " + String(e).slice(0, 200) }, 500);
  }
}

if (!Deno.env.get("WA_TESTE")) Deno.serve(handler);
