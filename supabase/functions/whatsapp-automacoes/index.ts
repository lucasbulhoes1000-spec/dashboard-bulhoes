// ============================================================
// whatsapp-automacoes — o motor das automações do CRM Bulhões
// 22/10/2026
//
// O agendador do banco (pg_cron) chama esta função a cada minuto com a
// chave do motor (cabeçalho x-motor-chave). Ela pega quem tem passo vencido
// (automacao_pegar) e executa os passos em ordem até chegar numa espera:
//   esperar · texto · midia · modelo · acao · por_tag · tirar_tag · atribuir · se · fim
// Também envia os disparos em massa (tabela disparos), no ritmo de cada um.
//
// Regras de cada automação (campo regras):
//   inicio/fim (horário de Brasília) e pular_fim_de_semana → mensagens fora do
//   horário ficam para o próximo horário permitido (tags e esperas não esperam).
//   Texto livre só sai com a janela de 24 h aberta; sem janela, o passo é
//   pulado (ou a pessoa sai, se o passo tiver "sem_janela":"parar").
//
// Chave geral (configuracoes 'automacoes_ligadas'): enquanto false, só andam as
// automações em modo teste.
//
// Segredos usados: WA_TOKEN, WA_PHONE_NUMBER_ID (mesmos da whatsapp-acoes).
// ============================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WA_TOKEN = Deno.env.get("WA_TOKEN") ?? "";
const WA_PHONE_NUMBER_ID = Deno.env.get("WA_PHONE_NUMBER_ID") ?? "";
const GRAPH = "https://graph.facebook.com/" + (Deno.env.get("WA_GRAPH_VERSION") ?? "v23.0");

const JANELA_MS = 24 * 60 * 60 * 1000;
const FUSO_MIN = -180; // Brasília (sem horário de verão)
const TEMPO_MAX_MS = 45_000; // a função tem até ~150 s; paramos antes
const PASSOS_POR_VEZ = 25; // proteção contra laço (ex.: "se" apontando para trás)

// ---------- banco ----------
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
const rpc = (nome: string, args: unknown) => bancoJson(`/rest/v1/rpc/${nome}`, { method: "POST", body: JSON.stringify(args) });

// ---------- Meta ----------
async function meta(caminho: string, corpo: unknown, token: string) {
  const r = await fetch(GRAPH + caminho, {
    method: "POST",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: JSON.stringify(corpo),
  });
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, j };
}
function erroMeta(j: any): string {
  const e = j?.error ?? {};
  return [e.message, e.error_data?.details].filter(Boolean).join(" — ") || "erro desconhecido da Meta";
}
const _tokens = new Map<string, string>();
async function tokenDoNumero(id: string): Promise<string> {
  if (_tokens.has(id)) return _tokens.get(id)!;
  let t = WA_TOKEN;
  try {
    const r = await bancoJson(`/rest/v1/whatsapp_numeros?phone_number_id=eq.${encodeURIComponent(id)}&select=token`);
    if (r?.[0]?.token) t = r[0].token;
  } catch (_) { /* usa a padrão */ }
  _tokens.set(id, t);
  return t;
}

// ---------- regras de horário ----------
function hm(s: unknown, padrao: number): number {
  const m = /^(\d{1,2}):(\d{2})$/.exec(String(s ?? ""));
  return m ? Math.min(24 * 60, Number(m[1]) * 60 + Number(m[2])) : padrao;
}
/** Próximo instante permitido para mandar mensagem (agora, se já estiver dentro do horário). */
export function proximoHorario(agora: number, regras: any): number {
  const ini = hm(regras?.inicio, 0), fim = hm(regras?.fim, 24 * 60);
  const pular = regras?.pular_fim_de_semana === true;
  if (ini >= fim) return agora; // horário inválido: não restringe
  const local = new Date(agora + FUSO_MIN * 60_000); // "relógio" de Brasília em campos UTC
  for (let d = 0; d < 8; d++) {
    const dia = new Date(Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate() + d));
    const sem = dia.getUTCDay();
    if (pular && (sem === 0 || sem === 6)) continue;
    const abre = dia.getTime() + ini * 60_000, fecha = dia.getTime() + fim * 60_000; // ainda em "relógio local"
    const agoraLocal = local.getTime();
    if (d === 0) {
      if (agoraLocal < abre) return abre - FUSO_MIN * 60_000;
      if (agoraLocal < fecha) return agora;
      continue;
    }
    return abre - FUSO_MIN * 60_000;
  }
  return agora;
}

export function janelaAberta(c: { ultima_recebida_em?: string | null; janela_gratis_ate?: string | null }, agora = Date.now()): boolean {
  const ultima = c?.ultima_recebida_em ? Date.parse(c.ultima_recebida_em) : 0;
  const gratis = c?.janela_gratis_ate ? Date.parse(c.janela_gratis_ate) : 0;
  return agora - ultima < JANELA_MS || gratis > agora;
}

/** Troca {nome}, {primeiro_nome}, {telefone} pelo dado do contato. */
export function preencher(texto: string, ctx: { nome?: string | null; telefone?: string }): string {
  const nome = String(ctx.nome ?? "").trim();
  const primeiro = nome.split(/\s+/)[0] ?? "";
  const pr = primeiro ? primeiro.charAt(0).toUpperCase() + primeiro.slice(1).toLowerCase() : "";
  return String(texto ?? "")
    .replace(/\{\s*primeiro_nome\s*\}/gi, pr)
    .replace(/\{\s*nome\s*\}/gi, nome || pr)
    .replace(/\{\s*telefone\s*\}/gi, ctx.telefone ?? "")
    .replace(/[ \t]+([,.!?])/g, "$1") // "Oi , tudo bem" quando não tem nome
    .replace(/[ \t]{2,}/g, " ");
}

/** Monta o corpo do modelo para a Meta (mesma regra da whatsapp-acoes). */
export function corpoModelo(p: any, ctx: { nome?: string | null; telefone?: string }) {
  const template: any = { name: String(p.nome), language: { code: String(p.idioma ?? "pt_BR") } };
  const components: any[] = [];
  const cab = p.cabecalho;
  if (cab && ["IMAGE", "VIDEO", "DOCUMENT"].includes(cab.formato) && cab.link) {
    const tipo = String(cab.formato).toLowerCase();
    components.push({ type: "header", parameters: [{ type: tipo, [tipo]: { link: String(cab.link) } }] });
  }
  const vars: string[] = Array.isArray(p.variaveis) ? p.variaveis.map((v: unknown) => preencher(String(v ?? ""), ctx) || "-") : [];
  const campos: string[] = Array.isArray(p.campos) ? p.campos.map(String) : [];
  if (vars.length) {
    components.push({
      type: "body",
      parameters: vars.map((t, i) => p.formato === "NAMED" ? { type: "text", parameter_name: campos[i], text: t } : { type: "text", text: t }),
    });
  }
  if (components.length) template.components = components;
  return { type: "template", template };
}

// ---------- execução ----------
type Exec = { id: number; automacao_id: number; telefone: string; conversa_id: string | null; passo: number; entrou_em: string; contexto: any };

async function avancar(x: Exec, feito: number, acao: string | null, resultado: string, detalhe: string | null, proximo: number | null, proximaEm: number | null, status = "ativa", conversa: string | null = null) {
  await rpc("automacao_avancar", {
    p_exec: x.id, p_passo_feito: feito + 1, p_acao: acao, p_resultado: resultado, p_detalhe: detalhe,
    p_proximo: proximo, p_proxima_em: proximaEm ? new Date(proximaEm).toISOString() : null, p_status: status, p_conversa: conversa,
  });
}

async function chaveGeralLigada(): Promise<boolean> {
  const r = await bancoJson(`/rest/v1/configuracoes?chave=eq.automacoes_ligadas&select=valor`);
  return r?.[0]?.valor === true;
}

async function contato(x: Exec, a: any) {
  let convId = x.conversa_id;
  if (!convId) {
    convId = await rpc("automacao_conversa", { p_numero: String(a.numero_clinica_id || WA_PHONE_NUMBER_ID), p_telefone: x.telefone });
  }
  const c = (await bancoJson(`/rest/v1/conversas?id=eq.${convId}&select=*`))?.[0];
  const p = (await bancoJson(`/rest/v1/pacientes?telefone=eq.${x.telefone}&select=nome,etapa`))?.[0];
  return { c, nome: p?.nome || c?.nome_contato || c?.nome_perfil || "", etapa: p?.etapa ?? null };
}

async function registrar(c: any, waId: string | null, tipo: string, texto: string, autor: string, status: string, erro: string | null, bruto: unknown) {
  return await rpc("wa_registrar_enviada", {
    p_conversa: c.id, p_wa_message_id: waId, p_tipo: tipo, p_texto: texto, p_autor: autor, p_status: status, p_erro: erro, p_bruto: bruto,
  });
}

async function tagIds(conversa: string): Promise<number[]> {
  const r = await bancoJson(`/rest/v1/conversa_tags?conversa_id=eq.${conversa}&select=tag_id`);
  return (r ?? []).map((t: any) => Number(t.tag_id));
}

export async function processar(x: Exec, a: any, agora = () => Date.now(), geral = true) {
  // automação desligada, ou fora do modo teste com a chave geral pausada: pausa (volta a andar quando religar)
  if (!a || !a.ligada || (!a.modo_teste && !geral)) {
    await avancar(x, x.passo, null, "ok", null, null, agora() + 60 * 60_000);
    return "pausada";
  }
  const passos: any[] = Array.isArray(a.passos) ? a.passos : [];
  const regras = a.regras ?? {};
  const autor = "automação: " + a.nome;
  let i = x.passo;
  let ctx: Awaited<ReturnType<typeof contato>> | null = null;
  const garantir = async () => (ctx ??= await contato(x, a));

  for (let volta = 0; volta < PASSOS_POR_VEZ; volta++) {
    const p = passos[i];
    if (!p || p.tipo === "fim") {
      await avancar(x, i, "fim", "ok", "concluiu os passos", i, null, "concluida");
      return "concluida";
    }
    try {
      switch (p.tipo) {
        case "esperar": {
          const min = Math.max(1, Number(p.minutos) || 0);
          await avancar(x, i, "esperar", "ok", `${min} min`, i + 1, agora() + min * 60_000);
          return "esperando";
        }
        case "texto":
        case "midia":
        case "modelo": {
          const quando = p.ignorar_horario ? agora() : proximoHorario(agora(), regras);
          if (quando > agora() + 30_000) {
            await avancar(x, i, null, "adiado", null, i, quando); // sem log: só reagenda
            return "fora_do_horario";
          }
          const k = await garantir();
          if (!k.c) throw new Error("não achei a conversa do contato");
          const dados = { nome: k.nome, telefone: x.telefone };
          let corpo: any, registro: string, tipo: string;
          if (p.tipo === "texto" || p.tipo === "midia") {
            if (!janelaAberta(k.c, agora())) {
              if (p.sem_janela === "parar") {
                await avancar(x, i, p.tipo, "pulado", "janela de 24 h fechada: saiu da automação", i, null, "saiu", k.c.id);
                return "saiu";
              }
              await avancar(x, i, p.tipo, "pulado", "janela de 24 h fechada", i + 1, null, "ativa", k.c.id);
              i++; continue;
            }
          }
          if (p.tipo === "midia") {
            const fmt = ["image", "video", "audio", "document"].includes(p.formato) ? p.formato : "document";
            if (!/^https:\/\//.test(String(p.link ?? ""))) throw new Error("passo de mídia sem arquivo");
            const conteudo: any = { link: String(p.link) };
            const legenda = preencher(p.legenda ?? "", dados).trim();
            if (legenda && fmt !== "audio") conteudo.caption = legenda.slice(0, 1024);
            if (fmt === "document") conteudo.filename = String(p.nome || "arquivo");
            corpo = { type: fmt, [fmt]: conteudo };
            registro = legenda || ({ image: "📷 Foto", video: "🎥 Vídeo", audio: "🎤 Áudio", document: "📄 " + (p.nome || "Arquivo") }[fmt]!);
            tipo = fmt;
          } else if (p.tipo === "texto") {
            registro = preencher(p.texto, dados).trim();
            if (!registro) { await avancar(x, i, "texto", "pulado", "texto vazio", i + 1, null, "ativa", k.c.id); i++; continue; }
            corpo = { type: "text", text: { body: registro.slice(0, 4096), preview_url: true } };
            tipo = "text";
          } else {
            if (!p.nome) throw new Error("passo de modelo sem modelo escolhido");
            corpo = corpoModelo(p, dados);
            registro = p.texto_preview ? preencher(p.texto_preview, dados) : `[modelo ${p.nome}]`;
            tipo = "template";
          }
          const r = await meta(`/${k.c.numero_clinica_id}/messages`, { messaging_product: "whatsapp", recipient_type: "individual", to: k.c.wa_id, ...corpo }, await tokenDoNumero(k.c.numero_clinica_id));
          if (!r.ok) {
            const erro = erroMeta(r.j);
            await registrar(k.c, null, tipo, registro, autor, "falhou", erro, r.j);
            await avancar(x, i, p.tipo, "erro", erro, i, null, "erro", k.c.id);
            return "erro";
          }
          await registrar(k.c, r.j?.messages?.[0]?.id ?? null, tipo, registro, autor, "enviada", null, r.j);
          await avancar(x, i, p.tipo, "ok", p.tipo === "modelo" ? p.nome : registro.slice(0, 120), i + 1, null, "ativa", k.c.id);
          i++; continue;
        }
        case "acao": {
          // passo "Ação" do Cloudia: adicionar/remover várias tags ou atribuir
          const k = await garantir();
          if (!k.c) throw new Error("não achei a conversa do contato");
          const tags: number[] = (Array.isArray(p.tags) ? p.tags : []).map(Number).filter(Boolean);
          if (p.acao === "por_tag" || p.acao === "tirar_tag") {
            for (const t of tags) {
              const r = p.acao === "por_tag"
                ? await banco(`/rest/v1/conversa_tags`, { method: "POST", headers: { Prefer: "resolution=ignore-duplicates,return=minimal" }, body: JSON.stringify({ conversa_id: k.c.id, tag_id: t, adicionada_por: autor }) })
                : await banco(`/rest/v1/conversa_tags?conversa_id=eq.${k.c.id}&tag_id=eq.${t}`, { method: "DELETE", headers: { Prefer: "return=minimal" } });
              if (!r.ok && r.status !== 409) throw new Error("tag: " + (await r.text()).slice(0, 200));
            }
          } else if (p.acao === "atribuir") {
            await bancoJson(`/rest/v1/conversas?id=eq.${k.c.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ atribuida_a: p.email || null }) });
          }
          await avancar(x, i, "acao", "ok", (p.acao || "?") + (tags.length ? " " + tags.join(",") : p.email ? " " + p.email : ""), i + 1, null, "ativa", k.c.id);
          i++; continue;
        }
        case "por_tag":
        case "tirar_tag": {
          const k = await garantir();
          if (!k.c) throw new Error("não achei a conversa do contato");
          if (p.tipo === "por_tag") {
            await banco(`/rest/v1/conversa_tags`, {
              method: "POST", headers: { Prefer: "resolution=ignore-duplicates,return=minimal" },
              body: JSON.stringify({ conversa_id: k.c.id, tag_id: Number(p.tag_id), adicionada_por: autor }),
            }).then(async (r) => { if (!r.ok && r.status !== 409) throw new Error("tag: " + (await r.text()).slice(0, 200)); });
          } else {
            const r = await banco(`/rest/v1/conversa_tags?conversa_id=eq.${k.c.id}&tag_id=eq.${Number(p.tag_id)}`, { method: "DELETE", headers: { Prefer: "return=minimal" } });
            if (!r.ok) throw new Error("tag: " + (await r.text()).slice(0, 200));
          }
          await avancar(x, i, p.tipo, "ok", String(p.tag_nome ?? p.tag_id), i + 1, null, "ativa", k.c.id);
          i++; continue;
        }
        case "atribuir": {
          const k = await garantir();
          if (!k.c) throw new Error("não achei a conversa do contato");
          await bancoJson(`/rest/v1/conversas?id=eq.${k.c.id}`, {
            method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ atribuida_a: p.email || null }),
          });
          await avancar(x, i, "atribuir", "ok", p.email || "sem atendente", i + 1, null, "ativa", k.c.id);
          i++; continue;
        }
        case "se": {
          const k = await garantir();
          const cond = p.condicao ?? {};
          let v = false;
          if (cond.tipo === "tem_tag") v = !!k.c && (await tagIds(k.c.id)).includes(Number(cond.tag_id));
          else if (cond.tipo === "nao_tem_tag") v = !k.c || !(await tagIds(k.c.id)).includes(Number(cond.tag_id));
          else if (cond.tipo === "etapa") v = String(k.etapa ?? "").toLowerCase() === String(cond.etapa ?? "").toLowerCase();
          else if (cond.tipo === "respondeu") {
            v = !!x.contexto?.respondeu_em || (!!k.c?.ultima_recebida_em && Date.parse(k.c.ultima_recebida_em) > Date.parse(x.entrou_em));
          } else if (cond.tipo === "janela_aberta") v = !!k.c && janelaAberta(k.c, agora());
          if (v) { await avancar(x, i, "se", "ok", "sim", i + 1, null, "ativa", k.c?.id ?? null); i++; continue; }
          if (p.senao === "fim" || p.senao == null) {
            await avancar(x, i, "se", "ok", "não: terminou", i, null, "concluida", k.c?.id ?? null);
            return "concluida";
          }
          const alvo = Math.max(0, Number(p.senao) - 1); // na tela o passo 1 é o primeiro
          await avancar(x, i, "se", "ok", `não: foi para o passo ${alvo + 1}`, alvo, null, "ativa", k.c?.id ?? null);
          i = alvo; continue;
        }
        default:
          await avancar(x, i, String(p.tipo ?? "?"), "pulado", "passo desconhecido", i + 1, null);
          i++; continue;
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      await avancar(x, i, String(p.tipo ?? "?"), "erro", msg.slice(0, 500), i, null, "erro");
      return "erro";
    }
  }
  // muitos passos imediatos seguidos: continua no próximo minuto
  await avancar(x, i, null, "ok", null, i, agora() + 60_000);
  return "continua";
}

// ---------- disparo em massa ----------
type Destino = { destino_id: number; disparo_id: number; telefone: string; nome: string | null };
export async function enviarDisparo(d: Destino, disp: any) {
  const marcar = (status: string, motivo: string | null, conversa: string | null, waId: string | null) =>
    rpc("disparo_marcar", { p_destino: d.destino_id, p_status: status, p_motivo: motivo, p_conversa: conversa, p_wa_message_id: waId });
  if (!disp || disp.status !== "enviando") return "ignorado";
  try {
    const convId = await rpc("automacao_conversa", { p_numero: String(disp.numero_clinica_id || WA_PHONE_NUMBER_ID), p_telefone: d.telefone });
    const c = (await bancoJson(`/rest/v1/conversas?id=eq.${convId}&select=*`))?.[0];
    if (!c) throw new Error("não achei a conversa");
    const nome = d.nome || c.nome_contato || c.nome_perfil || "";
    const corpo = corpoModelo(disp.modelo, { nome, telefone: d.telefone });
    const registro = disp.modelo?.texto_preview ? preencher(String(disp.modelo.texto_preview), { nome, telefone: d.telefone }) : `[modelo ${disp.modelo?.nome}]`;
    const r = await meta(`/${c.numero_clinica_id}/messages`, { messaging_product: "whatsapp", recipient_type: "individual", to: c.wa_id, ...corpo }, await tokenDoNumero(c.numero_clinica_id));
    const autor = "disparo: " + disp.nome;
    if (!r.ok) {
      const erro = erroMeta(r.j);
      await registrar(c, null, "template", registro, autor, "falhou", erro, r.j);
      await marcar("falhou", erro.slice(0, 300), c.id, null);
      return "falhou";
    }
    const waId = r.j?.messages?.[0]?.id ?? null;
    await registrar(c, waId, "template", registro, autor, "enviada", null, r.j);
    await marcar("enviado", null, c.id, waId);
    return "enviado";
  } catch (e) {
    await marcar("falhou", String((e as Error)?.message ?? e).slice(0, 300), null, null).catch(() => {});
    return "falhou";
  }
}

async function rodarDisparos(inicio: number, cont: Record<string, number>) {
  const lote: Destino[] = await rpc("disparo_pegar", {}).catch(() => []);
  if (!lote?.length) return;
  const ids = [...new Set(lote.map((x) => x.disparo_id))];
  const ds = await bancoJson(`/rest/v1/disparos?id=in.(${ids.join(",")})&select=id,nome,modelo,numero_clinica_id,status`);
  const porId = new Map<number, any>((ds ?? []).map((x: any) => [x.id, x]));
  for (const d of lote) {
    if (Date.now() - inicio > TEMPO_MAX_MS) break; // o resto fica pendente para o próximo minuto
    const r = await enviarDisparo(d, porId.get(d.disparo_id));
    cont["disparo_" + r] = (cont["disparo_" + r] ?? 0) + 1;
  }
}

export async function handler(req: Request): Promise<Response> {
  const json = (c: unknown, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);
  const chave = req.headers.get("x-motor-chave") ?? "";
  if (!chave || !(await rpc("automacao_conferir_chave", { p_chave: chave }))) return json({ ok: false, erro: "chave do motor inválida" }, 401);
  // chave geral pausada: só as automações em modo teste andam
  const geral = await chaveGeralLigada();

  const inicio = Date.now();
  const cont: Record<string, number> = {};
  // disparos em massa primeiro (não dependem da chave geral: cada um é decisão da equipe)
  await rodarDisparos(inicio, cont).catch((e) => { cont.disparo_erro_motor = 1; console.error("disparos", e); });
  const autos = new Map<number, any>();
  while (Date.now() - inicio < TEMPO_MAX_MS) {
    const lote: Exec[] = await rpc("automacao_pegar", { p_limite: 30 });
    if (!lote?.length) break;
    const faltam = [...new Set(lote.map((x) => x.automacao_id))].filter((id) => !autos.has(id));
    if (faltam.length) {
      const rs = await bancoJson(`/rest/v1/automacoes?id=in.(${faltam.join(",")})&select=id,nome,ligada,modo_teste,regras,passos,numero_clinica_id`);
      for (const a of rs ?? []) autos.set(a.id, a);
    }
    for (const x of lote) {
      const r = await processar(x, autos.get(x.automacao_id), undefined, geral).catch(async (e) => {
        await avancar(x, x.passo, "motor", "erro", String(e?.message ?? e).slice(0, 500), x.passo, null, "erro").catch(() => {});
        return "erro";
      });
      cont[r] = (cont[r] ?? 0) + 1;
    }
  }
  return json({ ok: true, geral, ...cont, ms: Date.now() - inicio });
}

if (!Deno.env.get("WA_TESTE")) Deno.serve(handler);
