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
//   configurar     {}  → (gestão) liga o app à conta e lista os números
//   conectar_numero { code, waba_id, phone_number_id?, apelido? } → (gestão) coexistência
//   instagram_configurar {} → (gestão) acha as contas do Instagram das Páginas, cadastra e assina os avisos
//
// Conversas do Instagram (canal = 'instagram') usam a mesma tela: texto e arquivo
// saem pela API de mensagens do Instagram (chave da Página, tirada do IG_TOKEN).
// Não existe modelo no Instagram: até 24 h depois da última mensagem da pessoa sai
// normal; de 24 h a 7 dias sai com a etiqueta HUMAN_AGENT (atendimento humano, precisa
// da permissão aprovada pela Meta); depois disso só pelo app do Instagram.
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
const WA_APP_ID = Deno.env.get("WA_APP_ID") ?? "2152669228663129";
const WA_APP_SECRET = Deno.env.get("WA_APP_SECRET") ?? "";
const IG_TOKEN = Deno.env.get("IG_TOKEN") ?? "";
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

async function meta(caminho: string, corpo?: unknown, token = WA_TOKEN) {
  const r = await fetch(GRAPH + caminho, {
    method: corpo === undefined ? "GET" : "POST",
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: corpo === undefined ? undefined : JSON.stringify(corpo),
  });
  const j = await r.json().catch(() => ({}));
  return { ok: r.ok, status: r.status, j };
}

// Chave do número: números conectados pelo celular têm chave própria; os demais usam a do crmmaluco
const _tokens = new Map<string, string>();
async function tokenDoNumero(phoneNumberId: string): Promise<string> {
  if (_tokens.has(phoneNumberId)) return _tokens.get(phoneNumberId)!;
  let t = WA_TOKEN;
  try {
    const r = await bancoJson(`/rest/v1/whatsapp_numeros?phone_number_id=eq.${encodeURIComponent(phoneNumberId)}&select=token`);
    if (r?.[0]?.token) t = r[0].token;
  } catch (_) { /* tabela ainda não criada: usa a chave padrão */ }
  _tokens.set(phoneNumberId, t);
  return t;
}

// ---------- Instagram ----------
const _paginas = new Map<string, string>();
async function tokenDaPaginaIg(igId: string): Promise<string> {
  if (_paginas.has(igId)) return _paginas.get(igId)!;
  if (!IG_TOKEN) throw new Error("falta o segredo IG_TOKEN (chave do Instagram)");
  const c = await bancoJson(`/rest/v1/instagram_contas?ig_id=eq.${encodeURIComponent(igId)}&select=page_id`);
  const page = c?.[0]?.page_id;
  if (!page) throw new Error("conta do Instagram sem Página cadastrada (rode instagram_configurar)");
  const r = await meta(`/${page}?fields=access_token`, undefined, IG_TOKEN);
  const t = r.ok ? String(r.j?.access_token ?? "") : "";
  if (!t) throw new Error("não consegui a chave da Página: " + erroMeta(r.j));
  _paginas.set(igId, t);
  return t;
}
async function enviarIg(req: Request, quem: { email: string }, c: any, message: any, tipo: string, textoRegistro: string, extra?: { caminho: string; mime: string; nome: string }) {
  const tk = await tokenDaPaginaIg(c.numero_clinica_id);
  // depois de 24 h (até 7 dias) a resposta sai com a etiqueta de atendimento humano
  const ult = c.ultima_recebida_em ? Date.parse(c.ultima_recebida_em) : 0;
  const humano = Date.now() - ult >= JANELA_MS;
  const r = await meta(`/${c.numero_clinica_id}/messages`, { recipient: { id: c.wa_id }, message, ...(humano ? { messaging_type: "MESSAGE_TAG", tag: "HUMAN_AGENT" } : {}) }, tk);
  const reg = (status: string, mid: string | null, erro: string | null, bruto: unknown) => extra
    ? bancoJson("/rest/v1/rpc/wa_registrar_enviada_midia", { method: "POST", body: JSON.stringify({ p_conversa: c.id, p_wa_message_id: mid, p_tipo: tipo, p_texto: textoRegistro, p_autor: quem.email, p_status: status, p_erro: erro, p_bruto: bruto, p_caminho: extra.caminho, p_mime: extra.mime, p_nome: extra.nome }) })
    : registrar(c, mid, tipo, textoRegistro, quem.email, status, erro, bruto);
  if (!r.ok) {
    const erro = erroMeta(r.j);
    await reg("falhou", null, erro, r.j);
    return resposta(req, { ok: false, erro }, 502);
  }
  const mid = r.j?.message_id ?? null;
  const id = await reg("enviada", mid, null, r.j);
  return resposta(req, { ok: true, mensagem_id: id, wa_message_id: mid });
}
const JANELA_IG = "Passaram mais de 7 dias desde a última mensagem dessa pessoa. Pela API da Meta o CRM não consegue mandar: chame pelo app do Instagram (a mensagem aparece no CRM também).";
const janelaIg = (c: any) => !!c.ultima_recebida_em && Date.now() - Date.parse(c.ultima_recebida_em) < 7 * JANELA_MS;

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
      body: JSON.stringify({ p_numero: String(dados.numero || WA_PHONE_NUMBER_ID), p_wa_id: tel.startsWith("55") ? tel : "55" + tel }),
    });
  }
  if (!id) throw new Error("informe conversa_id ou telefone");
  const c = await bancoJson(`/rest/v1/conversas?id=eq.${id}&select=*`);
  if (!c?.[0]) throw new Error("conversa não encontrada");
  return c[0];
}

export function tipoDaMidia(mime: string): "image" | "video" | "audio" | "document" {
  if (/^image\/(jpeg|png)$/.test(mime)) return "image";
  if (/^video\/(mp4|3gpp)$/.test(mime)) return "video";
  if (/^audio\/(ogg|mpeg|mp4|aac|amr)$/.test(mime)) return "audio";
  return "document";
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

// responder citando uma mensagem (context) e guardar a citação no CRM
async function marcarResposta(id: unknown, respondeA: string | null | undefined) {
  if (!id || !respondeA) return;
  await banco(`/rest/v1/mensagens?id=eq.${id}`, { method: "PATCH", headers: { Prefer: "return=minimal", "Content-Type": "application/json" }, body: JSON.stringify({ responde_a: respondeA }) }).catch(() => {});
}
async function enviar(req: Request, quem: { email: string }, c: any, corpoMeta: any, tipo: string, textoRegistro: string, respondeA?: string | null) {
  if (respondeA) corpoMeta = { ...corpoMeta, context: { message_id: respondeA } };
  const r = await meta(`/${c.numero_clinica_id}/messages`, { messaging_product: "whatsapp", recipient_type: "individual", to: c.wa_id, ...corpoMeta }, await tokenDoNumero(c.numero_clinica_id));
  if (!r.ok) {
    const erro = erroMeta(r.j);
    await registrar(c, null, tipo, textoRegistro, quem.email, "falhou", erro, r.j);
    return resposta(req, { ok: false, erro }, 502);
  }
  const waId = r.j?.messages?.[0]?.id ?? null;
  const id = await registrar(c, waId, tipo, textoRegistro, quem.email, "enviada", null, r.j);
  await marcarResposta(id, respondeA);
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
        if (c.canal === "instagram") {
          if (!janelaIg(c)) return resposta(req, { ok: false, erro: "janela_fechada", detalhe: JANELA_IG }, 409);
          if (texto.length > 1000) return resposta(req, { ok: false, erro: "no Instagram o limite é 1.000 caracteres por mensagem" }, 400);
          return await enviarIg(req, quem, c, { text: texto }, "text", texto);
        }
        if (!janelaAberta(c)) {
          return resposta(req, { ok: false, erro: "janela_fechada", detalhe: "Passaram mais de 24 h desde a última mensagem do paciente. Use um modelo aprovado." }, 409);
        }
        return await enviar(req, quem, c, { type: "text", text: { body: texto, preview_url: true } }, "text", texto, dados.responde_a ? String(dados.responde_a) : null);
      }
      case "reagir": {
        // reação com emoji a uma mensagem (emoji vazio tira a reação)
        const c = await conversa(dados);
        if (c.canal === "instagram") return resposta(req, { ok: false, erro: "Reação pelo CRM só no WhatsApp por enquanto." }, 400);
        const alvo = String(dados.wa_message_id ?? "");
        if (!alvo) return resposta(req, { ok: false, erro: "mensagem sem id do WhatsApp" }, 400);
        if (!janelaAberta(c)) return resposta(req, { ok: false, erro: "janela_fechada", detalhe: "Passaram mais de 24 h desde a última mensagem do paciente: a Meta não deixa reagir." }, 409);
        const emoji = String(dados.emoji ?? "").slice(0, 8);
        return await enviar(req, quem, c, { type: "reaction", reaction: { message_id: alvo, emoji } }, "reaction", emoji ? "Reagiu " + emoji : "Tirou a reação", alvo);
      }
      case "enviar_midia": {
        // A equipe já subiu o arquivo em whatsapp-midia/envios/<conversa>/...; aqui ele vai
        // para a Meta (upload de mídia) e sai como mensagem.
        const c = await conversa(dados);
        const caminho = String(dados.caminho ?? "");
        if (!caminho.startsWith(`envios/${c.id}/`) && !/^galeria\/[^/]+$/.test(caminho)) return resposta(req, { ok: false, erro: "arquivo inválido" }, 400);
        if (c.canal === "instagram") {
          if (!janelaIg(c)) return resposta(req, { ok: false, erro: "janela_fechada", detalhe: JANELA_IG }, 409);
          // o Instagram busca o arquivo por um link: link assinado do Storage, válido por 1 h
          const sg = await bancoJson(`/storage/v1/object/sign/whatsapp-midia/${caminho.split("/").map(encodeURIComponent).join("/")}`, { method: "POST", body: JSON.stringify({ expiresIn: 3600 }) });
          if (!sg?.signedURL) return resposta(req, { ok: false, erro: "não encontrei o arquivo enviado" }, 400);
          const link = SUPABASE_URL + "/storage/v1" + sg.signedURL;
          const mimeIg = String(dados.mime || "application/octet-stream").split(";")[0].trim();
          const t = /^image\//.test(mimeIg) ? "image" : /^video\//.test(mimeIg) ? "video" : /^audio\//.test(mimeIg) ? "audio" : "file";
          const nomeIg = String(dados.nome || caminho.split("/").pop() || "arquivo");
          const txt = ({ image: "📷 Foto", video: "🎥 Vídeo", audio: "🎤 Áudio", file: "📄 " + nomeIg } as Record<string, string>)[t];
          return await enviarIg(req, quem, c, { attachment: { type: t, payload: { url: link } } }, t === "file" ? "document" : t, txt, { caminho, mime: mimeIg, nome: nomeIg });
        }
        if (!janelaAberta(c)) {
          return resposta(req, { ok: false, erro: "janela_fechada", detalhe: "Passaram mais de 24 h desde a última mensagem do paciente. Use um modelo aprovado." }, 409);
        }
        const arq = await banco(`/storage/v1/object/whatsapp-midia/${caminho.split("/").map(encodeURIComponent).join("/")}`, { headers: { "Content-Type": "application/octet-stream" } });
        if (!arq.ok) return resposta(req, { ok: false, erro: "não encontrei o arquivo enviado" }, 400);
        const mime = String(dados.mime || arq.headers.get("content-type") || "application/octet-stream").split(";")[0].trim();
        const bytes = new Uint8Array(await arq.arrayBuffer());
        const tipo = tipoDaMidia(mime);
        const limite = { image: 5, video: 16, audio: 16, document: 100 }[tipo]! * 1024 * 1024;
        if (bytes.byteLength > limite) return resposta(req, { ok: false, erro: `arquivo grande demais para o WhatsApp (máx. ${limite / 1048576} MB para ${tipo === "image" ? "fotos" : tipo === "video" ? "vídeos" : tipo === "audio" ? "áudios" : "documentos"})` }, 400);
        const nome = String(dados.nome || caminho.split("/").pop() || "arquivo");
        const token = await tokenDoNumero(c.numero_clinica_id);
        const fd = new FormData();
        fd.append("messaging_product", "whatsapp");
        fd.append("type", mime);
        fd.append("file", new Blob([bytes], { type: mime }), nome);
        const up = await fetch(`${GRAPH}/${c.numero_clinica_id}/media`, { method: "POST", headers: { Authorization: "Bearer " + token }, body: fd });
        const uj = await up.json().catch(() => ({}));
        if (!up.ok || !uj.id) return resposta(req, { ok: false, erro: "A Meta recusou o arquivo: " + erroMeta(uj) }, 502);
        const legenda = String(dados.legenda ?? "").trim().slice(0, 1024);
        const conteudo: any = { id: uj.id };
        const respondeMidia = dados.responde_a ? String(dados.responde_a) : null;
        if (legenda && tipo !== "audio") conteudo.caption = legenda;
        if (tipo === "document") conteudo.filename = nome;
        const r = await meta(`/${c.numero_clinica_id}/messages`, { messaging_product: "whatsapp", recipient_type: "individual", to: c.wa_id, type: tipo, [tipo]: conteudo, ...(respondeMidia ? { context: { message_id: respondeMidia } } : {}) }, token);
        const texto = legenda || ({ image: "📷 Foto", video: "🎥 Vídeo", audio: "🎤 Áudio", document: "📄 " + nome }[tipo]!);
        const reg = (status: string, waId: string | null, erro: string | null, bruto: unknown) => bancoJson("/rest/v1/rpc/wa_registrar_enviada_midia", {
          method: "POST",
          body: JSON.stringify({ p_conversa: c.id, p_wa_message_id: waId, p_tipo: tipo, p_texto: texto, p_autor: quem.email,
            p_status: status, p_erro: erro, p_bruto: bruto, p_caminho: caminho, p_mime: mime, p_nome: nome }),
        });
        if (!r.ok) {
          const erro = erroMeta(r.j);
          await reg("falhou", null, erro, r.j);
          return resposta(req, { ok: false, erro }, 502);
        }
        const waId = r.j?.messages?.[0]?.id ?? null;
        const id = await reg("enviada", waId, null, r.j);
        await marcarResposta(id, respondeMidia);
        return resposta(req, { ok: true, mensagem_id: id, wa_message_id: waId });
      }
      case "enviar_modelo": {
        const nome = String(dados.nome ?? "").trim();
        if (!nome) return resposta(req, { ok: false, erro: "escolha um modelo" }, 400);
        const variaveis: string[] = Array.isArray(dados.variaveis) ? dados.variaveis.map(String) : [];
        const campos: string[] = Array.isArray(dados.campos) ? dados.campos.map(String) : [];
        const nomeado = dados.formato === "NAMED";
        const c = await conversa(dados);
        if (c.canal === "instagram") return resposta(req, { ok: false, erro: "Modelos são só do WhatsApp. No Instagram, responda quando a pessoa escrever." }, 400);
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
        if (c.canal === "instagram") {
          try { await meta(`/${c.numero_clinica_id}/messages`, { recipient: { id: c.wa_id }, sender_action: "mark_seen" }, await tokenDaPaginaIg(c.numero_clinica_id)); } catch (_) { /* segue */ }
        } else if (wamid) await meta(`/${c.numero_clinica_id}/messages`, { messaging_product: "whatsapp", status: "read", message_id: wamid }, await tokenDoNumero(c.numero_clinica_id));
        await banco(`/rest/v1/conversas?id=eq.${c.id}`, { method: "PATCH", headers: { Prefer: "return=minimal" }, body: JSON.stringify({ nao_lidas: 0 }) });
        return resposta(req, { ok: true });
      }
      case "criar_modelo": {
        // Só gestão: cria um modelo na Meta (vai para a análise dela).
        // { nome, categoria: "UTILITY"|"MARKETING", corpo, exemplos: [], rodape?, botoes?: ["Confirmar avaliação"] }
        if (quem.papel !== "gestao") return resposta(req, { ok: false, erro: "só a gestão cria modelos" }, 403);
        const nome = String(dados.nome ?? "").trim().toLowerCase();
        const corpo = String(dados.corpo ?? "").trim();
        if (!/^[a-z0-9_]{1,512}$/.test(nome) || !corpo) return resposta(req, { ok: false, erro: "nome (só letras minúsculas, números e _) e corpo são obrigatórios" }, 400);
        const exemplos: string[] = Array.isArray(dados.exemplos) ? dados.exemplos.map(String) : [];
        const components: any[] = [{ type: "BODY", text: corpo, ...(exemplos.length ? { example: { body_text: [exemplos] } } : {}) }];
        if (dados.rodape) components.push({ type: "FOOTER", text: String(dados.rodape).slice(0, 60) });
        const botoes: string[] = Array.isArray(dados.botoes) ? dados.botoes.map(String).filter(Boolean) : [];
        if (botoes.length) components.push({ type: "BUTTONS", buttons: botoes.map((t) => ({ type: "QUICK_REPLY", text: t.slice(0, 25) })) });
        const r = await meta(`/${WA_WABA_ID}/message_templates`, {
          name: nome, language: String(dados.idioma ?? "pt_BR"), category: String(dados.categoria ?? "UTILITY").toUpperCase(), components,
        });
        if (!r.ok) return resposta(req, { ok: false, erro: erroMeta(r.j) }, 502);
        return resposta(req, { ok: true, id: r.j?.id, status: r.j?.status, categoria: r.j?.category });
      }
      case "status_modelos": {
        // situação de alguns modelos (aprovado, em análise, recusado e o motivo)
        const nomes: string[] = Array.isArray(dados.nomes) ? dados.nomes.map(String) : [];
        const r = await meta(`/${WA_WABA_ID}/message_templates?limit=200&fields=name,status,category,rejected_reason,language`);
        if (!r.ok) return resposta(req, { ok: false, erro: erroMeta(r.j) }, 502);
        const lista = (r.j?.data ?? []).filter((t: any) => !nomes.length || nomes.includes(t.name));
        return resposta(req, { ok: true, modelos: lista });
      }
      case "instagram_configurar": {
        // Só gestão: lê as Páginas que o usuário do sistema enxerga, acha o Instagram de cada uma,
        // cadastra em instagram_contas (atendente padrão: dados.atribuir_a) e assina os avisos de mensagens.
        if (quem.papel !== "gestao") return resposta(req, { ok: false, erro: "só a gestão configura o Instagram" }, 403);
        if (!IG_TOKEN) return resposta(req, { ok: false, erro: "falta o segredo IG_TOKEN" }, 500);
        const pgs = await meta(`/me/accounts?fields=id,name,access_token,instagram_business_account{id,username}&limit=50`, undefined, IG_TOKEN);
        if (!pgs.ok) return resposta(req, { ok: false, erro: erroMeta(pgs.j) }, 502);
        const contas: any[] = [];
        for (const pg of pgs.j?.data ?? []) {
          const ig = pg.instagram_business_account;
          if (!ig?.id) { contas.push({ pagina: pg.name, instagram: null }); continue; }
          const apelido = /dra|lari/i.test(ig.username ?? "") ? "Dra. Larissa" : /bulhoesodonto/i.test(ig.username ?? "") ? "Clínica" : (ig.username ?? pg.name);
          await bancoJson("/rest/v1/instagram_contas?on_conflict=ig_id", {
            method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
            body: JSON.stringify({ ig_id: ig.id, page_id: pg.id, usuario: ig.username ?? null, apelido, ...(dados.atribuir_a ? { atribuir_a: String(dados.atribuir_a).toLowerCase() } : {}) }),
          });
          let assinatura: unknown = true;
          for (const campos of ["messages,messaging_postbacks,message_reactions,messaging_seen", "messages"]) {
            const a = await meta(`/${pg.id}/subscribed_apps?subscribed_fields=${campos}`, {}, pg.access_token);
            assinatura = a.ok ? campos : erroMeta(a.j);
            if (a.ok) break;
          }
          contas.push({ pagina: pg.name, page_id: pg.id, instagram: ig.username, ig_id: ig.id, apelido, assinatura });
        }
        return resposta(req, { ok: true, contas });
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
      case "conectar_numero": {
        // Só gestão. Recebe o código do cadastro incorporado da Meta (botão "Conectar número do
        // celular"), troca por uma chave, liga o app à conta, pede a cópia dos contatos e do
        // histórico (a Meta só deixa pedir uma vez e dentro de 24 h) e cadastra o número.
        if (quem.papel !== "gestao") return resposta(req, { ok: false, erro: "só a gestão conecta números" }, 403);
        const code = String(dados.code ?? "").trim();
        const wabaId = String(dados.waba_id ?? "").trim();
        if (!code || !wabaId) return resposta(req, { ok: false, erro: "faltou o código ou a conta do WhatsApp" }, 400);
        if (!WA_APP_SECRET) return resposta(req, { ok: false, erro: "falta o segredo WA_APP_SECRET" }, 500);
        const passos: Record<string, unknown> = {};

        const tk = await fetch(`${GRAPH}/oauth/access_token?client_id=${WA_APP_ID}&client_secret=${encodeURIComponent(WA_APP_SECRET)}&code=${encodeURIComponent(code)}`);
        const tj = await tk.json().catch(() => ({}));
        if (!tk.ok || !tj.access_token) return resposta(req, { ok: false, erro: "A Meta recusou o código: " + erroMeta(tj) }, 502);
        const token = String(tj.access_token);

        let phoneId = String(dados.phone_number_id ?? "").trim();
        const nums = await meta(`/${wabaId}/phone_numbers?fields=id,display_phone_number,verified_name,platform_type,status`, undefined, token);
        const lista: any[] = nums.ok ? nums.j?.data ?? [] : [];
        const num = lista.find((n) => n.id === phoneId) ?? lista[0];
        if (!num) return resposta(req, { ok: false, erro: "não encontrei o número nessa conta: " + erroMeta(nums.j) }, 502);
        phoneId = num.id;
        passos.numero = num.display_phone_number;

        const assinar = await meta(`/${wabaId}/subscribed_apps`, {}, token);
        passos.app_ligado = assinar.ok ? true : erroMeta(assinar.j);

        const coexistencia = dados.coexistencia !== false;
        let pedidoContatos: string | null = null, pedidoHistorico: string | null = null;
        if (coexistencia) {
          const c1 = await meta(`/${phoneId}/smb_app_data`, { messaging_product: "whatsapp", sync_type: "smb_app_state_sync" }, token);
          pedidoContatos = c1.ok ? c1.j?.request_id ?? "ok" : null;
          passos.contatos = c1.ok ? "pedido" : erroMeta(c1.j);
          const c2 = await meta(`/${phoneId}/smb_app_data`, { messaging_product: "whatsapp", sync_type: "history" }, token);
          pedidoHistorico = c2.ok ? c2.j?.request_id ?? "ok" : null;
          passos.historico = c2.ok ? "pedido" : erroMeta(c2.j);
        }

        await bancoJson("/rest/v1/rpc/wa_salvar_numero", {
          method: "POST",
          body: JSON.stringify({
            p_phone_number_id: phoneId, p_waba_id: wabaId, p_exibicao: num.display_phone_number ?? null,
            p_apelido: String(dados.apelido ?? "").trim() || num.verified_name || null, p_token: token,
            p_coexistencia: coexistencia, p_por: quem.email,
          }),
        });
        if (pedidoContatos || pedidoHistorico) {
          await banco(`/rest/v1/whatsapp_numeros?phone_number_id=eq.${phoneId}`, {
            method: "PATCH", headers: { Prefer: "return=minimal" },
            body: JSON.stringify({ sync_contatos_pedido: pedidoContatos, sync_historico_pedido: pedidoHistorico, historico_progresso: 0 }),
          });
        }
        _tokens.delete(phoneId);
        return resposta(req, { ok: true, phone_number_id: phoneId, passos });
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
