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
const CLINICORP_USUARIO = Deno.env.get("CLINICORP_USUARIO") ?? "";
const CLINICORP_TOKEN = Deno.env.get("CLINICORP_TOKEN") ?? "";
const CLINICORP_SUBSCRIBER_ID = Deno.env.get("CLINICORP_SUBSCRIBER_ID") ?? "";
const CLINICORP_URL = Deno.env.get("CLINICORP_URL") ?? "https://api.clinicorp.com/rest/v1";
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
// A Meta às vezes devolve um erro passageiro (#131000 "Something went wrong", 5xx, rede):
// tenta de novo algumas vezes antes de dar como falha.
async function enviarMetaTentando(c: any, corpo: any) {
  let r = await enviarMeta(c, corpo).catch((e) => ({ ok: false, id: null, erro: String(e?.message ?? e), j: {} as any }));
  const passageiro = (x: any) => !x.ok && (/131000|something went wrong|temporar|timeout|fetch/i.test(String(x.erro)) || Number(x.j?.error?.code) === 131000 || Number(x.j?.error?.code) === 2);
  // até 3 tentativas a mais (2,5 s, 6 s e 12 s): o #131000 às vezes dura alguns segundos
  for (const ms of [2500, 6000, 12000]) {
    if (!passageiro(r)) break;
    await new Promise((ok) => setTimeout(ok, ms));
    r = await enviarMeta(c, corpo).catch((e) => ({ ok: false, id: null, erro: String(e?.message ?? e), j: {} as any }));
  }
  return r;
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

// ---------- agenda do Clinicorp (marcar avaliação) ----------
async function clinicorp(caminho: string, params: Record<string, string | number> = {}, metodo = "GET", corpo?: unknown) {
  if (!CLINICORP_USUARIO || !CLINICORP_TOKEN) throw new Error("faltam os segredos CLINICORP_USUARIO e CLINICORP_TOKEN");
  const u = new URL(CLINICORP_URL + caminho);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, String(v));
  const r = await fetch(u, {
    method: metodo,
    headers: { Authorization: "Basic " + btoa(CLINICORP_USUARIO + ":" + CLINICORP_TOKEN), Accept: "application/json", ...(corpo ? { "Content-Type": "application/json" } : {}) },
    body: corpo ? JSON.stringify(corpo) : undefined,
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`Clinicorp ${r.status}: ${t.slice(0, 200)}`);
  try { return t ? JSON.parse(t) : null; } catch { return t; }
}
const assinante = () => CLINICORP_SUBSCRIBER_ID || CLINICORP_USUARIO;
const minutos = (hhmm: string) => { const m = /^(\d{1,2}):(\d{2})/.exec(String(hhmm ?? "")); return m ? Number(m[1]) * 60 + Number(m[2]) : NaN; };
const hhmm = (min: number) => `${String(Math.floor(min / 60)).padStart(2, "0")}:${String(min % 60).padStart(2, "0")}`;
const diaLocal = (agora: number, n = 0) => {
  const d = new Date(agora + FUSO_MIN * 60_000);
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + n)).toISOString().slice(0, 10);
};
const dataDoItem = (a: any) => {
  const at = String(a?.AtomicDate ?? "");
  if (/^\d{8}$/.test(at)) return `${at.slice(0, 4)}-${at.slice(4, 6)}-${at.slice(6, 8)}`;
  const d = Date.parse(String(a?.date ?? ""));
  return isNaN(d) ? "" : new Date(d + FUSO_MIN * 60_000).toISOString().slice(0, 10);
};

export type Horario = { data: string; hora: string; fim: string };
/** Horários livres da profissional, respeitando expediente, sábado, almoço e antecedência. */
export function horariosLivres(cfg: any, agenda: any[], agora: number): Horario[] {
  const prof = String(cfg.profissional_id ?? "");
  const dur = Number(cfg.duracao_min ?? 60), passo = Math.max(5, Number(cfg.passo_min ?? 30));
  const limite = agora + Number(cfg.antecedencia_horas ?? 2) * 3_600_000;
  const ocupado = new Map<string, [number, number][]>();
  const diaInteiro = new Set<string>();
  for (const a of Array.isArray(agenda) ? agenda : []) {
    if (String(a?.Canceled ?? "").toUpperCase() === "X" || String(a?.Deleted ?? "").toUpperCase() === "X") continue;
    const dono = a?.Dentist_PersonId != null ? String(a.Dentist_PersonId) : "";
    const tipo = String(a?.ItemType ?? "APPOINTMENT");
    // compromisso/agendamento de outra profissional não conta; evento sem profissional é da clínica toda
    if (dono && dono !== prof) continue;
    if (!dono && tipo === "APPOINTMENT") continue;
    const d = dataDoItem(a);
    if (!d) continue;
    if (String(a?.AllDay ?? "").toUpperCase() === "X") { diaInteiro.add(d); continue; }
    const i = minutos(a?.fromTime), f = minutos(a?.toTime);
    if (isNaN(i) || isNaN(f)) continue;
    if (!ocupado.has(d)) ocupado.set(d, []);
    ocupado.get(d)!.push([i, Math.max(f, i + 1)]);
  }
  const livreEm = (ints: [number, number][], ini: number, fim: number) => ints.every(([a, b]) => b <= ini || a >= fim);
  const sobraAlmoco = (ints: [number, number][]) => {
    const ai = minutos(cfg.almoco_inicio), af = minutos(cfg.almoco_fim), am = Number(cfg.almoco_min ?? 60);
    if (isNaN(ai) || isNaN(af) || af - ai < am) return true;
    for (let t = ai; t + am <= af; t += 5) if (livreEm(ints, t, t + am)) return true;
    return false;
  };
  const out: Horario[] = [];
  for (let n = 0; n <= Number(cfg.dias_busca ?? 14); n++) {
    const d = diaLocal(agora, n);
    const sem = new Date(d + "T12:00:00Z").getUTCDay();
    if (sem === 0 || diaInteiro.has(d)) continue;
    const ini = minutos(sem === 6 ? cfg.sabado_inicio : cfg.semana_inicio), ult = minutos(sem === 6 ? cfg.sabado_ultimo : cfg.semana_ultimo);
    if (isNaN(ini) || isNaN(ult)) continue;
    const ints = ocupado.get(d) ?? [];
    for (let t = ini; t <= ult; t += passo) {
      const inicioMs = Date.parse(`${d}T${hhmm(t)}:00-03:00`);
      if (inicioMs < limite) continue;
      if (!livreEm(ints, t, t + dur)) continue;
      if (sem !== 6 && !sobraAlmoco([...ints, [t, t + dur]])) continue;
      out.push({ data: d, hora: hhmm(t), fim: hhmm(t + dur) });
    }
  }
  return out;
}

/** As duas opções mais próximas no período pedido (a segunda não encosta na primeira). */
export function duasOpcoes(livres: Horario[], periodo: string, data?: string): Horario[] {
  const ok = livres.filter((h) => {
    if (data && h.data !== data) return false;
    const m = minutos(h.hora);
    if (periodo === "manha") return m < 12 * 60;
    if (periodo === "tarde") return m >= 12 * 60;
    return true;
  });
  if (!ok.length) return [];
  const a = ok[0];
  const b = ok.find((h) => h.data !== a.data || minutos(h.hora) >= minutos(a.fim));
  return b ? [a, b] : [a];
}

export function descreverHorario(h: Horario, agora: number): string {
  const [y, m, d] = h.data.split("-").map(Number);
  const sem = DIAS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
  const dm = `${String(d).padStart(2, "0")}/${String(m).padStart(2, "0")}`;
  const rel = h.data === diaLocal(agora) ? "hoje" : h.data === diaLocal(agora, 1) ? "amanhã" : "";
  return rel ? `${rel} (${sem}, ${dm}) às ${h.hora}` : `${sem}, ${dm}, às ${h.hora}`;
}

async function agendaDaProfissional(cfg: any, agora: number) {
  const de = diaLocal(agora), ate = diaLocal(agora, Number(cfg.dias_busca ?? 14));
  const p: Record<string, string> = { from: de, to: ate, includeAssigns: "X" };
  if (CLINICORP_SUBSCRIBER_ID) p.subscriber_id = CLINICORP_SUBSCRIBER_ID;
  const j = await clinicorp("/appointment/list", p);
  return Array.isArray(j) ? j : (j?.appointments ?? j?.data ?? []);
}

const telefoneBonito = (t: string) => { const d = String(t).replace(/\D/g, "").replace(/^55(?=\d{10,11}$)/, ""); return d.length === 11 ? `(${d.slice(0, 2)}) ${d.slice(2, 7)}-${d.slice(7)}` : d.length === 10 ? `(${d.slice(0, 2)}) ${d.slice(2, 6)}-${d.slice(6)}` : d; };

// ---------- paciente no Clinicorp (sem duplicar) ----------
const digitosTel = (t: unknown) => { let d = String(t ?? "").replace(/\D/g, ""); if (d.startsWith("55") && d.length >= 12) d = d.slice(2); return d; };
/** Mesmo telefone: mesmo DDD e mesmos 8 últimos dígitos (aceita com ou sem o 9 e com ou sem 55). */
export function mesmoTelefone(a: unknown, b: unknown): boolean {
  const x = digitosTel(a), y = digitosTel(b);
  if (x.length < 10 || y.length < 10) return false;
  return x.slice(0, 2) === y.slice(0, 2) && x.slice(-8) === y.slice(-8);
}
const telefonesDoCadastro = (x: any): string[] =>
  Object.entries(x ?? {}).filter(([k, v]) => /phone|fone|celular|tel/i.test(k) && (typeof v === "string" || typeof v === "number")).map(([, v]) => String(v));
const ativo = (x: any) => x?.PatientId && !/DELETED|INACTIVE/i.test(String(x?.Status ?? "")) && String(x?.Deleted ?? "").toUpperCase() !== "X";

/**
 * Procura o cadastro do paciente pelo telefone antes de criar um novo.
 * 1) CRM (pacientes.clinicorp_paciente_id), conferindo no Clinicorp se o cadastro ainda existe;
 * 2) /patient/get pelo telefone em vários formatos — só aceita o cadastro se o telefone dele bater de verdade;
 * 3) agendamentos dos últimos 12 meses com esse telefone.
 */
const semAcento = (t: string) => t.normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/\s+/g, " ").trim();
/** Variações do nome para a busca do Clinicorp (que só acha o nome inteiro): completo, primeiro + último, dois primeiros. */
export function variacoesNome(nomes: string[]): string[] {
  const out: string[] = [];
  for (const n of nomes) {
    const t = semAcento(String(n ?? "")).split(" ").filter((x) => x.length > 1 && !/^\d+$/.test(x));
    if (t.length < 2) continue;
    out.push(t.join(" "), `${t[0]} ${t[t.length - 1]}`, `${t[0]} ${t[1]}`);
    const sem = t.filter((x) => !/^(de|da|do|dos|das|e)$/i.test(x));
    if (sem.length >= 2) out.push(`${sem[0]} ${sem[1]}`, `${sem[0]} ${sem[sem.length - 1]}`);
  }
  return [...new Set(out)].slice(0, 8);
}

/**
 * Procura o cadastro do paciente antes de criar um novo, e só aceita se o TELEFONE do cadastro bater.
 * (A busca por telefone do Clinicorp não acha todos os cadastros, por isso também busca pelo nome.)
 * 1) CRM (pacientes.clinicorp_paciente_id), conferindo se o cadastro ainda está ativo;
 * 2) /patient/get pelo telefone;
 * 3) /patient/get pelos nomes (o informado e o do WhatsApp/CRM), em algumas variações;
 * 4) agendamentos dos últimos 3 meses com esse telefone.
 */
export async function buscarPacienteClinicorp(telefone: string, nomes: string[] = []): Promise<{ id: number; nome: string; como: string } | null> {
  const d = digitosTel(telefone);
  if (d.length < 10) return null;
  const sub = assinante();
  const conferir = async (pid: unknown) => {
    const r = await clinicorp("/patient/get", { subscriber_id: sub, PatientId: String(pid) }).catch(() => null);
    const x = Array.isArray(r) ? r[0] : r;
    return ativo(x) ? x : null;
  };
  const doTelefone = (r: any) => (Array.isArray(r) ? r : r ? [r] : []).filter(ativo).find((y: any) => telefonesDoCadastro(y).some((t) => mesmoTelefone(t, d)));
  const res = (x: any, como: string) => ({ id: Number(x.PatientId), nome: String(x.Name ?? x.PatientName ?? ""), como });
  // 1) o CRM já sabe o id
  const crm = await bancoJson(`/rest/v1/pacientes?telefone=eq.${d}&select=nome,clinicorp_paciente_id&limit=1`).catch(() => []);
  if (crm?.[0]?.clinicorp_paciente_id) {
    const x = await conferir(crm[0].clinicorp_paciente_id);
    if (x) return res(x, "crm");
  }
  // 2) telefone
  const t = doTelefone(await clinicorp("/patient/get", { subscriber_id: sub, Phone: d }).catch(() => null));
  if (t) return res(t, "telefone");
  // 3) nome (conferindo o telefone)
  for (const n of variacoesNome([...nomes, crm?.[0]?.nome ?? ""])) {
    const x = doTelefone(await clinicorp("/patient/get", { subscriber_id: sub, Name: n }).catch(() => null));
    if (x) return res(x, "nome: " + n);
  }
  // 4) agendamentos recentes com esse telefone
  for (let k = 0; k < 3; k++) {
    const ate = new Date(Date.now() + 30 * 86400000 - k * 31 * 86400000), de = new Date(ate.getTime() - 30 * 86400000);
    const ag = await clinicorp("/appointment/list", { subscriber_id: sub, from: de.toISOString().slice(0, 10), to: ate.toISOString().slice(0, 10) }).catch(() => []);
    const x = (Array.isArray(ag) ? ag : []).find((y: any) => y?.Patient_PersonId && String(y?.Deleted ?? "").toUpperCase() !== "X" && mesmoTelefone(y?.MobilePhone, d));
    if (x) {
      const c = await conferir(x.Patient_PersonId);
      if (c) return res(c, "agendamento");
    }
  }
  return null;
}

async function pacienteClinicorp(nome: string, telefone: string, outrosNomes: string[] = []): Promise<{ id: number | null; existente: boolean; como: string }> {
  const d = digitosTel(telefone);
  const achado = await buscarPacienteClinicorp(d, [nome, ...outrosNomes]).catch(() => null);
  let id: number | null = achado?.id ?? null;
  if (!id) {
    const novo = await clinicorp("/patient/create", {}, "POST", { subscriber_id: assinante(), Name: nome, MobilePhone: Number(d), IgnoreSameName: "X" });
    const v = novo?.PatientId ?? novo?.id ?? (Array.isArray(novo) ? novo[0]?.PatientId ?? novo[0]?.id : null);
    id = v ? Number(v) : null;
  }
  // guarda no CRM para a próxima vez achar direto
  if (id && d) await banco(`/rest/v1/pacientes?telefone=eq.${d}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ clinicorp_paciente_id: String(id) }) }).catch(() => {});
  return { id, existente: !!achado, como: achado?.como ?? "novo" };
}

/** Marca de verdade no Clinicorp (confere de novo se o horário ainda está livre). */
export async function marcarNoClinicorp(cfg: any, h: { data: string; hora: string }, nome: string, telefone: string, observacoes: string, agora = Date.now(), outrosNomes: string[] = []) {
  const livres = horariosLivres(cfg, await agendaDaProfissional(cfg, agora), agora);
  const escolhido = livres.find((x) => x.data === h.data && x.hora === h.hora);
  if (!escolhido) return { ok: false, motivo: "esse horário não está mais livre" };
  const pac = await pacienteClinicorp(nome, telefone, outrosNomes);
  const pacienteId = pac.id;
  const corpo: any = {
    PatientName: nome, MobilePhone: telefoneBonito(telefone),
    fromTime: escolhido.hora, toTime: escolhido.fim, date: `${escolhido.data}T03:00:00.000Z`,
    Dentist_PersonId: Number(cfg.profissional_id),
    Procedures: cfg.procedimento || "Avaliação",
    Notes: observacoes || "",
  };
  if (pacienteId) corpo.Patient_PersonId = pacienteId;
  if (cfg.clinica_id) corpo.Clinic_BusinessId = Number(cfg.clinica_id);
  if (cfg.categoria_id) corpo.CategoryId = Number(cfg.categoria_id);
  else if (cfg.categoria_nome) corpo.CategoryDescription = cfg.categoria_nome;
  const r = await clinicorp("/appointment/create_appointment_by_api", CLINICORP_SUBSCRIBER_ID ? { subscriber_id: CLINICORP_SUBSCRIBER_ID } : {}, "POST", corpo);
  const item = Array.isArray(r) ? r[0] : r;
  if (!item?.id) return { ok: false, motivo: "o Clinicorp não confirmou: " + JSON.stringify(r).slice(0, 150) };
  return { ok: true, id: String(item.id), horario: escolhido, pacienteId, cadastro: pac.existente ? "já existia (" + pac.como + ")" : "novo" };
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
  if (a.agendamento?.ligado) {
    partes.push("# Agendamento da avaliação\n" +
      `Você pode marcar a ${a.agendamento.procedimento || "avaliação"} direto na agenda${a.agendamento.profissional_nome ? " da " + a.agendamento.profissional_nome : ""}. ` +
      "Para saber os horários, use a ferramenta ver_horarios (nunca invente horário). Ofereça exatamente as opções que ela devolver. " +
      "Antes de marcar, confirme o horário escolhido e o nome completo do paciente. Para marcar, use agendar_avaliacao e só diga que está marcado se ela confirmar.");
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

export function ferramentas(imagens: any[], agendamento = false) {
  const t: any[] = [{
    name: "transferir_para_humano",
    description: "Passa a conversa para a equipe da clínica e para de responder automaticamente. Use quando as instruções pedirem ou quando não souber responder com segurança.",
    input_schema: { type: "object", properties: { motivo: { type: "string", description: "Por que está passando (ex.: pediu horários, dor forte, reclamação)" } }, required: ["motivo"] },
  }, {
    name: "encerrar_sem_interesse",
    description: "Marca o lead como Perdido e para de responder. Use só quando as instruções mandarem (ex.: mora fora da Baixada Santista e não pode vir a Santos fazer o tratamento). Agradeça antes de usar.",
    input_schema: { type: "object", properties: { motivo: { type: "string", description: "Por que o lead foi encerrado (ex.: mora em outra cidade e não pode vir a Santos)" } }, required: ["motivo"] },
  }];
  if (agendamento) {
    t.push({
      name: "ver_horarios",
      description: "Consulta a agenda e devolve as duas opções livres mais próximas para a avaliação.",
      input_schema: { type: "object", properties: {
        periodo: { type: "string", enum: ["manha", "tarde", "qualquer"], description: "Período que o paciente prefere" },
        data: { type: "string", description: "Opcional: um dia específico pedido pelo paciente (AAAA-MM-DD)" },
      }, required: ["periodo"] },
    });
    t.push({
      name: "agendar_avaliacao",
      description: "Marca a avaliação no horário escolhido pelo paciente (um dos devolvidos por ver_horarios).",
      input_schema: { type: "object", properties: {
        data: { type: "string", description: "AAAA-MM-DD" },
        hora: { type: "string", description: "HH:MM" },
        nome_completo: { type: "string", description: "Nome completo do paciente" },
        observacoes: { type: "string", description: "Resumo para a agenda: queixa, o que procura, procedimentos de interesse, como conheceu a clínica" },
        online: { type: "boolean", description: "true quando for avaliação online pelo Google Meet (paciente de fora da Baixada Santista que pode vir a Santos fazer o tratamento)" },
      }, required: ["data", "hora", "nome_completo", "observacoes"] },
    });
  }
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
type Uso = { entrada: number; saida: number; cache_lido?: number; cache_gravado?: number };

// Cache de prompt da Anthropic: o começo fixo (ferramentas + instruções + base + imagens) fica guardado
// por 5 min e é cobrado a 10% quando se repete. A parte que muda a cada conversa ("# Sobre esta conversa"
// em diante: horário, nome, etapa) vai depois do ponto de cache, então a IA sempre recebe esses dados novos.
const MARCA_CONVERSA = "\n\n# Sobre esta conversa";
export function sistemaComCache(sistema: string): any[] {
  const i = sistema.indexOf(MARCA_CONVERSA);
  if (i <= 0) return [{ type: "text", text: sistema, cache_control: { type: "ephemeral" } }];
  return [
    { type: "text", text: sistema.slice(0, i), cache_control: { type: "ephemeral" } },
    { type: "text", text: sistema.slice(i + 2) },
  ];
}
// segundo ponto de cache no fim do histórico: as voltas seguintes (ferramentas) e a próxima resposta da
// mesma conversa reaproveitam tudo o que já foi lido
export function mensagensComCache(msgs: any[]): any[] {
  if (!msgs.length) return msgs;
  const out = msgs.slice();
  const u = out[out.length - 1];
  if (typeof u.content === "string") {
    if (!u.content) return out;
    out[out.length - 1] = { ...u, content: [{ type: "text", text: u.content, cache_control: { type: "ephemeral" } }] };
  } else if (Array.isArray(u.content) && u.content.length) {
    const c = u.content.slice();
    c[c.length - 1] = { ...c[c.length - 1], cache_control: { type: "ephemeral" } };
    out[out.length - 1] = { ...u, content: c };
  }
  return out;
}
async function chamarClaude(modelo: string, sistema: string, mensagens: any[], tools: any[], criatividade: number, maxTokens = 2000) {
  if (!ANTHROPIC_API_KEY) throw new Error("falta a chave da Anthropic (segredo ANTHROPIC_API_KEY na Supabase)");
  const corpo: any = { model: modelo, max_tokens: maxTokens, system: sistemaComCache(sistema), messages: mensagensComCache(mensagens), temperature: Math.max(0, Math.min(1, Number(criatividade))) };
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

export type Acao = { tipo: "texto"; texto: string } | { tipo: "imagem"; nome: string; link: string } | { tipo: "transferir"; motivo: string } | { tipo: "perdido"; motivo: string };
export type Agenda = { ver: (periodo: string, data?: string) => Promise<string>; marcar: (x: any) => Promise<string> };

/**
 * Conversa com o Claude até ele terminar (no máximo 4 voltas), devolvendo as ações em ordem.
 * "executar" é chamado a cada ação (enviar de verdade ou só anotar, no teste); se devolver false, para.
 */
export async function gerarResposta(a: any, imagens: any[], sistema: string, historico: any[], executar: (x: Acao) => Promise<boolean>, agenda?: Agenda) {
  const tools = ferramentas(imagens, !!(agenda && a.agendamento?.ligado));
  const msgs: any[] = historico.map((h) => ({ role: h.role, content: h.content }));
  const uso: Uso = { entrada: 0, saida: 0 };
  let blocos = 0, transferiu = false;
  const bruto: string[] = [];
  let parada = "";
  const max = Number(a.max_blocos ?? 4);
  for (let volta = 0; volta < 6; volta++) {
    const j = await chamarClaude(a.modelo, sistema, msgs, tools, a.criatividade);
    const lido = Number(j?.usage?.cache_read_input_tokens ?? 0), gravado = Number(j?.usage?.cache_creation_input_tokens ?? 0);
    uso.entrada += Number(j?.usage?.input_tokens ?? 0) + lido + gravado;
    uso.saida += Number(j?.usage?.output_tokens ?? 0);
    uso.cache_lido = (uso.cache_lido ?? 0) + lido;
    uso.cache_gravado = (uso.cache_gravado ?? 0) + gravado;
    const resultados: any[] = [];
    for (const b of j?.content ?? []) {
      if (b.type === "text") {
        bruto.push(String(b.text ?? ""));
        for (const t of dividirBlocos(b.text, max - blocos)) {
          if (blocos >= max) break;
          blocos++;
          if (!(await executar({ tipo: "texto", texto: t }))) return { uso, transferiu, parou: true, bruto, parada };
        }
      } else if (b.type === "tool_use") {
        if (b.name === "transferir_para_humano") {
          transferiu = true;
          await executar({ tipo: "transferir", motivo: String(b.input?.motivo ?? "") });
          resultados.push({ type: "tool_result", tool_use_id: b.id, content: "Conversa passada para a equipe. Não escreva mais nada." });
        } else if (b.name === "encerrar_sem_interesse") {
          transferiu = true;
          await executar({ tipo: "perdido", motivo: String(b.input?.motivo ?? "") });
          resultados.push({ type: "tool_result", tool_use_id: b.id, content: "Lead encerrado como Perdido. Não escreva mais nada." });
        } else if (b.name === "enviar_imagem") {
          const img = imagens.find((i) => i.nome === b.input?.nome);
          if (img && (await executar({ tipo: "imagem", nome: img.nome, link: img.link }))) {
            resultados.push({ type: "tool_result", tool_use_id: b.id, content: "Imagem enviada." });
          } else {
            resultados.push({ type: "tool_result", tool_use_id: b.id, content: "Não foi possível enviar essa imagem.", is_error: true });
          }
        } else if (agenda && b.name === "ver_horarios") {
          const txt = await agenda.ver(String(b.input?.periodo ?? "qualquer"), b.input?.data ? String(b.input.data) : undefined).catch((e) => "Não consegui consultar a agenda agora (" + String(e?.message ?? e).slice(0, 120) + "). Passe para a equipe.");
          resultados.push({ type: "tool_result", tool_use_id: b.id, content: txt });
        } else if (agenda && b.name === "agendar_avaliacao") {
          const txt = await agenda.marcar(b.input ?? {}).catch((e) => "Não consegui marcar (" + String(e?.message ?? e).slice(0, 160) + "). Não diga que está marcado; passe para a equipe.");
          resultados.push({ type: "tool_result", tool_use_id: b.id, content: txt });
        } else {
          resultados.push({ type: "tool_result", tool_use_id: b.id, content: "Ferramenta desconhecida.", is_error: true });
        }
      }
    }
    parada = String(j?.stop_reason ?? "");
    if (transferiu || j?.stop_reason !== "tool_use" || !resultados.length) break;
    msgs.push({ role: "assistant", content: j.content });
    msgs.push({ role: "user", content: resultados });
  }
  return { uso, transferiu, parou: false, bruto, parada };
}

// ---------- ferramentas de agenda ----------
export function agendaReal(a: any, conv: any, ctx: any, conversaId: string | null, simular = false): Agenda {
  const cfg = a.agendamento ?? {};
  return {
    ver: async (periodo, data) => {
      const agora = Date.now();
      const op = duasOpcoes(horariosLivres(cfg, await agendaDaProfissional(cfg, agora), agora), periodo, data);
      if (!op.length) return data ? `Sem horário livre em ${data} nesse período. Ofereça procurar outro dia ou período.` : `Sem horário livre nos próximos ${cfg.dias_busca ?? 14} dias nesse período. Ofereça o outro período ou passe para a equipe.`;
      return "Opções (ofereça estas duas): " + op.map((h) => `${descreverHorario(h, agora)} [data=${h.data} hora=${h.hora}]`).join(" ou ");
    },
    marcar: async (x) => {
      const nome = String(x.nome_completo ?? "").trim();
      if (nome.split(/\s+/).length < 2) return "Falta o nome completo (nome e sobrenome). Peça ao paciente antes de marcar.";
      if (simular) return `Simulação: marcaria ${x.data} às ${x.hora} para ${nome}. Nada foi marcado de verdade (teste).`;
      if (conversaId) {
        // só conta o que foi marcado depois do último "reiniciar conversa" (ia_desde)
        const desde = Math.max(Date.now() - 30 * 86_400_000, conv?.ia_desde ? Date.parse(conv.ia_desde) : 0);
        const ja = await bancoJson(`/rest/v1/agente_registros?conversa_id=eq.${conversaId}&tipo=eq.agendamento&criado_em=gte.${new Date(desde).toISOString()}&select=id&limit=1`).catch(() => []);
        if (ja?.length) return "Esta conversa já tem uma avaliação marcada pelo agente. Para remarcar ou marcar outra, passe para a equipe.";
      }
      const online = x.online === true || String(x.online) === "true";
      const obs = (online ? "AVALIAÇÃO ONLINE (Google Meet): enviar o link ao paciente. " : "") + String(x.observacoes ?? "");
      const r = await marcarNoClinicorp(cfg, { data: String(x.data), hora: String(x.hora).slice(0, 5) }, nome, conv?.telefone ?? "", obs, Date.now(), [ctx?.nome, conv?.nome_contato, conv?.nome_perfil].filter(Boolean).map(String));
      if (!r.ok) return `Não foi possível marcar: ${r.motivo}. Consulte ver_horarios de novo e ofereça outras opções.`;
      // CRM: etapa "Agendou"
      const agoraIso = new Date().toISOString();
      if (conv?.telefone) {
        await banco(`/rest/v1/pacientes?on_conflict=telefone`, { method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
          body: JSON.stringify({ telefone: conv.telefone, nome: nome, etapa: "Agendou", etapa_alterada_em: agoraIso }) }).catch(() => {});
      }
      await registro({ conversa_id: conversaId, tipo: "agendamento", detalhe: `${online ? "Avaliação ONLINE (Google Meet)" : (cfg.procedimento || "Avaliação")} marcada no Clinicorp: ${r.horario!.data} ${r.horario!.hora}–${r.horario!.fim} (${nome}). Agendamento ${r.id}. Cadastro do paciente: ${r.cadastro ?? "?"}.`, autor: "agente" });
      return `Marcado no Clinicorp: ${descreverHorario(r.horario!, Date.now())}, até ${r.horario!.fim}.` +
        (online ? " É avaliação ONLINE: confirme sem o endereço e diga que no dia da avaliação a pessoa recebe o link do Google Meet por aqui." : " Confirme ao paciente.");
    },
  };
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
    // ia_desde: "reiniciar conversa" para o agente (ele só lê o que veio depois)
    bancoJson(`/rest/v1/mensagens?conversa_id=eq.${id}${c.ia_desde ? `&enviada_em=gte.${encodeURIComponent(c.ia_desde)}` : ""}&select=direcao,tipo,texto,autor_email,enviada_em&order=enviada_em.desc&limit=40`),
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
    let primeira = true, encerrou = false, enviados: string[] = [];
    const executar = async (x: Acao) => {
      if (primeira) primeira = false;
      else await pausa(Math.min(4000, 1200 + (x.tipo === "texto" ? x.texto.length * 15 : 1500)));
      // o paciente mandou mais alguma coisa enquanto o agente pensava ou digitava? para aqui e
      // responde de novo com tudo (antes só conferia na 1ª mensagem e atropelava o paciente)
      if (x.tipo === "texto" || x.tipo === "imagem") {
        const v = await rpc("agente_versao", { p_conversa: conversaId }).catch(() => versao);
        if (v !== versao) return false;
      }
      if (x.tipo === "texto") {
        const r = await enviarMetaTentando(c, { type: "text", text: { body: x.texto.slice(0, 4096), preview_url: true } });
        await registrarEnviada(c, r.id, "text", x.texto, autor, r.erro, r.j);
        enviados.push(x.texto);
        return r.ok;
      }
      if (x.tipo === "imagem") {
        const r = await enviarMetaTentando(c, { type: "image", image: { link: x.link } });
        await registrarEnviada(c, r.id, "image", "📷 " + x.nome, autor, r.erro, { ...r.j, link: x.link });
        enviados.push("[imagem: " + x.nome + "]");
        return r.ok;
      }
      if (x.tipo === "perdido") {
        encerrou = true;
        // CRM: etapa Perdido e robô desligado nesta conversa (ninguém precisa assumir)
        if (c.telefone) await banco(`/rest/v1/pacientes?on_conflict=telefone`, { method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
          body: JSON.stringify({ telefone: c.telefone, etapa: "Perdido", etapa_alterada_em: new Date().toISOString() }) }).catch(() => {});
        await banco(`/rest/v1/conversas?id=eq.${conversaId}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ robo_ligado: false }) }).catch(() => {});
        await registro({ conversa_id: conversaId, tipo: "perdido", detalhe: "Encerrado como Perdido: " + x.motivo, autor: "agente" });
        return true;
      }
      await rpc("agente_transferir", { p_conversa: conversaId, p_motivo: x.motivo });
      return true;
    };
    const res = await gerarResposta(a, imagens, montarSistema(a, imagens, ctx), hist, executar, a.agendamento?.ligado ? agendaReal(a, c, ctx, conversaId) : undefined);
    // passou para a equipe sem dizer nada: avisa o paciente (nunca deixar sem resposta)
    if (res.transferiu && !encerrou && !enviados.length && !res.parou) {
      const aviso = "Vou passar sua mensagem para a nossa equipe te orientar certinho, tá bom? 💙";
      const r = await enviarMetaTentando(c, { type: "text", text: { body: aviso, preview_url: false } });
      await registrarEnviada(c, r.id, "text", aviso, autor, r.erro, r.j);
      enviados.push(aviso);
    }
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
  const res = await gerarResposta(a, imagens, montarSistema(a, imagens, { nome: dados?.nome || "" }), hist, async (x) => { acoes.push(x); return true; },
    a.agendamento?.ligado ? agendaReal(a, { telefone: "" }, {}, null, true) : undefined);
  await registro({ tipo: "teste", detalhe: acoes.map((x) => x.tipo === "texto" ? x.texto : x.tipo === "imagem" ? "[imagem: " + x.nome + "]" : "[transferiu: " + x.motivo + "]").join("\n\n").slice(0, 2000), modelo: a.modelo, tokens_entrada: res.uso.entrada, tokens_saida: res.uso.saida, autor: dados?._autor });
  return { acoes, uso: res.uso, bruto: res.bruto, parada: res.parada };
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
      case "clinicorp_buscar_paciente": {
        // só leitura: confere como o agente acharia o cadastro desse telefone
        if (u.papel !== "gestao") return json({ ok: false, erro: "só a gestão" }, 403);
        if (dados.caminho) {
          // diagnóstico (só leitura): GET em /patient/... com os parâmetros dados
          const cam = String(dados.caminho);
          if (!/^\/patient\/(get|list|search|find)[a-z_]*$/i.test(cam)) return json({ ok: false, erro: "só /patient/..." }, 400);
          const r = await clinicorp(cam, { subscriber_id: assinante(), ...(dados.params ?? {}) }).catch((e) => ({ erro: String(e?.message ?? e) }));
          const lista = Array.isArray(r) ? r : [r];
          return json({ ok: true, n: lista.length, amostra: lista.slice(0, 3).map((x: any) => x && typeof x === "object" ? Object.fromEntries(Object.entries(x).filter(([k]) => /id$|name|phone|status|deleted|erro/i.test(k))) : x) });
        }
        return json({ ok: true, achado: await buscarPacienteClinicorp(String(dados.telefone ?? ""), [String(dados.nome ?? "")]) });
      }
      // ---------- (27/10/2026) agendar pela Central de mensagens ----------
      case "agenda_opcoes": {
        const [profs, cats, cfgA] = await Promise.all([
          clinicorp("/professional/list_all_professionals", { subscriber_id: assinante() }).catch(() => []),
          clinicorp("/appointment/list_categories", { subscriber_id: assinante() }).catch(() => []),
          bancoJson(`/rest/v1/agente_ia?id=eq.1&select=agendamento`).catch(() => []),
        ]);
        const lista = (x: any) => Array.isArray(x) ? x : (x?.data ?? x?.professionals ?? x?.categories ?? []);
        const g = cfgA?.[0]?.agendamento ?? {};
        return json({
          ok: true,
          profissionais: lista(profs).map((p: any) => ({ id: String(p.id ?? p.PersonId ?? ""), nome: p.Name ?? p.name ?? "" })).filter((p: any) => p.id && p.nome)
            .sort((a: any, b: any) => a.nome.localeCompare(b.nome)),
          categorias: lista(cats).map((c: any) => ({ id: String(c.id ?? c.CategoryId ?? ""), nome: c.Description ?? c.description ?? c.Name ?? "" })).filter((c: any) => c.id && c.nome)
            .sort((a: any, b: any) => a.nome.localeCompare(b.nome)),
          padrao: { profissional_id: g.profissional_id ?? null, categoria_id: g.categoria_id ?? null, duracao_min: Number(g.duracao_min ?? 60) },
        });
      }
      case "agenda_dia": {
        const data = String(dados.data ?? "");
        if (!/^\d{4}-\d{2}-\d{2}$/.test(data)) return json({ ok: false, erro: "data inválida" }, 400);
        const prof = String(dados.profissional_id ?? "");
        const p: Record<string, string> = { from: data, to: data, includeAssigns: "X" };
        if (CLINICORP_SUBSCRIBER_ID) p.subscriber_id = CLINICORP_SUBSCRIBER_ID;
        const ag = await clinicorp("/appointment/list", p);
        const itens = (Array.isArray(ag) ? ag : (ag?.appointments ?? ag?.data ?? [])).filter((a: any) =>
          String(a?.Canceled ?? "").toUpperCase() !== "X" && String(a?.Deleted ?? "").toUpperCase() !== "X" && dataDoItem(a) === data &&
          (!prof || !a?.Dentist_PersonId || String(a.Dentist_PersonId) === prof));
        const hm = (t: unknown) => { const m = /^(\d{1,2}):(\d{2})/.exec(String(t ?? "")); return m ? `${m[1].padStart(2, "0")}:${m[2]}` : ""; };
        return json({ ok: true, itens: itens.map((a: any) => ({
          inicio: hm(a.fromTime), fim: hm(a.toTime), dia_inteiro: String(a?.AllDay ?? "").toUpperCase() === "X",
          paciente: String(a.PatientName ?? a.Name ?? "").trim(), categoria: String(a.CategoryDescription ?? ""),
          tipo: String(a.ItemType ?? "APPOINTMENT"), de_outro: !a?.Dentist_PersonId,
        })).sort((x: any, y: any) => x.inicio.localeCompare(y.inicio)) });
      }
      case "agendar_manual": {
        const c = dados.conversa_id ? (await bancoJson(`/rest/v1/conversas?id=eq.${String(dados.conversa_id)}&select=id,telefone,canal`))?.[0] : null;
        const tel = String(c?.telefone ?? dados.telefone ?? "").replace(/\D/g, "");
        if (!tel || tel.length < 10) return json({ ok: false, erro: "contato sem telefone" }, 400);
        const data = String(dados.data ?? ""), ini = String(dados.inicio ?? ""), fim = String(dados.fim ?? "");
        const nome = String(dados.nome ?? "").trim();
        if (!/^\d{4}-\d{2}-\d{2}$/.test(data) || !/^\d{2}:\d{2}$/.test(ini) || !/^\d{2}:\d{2}$/.test(fim) || fim <= ini) return json({ ok: false, erro: "data ou horário inválido" }, 400);
        if (nome.split(/\s+/).length < 2) return json({ ok: false, erro: "coloque o nome completo" }, 400);
        const prof = String(dados.profissional_id ?? "");
        if (!prof) return json({ ok: false, erro: "escolha a profissional" }, 400);
        // conflito com outro agendamento da mesma profissional
        if (!dados.forcar) {
          const p: Record<string, string> = { from: data, to: data, includeAssigns: "X" };
          if (CLINICORP_SUBSCRIBER_ID) p.subscriber_id = CLINICORP_SUBSCRIBER_ID;
          const ag = await clinicorp("/appointment/list", p).catch(() => []);
          const a0 = minutos(ini), f0 = minutos(fim);
          const choque = (Array.isArray(ag) ? ag : []).filter((a: any) => String(a?.Canceled ?? "").toUpperCase() !== "X" && String(a?.Deleted ?? "").toUpperCase() !== "X"
            && dataDoItem(a) === data && (String(a?.Dentist_PersonId ?? "") === prof || (!a?.Dentist_PersonId && String(a?.ItemType ?? "") !== "APPOINTMENT"))
            && (String(a?.AllDay ?? "").toUpperCase() === "X" || (minutos(a?.fromTime) < f0 && minutos(a?.toTime) > a0)));
          if (choque.length) return json({ ok: false, conflito: choque.map((a: any) => `${String(a.fromTime ?? "").slice(0, 5)} ${String(a.PatientName ?? a.Name ?? a.CategoryDescription ?? "compromisso").trim()}`) }, 409);
        }
        const pac = await pacienteClinicorp(nome, tel, [String(dados.nome_perfil ?? "")].filter(Boolean));
        const cfg = (await bancoJson(`/rest/v1/agente_ia?id=eq.1&select=agendamento`).catch(() => []))?.[0]?.agendamento ?? {};
        const obs = String(dados.observacoes ?? "").trim();
        const corpo: any = {
          PatientName: nome, MobilePhone: telefoneBonito(tel), fromTime: ini, toTime: fim, date: `${data}T03:00:00.000Z`,
          Dentist_PersonId: Number(prof), Procedures: String(dados.procedimento || "Avaliação"),
          Notes: (obs ? obs + "\n" : "") + `Agendado pelo CRM (${u.email}).`,
        };
        if (pac.id) corpo.Patient_PersonId = pac.id;
        if (cfg.clinica_id) corpo.Clinic_BusinessId = Number(cfg.clinica_id);
        if (dados.categoria_id) corpo.CategoryId = Number(dados.categoria_id);
        const r = await clinicorp("/appointment/create_appointment_by_api", CLINICORP_SUBSCRIBER_ID ? { subscriber_id: CLINICORP_SUBSCRIBER_ID } : {}, "POST", corpo);
        const item = Array.isArray(r) ? r[0] : r;
        if (!item?.id) return json({ ok: false, erro: "o Clinicorp não confirmou: " + JSON.stringify(r).slice(0, 200) }, 502);
        await registro({ conversa_id: c?.id ?? null, tipo: "agendamento", detalhe: `Agendado pela Central (${u.email}): ${data} ${ini}–${fim} (${nome}). Agendamento ${item.id}. Cadastro: ${pac.existente ? "já existia (" + pac.como + ")" : "novo"}.`, autor: u.email });
        return json({ ok: true, id: String(item.id), cadastro: pac.existente ? "existente" : "novo" });
      }
      case "clinicorp_opcoes": {
        if (u.papel !== "gestao") return json({ ok: false, erro: "só a gestão" }, 403);
        const sub = CLINICORP_SUBSCRIBER_ID ? { subscriber_id: CLINICORP_SUBSCRIBER_ID } : {};
        const [profs, cats, ag] = await Promise.all([
          clinicorp("/professional/list_all_professionals", { subscriber_id: assinante() }).catch((e) => ({ erro: String(e.message) })),
          clinicorp("/appointment/list_categories", { subscriber_id: assinante() }).catch((e) => ({ erro: String(e.message) })),
          clinicorp("/appointment/list", { ...sub, from: diaLocal(Date.now()), to: diaLocal(Date.now(), 7) }).catch(() => []),
        ]);
        const lista = (x: any) => Array.isArray(x) ? x : (x?.data ?? x?.professionals ?? x?.categories ?? []);
        const clinicas = [...new Set(lista(ag).map((i: any) => i?.Clinic_BusinessId).filter(Boolean).map(String))];
        return json({
          ok: true, assinante: assinante(), clinicas,
          profissionais: Array.isArray(lista(profs)) ? lista(profs).map((p: any) => ({ id: String(p.id ?? p.PersonId ?? p.Dentist_PersonId ?? ""), nome: p.Name ?? p.name ?? p.Nome ?? "" })) : [],
          categorias: Array.isArray(lista(cats)) ? lista(cats).map((c: any) => ({ id: String(c.id ?? c.CategoryId ?? ""), nome: c.Description ?? c.description ?? c.Name ?? "" })) : [],
          erro_profissionais: (profs as any)?.erro ?? null, erro_categorias: (cats as any)?.erro ?? null,
          amostra_profissional: JSON.stringify(lista(profs)?.[0] ?? null).slice(0, 300), amostra_categoria: JSON.stringify(lista(cats)?.[0] ?? null).slice(0, 300),
        });
      }
      case "agenda_futura": {
        // próximas consultas de qualquer categoria (90 dias), por telefone, para o
        // Kanban do Fluxo avisar quem está em tratamento sem nada marcado
        const sub: Record<string, string> = CLINICORP_SUBSCRIBER_ID ? { subscriber_id: CLINICORP_SUBSCRIBER_ID } : {};
        const agora = Date.now();
        const todas: { tel: string; data: string; hora: string; categoria: string; nome: string }[] = [];
        for (let ini = 0; ini < 90; ini += 30) {
          const ag = await clinicorp("/appointment/list", { ...sub, from: diaLocal(agora, ini), to: diaLocal(agora, ini + 29) }).catch(() => []);
          for (const x of Array.isArray(ag) ? ag : []) {
            if (String(x?.Canceled ?? "").toUpperCase() === "X" || String(x?.Deleted ?? "").toUpperCase() === "X") continue;
            if (String(x?.ItemType ?? "APPOINTMENT") !== "APPOINTMENT") continue;
            let t = String(x?.MobilePhone ?? "").replace(/\D/g, "");
            if (t.startsWith("55") && t.length >= 12) t = t.slice(2);
            const d = dataDoItem(x); if (!d) continue;
            if (t.length < 10) t = "nome:" + String(x?.PatientName ?? "").trim().toLowerCase();
            if (t === "nome:") continue;
            const hm = /^(\d{1,2}):(\d{2})/.exec(String(x?.fromTime ?? ""));
            const hora = hm ? `${hm[1].padStart(2, "0")}:${hm[2]}` : "";
            // todas as consultas futuras (o CRM escolhe a primeira e a primeira avaliação)
            todas.push({ tel: t, data: d, hora, categoria: String(x?.CategoryDescription ?? ""), nome: String(x?.PatientName ?? "") });
          }
        }
        // quem foi ATENDIDO nos últimos 30 dias (status atendido ou check-in): o Kanban
        // não manda essas pessoas para "Faltou" quando a etapa ainda diz "Agendou"
        const atendidos: { tel: string; nome: string; data: string; categoria: string }[] = [];
        const ag30 = await clinicorp("/appointment/list", { ...sub, from: diaLocal(agora, -30), to: diaLocal(agora, -1) }).catch(() => []);
        for (const x of Array.isArray(ag30) ? ag30 : []) {
          if (String(x?.Canceled ?? "").toUpperCase() === "X" || String(x?.Deleted ?? "").toUpperCase() === "X") continue;
          if (!(x?.CheckinTime || String(x?.StatusId ?? "") === "5329595793145856")) continue;
          let t = String(x?.MobilePhone ?? "").replace(/\D/g, "");
          if (t.startsWith("55") && t.length >= 12) t = t.slice(2);
          atendidos.push({ tel: t, nome: String(x?.PatientName ?? ""), data: dataDoItem(x), categoria: String(x?.CategoryDescription ?? "") });
        }
        return json({ ok: true, agenda: todas, atendidos });
      }
      case "historico_atendimentos": {
        // (25/10/2026) histórico de atendimentos de um período (até 93 dias por
        // chamada), para achar a data do primeiro atendimento de lentes de cada
        // paciente (aba Renovação). Só leitura no Clinicorp.
        const sub: Record<string, string> = CLINICORP_SUBSCRIBER_ID ? { subscriber_id: CLINICORP_SUBSCRIBER_ID } : {};
        const de = String(dados.de ?? ""), ate = String(dados.ate ?? "");
        if (!/^\d{4}-\d{2}-\d{2}$/.test(de) || !/^\d{4}-\d{2}-\d{2}$/.test(ate)) return json({ ok: false, erro: "datas inválidas" }, 400);
        const filtro = dados.filtro ? new RegExp(String(dados.filtro), "i") : null;
        const ini = Date.parse(de + "T12:00:00Z"), fim = Date.parse(ate + "T12:00:00Z");
        if (!(fim >= ini) || fim - ini > 93 * 86400000) return json({ ok: false, erro: "período de até 93 dias" }, 400);
        const itens: { tel: string; nome: string; data: string; categoria: string; atendido: boolean; proc: string; obs: string }[] = [];
        // texto dos procedimentos do agendamento (o tipo/categoria só existe desde jun/2023;
        // antes disso o que foi feito aparece só em "Procedimentos")
        const textoProc = (x: any): string => {
          const partes: string[] = [];
          for (const [k, v] of Object.entries(x ?? {})) {
            if (!/proced|treatment|service|descri/i.test(k) || /categor|patient|professional|dentist|clinic/i.test(k)) continue;
            if (typeof v === "string") partes.push(v);
            else if (Array.isArray(v)) v.forEach((y: any) => { if (typeof y === "string") partes.push(y); else if (y && typeof y === "object") Object.values(y).forEach((z) => { if (typeof z === "string" && z.length < 200) partes.push(z); }); });
          }
          return partes.join(" | ").slice(0, 400);
        };
        let chaves: string[] | null = null;
        for (let t0 = ini; t0 <= fim; t0 += 31 * 86400000) {
          const t1 = Math.min(fim, t0 + 30 * 86400000);
          const ag = await clinicorp("/appointment/list", { ...sub, from: new Date(t0).toISOString().slice(0, 10), to: new Date(t1).toISOString().slice(0, 10) }).catch(() => []);
          for (const x of Array.isArray(ag) ? ag : []) {
            if (String(x?.Canceled ?? "").toUpperCase() === "X" || String(x?.Deleted ?? "").toUpperCase() === "X") continue;
            if (String(x?.ItemType ?? "APPOINTMENT") !== "APPOINTMENT") continue;
            const cat = String(x?.CategoryDescription ?? "");
            const proc = textoProc(x);
            const obs = String(x?.Notes ?? x?.Observation ?? x?.Obs ?? "").slice(0, 300);
            if (dados.chaves && !chaves) chaves = Object.keys(x ?? {});
            if (filtro && !filtro.test(cat) && !filtro.test(proc)) continue;
            let t = String(x?.MobilePhone ?? "").replace(/\D/g, "");
            if (t.startsWith("55") && t.length >= 12) t = t.slice(2);
            itens.push({ tel: t, nome: String(x?.PatientName ?? ""), data: dataDoItem(x), categoria: cat,
              atendido: !!(x?.CheckinTime || String(x?.StatusId ?? "") === "5329595793145856"), proc, obs });
          }
        }
        return json({ ok: true, itens, ...(chaves ? { chaves } : {}) });
      }
      case "agenda_passada": {
        // última consulta JÁ PASSADA de cada pessoa pedida (telefone ou nome completo),
        // com o status do Clinicorp, para limpar quem ficou em "Agendou" sem consulta futura
        const sub: Record<string, string> = CLINICORP_SUBSCRIBER_ID ? { subscriber_id: CLINICORP_SUBSCRIBER_ID } : {};
        const nn = (v: unknown) => String(v ?? "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/\s+/g, " ").trim();
        const itens: { tel: string; nome: string }[] = Array.isArray(dados.itens) ? dados.itens.slice(0, 500) : [];
        const porTel = new Map<string, number>(), porNome = new Map<string, number>();
        itens.forEach((it, i) => { const t = String(it.tel ?? "").replace(/\D/g, ""); if (t) porTel.set(t, i); const n = nn(it.nome); if (n.includes(" ")) porNome.set(n, i); });
        const dias = Math.min(720, Math.max(30, Number(dados.dias ?? 400)));
        const agora = Date.now();
        const achados: any[] = itens.map(() => null);
        let amostra: any = null;
        for (let fim = -1; fim > -dias; fim -= 30) {
          const ag = await clinicorp("/appointment/list", { ...sub, from: diaLocal(agora, Math.max(fim - 29, -dias)), to: diaLocal(agora, fim) }).catch(() => []);
          for (const x of Array.isArray(ag) ? ag : []) {
            if (String(x?.Deleted ?? "").toUpperCase() === "X") continue;
            if (String(x?.ItemType ?? "APPOINTMENT") !== "APPOINTMENT") continue;
            let t = String(x?.MobilePhone ?? "").replace(/\D/g, "");
            if (t.startsWith("55") && t.length >= 12) t = t.slice(2);
            const i = porTel.get(t) ?? porNome.get(nn(x?.PatientName));
            if (i === undefined) continue;
            const d = dataDoItem(x); if (!d) continue;
            const hm = /^(\d{1,2}):(\d{2})/.exec(String(x?.fromTime ?? ""));
            const hora = hm ? `${hm[1].padStart(2, "0")}:${hm[2]}` : "";
            const st: Record<string, unknown> = {};
            for (const [k, v] of Object.entries(x ?? {})) if (/status|confirm|arriv|attend|present|faltou|miss|check/i.test(k)) st[k] = v;
            if (!amostra) amostra = Object.keys(x ?? {});
            const atual = achados[i];
            if (!atual || (d + hora) > (atual.data + atual.hora)) achados[i] = { data: d, hora, categoria: String(x?.CategoryDescription ?? ""), cancelado: String(x?.Canceled ?? "").toUpperCase() === "X", status: st };
          }
        }
        return json({ ok: true, achados, campos: amostra });
      }
      case "horarios": {
        const { a } = await carregarAgente();
        const cfg = { ...(a?.agendamento ?? {}), ...(dados.rascunho ?? {}) };
        if (!cfg.profissional_id) return json({ ok: false, erro: "escolha a profissional" });
        const agora = Date.now();
        const livres = horariosLivres(cfg, await agendaDaProfissional(cfg, agora), agora);
        return json({ ok: true, livres: livres.slice(0, 40), manha: duasOpcoes(livres, "manha").map((h) => descreverHorario(h, agora)), tarde: duasOpcoes(livres, "tarde").map((h) => descreverHorario(h, agora)) });
      }
      case "agendar_teste": {
        // (gestão) marca de verdade, para conferir como fica no Clinicorp
        if (u.papel !== "gestao") return json({ ok: false, erro: "só a gestão" }, 403);
        const { a } = await carregarAgente();
        const r = await marcarNoClinicorp(a?.agendamento ?? {}, { data: String(dados.data), hora: String(dados.hora) }, String(dados.nome), String(dados.telefone), String(dados.observacoes ?? ""));
        let conferido = null;
        if (r.ok) {
          const ag = await clinicorp("/appointment/list", { from: String(dados.data), to: String(dados.data), ...(CLINICORP_SUBSCRIBER_ID ? { subscriber_id: CLINICORP_SUBSCRIBER_ID } : {}) }).catch(() => []);
          const it = (Array.isArray(ag) ? ag : []).find((x: any) => String(x.id) === r.id);
          if (it) conferido = { PatientName: it.PatientName, MobilePhone: it.MobilePhone, fromTime: it.fromTime, toTime: it.toTime, Dentist_PersonId: String(it.Dentist_PersonId), CategoryDescription: it.CategoryDescription, Procedures: it.Procedures, Notes: it.Notes, Patient_PersonId: String(it.Patient_PersonId ?? "") };
        }
        await registro({ tipo: "agendamento", detalhe: `Teste da gestão: ${JSON.stringify(r).slice(0, 300)}`, autor: u.email });
        return json({ ok: r.ok, resultado: r, conferido });
      }
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
