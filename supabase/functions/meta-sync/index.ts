// ============================================================
// meta-sync — números do Meta Ads direto da API para a Supabase
// CRM Bulhões, 01/11/2026
//
// Grava em meta_estrutura (status real, objetivo, criativo de cada anúncio)
// e meta_insights_dia (gasto, alcance, frequência, cliques, conversas, vídeo… por dia).
//
// Chamadas (POST JSON):
//   x-motor-chave (cron)   { acao: "sincronizar", dias: 3 }
//   gestão logada           { acao: "sincronizar", dias? }            → estrutura + últimos N dias
//                           { acao: "historico", de: "AAAA-MM-DD", ate } → busca um período (em blocos de 10 dias)
//                           { acao: "diagnostico" }                    → contas, token e tipos de ação encontrados
//
// Segredos: META_ACCESS_TOKEN (usuário do sistema com ads_read na conta de anúncios).
// Opcional: META_AD_ACCOUNT_IDS ("act_123,act_456"); sem ele, usa as contas que o token enxerga.
// "Verify JWT" DESLIGADO (o cron entra pela chave do motor; a tela, pelo login conferido aqui).
// ============================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const TOKEN = Deno.env.get("META_ACCESS_TOKEN") ?? "";
const CONTAS_FIXAS = (Deno.env.get("META_AD_ACCOUNT_IDS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
const GRAPH = "https://graph.facebook.com/" + (Deno.env.get("META_GRAPH_VERSION") ?? "v23.0");
const ORIGENS = (Deno.env.get("CRM_ORIGENS") ?? "https://dashboard-bulhoes.vercel.app").split(",").map((s) => s.trim());
const FUSO_MIN = -180;

function cors(req: Request): Record<string, string> {
  const origem = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGENS.includes(origem) ? origem : ORIGENS[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-motor-chave",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

async function banco(caminho: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers ?? {});
  headers.set("apikey", SERVICE_KEY);
  headers.set("Authorization", "Bearer " + SERVICE_KEY);
  if (!headers.has("Content-Type")) headers.set("Content-Type", "application/json");
  return await fetch(SUPABASE_URL + caminho, { ...init, headers });
}
async function bancoJson(caminho: string, init: RequestInit = {}): Promise<any> {
  const r = await banco(caminho, init);
  const t = await r.text();
  if (!r.ok) throw new Error(`Supabase ${r.status}: ${t.slice(0, 200)}`);
  return t ? JSON.parse(t) : null;
}

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

// ---------- Graph API ----------
async function graph(caminho: string, params: Record<string, string> = {}): Promise<any> {
  const u = new URL(caminho.startsWith("http") ? caminho : GRAPH + caminho);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  if (!u.searchParams.has("access_token")) u.searchParams.set("access_token", TOKEN);
  for (let t = 0; t < 3; t++) {
    const r = await fetch(u.toString());
    const j = await r.json().catch(() => ({}));
    if (r.ok) return j;
    const cod = j?.error?.code;
    // limite de chamadas: espera e tenta de novo
    if ((cod === 4 || cod === 17 || cod === 80004 || r.status >= 500) && t < 2) { await new Promise((ok) => setTimeout(ok, 4000 * (t + 1))); continue; }
    throw new Error(`Meta ${r.status}: ${j?.error?.message ?? JSON.stringify(j).slice(0, 200)}`);
  }
}
async function todasPaginas(caminho: string, params: Record<string, string>, limite = 40): Promise<any[]> {
  const out: any[] = [];
  let j = await graph(caminho, params);
  for (let p = 0; p < limite; p++) {
    out.push(...(j?.data ?? []));
    const prox = j?.paging?.next;
    if (!prox) break;
    j = await graph(prox);
  }
  return out;
}

async function contas(): Promise<string[]> {
  if (CONTAS_FIXAS.length) return CONTAS_FIXAS.map((c) => c.startsWith("act_") ? c : "act_" + c);
  const l = await todasPaginas("/me/adaccounts", { fields: "id,name,account_status", limit: "50" }, 5);
  return l.filter((c: any) => Number(c.account_status) === 1).map((c: any) => String(c.id));
}

// ---------- classificação ----------
/** mensagem | perfil | cadastro | outro, pelo objetivo/destino do Meta (e pelo nome, se faltar). */
export function tipoCampanha(x: { objetivo?: string | null; destino?: string | null; otimizacao?: string | null; nome?: string | null }): string {
  const obj = String(x.objetivo ?? "").toUpperCase(), dest = String(x.destino ?? "").toUpperCase(), ot = String(x.otimizacao ?? "").toUpperCase();
  const nome = String(x.nome ?? "").toUpperCase();
  if (/WHATSAPP|MESSENGER|INSTAGRAM_DIRECT|MESSAG/.test(dest) || /CONVERSATIONS|REPLIES/.test(ot) || obj === "MESSAGES") return "mensagem";
  if (/INSTAGRAM_PROFILE|PROFILE/.test(dest) || /PROFILE_VISIT/.test(ot)) return "perfil";
  if (obj === "OUTCOME_LEADS" || obj === "LEAD_GENERATION" || /LEAD/.test(ot) || dest === "ON_AD") return "cadastro";
  if (obj === "OUTCOME_TRAFFIC" || obj === "LINK_CLICKS" || obj === "OUTCOME_AWARENESS") return "perfil";
  // sem dado do Meta: pelo padrão de nomes da clínica
  if (/WPP|WHATS|MENSAG|DIRECT/.test(nome)) return "mensagem";
  if (/TRAFEGO|TRÁFEGO|PERFIL|SEGUID|TOPO BIO|VISITA/.test(nome)) return "perfil";
  if (/LEAD|FORM|CADASTRO/.test(nome)) return "cadastro";
  return "outro";
}

const num = (v: unknown) => { const n = Number(v); return isFinite(n) ? n : null; };
const somaAcoes = (lista: any, teste: (t: string) => boolean) => {
  if (!Array.isArray(lista)) return null;
  let s = 0, achou = false;
  for (const a of lista) if (teste(String(a?.action_type ?? ""))) { s += Number(a?.value ?? 0); achou = true; }
  return achou ? Math.round(s) : null;
};
const primeiraAcao = (lista: any) => Array.isArray(lista) && lista.length ? Math.round(Number(lista[0]?.value ?? 0)) : null;

/** Resumo legível da segmentação do conjunto (sem dados pessoais: só critérios do anúncio). */
export function resumoPublico(t: any): any {
  if (!t || typeof t !== "object") return null;
  const nomes = (l: any) => (Array.isArray(l) ? l.map((x: any) => x?.name ?? x?.id).filter(Boolean) : []);
  const geo = t.geo_locations ?? {};
  const locais = [
    ...nomes(geo.cities).map((n: string, i: number) => n + (geo.cities[i]?.radius ? ` (+${geo.cities[i].radius} ${geo.cities[i].distance_unit ?? "km"})` : "")),
    ...nomes(geo.regions), ...nomes(geo.zips),
    ...(Array.isArray(geo.custom_locations) ? geo.custom_locations.map((c: any) => `${c.name ?? c.address_string ?? "ponto"} (${c.radius ?? "?"} ${c.distance_unit ?? "km"})`) : []),
    ...(Array.isArray(geo.countries) ? geo.countries : []),
  ];
  const flex = Array.isArray(t.flexible_spec) ? t.flexible_spec : [];
  const interesses = flex.flatMap((f: any) => [...nomes(f.interests), ...nomes(f.behaviors), ...nomes(f.life_events), ...nomes(f.work_positions), ...nomes(f.education_majors)]);
  return {
    idade: `${t.age_min ?? 18}-${t.age_max ?? 65}`,
    generos: Array.isArray(t.genders) && t.genders.length ? t.genders.map((g: number) => g === 1 ? "homens" : g === 2 ? "mulheres" : String(g)) : ["todos"],
    locais: locais.slice(0, 20),
    interesses: [...nomes(t.interests), ...interesses].slice(0, 40),
    publicos_personalizados: nomes(t.custom_audiences).slice(0, 20),
    publicos_excluidos: nomes(t.excluded_custom_audiences).slice(0, 20),
    advantage_publico: t.targeting_automation?.advantage_audience === 1,
    plataformas: t.publisher_platforms ?? "automático",
    posicionamentos_instagram: t.instagram_positions ?? null,
  };
}

// ---------- sincronização ----------
async function sincronizarEstrutura(conta: string): Promise<number> {
  const campos = "id,name,status,effective_status,created_time," +
    "adset{id,name,effective_status,optimization_goal,destination_type,daily_budget,targeting}," +
    "campaign{id,name,effective_status,objective,daily_budget}," +
    "creative{object_type,title,body,thumbnail_url}";
  const ads = await todasPaginas(`/${conta}/ads`, {
    fields: campos, limit: "200",
    effective_status: JSON.stringify(["ACTIVE", "PAUSED", "CAMPAIGN_PAUSED", "ADSET_PAUSED", "ARCHIVED", "IN_PROCESS", "WITH_ISSUES", "DISAPPROVED", "PENDING_REVIEW", "PREAPPROVED", "PENDING_BILLING_INFO"]),
  });
  const agora = new Date().toISOString();
  const linhas = ads.map((a: any) => {
    const l = {
      ad_id: String(a.id), ad_nome: a.name ?? null, ad_status: a.status ?? null, ad_status_efetivo: a.effective_status ?? null,
      ad_criado_em: a.created_time ?? null,
      adset_id: a.adset?.id ?? null, adset_nome: a.adset?.name ?? null, adset_status_efetivo: a.adset?.effective_status ?? null,
      otimizacao: a.adset?.optimization_goal ?? null, destino: a.adset?.destination_type ?? null,
      orcamento_dia_conjunto: a.adset?.daily_budget != null ? Number(a.adset.daily_budget) / 100 : null,
      campaign_id: a.campaign?.id ?? null, campaign_nome: a.campaign?.name ?? null, campaign_status_efetivo: a.campaign?.effective_status ?? null,
      objetivo: a.campaign?.objective ?? null,
      orcamento_dia_campanha: a.campaign?.daily_budget != null ? Number(a.campaign.daily_budget) / 100 : null,
      tipo: "", criativo_tipo: a.creative?.object_type ?? null, criativo_titulo: a.creative?.title ?? null,
      criativo_texto: a.creative?.body ? String(a.creative.body).slice(0, 1500) : null, criativo_miniatura: a.creative?.thumbnail_url ?? null,
      publico: resumoPublico(a.adset?.targeting),
      atualizado_em: agora,
    };
    l.tipo = tipoCampanha({ objetivo: l.objetivo, destino: l.destino, otimizacao: l.otimizacao, nome: l.campaign_nome });
    return l;
  });
  for (let i = 0; i < linhas.length; i += 500) {
    await bancoJson("/rest/v1/meta_estrutura?on_conflict=ad_id", {
      method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(linhas.slice(i, i + 500)),
    });
  }
  return linhas.length;
}

const CAMPOS_INSIGHTS = "ad_id,spend,impressions,reach,frequency,clicks,inline_link_clicks,ctr,cpm,actions," +
  "video_p25_watched_actions,video_p50_watched_actions,video_p75_watched_actions,video_p100_watched_actions,video_thruplay_watched_actions";

async function sincronizarInsights(conta: string, de: string, ate: string): Promise<number> {
  const l = await todasPaginas(`/${conta}/insights`, {
    level: "ad", time_increment: "1", fields: CAMPOS_INSIGHTS, limit: "500",
    time_range: JSON.stringify({ since: de, until: ate }),
  }, 60);
  const agora = new Date().toISOString();
  const linhas = l.map((x: any) => ({
    dia: x.date_start, ad_id: String(x.ad_id),
    gasto: num(x.spend) ?? 0, impressoes: Math.round(num(x.impressions) ?? 0), alcance: num(x.reach), frequencia: num(x.frequency),
    cliques: num(x.clicks), cliques_link: num(x.inline_link_clicks), ctr: num(x.ctr), cpm: num(x.cpm),
    conversas: somaAcoes(x.actions, (t) => t === "onsite_conversion.messaging_conversation_started_7d"),
    visitas_perfil: somaAcoes(x.actions, (t) => /profile_visit|instagram_profile/i.test(t)),
    leads_formulario: somaAcoes(x.actions, (t) => t === "lead" || t === "onsite_conversion.lead_grouped"),
    video_3s: somaAcoes(x.actions, (t) => t === "video_view"),
    video_25: primeiraAcao(x.video_p25_watched_actions), video_50: primeiraAcao(x.video_p50_watched_actions),
    video_75: primeiraAcao(x.video_p75_watched_actions), video_100: primeiraAcao(x.video_p100_watched_actions),
    thruplays: primeiraAcao(x.video_thruplay_watched_actions),
    acoes: Array.isArray(x.actions) ? Object.fromEntries(x.actions.map((a: any) => [a.action_type, Number(a.value)])) : null,
    atualizado_em: agora,
  }));
  for (let i = 0; i < linhas.length; i += 500) {
    await bancoJson("/rest/v1/meta_insights_dia?on_conflict=dia,ad_id", {
      method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(linhas.slice(i, i + 500)),
    });
  }
  return linhas.length;
}

/** Números por conjunto e dia, quebrados por idade+gênero e por posicionamento. */
async function sincronizarQuebras(conta: string, de: string, ate: string): Promise<number> {
  const conjuntos: [string, string, (x: any) => string][] = [
    ["idade_genero", "age,gender", (x) => `${x.age}|${x.gender}`],
    ["posicionamento", "publisher_platform,platform_position", (x) => `${x.publisher_platform}|${x.platform_position}`],
  ];
  const agora = new Date().toISOString();
  let n = 0;
  for (const [quebra, breakdowns, chave] of conjuntos) {
    const l = await todasPaginas(`/${conta}/insights`, {
      level: "adset", time_increment: "1", breakdowns, limit: "500",
      fields: "adset_id,spend,impressions,inline_link_clicks,clicks,actions",
      time_range: JSON.stringify({ since: de, until: ate }),
    }, 80);
    const linhas = l.map((x: any) => ({
      dia: x.date_start, adset_id: String(x.adset_id), quebra, chave: chave(x),
      gasto: num(x.spend) ?? 0, impressoes: Math.round(num(x.impressions) ?? 0), cliques: num(x.inline_link_clicks ?? x.clicks),
      conversas: somaAcoes(x.actions, (t) => t === "onsite_conversion.messaging_conversation_started_7d"),
      visitas_perfil: somaAcoes(x.actions, (t) => /profile_visit|instagram_profile/i.test(t)),
      atualizado_em: agora,
    }));
    for (let i = 0; i < linhas.length; i += 500) {
      await bancoJson("/rest/v1/meta_quebras_dia?on_conflict=dia,adset_id,quebra,chave", {
        method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(linhas.slice(i, i + 500)),
      });
    }
    n += linhas.length;
  }
  return n;
}

const diaLocal = (ms: number, n = 0) => new Date(ms + FUSO_MIN * 60_000 + n * 86_400_000).toISOString().slice(0, 10);
const somaDias = (d: string, n: number) => new Date(Date.parse(d + "T12:00:00Z") + n * 86_400_000).toISOString().slice(0, 10);

async function sincronizar(de: string, ate: string, comEstrutura = true) {
  if (!TOKEN) throw new Error("falta o segredo META_ACCESS_TOKEN na Supabase");
  const cs = await contas();
  if (!cs.length) throw new Error("o token não enxerga nenhuma conta de anúncios ativa (dê acesso ao usuário do sistema)");
  let anuncios = 0, linhas = 0, quebras = 0;
  const avisos: string[] = [];
  for (const c of cs) {
    if (comEstrutura) anuncios += await sincronizarEstrutura(c);
    // blocos de 10 dias para não estourar o tempo da Meta
    for (let ini = de; ini <= ate; ini = somaDias(ini, 10)) {
      const fim = somaDias(ini, 9) < ate ? somaDias(ini, 9) : ate;
      linhas += await sincronizarInsights(c, ini, fim);
      quebras += await sincronizarQuebras(c, ini, fim).catch((e) => { avisos.push("quebras: " + String(e?.message ?? e).slice(0, 150)); return 0; });
    }
  }
  return { contas: cs, anuncios, linhas_dia: linhas, linhas_quebras: quebras, avisos, de, ate };
}

export async function handler(req: Request): Promise<Response> {
  const h = cors(req);
  const json = (c: unknown, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { ...h, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: h });
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);
  const dados = await req.json().catch(() => ({}));
  try {
    const chave = req.headers.get("x-motor-chave");
    if (chave) {
      const ok = await bancoJson("/rest/v1/rpc/automacao_conferir_chave", { method: "POST", body: JSON.stringify({ p_chave: chave }) }).catch(() => false);
      if (!ok) return json({ ok: false, erro: "chave do motor inválida" }, 401);
      const dias = Math.min(10, Math.max(1, Number(dados.dias ?? 3)));
      const hoje = diaLocal(Date.now());
      return json({ ok: true, ...(await sincronizar(somaDias(hoje, -(dias - 1)), hoje)) });
    }
    const u = await usuario(req);
    if (!u || u.papel !== "gestao") return json({ ok: false, erro: "só a gestão" }, 403);
    const hoje = diaLocal(Date.now());
    switch (dados?.acao) {
      case "sincronizar": {
        const dias = Math.min(30, Math.max(1, Number(dados.dias ?? 3)));
        return json({ ok: true, ...(await sincronizar(somaDias(hoje, -(dias - 1)), hoje)) });
      }
      case "historico": {
        const de = String(dados.de ?? ""), ate = String(dados.ate ?? hoje);
        if (!/^\d{4}-\d{2}-\d{2}$/.test(de) || !/^\d{4}-\d{2}-\d{2}$/.test(ate) || de > ate) return json({ ok: false, erro: "datas inválidas" }, 400);
        if (Date.parse(ate) - Date.parse(de) > 95 * 86_400_000) return json({ ok: false, erro: "no máximo 95 dias por vez" }, 400);
        return json({ ok: true, ...(await sincronizar(de, ate, dados.estrutura !== false)) });
      }
      case "diagnostico": {
        if (!TOKEN) return json({ ok: false, erro: "falta o segredo META_ACCESS_TOKEN" });
        const perm = await graph("/me/permissions").catch((e) => ({ erro: String(e.message ?? e) }));
        const cs = await todasPaginas("/me/adaccounts", { fields: "id,name,account_status,currency,timezone_name", limit: "50" }, 3).catch((e) => [{ erro: String(e.message ?? e) }]);
        const tipos: Record<string, number> = {};
        const amostra = await bancoJson(`/rest/v1/meta_insights_dia?select=acoes&dia=gte.${somaDias(hoje, -14)}&limit=500`).catch(() => []);
        for (const r of amostra ?? []) for (const [k, v] of Object.entries(r.acoes ?? {})) tipos[k] = (tipos[k] ?? 0) + Number(v);
        return json({ ok: true, permissoes: (perm?.data ?? perm), contas: cs, tipos_de_acao_14d: tipos });
      }
      default:
        return json({ ok: false, erro: "ação desconhecida" }, 400);
    }
  } catch (e) {
    console.error("[meta-sync]", dados?.acao, String(e));
    return json({ ok: false, erro: String((e as any)?.message ?? e) }, 500);
  }
}

Deno.serve(handler);
