// ============================================================
// crm-dados — leituras do Dashboard que antes passavam pelo Apps Script
// 25/10/2026
//
// Ações (POST {acao, ...}), só para a equipe logada (token do CRM):
//   • vendas {from, to}: analyticsVendasReaisClinicorp (lançamentos de receita, Novo × Recompra).
//   • futuros: analyticsAgendamentosFuturosClinicorp (avaliações marcadas daqui para frente).
//   • agenda {from, to}: igual ao analyticsAgendaClinicorp do Apps Script
//     (agenda de avaliações do Clinicorp: leads na agenda, comparecimentos e
//     atos de agendar no período). Porte linha a linha, mesmas regras.
//
// Segredos: SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY (automáticos). A
// credencial do Clinicorp vem da tabela api_credentials, como no Apps Script.
// ============================================================

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

const AGENDA_AVALIACOES_KEY = "bulhoes-agenda-avaliacoes";
const BUSINESS_ID_CLINICORP = "5978719232196608";
const STATUS_COMPARECIMENTO_IDS = [4535647399051264, 5329595793145856];
const STATUS_MOSTRAR_EM_CLIENTES_IDS = [5428028591833088, 4535647399051264, 5329595793145856];
const STATUS_LABELS_CLINICORP: Record<number, string> = {
  5713963623645184: "Confirmado",
  5428028591833088: "Em espera",
  4535647399051264: "Em atendimento",
  5329595793145856: "Atendido",
  6203242003038208: "Atrasado",
  5956546933293056: "Ligar",
  5995438600355840: "Prótese pendente",
  5393596979871744: "Faltou",
};

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (c: unknown, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

// ---------- banco ----------
async function banco(caminho: string, init: RequestInit = {}) {
  const h = new Headers(init.headers ?? {});
  h.set("apikey", SERVICE_KEY);
  h.set("Authorization", "Bearer " + SERVICE_KEY);
  if (!h.has("Content-Type")) h.set("Content-Type", "application/json");
  const r = await fetch(SUPABASE_URL + "/rest/v1/" + caminho, { ...init, headers: h });
  const t = await r.text();
  if (!r.ok) throw new Error(`Supabase ${r.status}: ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}
const supabaseGet = (q: string) => banco(q);
const supabaseUpsert = (q: string, body: unknown) =>
  banco(q, { method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" }, body: JSON.stringify(body) });

async function cacheLer(chave: string): Promise<any> {
  const r = await banco(`cache_kv?chave=eq.${encodeURIComponent(chave)}&expira=gt.${encodeURIComponent(new Date().toISOString())}&select=valor`).catch(() => null);
  return r && r[0] ? r[0].valor : null;
}
async function cacheGravar(chave: string, valor: unknown, segundos: number) {
  await banco("cache_kv?on_conflict=chave", {
    method: "POST", headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
    body: JSON.stringify({ chave, valor, expira: new Date(Date.now() + segundos * 1000).toISOString() }),
  }).catch(() => {});
}

// ---------- utilidades (iguais às do Apps Script) ----------
/** yyyy-MM-dd no fuso de São Paulo (Session.getScriptTimeZone do Apps Script). */
function formatarDataISO(d: Date): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo", year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}
function normalizarTelefoneClinicorp(raw: unknown): string | null {
  if (!raw) return null;
  let d = String(raw).replace(/\D/g, "");
  if (!d) return null;
  if (d.length === 12 || d.length === 13) {
    if (d.indexOf("55") === 0) d = d.substring(2);
  }
  return d || null;
}
function limparNomeClinicorp(nomeCru: unknown): string {
  return String(nomeCru || "").replace(/\s*\(\d+\)\s*$/, "").trim();
}
function normalizarCanonico(tel: unknown): string {
  let d = String(tel || "").replace(/\D/g, "");
  if (!d) return "";
  if ((d.length === 12 || d.length === 13) && d.indexOf("55") === 0) d = d.substring(2);
  if (d.length === 10) d = d.substring(0, 2) + "9" + d.substring(2);
  return d;
}
function normalizarNomeSafety(nome: unknown): string {
  return String(nome || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").trim();
}
const tem = (o: any, k: string) => Object.prototype.hasOwnProperty.call(o, k);

// ---------- agenda de avaliações (analyticsAgendaClinicorp) ----------
async function agenda(fromParam?: string, toParam?: string) {
  const hoje = new Date();
  const [ay, am] = formatarDataISO(hoje).split("-").map(Number);
  const from = fromParam || `${ay}-${String(am).padStart(2, "0")}-01`;
  const to = toParam || formatarDataISO(hoje);

  const rows = await supabaseGet("crm_sessions?email_clinica=eq." + encodeURIComponent(AGENDA_AVALIACOES_KEY) + "&select=crm_json");
  const agenda: Record<string, any> = (rows && rows[0] && rows[0].crm_json) ? JSON.parse(rows[0].crm_json) : {};

  let fonte = "supabase";
  const diasNoPeriodo = Math.round((Date.parse(to + "T12:00") - Date.parse(from + "T12:00")) / 86400000);
  if (diasNoPeriodo <= 100) {
    const cred = await supabaseGet("api_credentials?servico=eq.clinicorp&select=username,token");
    if (cred && cred.length > 0) {
      const username = cred[0].username;
      const token = cred[0].token;
      const authHeader = "Basic " + btoa(username + ":" + token);
      const queryFrom = formatarDataISO(new Date(hoje.getTime() - 90 * 24 * 60 * 60 * 1000));
      const queryTo = formatarDataISO(new Date(hoje.getTime() + 365 * 24 * 60 * 60 * 1000));
      const urlLive = "https://api.clinicorp.com/rest/v1/appointment/list"
        + "?subscriber_id=" + encodeURIComponent(username)
        + "&from=" + queryFrom + "&to=" + queryTo + "&businessId=" + BUSINESS_ID_CLINICORP;
      const respLive = await fetch(urlLive, { headers: { accept: "application/json", Authorization: authHeader } });
      if (respLive.status === 200) {
        const agendamentosLive: any[] = JSON.parse(await respLive.text());
        let mesclados = 0;
        const CACHE_KEY = "clinicorp_phone_by_personid_v1";
        const telefonePorPatientId: Record<string, string | null> = (await cacheLer(CACHE_KEY)) ?? {};
        const faltando: string[] = [];
        const vistosPid: Record<string, boolean> = {};
        for (const agPre of agendamentosLive) {
          const categoriaPre = String(agPre.CategoryDescription || "").trim().toLowerCase();
          if (categoriaPre.indexOf("avalia") === -1) continue;
          if (normalizarTelefoneClinicorp(agPre.MobilePhone)) continue;
          const pid = agPre.Patient_PersonId;
          if (!pid) continue;
          if (!tem(telefonePorPatientId, String(pid)) && !vistosPid[pid]) { vistosPid[pid] = true; faltando.push(String(pid)); }
        }
        if (faltando.length > 0) {
          try {
            const resps = await Promise.all(faltando.map((pid) =>
              fetch("https://api.clinicorp.com/rest/v1/patient/get?subscriber_id=" + encodeURIComponent(username) + "&PatientId=" + pid,
                { headers: { accept: "application/json", Authorization: authHeader } })
                .then(async (r) => ({ ok: r.status === 200, t: await r.text() })).catch(() => ({ ok: false, t: "" }))));
            resps.forEach((r, idx) => {
              let tel: string | null = null;
              if (r.ok) { try { tel = normalizarTelefoneClinicorp(JSON.parse(r.t).Phone); } catch (_e) { /* segue */ } }
              telefonePorPatientId[faltando[idx]] = tel;
            });
            await cacheGravar(CACHE_KEY, telefonePorPatientId, 21600);
          } catch (_e) {
            faltando.forEach((pid) => { telefonePorPatientId[pid] = null; });
          }
        }
        const resolverTel = (ag: any) => {
          const telDireto = normalizarTelefoneClinicorp(ag.MobilePhone);
          if (telDireto) return telDireto;
          const pid = ag.Patient_PersonId;
          if (!pid) return null;
          return tem(telefonePorPatientId, String(pid)) ? telefonePorPatientId[String(pid)] : null;
        };
        for (const ag of agendamentosLive) {
          const idAg = ag.id || ag.AppointmentId;
          if (!idAg) continue;
          const categoria = String(ag.CategoryDescription || "").trim().toLowerCase();
          if (categoria.indexOf("avalia") === -1) continue;
          const tel = resolverTel(ag);
          if (!tel) continue;
          const statusIdAg = ag.StatusId ? Number(ag.StatusId) : null;
          const deletadoAg = ag.Deleted === "X";
          agenda[idAg] = {
            tel,
            nome: limparNomeClinicorp(ag.PatientName || ag.Name || "") || "(sem nome)",
            categoria: ag.CategoryDescription,
            data: ag.date ? String(ag.date).substring(0, 10) : null,
            dataCriacao: ag.CreateDate ? String(ag.CreateDate).substring(0, 10) : (ag.date ? String(ag.date).substring(0, 10) : null),
            statusId: statusIdAg,
            statusLabel: deletadoAg ? "Desmarcado/excluído" : (statusIdAg ? (STATUS_LABELS_CLINICORP[statusIdAg] || ("Status " + statusIdAg)) : "Agendado"),
            deletado: deletadoAg,
            evento: "LIVE_MERGE",
            atualizadoEm: new Date().toISOString(),
          };
          mesclados++;
        }
        fonte = "supabase+clinicorp-ao-vivo (" + mesclados + " mesclados)";
        if (mesclados > 0) {
          try {
            await supabaseUpsert("crm_sessions?on_conflict=email_clinica", { email_clinica: AGENDA_AVALIACOES_KEY, crm_json: JSON.stringify(agenda), atualizado_em: new Date().toISOString() });
          } catch (_e) { /* não bloqueia a resposta */ }
        }
      } else {
        fonte = "supabase (busca ao vivo falhou: HTTP " + respLive.status + ")";
      }
    } else {
      fonte = "supabase (sem credencial clinicorp pra buscar ao vivo)";
    }
  } else {
    fonte = "supabase (período > 100 dias, pulou a busca ao vivo pra não estourar o tempo de execução)";
  }

  // deduplicação por conteúdo
  const vistos: Record<string, string> = {};
  for (const id of Object.keys(agenda)) {
    const item = agenda[id];
    if (!item || !item.tel) continue;
    const chave = item.tel + "|" + (item.data || "") + "|" + (item.statusId || "") + "|" + (item.deletado ? "1" : "0");
    if (vistos[chave]) delete agenda[id]; else vistos[chave] = id;
  }

  const porTelefone: Record<string, any[]> = {};
  for (const id of Object.keys(agenda)) {
    const item = agenda[id];
    if (!item.data || item.data < from || item.data > to) continue;
    if (String(item.categoria || "").toLowerCase().indexOf("parceria") !== -1) continue;
    (porTelefone[item.tel] = porTelefone[item.tel] || []).push(item);
  }

  const detalheAgendados: any[] = [];
  for (const tel of Object.keys(porTelefone)) {
    const ags = porTelefone[tel];
    const temComparecimento = ags.some((a) => !a.deletado && a.statusId && STATUS_COMPARECIMENTO_IDS.indexOf(Number(a.statusId)) !== -1);
    const deveAparecerEmClientes = ags.some((a) => !a.deletado && a.statusId && STATUS_MOSTRAR_EM_CLIENTES_IDS.indexOf(Number(a.statusId)) !== -1);
    detalheAgendados.push({
      tel, nome: ags[0].nome, qtd: ags.length,
      statusResumo: ags.map((a) => a.statusLabel + " (" + a.data + ")").join(", "),
      comparecimento: temComparecimento, deveAparecerEmClientes,
    });
  }
  let leadsAgendados = detalheAgendados.length;
  const detalheComparecimentos = detalheAgendados.filter((d) => d.comparecimento);
  let comparecimentos = detalheComparecimentos.length;

  // rede de segurança via _ccData
  const adicionadosPelaRedeDeSeguranca: any[] = [];
  try {
    const crmRows = await supabaseGet("crm_sessions?email_clinica=eq." + encodeURIComponent("bulhoes-clinica-crm") + "&select=crm_json");
    const cc: Record<string, any> = (crmRows && crmRows[0] && crmRows[0].crm_json) ? JSON.parse(crmRows[0].crm_json) : {};
    const telefonesJaContados: Record<string, boolean> = {};
    detalheAgendados.forEach((d) => { telefonesJaContados[normalizarCanonico(d.tel)] = true; });
    const nomesJaContados: Record<string, boolean> = {};
    detalheAgendados.forEach((d) => { if (d.nome) nomesJaContados[normalizarNomeSafety(d.nome)] = true; });
    const telefonesComParceria: Record<string, boolean> = {};
    for (const idAg of Object.keys(agenda)) {
      const itemAg = agenda[idAg];
      if (itemAg && itemAg.tel && String(itemAg.categoria || "").toLowerCase().indexOf("parceria") !== -1) telefonesComParceria[normalizarCanonico(itemAg.tel)] = true;
    }
    for (const tel of Object.keys(cc)) {
      if (tel === "__exclusoes__") continue;
      const e = cc[tel];
      if (!e || !e.consultaTimestampViaClinicorp || !e.consultaTimestamp) continue;
      const dataConsulta = String(e.consultaTimestamp).substring(0, 10);
      if (dataConsulta < from || dataConsulta > to) continue;
      const telCanonico = normalizarCanonico(tel);
      if (!telCanonico || telefonesJaContados[telCanonico]) continue;
      const nomeCanonico = normalizarNomeSafety(e.nomeAtual);
      if (nomeCanonico && nomesJaContados[nomeCanonico]) continue;
      if (telefonesComParceria[telCanonico]) continue;
      telefonesJaContados[telCanonico] = true;
      if (nomeCanonico) nomesJaContados[nomeCanonico] = true;
      comparecimentos++;
      detalheComparecimentos.push({ tel, nome: e.nomeAtual || "(sem nome)", qtd: 1, statusResumo: "Via _ccData (rede de segurança)", comparecimento: true, deveAparecerEmClientes: true });
      leadsAgendados++;
      adicionadosPelaRedeDeSeguranca.push({ tel, nome: e.nomeAtual, data: dataConsulta });
    }
  } catch (_e) { /* não bloqueia */ }

  let totalAgendamentos = 0;
  const detalheAtos: any[] = [];
  for (const id of Object.keys(agenda)) {
    const item = agenda[id];
    const dataAto = item.dataCriacao || item.data;
    if (!dataAto || dataAto < from || dataAto > to) continue;
    if (String(item.categoria || "").toLowerCase().indexOf("parceria") !== -1) continue;
    totalAgendamentos++;
    detalheAtos.push({ tel: item.tel, nome: item.nome, data: item.data, dataCriacao: dataAto, statusLabel: item.statusLabel, statusId: item.statusId || null, deletado: !!item.deletado });
  }
  const pctComparecimento = leadsAgendados > 0 ? Math.round((comparecimentos / leadsAgendados) * 1000) / 10 : 0;
  return {
    status: "ok", fonte, periodo: { from, to }, totalAgendamentos, detalheAtos, leadsAgendados, comparecimentos,
    pctComparecimento, detalheAgendados, detalheComparecimentos, adicionadosPelaRedeDeSeguranca,
  };
}


// ---------- vendas reais (analyticsVendasReaisClinicorp) ----------
async function vendasBruto(fromParam?: string, toParam?: string) {
  const cred = await supabaseGet("api_credentials?servico=eq.clinicorp&select=username,token");
  if (!cred || cred.length === 0) return { status: "erro", mensagem: "Credencial clinicorp não encontrada" };
  const username = cred[0].username, token = cred[0].token;
  const authHeader = "Basic " + btoa(username + ":" + token);
  const hoje = new Date();
  const [ay, am] = formatarDataISO(hoje).split("-").map(Number);
  const from = fromParam || `${ay}-${String(am).padStart(2, "0")}-01`;
  const to = toParam || formatarDataISO(hoje);
  const url = "https://api.clinicorp.com/rest/v1/financial/list_summary?subscriber_id=" + encodeURIComponent(username) + "&from=" + from + "&to=" + to;
  const resp = await fetch(url, { headers: { accept: "application/json", Authorization: authHeader } });
  const corpoTxt = await resp.text();
  if (resp.status !== 200) return { status: "erro", mensagem: "Clinicorp (financial/list_summary) retornou " + resp.status, corpo: corpoTxt.substring(0, 500) };
  const data = JSON.parse(corpoTxt);
  let revenue: any[] = (data.values || []).filter((v: any) => v.PostType === "REVENUE");
  let totalExcluidoPixHonra = 0, qtdExcluidaPixHonra = 0;
  revenue = revenue.filter((v) => {
    const desc = String(v.Description || "").toLowerCase();
    if (desc.indexOf("honra") !== -1) { totalExcluidoPixHonra += Number(v.Amount || 0); qtdExcluidaPixHonra++; return false; }
    return true;
  });
  const crmRows = await supabaseGet("crm_sessions?email_clinica=eq.bulhoes-clinica-crm&select=crm_json");
  const ccData: Record<string, any> = (crmRows && crmRows[0] && crmRows[0].crm_json) ? JSON.parse(crmRows[0].crm_json) : {};
  const telefonePorPersonId: Record<string, string | null> = {};
  const registros: any[] = [];
  let total = 0, chamadasPatientGet = 0, qtdSemDataLancamento = 0;
  revenue = revenue.filter((v) => {
    const dl = String(v.Date || "").substring(0, 10);
    if (!dl) { qtdSemDataLancamento++; return true; }
    return dl >= from && dl <= to;
  });
  const CACHE_KEY = "clinicorp_phone_by_personid_v1";
  const cacheTelefones: Record<string, string | null> = (await cacheLer(CACHE_KEY)) ?? {};
  const unicos: string[] = [];
  const vistos: Record<string, boolean> = {};
  revenue.forEach((v) => { const pid = v.PersonId; if (!pid || pid === -1 || vistos[pid]) return; vistos[pid] = true; unicos.push(String(pid)); });
  const faltando = unicos.filter((pid) => { if (tem(cacheTelefones, pid)) { telefonePorPersonId[pid] = cacheTelefones[pid]; return false; } return true; });
  if (faltando.length > 0) {
    try {
      const resps = await Promise.all(faltando.map((pid) =>
        fetch("https://api.clinicorp.com/rest/v1/patient/get?subscriber_id=" + encodeURIComponent(username) + "&PatientId=" + pid,
          { headers: { accept: "application/json", Authorization: authHeader } })
          .then(async (r) => ({ ok: r.status === 200, t: await r.text() })).catch(() => ({ ok: false, t: "" }))));
      chamadasPatientGet += resps.length;
      resps.forEach((r, idx) => {
        const pid = faltando[idx];
        let tel: string | null = null;
        if (r.ok) { try { tel = normalizarTelefoneClinicorp(JSON.parse(r.t).Phone); } catch (_e) { /* segue */ } }
        telefonePorPersonId[pid] = tel;
        if (tel) cacheTelefones[pid] = tel;
      });
      await cacheGravar(CACHE_KEY, cacheTelefones, 21600);
    } catch (_e) { faltando.forEach((pid) => { telefonePorPersonId[pid] = null; }); }
  }
  const palavrasRecompra = ["manutenç", "manutenc", "ajuste", "avaliaç", "avaliac", "profilaxia", "pix"];
  for (const v of revenue) {
    const valor = Number(v.Amount || 0);
    total += valor;
    const personId = v.PersonId;
    const tel = (personId && personId !== -1 && tem(telefonePorPersonId, String(personId))) ? telefonePorPersonId[String(personId)] : null;
    const descLower = String(v.Description || "").toLowerCase();
    const ehClaramenteRecompra = palavrasRecompra.some((p) => descLower.indexOf(p) !== -1);
    let classe = "Recompra";
    let descricaoFinal = v.Description || "";
    let entradaCc = tel ? ccData[tel] : ccData[String(tel)];
    if (tel && !entradaCc) {
      const vt = [tel, "55" + tel];
      if (tel.length === 11) vt.push(tel.substring(0, 2) + tel.substring(3), "55" + tel.substring(0, 2) + tel.substring(3));
      else if (tel.length === 10) vt.push(tel.substring(0, 2) + "9" + tel.substring(2), "55" + tel.substring(0, 2) + "9" + tel.substring(2));
      for (const x of vt) { if (ccData[x]) { entradaCc = ccData[x]; break; } }
    }
    const manual = entradaCc && entradaCc.orcamentos && entradaCc.orcamentos.find((o: any) => {
      if (o.status !== "Aprovado" || !o.entradaManual) return false;
      return Math.abs(Number(o.fechValor || o.valor || 0) - valor) < 0.01;
    });
    if (manual) {
      classe = manual.pacienteAntigo ? "Recompra" : "Novo";
      if (manual.tratamento) descricaoFinal = manual.tratamento;
    } else if (!ehClaramenteRecompra && tel) {
      const batido = entradaCc && entradaCc.orcamentos && entradaCc.orcamentos.find((o: any) => {
        if (o.status !== "Aprovado" || o.pacienteAntigo) return false;
        return Math.abs(Number(o.fechValor || o.valor || 0) - valor) < 0.01;
      });
      if (batido) { classe = "Novo"; if (batido.tratamento) descricaoFinal = batido.tratamento; }
    }
    registros.push({ nome: limparNomeClinicorp(v.PatientName) || "(sem nome)", telefone: tel || "", valor, data: (v.Date || "").substring(0, 10), descricao: descricaoFinal, classe });
  }
  const totalNovo = registros.filter((r) => r.classe === "Novo").reduce((s, r) => s + r.valor, 0);
  return {
    status: "ok", periodo: { from, to }, total, totalNovo, totalRecompra: total - totalNovo, totalRegistros: registros.length,
    chamadasPatientGet, totalExcluidoPixHonra, qtdExcluidaPixHonra, qtdSemDataLancamento, registros,
  };
}
async function vendas(fromParam?: string, toParam?: string) {
  const hoje = new Date();
  const [ay, am] = formatarDataISO(hoje).split("-").map(Number);
  const f0 = fromParam || `${ay}-${String(am).padStart(2, "0")}-01`;
  const t0 = toParam || formatarDataISO(hoje);
  const kStale = "vr_s_" + f0 + "_" + t0;
  let out: any;
  try { out = await vendasBruto(fromParam, toParam); } catch (e) { out = { status: "erro", mensagem: String((e as Error)?.message ?? e) }; }
  if (out && out.status === "ok") { await cacheGravar(kStale, out, 21600); return out; }
  const velho = await cacheLer(kStale);
  if (velho) { velho.emCache = true; velho.aviso = "Clinicorp indisponível agora — mostrando o último resultado real calculado."; return velho; }
  return out;
}


// ---------- agendamentos futuros (analyticsAgendamentosFuturosClinicorp) ----------
async function futuros() {
  const cred = await supabaseGet("api_credentials?servico=eq.clinicorp&select=username,token");
  if (!cred || cred.length === 0) return { status: "erro", mensagem: "Credencial clinicorp não encontrada em api_credentials" };
  const username = cred[0].username, token = cred[0].token;
  const authHeader = "Basic " + btoa(username + ":" + token);
  const hoje = formatarDataISO(new Date());
  const umAno = formatarDataISO(new Date(Date.now() + 365 * 24 * 60 * 60 * 1000));
  const url = "https://api.clinicorp.com/rest/v1/appointment/list?subscriber_id=" + encodeURIComponent(username) + "&from=" + hoje + "&to=" + umAno + "&businessId=" + BUSINESS_ID_CLINICORP;
  const resp = await fetch(url, { headers: { accept: "application/json", Authorization: authHeader } });
  const txt = await resp.text();
  if (resp.status === 401) return { status: "erro", mensagem: "Clinicorp retornou 401 — ID de acesso ou Token API incorretos/revogados." };
  if (resp.status !== 200) return { status: "erro", mensagem: "Clinicorp retornou " + resp.status, corpo: txt.substring(0, 500) };
  const ags: any[] = JSON.parse(txt);
  const porTelefone: Record<string, any> = {};
  for (const ag of ags) {
    if (ag.Deleted === "X") continue;
    const categoria = String(ag.CategoryDescription || "").trim().toLowerCase();
    if (categoria.indexOf("avalia") === -1 || categoria.indexOf("parceria") !== -1) continue;
    const tel = normalizarTelefoneClinicorp(ag.MobilePhone);
    if (!tel) continue;
    const dataConsulta = ag.date ? String(ag.date).substring(0, 10) : null;
    if (!dataConsulta || dataConsulta < hoje) continue;
    if (!porTelefone[tel] || dataConsulta < porTelefone[tel].data) {
      porTelefone[tel] = { tel, nome: limparNomeClinicorp(ag.PatientName || ag.Name || ""), data: dataConsulta, categoria: ag.CategoryDescription || "" };
    }
  }
  return { status: "ok", fonte: "clinicorp-ao-vivo", periodo: { from: hoje, to: umAno }, total: Object.keys(porTelefone).length, agendamentos: Object.keys(porTelefone).map((t) => porTelefone[t]) };
}

// ---------- entrada ----------
async function ehEquipe(req: Request): Promise<boolean> {
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return false;
  const r = await fetch(SUPABASE_URL + "/rest/v1/rpc/is_equipe_crm", {
    method: "POST", headers: { apikey: ANON_KEY || SERVICE_KEY, Authorization: auth, "Content-Type": "application/json" }, body: "{}",
  }).catch(() => null);
  if (!r || !r.ok) return false;
  return (await r.json().catch(() => false)) === true;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ status: "erro", mensagem: "use POST" }, 405);
  if (!(await ehEquipe(req))) return json({ status: "erro", mensagem: "Não autorizado." }, 401);
  const p = await req.json().catch(() => ({}));
  try {
    if (p.acao === "agenda") return json(await agenda(p.from, p.to));
    if (p.acao === "vendas") return json(await vendas(p.from, p.to));
    if (p.acao === "futuros") return json(await futuros());
    return json({ status: "erro", mensagem: "ação desconhecida" }, 400);
  } catch (e) {
    return json({ status: "erro", mensagem: String((e as Error)?.message ?? e) });
  }
});
