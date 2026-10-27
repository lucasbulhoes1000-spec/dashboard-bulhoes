// ============================================================
// whatsapp-automacoes — o motor das automações do CRM Bulhões
// 22/10/2026
//
// O agendador do banco (pg_cron) chama esta função a cada minuto com a
// chave do motor (cabeçalho x-motor-chave). Ela pega quem tem passo vencido
// (automacao_pegar) e executa os passos em ordem até chegar numa espera:
//   esperar · texto · midia · modelo · acao · por_tag · tirar_tag · atribuir · se · fim
// Também envia os disparos em massa (tabela disparos), no ritmo de cada um, e as
// mensagens agendadas pela equipe na Central (tabela mensagens_agendadas) e os
// lembretes de consulta pela agenda do Clinicorp (configuracoes 'lembretes_consulta').
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
// Segredos usados: WA_TOKEN, WA_PHONE_NUMBER_ID (mesmos da whatsapp-acoes) e, para os
// lembretes, CLINICORP_USUARIO e CLINICORP_TOKEN (e CLINICORP_SUBSCRIBER_ID em conta de grupo).
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
export function preencher(texto: string, ctx: { nome?: string | null; telefone?: string; extra?: Record<string, string> }): string {
  const nome = String(ctx.nome ?? "").trim();
  const primeiro = nome.split(/\s+/)[0] ?? "";
  const pr = primeiro ? primeiro.charAt(0).toUpperCase() + primeiro.slice(1).toLowerCase() : "";
  let t = String(texto ?? "");
  // {data}, {hora}, {dia_semana}, {quando} dos lembretes de consulta
  for (const [k, v] of Object.entries(ctx.extra ?? {})) t = t.replace(new RegExp("\\{\\s*" + k + "\\s*\\}", "gi"), v);
  return t
    .replace(/\{\s*primeiro_nome\s*\}/gi, pr)
    .replace(/\{\s*nome\s*\}/gi, nome || pr)
    .replace(/\{\s*telefone\s*\}/gi, ctx.telefone ?? "")
    .replace(/[ \t]+([,.!?])/g, "$1") // "Oi , tudo bem" quando não tem nome
    .replace(/[ \t]{2,}/g, " ");
}

/** Monta o corpo do modelo para a Meta (mesma regra da whatsapp-acoes). */
export function corpoModelo(p: any, ctx: { nome?: string | null; telefone?: string; extra?: Record<string, string> }) {
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

// ---------- follow-up escrito pela IA (27/10/2026) ----------
// A IA lê a conversa e escreve UMA mensagem que retoma do ponto em que o lead parou.
// Usa o modelo e a base de conhecimento da tela "Agente de IA". Se falhar, o passo
// manda o texto fixo dele (p.texto).
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
export async function textoDaIA(c: any, nome?: string | null): Promise<string> {
  if (!ANTHROPIC_API_KEY || !c?.id) return "";
  const ag = (await bancoJson(`/rest/v1/agente_ia?id=eq.1&select=modelo,base_conhecimento`).catch(() => []))?.[0] ?? {};
  const msgs: any[] = ((await bancoJson(`/rest/v1/mensagens?conversa_id=eq.${c.id}&select=direcao,texto,tipo,enviada_em&order=enviada_em.desc&limit=30`).catch(() => [])) ?? []).reverse();
  const hist = msgs.filter((m) => String(m.texto ?? "").trim()).map((m) => (m.direcao === "recebida" ? "LEAD: " : "CLÍNICA: ") + String(m.texto).trim().slice(0, 600)).join("\n");
  if (!hist) return "";
  const sistema =
    "Você é a Raffa, do atendimento da Bulhões Odontologia (lentes de contato dental em Santos). " +
    "O lead parou de responder. Escreva UMA mensagem curta de follow-up (no máximo 300 caracteres) que retome a conversa exatamente do ponto em que parou.\n" +
    "Regras: se o lead fez uma pergunta que ficou sem resposta, responda primeiro, usando só a base de conhecimento. " +
    "Termine com uma pergunta simples que leve ao próximo passo (contar a queixa, escolher manhã ou tarde, confirmar). " +
    "Não invente horários, valores, condições, prêmios ou números que não estejam na base. Não repita uma mensagem que a clínica já mandou. " +
    "Tom da Raffa: próximo, carinhoso, natural (pode usar \"Oiii\", no máximo um emoji). Nunca use hífen nem travessão. Não diga que é IA nem cite há quanto tempo a pessoa não responde. " +
    "Responda só com o texto da mensagem." +
    (String(ag.base_conhecimento ?? "").trim() ? "\n\n# Base de conhecimento\n" + String(ag.base_conhecimento).trim() : "") +
    (nome ? `\n\nNome do lead: ${nome}.` : "");
  const r = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: { "x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
    body: JSON.stringify({ model: ag.modelo || "claude-sonnet-5-5", max_tokens: 400, system: [{ type: "text", text: sistema, cache_control: { type: "ephemeral" } }], messages: [{ role: "user", content: "Conversa até agora:\n" + hist + "\n\nEscreva a mensagem de follow-up." }] }),
  });
  if (!r.ok) throw new Error("Anthropic " + r.status + " " + (await r.text()).slice(0, 200));
  const j = await r.json();
  const t = (j?.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("\n").trim();
  return t.replace(/\s*[—–]\s*/g, ", ").slice(0, 700);
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
        case "ia":
        case "midia":
        case "modelo": {
          const quando = p.ignorar_horario ? agora() : proximoHorario(agora(), regras);
          if (quando > agora() + 30_000) {
            // (25/10/2026) volta para as condições ("se") logo antes da mensagem: elas
            // são conferidas de novo na hora em que a mensagem sai de fato (ex.: quem
            // agendou de manhã não recebe às 11h o follow-up de lead)
            let volta = i;
            while (volta > 0 && passos[volta - 1]?.tipo === "se") volta--;
            // (26/10/2026) várias guardadas para o mesmo horário saem na ordem da
            // sequência (a de espera menor primeiro)
            const esperaSeq = Number(passos.find((q: any) => q?.tipo === "esperar")?.minutos) || 0;
            const ordem = Math.min(1800, Math.round(esperaSeq / 2)) * 1000;
            await avancar(x, i, null, "adiado", null, volta, quando + ordem); // sem log: só reagenda
            return "fora_do_horario";
          }
          const k = await garantir();
          if (!k.c) throw new Error("não achei a conversa do contato");
          // (26/10/2026) no máximo um follow-up automático por hora para a mesma pessoa
          // (ex.: o de 2 h e o de 4 h guardados da madrugada não saem colados às 11h)
          const espaco = regras.espaco_min === 0 ? 0 : Number(regras.espaco_min ?? 60);
          if (espaco > 0 && !p.ignorar_horario) {
            const desde = new Date(agora() - espaco * 60_000).toISOString();
            const rec = await bancoJson(`/rest/v1/mensagens?conversa_id=eq.${k.c.id}&direcao=eq.enviada&autor_email=like.automa*&status=neq.falhou&enviada_em=gte.${encodeURIComponent(desde)}&select=enviada_em&order=enviada_em.desc&limit=1`).catch(() => []);
            if (rec && rec.length) {
              let volta = i;
              while (volta > 0 && passos[volta - 1]?.tipo === "se") volta--;
              const depois = proximoHorario(Date.parse(rec[0].enviada_em) + espaco * 60_000, regras);
              await avancar(x, i, null, "adiado", null, volta, Math.max(depois, agora() + 60_000));
              return "fora_do_horario";
            }
          }
          const dados = { nome: k.nome, telefone: x.telefone };
          let corpo: any, registro: string, tipo: string;
          if (p.tipo === "texto" || p.tipo === "ia" || p.tipo === "midia") {
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
          } else if (p.tipo === "texto" || p.tipo === "ia") {
            registro = "";
            if (p.tipo === "ia") registro = (await textoDaIA(k.c, k.nome).catch((e) => { console.error("[automacoes] ia", String(e)); return ""; })).trim();
            if (!registro) registro = preencher(p.texto, dados).trim();
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
          else if (cond.tipo === "calado_ha") {
            // (24/10/2026) o paciente não mandou mensagem nos últimos N minutos
            // (conversa parada): só então o follow-up sai; se falou há pouco, pula
            const ult = k.c?.ultima_recebida_em ? Date.parse(k.c.ultima_recebida_em) : 0;
            v = !ult || agora() - ult >= Math.max(1, Number(cond.minutos) || 0) * 60_000;
          }
          else if (cond.tipo === "ninguem_respondeu") {
            // (27/10/2026) primeira mensagem automática: ninguém (equipe, IA ou celular)
            // mandou nada para o lead desde que ele chegou, e o robô não está cuidando
            const desde = new Date(Date.parse(x.entrou_em) - 10 * 60_000).toISOString();
            const env: any[] = k.c ? ((await bancoJson(`/rest/v1/mensagens?conversa_id=eq.${k.c.id}&direcao=eq.enviada&status=neq.falhou&enviada_em=gte.${encodeURIComponent(desde)}&select=autor_email&limit=50`).catch(() => [])) ?? []) : [];
            v = !!k.c && !k.c.robo_ligado && !env.some((m) => !/^automa/i.test(String(m.autor_email ?? "")));
          }
          else if (cond.tipo === "sem_resposta") {
            // (26/10/2026) follow-up de verdade: a equipe falou e o lead não respondeu
            // há N minutos (contados da última mensagem da equipe). Se ninguém da
            // equipe respondeu o lead ainda, ou se o lead respondeu depois, espera
            // (não termina a sequência): confere de novo mais tarde.
            const min = Math.max(1, Number(cond.minutos) || 0);
            let volta = i; while (volta > 0 && passos[volta - 1]?.tipo === "se") volta--; // reconfere a etapa também
            const ultLead = k.c?.ultima_recebida_em ? Date.parse(k.c.ultima_recebida_em) : 0;
            if (x.contexto?.virada) {
              // veio do Cloudia na virada: as mensagens da equipe ficaram no Cloudia
              v = !ultLead || agora() - ultLead >= Math.min(min, 1440) * 60_000;
            } else {
              const eq = k.c ? (await bancoJson(`/rest/v1/mensagens?conversa_id=eq.${k.c.id}&direcao=eq.enviada&autor_email=like.*%40*&status=neq.falhou&select=enviada_em&order=enviada_em.desc&limit=1`).catch(() => []))?.[0] : null;
              const ultEquipe = eq?.enviada_em ? Date.parse(eq.enviada_em) : 0;
              if (ultEquipe && ultEquipe > ultLead) {
                const vence = ultEquipe + min * 60_000;
                if (agora() >= vence) v = true;
                else { await avancar(x, i, null, "aguardando", null, volta, vence + 30_000, "ativa", k.c?.id ?? null); return "esperando"; }
              } else {
                // a equipe ainda não respondeu (ou o lead falou por último): confere em 30 min
                await avancar(x, i, null, "aguardando", null, volta, agora() + 30 * 60_000, "ativa", k.c?.id ?? null);
                return "esperando";
              }
            }
          }
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

// ---------- mensagens agendadas (Central de Mensagens) ----------
type Agendada = { id: number; conversa_id: string; tipo: string; texto: string | null; modelo: any; criada_por: string | null };
export async function enviarAgendada(a: Agendada, agora = () => Date.now()) {
  const marcar = (status: string, erro: string | null, wa: string | null) => rpc("agendadas_marcar", { p_id: a.id, p_status: status, p_erro: erro, p_wa: wa });
  try {
    const c = (await bancoJson(`/rest/v1/conversas?id=eq.${a.conversa_id}&select=*`))?.[0];
    if (!c) { await marcar("falhou", "conversa não encontrada", null); return "falhou"; }
    const p = (await bancoJson(`/rest/v1/pacientes?telefone=eq.${c.telefone}&select=nome`))?.[0];
    const dados = { nome: p?.nome || c.nome_contato || c.nome_perfil || "", telefone: c.telefone };
    let corpo: any, registro: string, tipo: string;
    if (a.tipo === "texto") {
      if (!janelaAberta(c, agora())) { await marcar("falhou", "janela de 24 h fechada na hora do envio: use um modelo", null); return "falhou"; }
      registro = preencher(String(a.texto ?? ""), dados).trim();
      corpo = { type: "text", text: { body: registro.slice(0, 4096), preview_url: true } };
      tipo = "text";
    } else {
      corpo = corpoModelo(a.modelo, dados);
      registro = a.modelo?.texto_preview ? preencher(String(a.modelo.texto_preview), dados) : `[modelo ${a.modelo?.nome}]`;
      tipo = "template";
    }
    const autor = a.criada_por || "mensagem agendada";
    const r = await meta(`/${c.numero_clinica_id}/messages`, { messaging_product: "whatsapp", recipient_type: "individual", to: c.wa_id, ...corpo }, await tokenDoNumero(c.numero_clinica_id));
    if (!r.ok) {
      const erro = erroMeta(r.j);
      await registrar(c, null, tipo, registro, autor, "falhou", erro, r.j);
      await marcar("falhou", erro.slice(0, 300), null);
      return "falhou";
    }
    const waId = r.j?.messages?.[0]?.id ?? null;
    await registrar(c, waId, tipo, registro, autor, "enviada", null, r.j);
    await marcar("enviada", null, waId);
    return "enviada";
  } catch (e) {
    await marcar("falhou", String((e as Error)?.message ?? e).slice(0, 300), null).catch(() => {});
    return "falhou";
  }
}
async function rodarAgendadas(inicio: number, cont: Record<string, number>) {
  const lote: Agendada[] = await rpc("agendadas_pegar", {}).catch(() => []);
  for (const a of lote ?? []) {
    if (Date.now() - inicio > TEMPO_MAX_MS) {
      // sem tempo: devolve para a fila (ainda não tentou enviar)
      await bancoJson(`/rest/v1/mensagens_agendadas?id=eq.${a.id}&status=eq.enviando`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ status: "agendada" }) }).catch(() => {});
      continue;
    }
    const r = await enviarAgendada(a);
    cont["agendada_" + r] = (cont["agendada_" + r] ?? 0) + 1;
  }
}

// ---------- lembretes de consulta (agenda do Clinicorp) ----------
const CLINICORP_USUARIO = Deno.env.get("CLINICORP_USUARIO") ?? "";
const CLINICORP_TOKEN = Deno.env.get("CLINICORP_TOKEN") ?? "";
const CLINICORP_SUBSCRIBER_ID = Deno.env.get("CLINICORP_SUBSCRIBER_ID") ?? "";
const DIAS_SEMANA = ["domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"];
const ymd = (d: Date) => d.toISOString().slice(0, 10);

/** Dias de consulta que a rodada de hoje cobre. Véspera: amanhã; sábado também segunda; domingo nada. */
export function diasDoLembrete(tipo: "vespera" | "dia", agora: number): string[] {
  const local = new Date(agora + FUSO_MIN * 60_000);
  const base = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate());
  const dia = (n: number) => ymd(new Date(base + n * 86_400_000));
  if (tipo === "dia") return [dia(0)];
  const sem = local.getUTCDay();
  if (sem === 0) return [];
  if (sem === 6) return [dia(1), dia(2)];
  return [dia(1)];
}

/** (27/10/2026) Aquecimento: consultas que recebem o vídeo de desejo hoje (2 dias antes,
 *  sem cair no mesmo dia da véspera). Seg→qua, ter→qui, qua→sex, qui→sáb, sex→seg, sáb→ter, dom nada. */
export function diasDoAquecimento(agora: number): string[] {
  const local = new Date(agora + FUSO_MIN * 60_000);
  const base = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate());
  const sem = local.getUTCDay();
  if (sem === 0) return [];
  const n = sem === 5 || sem === 6 ? 3 : 2;
  return [ymd(new Date(base + n * 86_400_000))];
}

export type Consulta = { id: string; data: string; hora: string; nome: string; telefone: string };
/** Agendamentos válidos do Clinicorp: paciente, com celular, não desmarcado/excluído, no dia pedido. Um por telefone e dia (o mais cedo). */
const semAcento = (t: unknown) => String(t ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim();
/** Só as categorias que contêm algum dos termos (padrão: avaliação). Vazio = todas. */
export function categoriaValida(desc: unknown, termos: unknown): boolean {
  const lista = (Array.isArray(termos) ? termos : String(termos ?? "avaliação").split(/[,;\n]+/)).map(semAcento).filter(Boolean);
  if (!lista.length) return true;
  const d = semAcento(desc);
  return lista.some((t) => d.includes(t));
}
export function consultasDoClinicorp(lista: any[], dias: string[], tipo: "vespera" | "dia", agora: number, categorias: unknown = "avaliação"): Consulta[] {
  const minutosAgora = Math.floor(((agora + FUSO_MIN * 60_000) % 86_400_000) / 60_000);
  const hoje = diasDoLembrete("dia", agora)[0];
  const porChave = new Map<string, Consulta>();
  for (const a of Array.isArray(lista) ? lista : []) {
    if (a?.ItemType && a.ItemType !== "APPOINTMENT") continue;
    if (String(a?.Canceled ?? "").toUpperCase() === "X" || String(a?.Deleted ?? "").toUpperCase() === "X") continue;
    if (!categoriaValida(a?.CategoryDescription, categorias)) continue;
    const tel = String(a?.MobilePhone ?? "").replace(/\D/g, "");
    if (tel.length < 10) continue;
    const at = String(a?.AtomicDate ?? "");
    const data = /^\d{8}$/.test(at) ? `${at.slice(0, 4)}-${at.slice(4, 6)}-${at.slice(6, 8)}` : String(a?.date ?? "").slice(0, 10);
    if (!dias.includes(data)) continue;
    const hora = /^\d{1,2}:\d{2}/.test(String(a?.fromTime ?? "")) ? String(a.fromTime).slice(0, 5).padStart(5, "0") : "";
    if (tipo === "dia" && data === hoje && hora && hm(hora, 0) <= minutosAgora) continue; // já começou
    const c: Consulta = { id: String(a?.id ?? ""), data, hora, nome: String(a?.PatientName ?? "").trim(), telefone: tel };
    const k = data + "|" + tel.slice(-9);
    const ja = porChave.get(k);
    if (!ja || (c.hora && (!ja.hora || c.hora < ja.hora))) porChave.set(k, c);
  }
  return [...porChave.values()].sort((x, y) => (x.data + x.hora).localeCompare(y.data + y.hora));
}

export function variaveisDaConsulta(c: Consulta, tipo: "vespera" | "dia", agora: number): Record<string, string> {
  const [y, m, d] = c.data.split("-").map(Number);
  const sem = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  const amanha = diasDoLembrete("dia", agora + 86_400_000)[0];
  const quando = tipo === "dia" ? "hoje" : c.data === amanha ? "amanhã" : DIAS_SEMANA[sem];
  return { data: `${String(d).padStart(2, "0")}/${String(m).padStart(2, "0")}`, hora: c.hora || "-", dia_semana: DIAS_SEMANA[sem], quando };
}

async function agendaClinicorp(de: string, ate: string): Promise<any[]> {
  const u = new URL("https://api.clinicorp.com/rest/v1/appointment/list");
  u.searchParams.set("from", de);
  u.searchParams.set("to", ate);
  if (CLINICORP_SUBSCRIBER_ID) u.searchParams.set("subscriber_id", CLINICORP_SUBSCRIBER_ID);
  const r = await fetch(u, { headers: { Authorization: "Basic " + btoa(CLINICORP_USUARIO + ":" + CLINICORP_TOKEN), Accept: "application/json" } });
  const t = await r.text();
  if (!r.ok) throw new Error(`Clinicorp ${r.status}: ${t.slice(0, 200)}`);
  const j = t ? JSON.parse(t) : [];
  return Array.isArray(j) ? j : (j?.appointments ?? j?.data ?? []);
}

async function enviarLembrete(c: Consulta, tipo: TipoLembrete, cfg: any, agora: number, modeloTipo?: any): Promise<string> {
  const res = await rpc("lembrete_reservar", { p_data: c.data, p_tipo: tipo, p_tel: c.telefone, p_nome: c.nome, p_hora: c.hora, p_cid: c.id });
  if (!res) return "ja_enviado";
  const marcar = (st: string, erro: string | null, wa: string | null, conv: string | null) =>
    rpc("lembrete_marcar", { p_id: res.id, p_status: st, p_erro: erro, p_wa: wa, p_conversa: conv });
  try {
    const numero = String(cfg.numero_clinica_id || WA_PHONE_NUMBER_ID);
    const convId = await rpc("automacao_conversa", { p_numero: numero, p_telefone: res.telefone });
    const conv = (await bancoJson(`/rest/v1/conversas?id=eq.${convId}&select=*`))?.[0];
    const p = (await bancoJson(`/rest/v1/pacientes?telefone=eq.${res.telefone}&select=nome`))?.[0];
    const dados = { nome: c.nome || p?.nome || conv?.nome_contato || conv?.nome_perfil || "", telefone: res.telefone, extra: variaveisDaConsulta(c, baseLembrete(tipo), agora) };
    const modelo = modeloTipo ?? cfg[tipo].modelo;
    const corpo = corpoModelo(modelo, dados);
    const registro = modelo?.texto_preview ? preencher(String(modelo.texto_preview), dados) : `[modelo ${modelo?.nome}]`;
    const autor = tipo === "dia" ? "Lembrete do dia" : tipo === "aquecimento" ? "Aquecimento (2 dias antes)" : "Lembrete de véspera" + (tipo === "vespera" ? "" : tipo === "vespera2" ? " (2ª)" : " (3ª)");
    const r = await meta(`/${conv.numero_clinica_id}/messages`, { messaging_product: "whatsapp", recipient_type: "individual", to: conv.wa_id, ...corpo }, await tokenDoNumero(conv.numero_clinica_id));
    if (!r.ok) {
      const erro = erroMeta(r.j);
      await registrar(conv, null, "template", registro, autor, "falhou", erro, r.j);
      await marcar("falhou", erro.slice(0, 300), null, conv.id);
      return "falhou";
    }
    const waId = r.j?.messages?.[0]?.id ?? null;
    await registrar(conv, waId, "template", registro, autor, "enviada", null, r.j);
    await marcar("enviado", null, waId, conv.id);
    return "enviado";
  } catch (e) {
    await marcar("falhou", String((e as Error)?.message ?? e).slice(0, 300), null, null).catch(() => {});
    return "falhou";
  }
}

// (25/10/2026) véspera em até 3 horários (vespera, vespera2, vespera3) + no dia.
// A 2ª e a 3ª confirmação só saem para quem ainda não confirmou nem respondeu
// depois da anterior. No sábado (véspera de segunda) a 1ª usa "modelo_sabado"
// (ex.: confirmarsegunda) e a 2ª e a 3ª não saem, porque o texto diz "amanhã".
// (27/10/2026) "aquecimento": vídeo de desejo 2 dias antes (modelo com vídeo). Na 1ª confirmação,
// quem NÃO recebeu o aquecimento (agendou em cima da hora) recebe "modelo_video" no lugar do modelo normal.
type TipoLembrete = "dia" | "vespera" | "vespera2" | "vespera3" | "aquecimento";
const baseLembrete = (t: TipoLembrete): "vespera" | "dia" => (t === "dia" ? "dia" : "vespera");
const HORA_PADRAO: Record<TipoLembrete, number> = { dia: 8 * 60 + 30, vespera: 10 * 60 + 30, vespera2: 13 * 60, vespera3: 15 * 60, aquecimento: 11 * 60 + 30 };
async function recebeuAquecimento(c: Consulta): Promise<boolean> {
  const ls: any[] = (await bancoJson(`/rest/v1/lembretes_consulta?data=eq.${c.data}&telefone=eq.${telCurto(c.telefone)}&tipo=eq.aquecimento&status=eq.enviado&select=id&limit=1`).catch(() => [])) ?? [];
  return ls.length > 0;
}
const telCurto = (t: string) => { let x = String(t ?? "").replace(/\D/g, ""); if (x.length >= 12 && x.startsWith("55")) x = x.slice(2); return x; };

/** 2ª/3ª confirmação: já confirmou, pediu para cancelar ou respondeu depois da anterior? */
async function jaRespondeuVespera(c: Consulta, tipo: TipoLembrete, cfg: any, agora: number): Promise<boolean> {
  if (tipo !== "vespera2" && tipo !== "vespera3") return false;
  // a 1ª confirmação pode ter saído por fora (ex.: Cloudia, enquanto não é desligado):
  // quem mandou mensagem hoje depois do horário da 1ª também não recebe a próxima
  const local = new Date(agora + FUSO_MIN * 60_000);
  const h1 = hm(cfg?.vespera?.hora, HORA_PADRAO.vespera);
  const ref1 = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate()) + h1 * 60_000 - FUSO_MIN * 60_000;
  const cvs: any[] = (await bancoJson(`/rest/v1/conversas?telefone=like.*${telCurto(c.telefone).slice(-9)}&select=ultima_recebida_em`).catch(() => [])) ?? [];
  if (cvs.some((x) => x.ultima_recebida_em && Date.parse(x.ultima_recebida_em) > ref1 && ref1 < agora)) return true;
  const ant = tipo === "vespera3" ? "vespera,vespera2" : "vespera";
  const ls: any[] = (await bancoJson(`/rest/v1/lembretes_consulta?data=eq.${c.data}&telefone=eq.${telCurto(c.telefone)}&tipo=in.(${ant})&status=eq.enviado&select=enviado_em,resposta,conversa_id`).catch(() => [])) ?? [];
  if (!ls.length) return false; // não recebeu a anterior (ex.: agendou depois): manda
  if (ls.some((l) => l.resposta)) return true;
  const primeiro = Math.min(...ls.map((l) => Date.parse(l.enviado_em) || Infinity));
  const conv = ls.find((l) => l.conversa_id)?.conversa_id;
  if (!conv || !isFinite(primeiro)) return false;
  const cv = (await bancoJson(`/rest/v1/conversas?id=eq.${conv}&select=ultima_recebida_em`).catch(() => []))?.[0];
  return !!cv?.ultima_recebida_em && Date.parse(cv.ultima_recebida_em) > primeiro;
}

export async function rodarLembretes(inicio: number, cont: Record<string, number>, agora = Date.now()) {
  const cfg = (await bancoJson(`/rest/v1/configuracoes?chave=eq.lembretes_consulta&select=valor`).catch(() => null))?.[0]?.valor;
  if (!cfg?.ligado) return;
  await rpc("lembretes_limpar_presos", {}).catch(() => {});
  const local = new Date(agora + FUSO_MIN * 60_000);
  const hoje = ymd(local);
  const minutos = local.getUTCHours() * 60 + local.getUTCMinutes();
  const teste = cfg.modo_teste !== false;
  const telsTeste = new Set((Array.isArray(cfg.telefones_teste) ? cfg.telefones_teste : []).map((t: unknown) => String(t).replace(/\D/g, "").slice(-9)).filter(Boolean));
  const sabado = local.getUTCDay() === 6;
  for (const tipo of ["dia", "vespera", "vespera2", "vespera3", "aquecimento"] as const) {
    const c = cfg[tipo];
    if (!c?.modelo?.nome || c.pausado === true) continue;
    const base = baseLembrete(tipo);
    if (sabado && (tipo === "vespera2" || tipo === "vespera3") && c.no_sabado !== true) continue;
    const modeloTipo = sabado && base === "vespera" && c.modelo_sabado?.nome ? c.modelo_sabado : c.modelo;
    const h = hm(c.hora, HORA_PADRAO[tipo]);
    // roda nas horas depois do horário (se o motor atrasar, ainda manda), sem encostar na próxima confirmação
    const folga = Number(c.janela_min) || (tipo === "vespera" || tipo === "vespera2" ? 120 : 180);
    if (minutos < h || minutos > h + folga) continue;
    const rod = (await bancoJson(`/rest/v1/lembretes_rodadas?dia=eq.${hoje}&tipo=eq.${tipo}&select=status`).catch(() => null))?.[0];
    if (rod?.status === "concluida") continue;
    let dias = tipo === "aquecimento" ? diasDoAquecimento(agora) : diasDoLembrete(base, agora);
    const fake = teste && cfg.consulta_teste?.telefone ? cfg.consulta_teste : null;
    if (!dias.length && fake && base === "vespera") dias = [ymd(new Date(Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate() + 1)))];
    if (!dias.length) { await rpc("lembrete_rodada", { p_dia: hoje, p_tipo: tipo, p_status: "concluida", p_consultas: 0, p_enviados: 0, p_falhas: 0, p_erro: null }); continue; }
    if (!CLINICORP_USUARIO || !CLINICORP_TOKEN) {
      await rpc("lembrete_rodada", { p_dia: hoje, p_tipo: tipo, p_status: "erro", p_consultas: 0, p_enviados: 0, p_falhas: 0, p_erro: "faltam os segredos CLINICORP_USUARIO e CLINICORP_TOKEN na Supabase" });
      continue;
    }
    let lista: Consulta[];
    try {
      lista = consultasDoClinicorp(await agendaClinicorp(dias[0], dias[dias.length - 1]), dias, base, agora, cfg.categorias ?? "avaliação");
    } catch (e) {
      await rpc("lembrete_rodada", { p_dia: hoje, p_tipo: tipo, p_status: "erro", p_consultas: 0, p_enviados: 0, p_falhas: 0, p_erro: String((e as Error)?.message ?? e).slice(0, 300) });
      continue;
    }
    if (teste) lista = lista.filter((x) => telsTeste.has(x.telefone.slice(-9)));
    // teste sem consulta de verdade: uma consulta de mentira para o telefone de teste
    if (fake && !lista.some((x) => x.telefone.slice(-9) === String(fake.telefone).replace(/\D/g, "").slice(-9))) {
      lista.push({ id: "teste", data: dias[0], hora: base === "dia" ? "23:59" : String(fake.hora || "10:00"), nome: String(fake.nome || "Teste"), telefone: String(fake.telefone).replace(/\D/g, "") });
    }
    let enviados = 0, falhas = 0, completo = true;
    for (const x of lista) {
      if (Date.now() - inicio > TEMPO_MAX_MS) { completo = false; break; }
      if (await jaRespondeuVespera(x, tipo, cfg, agora)) { cont["lembrete_ja_respondeu"] = (cont["lembrete_ja_respondeu"] ?? 0) + 1; continue; }
      // 1ª confirmação com vídeo para quem não recebeu o aquecimento (agendou em cima da hora)
      let modeloX = modeloTipo;
      if (tipo === "vespera" && c.modelo_video?.nome && c.video_pausado !== true && !(await recebeuAquecimento(x))) modeloX = c.modelo_video;
      const r = await enviarLembrete(x, tipo, cfg, agora, modeloX);
      if (r === "enviado") enviados++;
      if (r === "falhou") falhas++;
      cont["lembrete_" + r] = (cont["lembrete_" + r] ?? 0) + 1;
    }
    await rpc("lembrete_rodada", { p_dia: hoje, p_tipo: tipo, p_status: completo ? "concluida" : "rodando", p_consultas: lista.length, p_enviados: enviados, p_falhas: falhas, p_erro: null });
  }
}


// ---------- respostas aos lembretes (confirmar / cancelar) ----------
async function confirmarNoClinicorp(id: string): Promise<void> {
  // POST /appointment/confirm_appointment { subscriber_id, id } (API do Clinicorp)
  const sub = CLINICORP_SUBSCRIBER_ID || CLINICORP_USUARIO;
  const u = new URL("https://api.clinicorp.com/rest/v1/appointment/confirm_appointment");
  u.searchParams.set("subscriber_id", sub);
  const r = await fetch(u, {
    method: "POST",
    headers: { Authorization: "Basic " + btoa(CLINICORP_USUARIO + ":" + CLINICORP_TOKEN), Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify({ subscriber_id: sub, id: Number(id) }),
  });
  if (!r.ok) throw new Error(`Clinicorp ${r.status}: ${(await r.text()).slice(0, 200)}`);
}

async function porTag(conversa: string, nome: string) {
  if (!nome) return;
  const t = (await bancoJson(`/rest/v1/wa_tags?nome=ilike.${encodeURIComponent(nome)}&select=id&limit=1`).catch(() => []))?.[0];
  if (!t?.id) return;
  await banco(`/rest/v1/conversa_tags`, { method: "POST", headers: { Prefer: "resolution=ignore-duplicates,return=minimal" }, body: JSON.stringify({ conversa_id: conversa, tag_id: t.id }) }).catch(() => {});
}

export async function rodarRespostasLembrete(cont: Record<string, number>) {
  const lote: any[] = await rpc("lembrete_respostas_pegar", {}).catch(() => []);
  if (!lote?.length) return;
  const cfg = (await bancoJson(`/rest/v1/configuracoes?chave=eq.lembretes_consulta&select=valor`).catch(() => null))?.[0]?.valor ?? {};
  for (const x of lote) {
    let ok = true, erro: string | null = null, confirmado: boolean | null = null;
    try {
      const c = (await bancoJson(`/rest/v1/conversas?id=eq.${x.conversa_id}&select=*`))?.[0];
      if (x.acao === "confirmar") {
        if (cfg.confirmar_no_clinicorp !== false && x.clinicorp_id && x.clinicorp_id !== "teste") {
          try { await confirmarNoClinicorp(String(x.clinicorp_id)); confirmado = true; }
          catch (e) { confirmado = false; erro = "não confirmou no Clinicorp: " + String((e as Error)?.message ?? e).slice(0, 200); }
        }
        await porTag(x.conversa_id, cfg.tag_confirmou ?? "confirmou lembrete");
      } else {
        await porTag(x.conversa_id, cfg.tag_cancelar ?? "cancelar consulta");
        // vai para a fila da equipe remarcar
        await banco(`/rest/v1/conversas?id=eq.${x.conversa_id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ status: "aberta", robo_ligado: false }) });
      }
      const texto = String((x.acao === "confirmar" ? cfg.resposta_confirmou : cfg.resposta_cancelar) ?? "").trim();
      if (texto && c && janelaAberta(c)) {
        const r = await meta(`/${c.numero_clinica_id}/messages`, { messaging_product: "whatsapp", recipient_type: "individual", to: c.wa_id, type: "text", text: { body: texto } }, await tokenDoNumero(c.numero_clinica_id));
        await registrar(c, r.ok ? (r.j?.messages?.[0]?.id ?? null) : null, "text", texto, "Lembrete: resposta automática", r.ok ? "enviada" : "falhou", r.ok ? null : erroMeta(r.j), r.j);
      }
    } catch (e) {
      ok = false; erro = String((e as Error)?.message ?? e).slice(0, 300);
    }
    await rpc("lembrete_resposta_feita", { p_id: x.id, p_ok: ok, p_erro: erro, p_confirmado: confirmado }).catch(() => {});
    cont["lembrete_resposta_" + x.acao] = (cont["lembrete_resposta_" + x.acao] ?? 0) + 1;
  }
}

export async function handler(req: Request): Promise<Response> {
  const json = (c: unknown, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { "Content-Type": "application/json" } });
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);
  const chave = req.headers.get("x-motor-chave") ?? "";
  if (!chave || !(await rpc("automacao_conferir_chave", { p_chave: chave }))) return json({ ok: false, erro: "chave do motor inválida" }, 401);
  // conferência da conexão com o Clinicorp (só conta, não envia nada)
  const pedido = await req.json().catch(() => ({}));
  if (pedido?.acao === "testar_clinicorp") {
    if (!CLINICORP_USUARIO || !CLINICORP_TOKEN) return json({ ok: false, erro: "faltam os segredos CLINICORP_USUARIO e CLINICORP_TOKEN" });
    try {
      const dias = [...diasDoLembrete("dia", Date.now()), ...diasDoLembrete("dia", Date.now() + 86_400_000)];
      const bruto = await agendaClinicorp(dias[0], dias[1]);
      const cfgL = (await bancoJson(`/rest/v1/configuracoes?chave=eq.lembretes_consulta&select=valor`).catch(() => null))?.[0]?.valor;
      const validas = consultasDoClinicorp(bruto, dias, "vespera", Date.now(), cfgL?.categorias ?? "avaliação");
      const porDia: Record<string, number> = {};
      for (const c of validas) porDia[c.data] = (porDia[c.data] ?? 0) + 1;
      const categorias: Record<string, number> = {};
      for (const a of bruto) { const c = String(a?.CategoryDescription ?? "(sem categoria)"); categorias[c] = (categorias[c] ?? 0) + 1; }
      return json({ ok: true, itens_na_agenda: bruto.length, lembretes_por_dia: porDia, categorias });
    } catch (e) {
      return json({ ok: false, erro: String((e as Error)?.message ?? e).slice(0, 300) });
    }
  }
  // chave geral pausada: só as automações em modo teste andam
  const geral = await chaveGeralLigada();

  const inicio = Date.now();
  const cont: Record<string, number> = {};
  // disparos em massa primeiro (não dependem da chave geral: cada um é decisão da equipe)
  // mensagens agendadas pela equipe primeiro (hora marcada), depois disparos em massa
  await rodarAgendadas(inicio, cont).catch((e) => { cont.agendada_erro_motor = 1; console.error("agendadas", e); });
  await rodarRespostasLembrete(cont).catch((e) => { cont.lembrete_resposta_erro_motor = 1; console.error("respostas lembrete", e); });
  await rodarLembretes(inicio, cont).catch((e) => { cont.lembrete_erro_motor = 1; console.error("lembretes", e); });
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
