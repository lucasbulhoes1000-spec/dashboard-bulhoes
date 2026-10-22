// ============================================================
// whatsapp-agente — o Agente de IA do CRM Bulhões (Claude, da Anthropic)
// 22/10/2026
//
// Igual ao "Agentes de IA" do Cloudia: a gestão escreve instruções e base de
// conhecimento na tela Agente de IA (tabela agente_ia) e liga:
//   • Habilitar IA       → responde sozinho as conversas com o robô ligado
//   • Assistente Virtual → sugestão de resposta para a equipe (Central)
//   • Resumos            → "Resumir com IA" (Central)
//
// Chamadas:
//   • Interna (webhook na hora e agendador a cada minuto), cabeçalho
//     x-motor-chave: { acao: "fila" } → responde as conversas da agente_fila.
//   • Pelo CRM (login da equipe):
//       status  {}                         → a chave está configurada? (todos)
//       testar  { historico, rascunho? }   → (gestão) simula sem enviar nada
//       sugerir { conversa_id }            → texto sugerido (Assistente Virtual)
//       resumir { conversa_id }            → resumo salvo na conversa (Resumos)
//
// Ferramentas que o agente pode usar: enviar_imagem (lista da tela) e
// transferir_para_humano (desliga o robô da conversa e manda para a fila).
//
// Segredos: ANTHROPIC_API_KEY (chave da Anthropic), WA_TOKEN e
// WA_PHONE_NUMBER_ID (mesmos das outras funções).
// "Verify JWT" DESLIGADO nesta função (o agendador usa a chave do motor;
// o CRM manda o login, que a função confere).
// ============================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const WA_TOKEN = Deno.env.get("WA_TOKEN") ?? "";
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const ANTHROPIC_URL = Deno.env.get("ANTHROPIC_URL") ?? "https://api.anthropic.com/v1/messages";
const GRAPH = "https://graph.facebook.com/" + (Deno.env.get("WA_GRAPH_VERSION") ?? "v23.0");
const ORIGENS = (Deno.env.get("CRM_ORIGENS") ?? "https://dashboard-bulhoes.vercel.app").split(",").map((s) => s.trim());
const TEMPO_MAX_MS = 100_000;
const JANELA_MS = 24 * 60 * 60 * 1000;
const FUSO_MIN = -180;

export const MODELOS: Record<string, string> = {
  "claude-haiku-5-5": "Claude Haiku 5.5 (rápido e econômico)",
  "claude-sonnet-5-5": "Claude Sonnet 5.5 (equilibrado)",
  "claude-opus-5-5": "Claude Opus 5.5 (mais inteligente)",
};
export const PERSONALIDADES: Record<string, string> = {
  "Empático": "Acolhedora, calorosa e atenciosa. Mostra que entendeu o que a pessoa sente antes de seguir.",
  "Profissional": "Cordial, clara e segura, com linguagem cuidada e sem excesso de informalidade.",
  "Descontraído": "Leve, simpática e próxima, como uma conversa entre conhecidos, sem perder o respeito.",
  "Objetivo": "Direta e prática. Respostas curtas, sem rodeios, sempre com o próximo passo claro.",
  "Formal": "Tratamento formal e respeitoso, frases completas e vocabulário mais elaborado.",
};

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
const registro = (r: Record<string, unknown>) =>
  banco("/rest/v1/agente_registros", { method: "POST", headers: { Prefer: "return=minimal" }, body: JSON.stringify(r) }).catch(() => {});

// ---------- Meta ----------
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
async function enviarMeta(c: any, corpo: any) {
  const r = await fetch(`${GRAPH}/${c.numero_clinica_id}/messages`, {
    method: "POST",
    headers: { Authorization: "Bearer " + (await tokenDoNumero(c.numero_clinica_id)), "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", recipient_type: "individual", to: c.wa_id, ...corpo }),
  });
  const j = await r.json().catch(() => ({}));
  const e = j?.error ?? {};
  return { ok: r.ok, id: j?.messages?.[0]?.id ?? null, erro: r.ok ? null : ([e.message, e.error_data?.details].filter(Boolean).join(" — ") || "erro da Meta"), j };
}
async function registrarEnviada(c: any, waId: string | null, tipo: string, texto: string, autor: string, erro: string | null, bruto: unknown) {
  await rpc("wa_registrar_enviada", {
    p_conversa: c.id, p_wa_message_id: waId, p_tipo: tipo, p_texto: texto, p_autor: autor,
    p_status: erro ? "falhou" : "enviada", p_erro: erro, p_bruto: bruto,
  });
}
export function janelaAberta(c: { ultima_recebida_em?: string | null; janela_gratis_ate?: string | null }, agora = Date.now()): boolean {
  const ultima = c?.ultima_recebida_em ? Date.parse(c.ultima_recebida_em) : 0;
  const gratis = c?.janela_gratis_ate ? Date.parse(c.janela_gratis_ate) : 0;
  return agora - ultima < JANELA_MS || gratis > agora;
}

// ---------- montagem do pedido ao Claude ----------
const DIAS = ["domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"];
export function agoraBrasilia(agora = Date.now()): string {
  const d = new Date(agora + FUSO_MIN * 60_000);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${DIAS[d.getUTCDay()]}, ${p(d.getUTCDate())}/${p(d.getUTCMonth() + 1)}/${d.getUTCFullYear()}, ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`;
}

export function montarSistema(a: any, imagens: any[], ctx: { nome?: string; etapa?: string | null; origem?: string | null }, agora = Date.now()): string {
  const partes: string[] = [];
  if (String(a.instrucoes ?? "").trim()) partes.push(String(a.instrucoes).trim());
  const pers = PERSONALIDADES[a.personalidade] ?? "";
  if (pers) partes.push(`# Personalidade\n${a.personalidade}: ${pers}`);
  if (String(a.base_conhecimento ?? "").trim()) partes.push(`# Base de conhecimento\n${String(a.base_conhecimento).trim()}`);
  if (imagens.length) {
    partes.push("# Imagens que você pode enviar (ferramenta enviar_imagem)\n" +
      imagens.map((i) => `- "${i.nome}"${i.quando_usar ? ": " + i.quando_usar : ""}`).join("\n"));
  }
  const info = [`Agora: ${agoraBrasilia(agora)} (horário de Brasília).`];
  if (ctx.nome) info.push(`Nome do contato no WhatsApp/CRM: ${ctx.nome}.`);
  if (ctx.etapa) info.push(`Etapa no CRM: ${ctx.etapa}.`);
  if (ctx.origem) info.push(`Origem: ${ctx.origem}.`);
  partes.push("# Sobre esta conversa\n" + info.join("\n"));
  partes.push(
    "# Como responder\n" +
      "Você está no WhatsApp, falando com o paciente em nome da clínica. " +
      `Separe cada mensagem com uma linha em branco. No máximo ${a.max_blocos ?? 4} mensagens por resposta. ` +
      "Escreva só o texto que vai para o paciente, sem comentários sobre o que você está fazendo. " +
      (imagens.length ? "Para mandar uma imagem, use a ferramenta enviar_imagem; nunca diga que mandou sem usar a ferramenta. " : "") +
      "Quando as instruções mandarem passar para a equipe, ou quando você não souber responder com segurança, use a ferramenta transferir_para_humano. " +
      "Mensagens entre colchetes, como [áudio], são mídias que você não consegue ver nem ouvir.",
  );
  return partes.join("\n\n");
}

export function ferramentas(imagens: any[]) {
  const t: any[] = [{
    name: "transferir_para_humano",
    description: "Passa a conversa para a equipe da clínica e para de responder automaticamente. Use quando as instruções pedirem ou quando não souber responder com segurança.",
    input_schema: { type: "object", properties: { motivo: { type: "string", description: "Por que está passando (ex.: pediu horários, dor forte, reclamação)" } }, required: ["motivo"] },
  }];
  if (imagens.length) {
    t.push({
      name: "enviar_imagem",
      description: "Envia ao paciente uma das imagens cadastradas pela clínica.",
      input_schema: { type: "object", properties: { nome: { type: "string", enum: imagens.map((i) => i.nome) } }, required: ["nome"] },
    });
  }
  return t;
}

/** Texto de uma mensagem do banco para o histórico do agente. */
export function textoDaMensagem(m: any): string {
  const t = String(m.texto ?? "").trim();
  switch (m.tipo) {
    case "text": case "button": case "interactive": return t;
    case "image": return "[foto]" + (t && !/^📷/.test(t) ? " " + t : "");
    case "audio": case "voice": return "[áudio]";
    case "video": return "[vídeo]" + (t && !/^🎥/.test(t) ? " " + t : "");
    case "document": return "[documento] " + t.replace(/^📄\s*/, "");
    case "sticker": return "[figurinha]";
    case "template": return t || "[modelo de mensagem]";
    case "reaction": return "";
    default: return t || `[${m.tipo}]`;
  }
}

/** Histórico em turnos alternados (paciente = user, clínica = assistant). Começa e termina como o Claude exige. */
export function montarHistorico(msgs: any[], terminarComPaciente = true): { role: string; content: string }[] {
  const out: { role: string; content: string }[] = [];
  for (const m of msgs) {
    const txt = textoDaMensagem(m);
    if (!txt) continue;
    const role = m.direcao === "recebida" ? "user" : "assistant";
    const ult = out[out.length - 1];
    if (ult && ult.role === role) ult.content += "\n" + txt;
    else out.push({ role, content: txt });
  }
  if (out.length && out[0].role === "assistant") out.unshift({ role: "user", content: "(a clínica iniciou a conversa)" });
  if (terminarComPaciente) while (out.length && out[out.length - 1].role === "assistant") out.pop();
  return out;
}

export function dividirBlocos(texto: string, max: number): string[] {
  return String(texto ?? "").split(/\n\s*\n/).map((b) => b.trim()).filter(Boolean).slice(0, Math.max(1, max));
}

// ---------- Claude ----------
type Uso = { entrada: number; saida: number };
async function chamarClaude(modelo: string, sistema: string, mensagens: any[], tools: any[], criatividade: number, maxTokens = 1024) {
  if (!ANTHROPIC_API_KEY) throw new Error("falta a chave da Anthropic (segredo ANTHROPIC_API_KEY na Supabase)");
  const corpo: any = { model: modelo, max_tokens: maxTokens, system: sistema, messages: mensagens, temperature: Math.max(0, Math.min(1, Number(criatividade))) };
  if (tools.length) corpo.tools = tools;
  const pedir = async (c: any) => {
    const r = await fetch(ANTHROPIC_URL, {
      method: "POST",
      headers: { "x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify(c),
    });
    const j = await r.json().catch(() => ({}));
    return { ok: r.ok, status: r.status, j };
  };
  let r = await pedir(corpo);
  // alguns modelos não aceitam "temperature": tenta de novo sem
  if (!r.ok && r.status === 400 && /temperature/i.test(JSON.stringify(r.j))) { delete corpo.temperature; r = await pedir(corpo); }
  if (!r.ok) throw new Error(`Anthropic ${r.status}: ${String(r.j?.error?.message ?? JSON.stringify(r.j)).slice(0, 300)}`);
  return r.j;
}

export type Acao = { tipo: "texto"; texto: string } | { tipo: "imagem"; nome: string; link: string } | { tipo: "transferir"; motivo: string };

/**
 * Conversa com o Claude até ele terminar (no máximo 4 voltas), devolvendo as ações em ordem.
 * "executar" é chamado a cada ação (enviar de verdade ou só anotar, no teste); se devolver false, para.
 */
export async function gerarResposta(a: any, imagens: any[], sistema: string, historico: any[], executar: (x: Acao) => Promise<boolean>) {
  const tools = ferramentas(imagens);
  const msgs: any[] = historico.map((h) => ({ role: h.role, content: h.content }));
  const uso: Uso = { entrada: 0, saida: 0 };
  let blocos = 0, transferiu = false;
  const max = Number(a.max_blocos ?? 4);
  for (let volta = 0; volta < 4; volta++) {
    const j = await chamarClaude(a.modelo, sistema, msgs, tools, a.criatividade);
    uso.entrada += Number(j?.usage?.input_tokens ?? 0);
    uso.saida += Number(j?.usage?.output_tokens ?? 0);
    const resultados: any[] = [];
    for (const b of j?.content ?? []) {
      if (b.type === "text") {
        for (const t of dividirBlocos(b.text, max - blocos)) {
          if (blocos >= max) break;
          blocos++;
          if (!(await executar({ tipo: "texto", texto: t }))) return { uso, transferiu, parou: true };
        }
      } else if (b.type === "tool_use") {
        if (b.name === "transferir_para_humano") {
          transferiu = true;
          await executar({ tipo: "transferir", motivo: String(b.input?.motivo ?? "") });
          resultados.push({ type: "tool_result", tool_use_id: b.id, content: "Conversa passada para a equipe. Não escreva mais nada." });
        } else if (b.name === "enviar_imagem") {
          const img = imagens.find((i) => i.nome === b.input?.nome);
          if (img && (await executar({ tipo: "imagem", nome: img.nome, link: img.link }))) {
            resultados.push({ type: "tool_result", tool_use_id: b.id, content: "Imagem enviada." });
          } else {
            resultados.push({ type: "tool_result", tool_use_id: b.id, content: "Não foi possível enviar essa imagem.", is_error: true });
          }
        } else {
          resultados.push({ type: "tool_result", tool_use_id: b.id, content: "Ferramenta desconhecida.", is_error: true });
        }
      }
    }
    if (transferiu || j?.stop_reason !== "tool_use" || !resultados.length) break;
    msgs.push({ role: "assistant", content: j.content });
    msgs.push({ role: "user", content: resultados });
  }
  return { uso, transferiu, parou: false };
}

// ---------- dados da conversa ----------
async function carregarAgente() {
  const [a, imgs] = await Promise.all([
    bancoJson(`/rest/v1/agente_ia?id=eq.1&select=*`),
    bancoJson(`/rest/v1/agente_imagens?select=nome,quando_usar,link&order=ordem,id`),
  ]);
  return { a: a?.[0], imagens: imgs ?? [] };
}
async function carregarConversa(id: string) {
  const c = (await bancoJson(`/rest/v1/conversas?id=eq.${id}&select=*`))?.[0];
  if (!c) return null;
  const [p, msgs] = await Promise.all([
    bancoJson(`/rest/v1/pacientes?telefone=eq.${c.telefone}&select=nome,etapa,origem`).catch(() => []),
    bancoJson(`/rest/v1/mensagens?conversa_id=eq.${id}&select=direcao,tipo,texto,autor_email,enviada_em&order=enviada_em.desc&limit=40`),
  ]);
  const pac = p?.[0];
  return { c, ctx: { nome: pac?.nome || c.nome_contato || c.nome_perfil || "", etapa: pac?.etapa ?? null, origem: pac?.origem ?? null }, msgs: (msgs ?? []).reverse() };
}
const espera = (ms: number) => new Promise((r) => setTimeout(r, ms));

// ---------- responder (fila) ----------
export async function responder(conversaId: string, versao: number, pausa = espera): Promise<string> {
  const concluir = () => rpc("agente_concluir", { p_conversa: conversaId, p_versao: versao }).catch(() => {});
  try {
    const { a, imagens } = await carregarAgente();
    if (!a?.habilitar_ia) { await concluir(); return "desligado"; }
    const dados = await carregarConversa(conversaId);
    if (!dados || !dados.c.robo_ligado) { await concluir(); return "sem_robo"; }
    const { c, ctx, msgs } = dados;
    const hist = montarHistorico(msgs);
    if (!hist.length || msgs[msgs.length - 1]?.direcao !== "recebida") { await concluir(); return "nada"; }
    if (!janelaAberta(c)) { await concluir(); return "sem_janela"; }
    const autor = "IA: " + (a.nome || "Agente");
    let primeira = true, enviados: string[] = [];
    const executar = async (x: Acao) => {
      if (primeira) {
        primeira = false;
        // o paciente mandou mais alguma coisa enquanto o agente pensava? responde de novo com tudo
        const v = await rpc("agente_versao", { p_conversa: conversaId }).catch(() => versao);
        if (v !== versao) return false;
      } else {
        await pausa(Math.min(4000, 1200 + (x.tipo === "texto" ? x.texto.length * 15 : 1500)));
      }
      if (x.tipo === "texto") {
        const r = await enviarMeta(c, { type: "text", text: { body: x.texto.slice(0, 4096), preview_url: true } });
        await registrarEnviada(c, r.id, "text", x.texto, autor, r.erro, r.j);
        enviados.push(x.texto);
        return r.ok;
      }
      if (x.tipo === "imagem") {
        const r = await enviarMeta(c, { type: "image", image: { link: x.link } });
        await registrarEnviada(c, r.id, "image", "📷 " + x.nome, autor, r.erro, { ...r.j, link: x.link });
        enviados.push("[imagem: " + x.nome + "]");
        return r.ok;
      }
      await rpc("agente_transferir", { p_conversa: conversaId, p_motivo: x.motivo });
      return true;
    };
    const res = await gerarResposta(a, imagens, montarSistema(a, imagens, ctx), hist, executar);
    if (res.parou && !enviados.length) { await concluir(); return "refazer"; }
    await registro({ conversa_id: conversaId, tipo: "resposta", detalhe: enviados.join("\n\n").slice(0, 4000), modelo: a.modelo, tokens_entrada: res.uso.entrada, tokens_saida: res.uso.saida, autor: "agente" });
    await concluir();
    return res.transferiu ? "transferiu" : "respondeu";
  } catch (e) {
    await registro({ conversa_id: conversaId, tipo: "erro", detalhe: String((e as Error)?.message ?? e).slice(0, 1000), autor: "agente" });
    await concluir();
    return "erro";
  }
}

export async function rodarFila(inicio = Date.now(), pausa = espera) {
  const cont: Record<string, number> = {};
  while (Date.now() - inicio < TEMPO_MAX_MS) {
    const lote: { conversa_id: string; versao: number }[] = await rpc("agente_pegar", { p_limite: 10 }).catch(() => []);
    if (lote?.length) {
      const rs = await Promise.all(lote.map((x) => responder(x.conversa_id, x.versao, pausa)));
      for (const r of rs) cont[r] = (cont[r] ?? 0) + 1;
      continue;
    }
    // ninguém pronto: espera a próxima (se for logo), senão termina
    const prox = await rpc("agente_proxima", {}).catch(() => null);
    if (!prox) break;
    const falta = Date.parse(prox) - Date.now();
    if (falta > 45_000 || Date.now() - inicio + falta > TEMPO_MAX_MS) break;
    await pausa(Math.max(300, falta + 200));
  }
  return cont;
}

// ---------- ações da tela ----------
function cors(req: Request): Record<string, string> {
  const origem = req.headers.get("origin") ?? "";
  return {
    "Access-Control-Allow-Origin": ORIGENS.includes(origem) ? origem : ORIGENS[0],
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
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

async function testar(dados: any) {
  const { a: salvo, imagens } = await carregarAgente();
  const a = { ...salvo, ...(dados?.rascunho ?? {}) };
  const hist = montarHistorico((dados?.historico ?? []).map((h: any) => ({ direcao: h.de === "paciente" ? "recebida" : "enviada", tipo: "text", texto: String(h.texto ?? "") })));
  if (!hist.length) throw new Error("escreva uma mensagem como se fosse o paciente");
  const acoes: Acao[] = [];
  const res = await gerarResposta(a, imagens, montarSistema(a, imagens, { nome: dados?.nome || "" }), hist, async (x) => { acoes.push(x); return true; });
  await registro({ tipo: "teste", detalhe: acoes.map((x) => x.tipo === "texto" ? x.texto : x.tipo === "imagem" ? "[imagem: " + x.nome + "]" : "[transferiu: " + x.motivo + "]").join("\n\n").slice(0, 2000), modelo: a.modelo, tokens_entrada: res.uso.entrada, tokens_saida: res.uso.saida, autor: dados?._autor });
  return { acoes, uso: res.uso };
}

async function sugerir(conversaId: string, autor: string) {
  const { a, imagens } = await carregarAgente();
  if (!a?.assistente_virtual) throw new Error("o Assistente Virtual está desligado na tela Agente de IA");
  const dados = await carregarConversa(conversaId);
  if (!dados) throw new Error("conversa não encontrada");
  const hist = montarHistorico(dados.msgs, false);
  const pedido = "[Pedido interno da equipe: escreva a próxima mensagem que a clínica deve mandar nesta conversa. Responda só com o texto da mensagem, pronto para enviar.]";
  if (hist.length && hist[hist.length - 1].role === "user") hist[hist.length - 1].content += "\n\n" + pedido;
  else hist.push({ role: "user", content: pedido });
  const sistema = montarSistema(a, imagens, dados.ctx) + "\n\n# Agora\nVocê está sugerindo uma resposta para uma atendente humana revisar antes de enviar. Não use ferramentas.";
  const j = await chamarClaude(a.modelo, sistema, hist, [], a.criatividade, 700);
  const texto = (j?.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("\n").trim();
  await registro({ conversa_id: conversaId, tipo: "sugestao", detalhe: texto.slice(0, 2000), modelo: a.modelo, tokens_entrada: j?.usage?.input_tokens, tokens_saida: j?.usage?.output_tokens, autor });
  return { texto };
}

export function transcricao(msgs: any[]): string {
  return msgs.map((m) => {
    const t = textoDaMensagem(m);
    if (!t) return "";
    const quem = m.direcao === "recebida" ? "Paciente" : (String(m.autor_email ?? "").startsWith("IA:") ? "Agente de IA" : String(m.autor_email ?? "").startsWith("automação") ? "Automação" : "Clínica");
    return `${quem}: ${t}`;
  }).filter(Boolean).join("\n");
}

async function resumir(conversaId: string, autor: string) {
  const { a } = await carregarAgente();
  if (!a?.resumos) throw new Error("os Resumos estão desligados na tela Agente de IA");
  const dados = await carregarConversa(conversaId);
  if (!dados) throw new Error("conversa não encontrada");
  const txt = transcricao(dados.msgs);
  if (!txt) throw new Error("a conversa ainda não tem mensagens");
  const sistema = "Você resume conversas de WhatsApp de uma clínica odontológica para a equipe. Em português, em até 6 tópicos curtos: quem é a pessoa, o que ela busca, dúvidas e objeções, o que já foi combinado, próximo passo e pendências. Não invente nada que não esteja na conversa.";
  const j = await chamarClaude(a.modelo, sistema, [{ role: "user", content: `Contato: ${dados.ctx.nome || "sem nome"}${dados.ctx.etapa ? " (etapa " + dados.ctx.etapa + ")" : ""}\n\n${txt}` }], [], 0.2, 600);
  const texto = (j?.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("\n").trim();
  await banco(`/rest/v1/conversas?id=eq.${conversaId}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ resumo_ia: texto, resumo_ia_em: new Date().toISOString() }) });
  await registro({ conversa_id: conversaId, tipo: "resumo", detalhe: texto.slice(0, 2000), modelo: a.modelo, tokens_entrada: j?.usage?.input_tokens, tokens_saida: j?.usage?.output_tokens, autor });
  return { texto, em: new Date().toISOString() };
}

// ---------- entrada ----------
export async function handler(req: Request): Promise<Response> {
  const h = cors(req);
  const json = (c: unknown, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { ...h, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response("ok", { headers: h });
  if (req.method !== "POST") return json({ ok: false, erro: "use POST" }, 405);
  const dados = await req.json().catch(() => ({}));

  const chave = req.headers.get("x-motor-chave");
  if (chave) {
    if (!(await rpc("automacao_conferir_chave", { p_chave: chave }).catch(() => false))) return json({ ok: false, erro: "chave do motor inválida" }, 401);
    const cont = await rodarFila();
    return json({ ok: true, ...cont });
  }

  const u = await usuario(req);
  if (!u || !["gestao", "avaliacao", "comercial"].includes(u.papel)) return json({ ok: false, erro: "sem permissão" }, 403);
  try {
    switch (dados?.acao) {
      case "status":
        return json({ ok: true, chave: !!ANTHROPIC_API_KEY, modelos: MODELOS, personalidades: Object.keys(PERSONALIDADES) });
      case "testar":
        if (u.papel !== "gestao") return json({ ok: false, erro: "só a gestão testa o agente" }, 403);
        return json({ ok: true, ...(await testar({ ...dados, _autor: u.email })) });
      case "sugerir":
        return json({ ok: true, ...(await sugerir(String(dados.conversa_id), u.email)) });
      case "resumir":
        return json({ ok: true, ...(await resumir(String(dados.conversa_id), u.email)) });
      default:
        return json({ ok: false, erro: "ação desconhecida" }, 400);
    }
  } catch (e) {
    return json({ ok: false, erro: String((e as Error)?.message ?? e).slice(0, 400) });
  }
}

if (!Deno.env.get("WA_TESTE")) Deno.serve(handler);
