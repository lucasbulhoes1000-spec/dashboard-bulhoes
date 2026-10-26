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
function ok(data) {
  return ContentService.createTextOutput(JSON.stringify(data || {status:'ok'}))
    .setMimeType(ContentService.MimeType.JSON);
}

var SUPABASE_URL_PAC = 'https://gcxuikfjyajlmqbqlyca.supabase.co';

function rankEstagio(stage) {
  var s = String(stage || '').toLowerCase();
  if (s.indexOf('ganho') !== -1 || s.indexOf('fechado') !== -1) return 4;
  if (s.indexOf('compareceu') !== -1) return 3;
  if (s.indexOf('agendou') !== -1) return 2;
  return 1;
}

var ALIAS_AVALIADORES = {
  'dra victoria mota': 'Victória Silva Sanches de Toledo Mota',
  'victoria mota': 'Victória Silva Sanches de Toledo Mota',
  'dra vitoria mota': 'Victória Silva Sanches de Toledo Mota',
  'dra victoria': 'Victória Silva Sanches de Toledo Mota',
  'dra gabriela vera': 'Gabriela Martins Vera',
  'dra gabriela': 'Gabriela Martins Vera',
  'gabriela vera': 'Gabriela Martins Vera'
};

function normalizarNomeAvaliador(nome) {
  if (!nome) return nome;
  var chave = normalizarNome(nome);
  return ALIAS_AVALIADORES[chave] || nome;
}

var MAPA_FORMA_PAGAMENTO = {
  'pix': 'PIX',
  'cartao de credito': 'Cartão de Crédito',
  'cartao de credito externo': 'Cartão de Crédito',
  'cartao de debito': 'Cartão de Débito',
  'boleto': 'Boleto',
  'dinheiro': 'Dinheiro'
};

function normalizarFormaPagamento(raw) {
  if (!raw) return '';
  var chave = normalizarNome(raw);
  return MAPA_FORMA_PAGAMENTO[chave] || raw; // se não reconhecer, devolve cru (melhor que perder a info)
}

function formatarParcelas(n) {
  n = Number(n) || 0;
  if (n <= 1) return 'À vista';
  return n + 'x';
}

function limparNomeClinicorp(nomeCru) {
  return String(nomeCru || '').replace(/\s*\(\d+\)\s*$/, '').trim();
}

function campoOrcamentoManual(orc, campo) {
  if (!orc) return false;
  if (orc._manualFields && orc._manualFields[campo]) return true;
  if (orc.entradaManual && (
      campo === 'pagamento' || campo === 'parcelas' || campo === 'entrada' ||
      campo === 'entradaData' || campo === 'entradaPgto' || campo === 'temEntrada')) {
    return true;
  }
  return false;
}

async function syncOrcamentosClinicorp(dryRun, candidatos, fromParam, toParam) {
  try {
    var serviceKey = PropertiesService.getScriptProperties().getProperty('SUPABASE_SERVICE_KEY');
    if (!serviceKey) return ok({ status: 'erro', mensagem: 'SUPABASE_SERVICE_KEY não configurada nas Script Properties' });

    var CRM_SHARED_KEY = 'bulhoes-clinica-crm';

    // --- MODO "APLICAR CANDIDATOS" — não chama o Clinicorp de novo ---
    if (candidatos) {
      // ⚠️ TRAVA DE CONCORRÊNCIA (22/07/2026): protege o ler+modificar+salvar
      // do crm_json — essa etapa é só processamento local (sem chamada
      // externa lenta), então o lock fica curto.
      var lockCandidatos = LockService.getScriptLock();
      if (!lockCandidatos.tryLock(20000)) {
        return ok({ status: 'erro', pulado: true, mensagem: 'Outra execução estava gravando no CRM ao mesmo tempo — tente novamente em instantes.' });
      }
      try {
      var crmRows2 = (await supabaseGet(serviceKey, 'crm_sessions?email_clinica=eq.' + encodeURIComponent(CRM_SHARED_KEY) + '&select=crm_json'));
      if (!crmRows2 || !crmRows2[0] || !crmRows2[0].crm_json) {
        return ok({ status: 'erro', mensagem: 'Nenhum crm_json encontrado em crm_sessions para a chave compartilhada da clínica.' });
      }
      var ccData2 = JSON.parse(crmRows2[0].crm_json);
      var novosAplicados = 0, atualizadosAplicados = 0, clientesCriadosAplicados = 0;

      (candidatos.novoCliente || []).forEach(function (c) {
        if (ccData2[c.tel]) {
          // Nesse meio-tempo (entre simular e confirmar) o telefone passou a existir —
          // não sobrescreve o cliente, só acrescenta os orçamentos que vieram junto.
          if (!ccData2[c.tel].orcamentos) ccData2[c.tel].orcamentos = [];
          (c.cliente.orcamentos || []).forEach(function (o) {
            // ⚠️ CORRIGIDO (11/08/2026, mesmo padrão do bug do Marcelo): sem o
            // fallback por _treatmentId, se o "id" do Clinicorp mudasse entre
            // simular e confirmar, essa checagem de duplicata podia falhar e
            // deixar o MESMO orçamento entrar duas vezes.
            var jaExiste = ccData2[c.tel].orcamentos.some(function (ex) {
              return ex._clinicorpId === o._clinicorpId || (o._treatmentId && ex._treatmentId === o._treatmentId && ex.data === o.data);
            });
            if (!jaExiste) { ccData2[c.tel].orcamentos.unshift(o); novosAplicados++; }
          });
        } else {
          ccData2[c.tel] = c.cliente;
          clientesCriadosAplicados++;
        }
      });
      (candidatos.novos || []).forEach(function (c) {
        if (!ccData2[c.tel]) return; // segurança extra — não cria telefone novo do zero
        if (!ccData2[c.tel].orcamentos) ccData2[c.tel].orcamentos = [];
        if (c.nomeCompleto) ccData2[c.tel].nomeAtual = c.nomeCompleto;
        if (c.statusGanho) { ccData2[c.tel].statusAtual = 'Ganho'; ccData2[c.tel].statusAtualEditedAt = new Date().toISOString(); }
        // Confere de novo se já não foi importado por outro caminho nesse meio-tempo
        var jaExiste = ccData2[c.tel].orcamentos.some(function (o) {
          return o._clinicorpId === c.orcamento._clinicorpId || (c.orcamento._treatmentId && o._treatmentId === c.orcamento._treatmentId && o.data === c.orcamento.data);
        });
        if (!jaExiste) {
          ccData2[c.tel].orcamentos.unshift(c.orcamento);
          novosAplicados++;
        }
      });
      (candidatos.atualizados || []).forEach(function (c) {
        if (!ccData2[c.tel] || !ccData2[c.tel].orcamentos) return;
        if (c.nomeCompleto) ccData2[c.tel].nomeAtual = c.nomeCompleto;
        if (c.statusGanho) { ccData2[c.tel].statusAtual = 'Ganho'; ccData2[c.tel].statusAtualEditedAt = new Date().toISOString(); }
        // ⚠️ CORRIGIDO (11/08/2026, caso "Marcelo" de novo — o mesmo bug do
        // _treatmentId existia AQUI TAMBÉM, na etapa de APLICAR, não só na
        // de detectar): sem o fallback por _treatmentId, essa busca falhava
        // silenciosamente sempre que o "id" do Clinicorp vinha diferente do
        // que foi salvo — o statusAtual do cliente virava "Ganho" (isso não
        // depende de achar o orçamento), mas o orçamento em si (status,
        // entrada, valor fechado) nunca era tocado.
        var existente = ccData2[c.tel].orcamentos.find(function (o) { return o._clinicorpId === c.clinicorpId; });
        if (!existente) existente = ccData2[c.tel].orcamentos.find(function (o) { return o._treatmentId && o._treatmentId === c.treatmentId && o.data === c.data; });
        if (!existente && c.treatmentId) { existente = ccData2[c.tel].orcamentos.find(function (o) { return !o._treatmentId && o._clinicorpId === c.treatmentId; }); if (existente) existente._treatmentId = c.treatmentId; }
        if (existente) {
          existente.status = c.status;
          existente.valor = c.valor;
          // ⚠️ CORRIGIDO: fechValor nunca era atualizado aqui — o orçamento
          // virava "Aprovado" mas o valor fechado ficava travado em 0 pra
          // sempre, mesmo depois de reaplicar.
          existente.fechValor = c.status === 'Aprovado' ? c.valor : 0;
          if (c.status === 'Aprovado' && !existente.fechData) existente.fechData = c.fechData;
          if (c.pagamento !== undefined) existente.pagamento = c.pagamento;
          if (c.parcelas !== undefined) existente.parcelas = c.parcelas;
          if (c.entrada !== undefined) existente.entrada = c.entrada;
          if (c.entradaData !== undefined) existente.entradaData = c.entradaData;
          if (c.entradaPgto !== undefined) existente.entradaPgto = c.entradaPgto;
          if (c.temEntrada !== undefined) existente.temEntrada = c.temEntrada;
          if (c.obs !== undefined) existente.obs = c.obs;
          atualizadosAplicados++;
        }
      });

      if (novosAplicados > 0 || atualizadosAplicados > 0 || clientesCriadosAplicados > 0) {
        (await supabasePatch(serviceKey, 'crm_sessions?email_clinica=eq.' + encodeURIComponent(CRM_SHARED_KEY), {
          crm_json: JSON.stringify(ccData2),
          atualizado_em: new Date().toISOString()
        }));
      }

      return ok({ status: 'ok', aplicado: true, novos: novosAplicados, atualizados: atualizadosAplicados, clientesCriados: clientesCriadosAplicados });
      } finally {
        lockCandidatos.releaseLock();
      }
    }

    // --- MODO NORMAL — busca no Clinicorp (simulação ou aplicação direta) ---
    var cred = (await supabaseGet(serviceKey, 'api_credentials?servico=eq.clinicorp&select=username,token'));
    if (!cred || cred.length === 0) return ok({ status: 'erro', mensagem: 'Credencial clinicorp não encontrada em api_credentials' });

    var username = cred[0].username;
    var token = cred[0].token;
    var authHeader = 'Basic ' + Utilities.base64Encode(username + ':' + token);

    var hoje = new Date();
    var hojeStr = formatarDataISO(hoje);
    // Usa o período escolhido no filtro da tela (rof-from/rof-to), se enviado.
    // Sem filtro, cai no padrão de últimos 30 dias.
    var periodoFrom = fromParam || formatarDataISO(new Date(hoje.getTime() - 30 * 24 * 60 * 60 * 1000));
    var periodoTo = toParam || hojeStr;

    // ⚠️ O /estimates/list já deu erro 400 com uma janela de 90 dias em produção
    // (07/07/2026) — provável limite de intervalo não documentado. Pra permitir
    // QUALQUER período escolhido no filtro (ex: um mês inteiro de 31 dias, ou um
    // trimestre) sem esbarrar nesse limite, quebramos a busca em blocos de no
    // máximo 30 dias e juntamos os resultados (dedup por id, caso algum orçamento
    // apareça em dois blocos por causa da borda da data).
    var blocos = [];
    var cursorInicio = new Date(periodoFrom + 'T00:00:00-03:00');
    var fimTotal = new Date(periodoTo + 'T00:00:00-03:00');
    while (cursorInicio <= fimTotal) {
      var cursorFim = new Date(cursorInicio.getTime() + 29 * 24 * 60 * 60 * 1000);
      if (cursorFim > fimTotal) cursorFim = fimTotal;
      blocos.push({ from: formatarDataISO(cursorInicio), to: formatarDataISO(cursorFim) });
      cursorInicio = new Date(cursorFim.getTime() + 24 * 60 * 60 * 1000);
    }
    if (blocos.length === 0) blocos.push({ from: periodoFrom, to: periodoTo });

    var estimates = [];
    var idsVistos = {};
    for (var b = 0; b < blocos.length; b++) {
      var urlEstim = 'https://api.clinicorp.com/rest/v1/estimates/list'
        + '?subscriber_id=' + encodeURIComponent(username)
        + '&from=' + blocos[b].from
        + '&to=' + blocos[b].to;

      var respEstim = (await UrlFetchApp.fetch(urlEstim, {
        method: 'get',
        headers: { 'accept': 'application/json', 'Authorization': authHeader },
        muteHttpExceptions: true
      }));
      if (respEstim.getResponseCode() === 401) {
        return ok({ status: 'erro', mensagem: 'Clinicorp retornou 401 — ID de acesso ou Token API incorretos/revogados.' });
      }
      if (respEstim.getResponseCode() !== 200) {
        return ok({ status: 'erro', mensagem: 'Clinicorp (estimates/list) retornou ' + respEstim.getResponseCode() + ' no bloco ' + blocos[b].from + ' a ' + blocos[b].to, corpo: respEstim.getContentText().substring(0, 500) });
      }
      var loteEstimates = JSON.parse(respEstim.getContentText());
      loteEstimates.forEach(function (est) {
        var idU = est.id || est.TreatmentId;
        if (idU && idsVistos[idU]) return; // já veio em outro bloco (borda de data)
        if (idU) idsVistos[idU] = true;
        estimates.push(est);
      });
    }

    // ⚠️ REATIVADO (29/07/2026, pedido do usuário): a entrada/forma de
    // pagamento tinha sido desativada porque o PARCELAMENTO NO CARTÃO não
    // aparece de forma confiável nesse endpoint — mas a ENTRADA (geralmente
    // um pagamento único, à vista, em PIX/dinheiro) normalmente aparece
    // certinho. A lógica de agrupamento mais abaixo (por PaymentHeaderId) já
    // lida com isso: se só a entrada vier (parcelamento faltando), ela ainda
    // é capturada certinha, e o aviso "⚠️ Só R$ X de R$ Y foi encontrado"
    // avisa quando o total não bate — mais honesto que deixar tudo em
    // branco sempre. Se o /payment/list falhar num bloco, não trava a
    // importação inteira — só aquele bloco fica sem dado de pagamento.
    var pagamentosPorTreatmentId = {};
    for (var bp = 0; bp < blocos.length; bp++) {
      var urlPag = 'https://api.clinicorp.com/rest/v1/payment/list'
        + '?subscriber_id=' + encodeURIComponent(username)
        + '&from=' + blocos[bp].from
        + '&to=' + blocos[bp].to;

      var respPag = (await UrlFetchApp.fetch(urlPag, {
        method: 'get',
        headers: { 'accept': 'application/json', 'Authorization': authHeader },
        muteHttpExceptions: true
      }));
      if (respPag.getResponseCode() !== 200) continue; // segue sem dado de pagamento nesse bloco
      var lotePag = JSON.parse(respPag.getContentText());
      lotePag.forEach(function (pag) {
        if (!pag.TreatmentId) return;
        if (!pagamentosPorTreatmentId[pag.TreatmentId]) pagamentosPorTreatmentId[pag.TreatmentId] = [];
        pagamentosPorTreatmentId[pag.TreatmentId].push(pag);
      });
    }

    // ⚠️ TRAVA DE CONCORRÊNCIA (22/07/2026): a busca no Clinicorp acima
    // (potencialmente mais lenta) já terminou antes daqui — a partir deste
    // ponto só falta processar em memória (rápido) e escrever o crm_json,
    // então o lock protege exatamente esse trecho, sem segurar outras
    // execuções durante a parte mais lenta da função.
    var lockOrcamentos = LockService.getScriptLock();
    if (!lockOrcamentos.tryLock(20000)) {
      return ok({ status: 'erro', pulado: true, mensagem: 'Outra execução estava gravando no CRM ao mesmo tempo — tente novamente em instantes.' });
    }
    try {
    var crmRows = (await supabaseGet(serviceKey, 'crm_sessions?email_clinica=eq.' + encodeURIComponent(CRM_SHARED_KEY) + '&select=crm_json'));
    if (!crmRows || !crmRows[0] || !crmRows[0].crm_json) {
      return ok({ status: 'erro', mensagem: 'Nenhum crm_json encontrado em crm_sessions para a chave compartilhada da clínica.' });
    }
    var ccData = JSON.parse(crmRows[0].crm_json);
    // Lista de orçamentos e clientes que a equipe já excluiu manualmente —
    // nunca recriar isso automaticamente num sync futuro (14/07/2026).
    var exclusoes = ccData['__exclusoes__'] || { orcamentos: [], clientes: [] };
    var orcamentosExcluidos = {};
    (exclusoes.orcamentos || []).forEach(function (id) { orcamentosExcluidos[id] = true; });
    var clientesExcluidos = {};
    (exclusoes.clientes || []).forEach(function (tel) { clientesExcluidos[tel] = true; });

    var novos = 0, atualizados = 0, clientesCriados = 0;
    var semTelefone = [];
    var candidatosNovos = [];       // {tel, orcamento} pra orçamento em cliente JÁ existente
    var candidatosAtualizados = []; // {tel, clinicorpId, status, valor, fechData}
    var candidatosNovoCliente = []; // {tel, cliente} — cliente novo inteiro, criado a partir do Clinicorp
    var possiveisDuplicatas = [];
    var novosClientesPorTelefone = {}; // agrupa múltiplos orçamentos do mesmo cliente novo antes de devolver
    var debugAmostra = []; // 🔍 DEBUG TEMPORÁRIO — remover depois

    estimates.forEach(function (est) {
      var tel = normalizarTelefoneClinicorp(est.PatientMobilePhone);
      var idUnico = est.id || est.TreatmentId;
      // Nome SEMPRE completo, sem o código de prontuário colado (ex: "(3227)") —
      // usa o registro oficial do Clinicorp, nunca um apelido que já estivesse
      // salvo no CRM (bug encontrado com a "Carla", 13/07/2026).
      var nomeClinicorp = limparNomeClinicorp(est.PatientName) || '(sem nome)';

      if (!tel) {
        semTelefone.push({ nome: nomeClinicorp, valor: est.Amount, status: est.Status, motivo: 'sem PatientMobilePhone no Clinicorp' });
        return;
      }

      // ⚠️ Nunca recria um orçamento que a equipe já excluiu manualmente
      // (14/07/2026) — sem isso, todo "Puxar orçamentos" trazia de volta algo
      // que tinha sido apagado de propósito.
      if (orcamentosExcluidos[idUnico]) return;

      var entrada = ccData[tel];
      var telResolvido = tel;
      if (!entrada) {
        // ⚠️ Descoberto em produção (07/07/2026): existem entradas antigas no CRM
        // cuja CHAVE foi salva COM o DDI 55 (viola a regra de ouro do projeto,
        // mas existe de fato — provavelmente de importação manual antiga). Sem
        // checar essa variação, o sync não encontrava esses clientes e ia
        // recriar duplicado. Agora testa COM e SEM 55 antes de desistir.
        var variacoes = [tel, '55' + tel];
        if (tel.length === 11) variacoes.push(tel.substring(0, 2) + tel.substring(3), '55' + tel.substring(0, 2) + tel.substring(3));
        else if (tel.length === 10) variacoes.push(tel.substring(0, 2) + '9' + tel.substring(2), '55' + tel.substring(0, 2) + '9' + tel.substring(2));
        for (var i = 0; i < variacoes.length; i++) {
          if (ccData[variacoes[i]]) { entrada = ccData[variacoes[i]]; telResolvido = variacoes[i]; break; }
        }
      }
      // Também considera clientes JÁ criados nesta mesma execução (agrupamento)
      if (!entrada && novosClientesPorTelefone[tel]) entrada = novosClientesPorTelefone[tel];

      var tratamento = '';
      if (Array.isArray(est.ProcedureList)) {
        tratamento = est.ProcedureList.map(function (p) {
          var desc = p.OperationDescription || p.Description || p.Name || '';
          if (!desc) return '';
          // Inclui o número do dente na descrição, quando o Clinicorp manda
          // esse dado (campo "Tooth") — sem isso, várias Restaurações Diretas
          // em dentes diferentes vinham com o MESMO texto e viravam um card
          // só no Fluxo de Tratamento, sem dar pra marcar cada uma
          // separadamente (pedido do usuário, 18/07/2026).
          if (p.Tooth) desc += ' - Dente ' + p.Tooth;
          return desc;
        }).filter(Boolean).join(', ');
      }

      var avaliador = normalizarNomeAvaliador(est.ProfessionalName || '');
      var statusRaw = String(est.Status || '').toUpperCase();
      var statusDash = 'Em aberto';
      if (statusRaw === 'APPROVED') statusDash = 'Aprovado';
      else if (statusRaw === 'REJECTED' || statusRaw === 'DISAPPROVED' || statusRaw === 'REPROVED') statusDash = 'Reprovado';
      var obsExtra = (statusRaw && statusRaw !== 'APPROVED' && statusDash === 'Em aberto') ? ' (status Clinicorp: ' + est.Status + ')' : '';

      var valor = Number(est.Amount || 0);
      var dataOrcamento = (est.CreateDate || est.Date || hojeStr).substring(0, 10);
      // ⚠️ INVESTIGADO (19/07/2026): cheguei a testar usar `CreateDate` aqui
      // (caso "Aline Araújo" — bateu certinho com a aprovação dela,
      // 30/06/2026). Mas o caso "Silvia de Oliveira Araujo" provou que isso é
      // perigoso: o orçamento dela foi CRIADO em 23/10/2025 e só foi
      // APROVADO em 16/07/2026 (quase 9 meses depois) — `CreateDate` fica
      // CONGELADO na criação/rascunho, nunca reflete quando a pessoa
      // realmente aprovou. Usar `CreateDate` teria jogado o fechamento dela
      // pra outubro/2025, um erro muito pior que o problema original.
      // `Date`/`LastChange_Date` continuam sendo a aposta mais segura —
      // acompanham a ÚLTIMA atividade no registro, que normalmente é a
      // própria aprovação (confirmado no caso da Silvia: os três batem
      // juntos em 16/07). Existe um erro residual conhecido e MENOR (caso
      // Aline: 1 dia de diferença, provavelmente alguém só abriu o
      // orçamento no dia seguinte à aprovação) — mas é um risco bem menor
      // que "vazar pra quando a pessoa só começou a negociar".
      var dataFechamento = (est.Date || est.LastChange_Date || '').substring(0, 10);

      // --- Dados de pagamento (entrada, forma, parcelas) — vínculo por TreatmentId ---
      // ⚠️ Descoberto em produção (07/07/2026): um mesmo orçamento pode ter DOIS
      // lançamentos de pagamento separados no Clinicorp — ex: entrada via PIX
      // (1 registro) + restante parcelado no Cartão de Crédito (N registros).
      // Cada lançamento tem seu próprio PaymentHeaderId. Pegar só "o pagamento
      // mais antigo" pra tudo (como era antes) fazia a entrada em PIX ser
      // confundida com a forma de pagamento do orçamento inteiro. Agora agrupa
      // por PaymentHeaderId primeiro: o grupo com MAIOR valor total vira a forma
      // de pagamento "oficial" do orçamento; se houver outro grupo menor E com
      // 1 parcela só, esse vira a "entrada".
      var pagamentosDoTratamento = (est.TreatmentId && pagamentosPorTreatmentId[est.TreatmentId]) || [];
      var pagamentoField = '', parcelasField = '', entradaValor = 0, entradaDataField = '', entradaPgtoField = '', temEntradaField = '';
      if (pagamentosDoTratamento.length > 0) {
        var gruposPorHeader = {};
        pagamentosDoTratamento.forEach(function (p) {
          var chave = p.PaymentHeaderId || ('sem-header-' + (p.PaymentForm || '') + '-' + (p.Amount || 0));
          if (!gruposPorHeader[chave]) gruposPorHeader[chave] = [];
          gruposPorHeader[chave].push(p);
        });
        var grupos = Object.keys(gruposPorHeader).map(function (chave) {
          var itens = gruposPorHeader[chave];
          var total = itens.reduce(function (s, p) { return s + Number(p.Amount || 0); }, 0);
          var maxParcelas = Math.max.apply(null, itens.map(function (p) {
            return Number(p.CreditCardInstallmentsCount || p.InstallmentsCount || 1);
          }));
          var maisAntigo = itens.slice().sort(function (a, b) {
            return String(a.PostDate || a.PaymentDate || '').localeCompare(String(b.PostDate || b.PaymentDate || ''));
          })[0];
          return {
            paymentForm: maisAntigo.PaymentForm,
            total: total,
            parcelas: maxParcelas,
            data: (maisAntigo.PaymentDate || maisAntigo.PostDate || '').substring(0, 10)
          };
        });

        // Ordena do maior valor total pro menor — o maior é o "plano principal"
        grupos.sort(function (a, b) { return b.total - a.total; });
        var planoPrincipal = grupos[0];

        // Se existir um SEGUNDO grupo (menor, geralmente à vista/1 parcela),
        // trata como entrada separada. Se só tiver 1 grupo, e ele for à vista
        // (1 parcela), o valor todo conta como entrada também (mesma convenção
        // já usada no dashboard pra pagamento à vista).
        if (grupos.length > 1) {
          // 2+ grupos capturados = confiança alta de que vimos o quadro
          // completo (entrada + parcelamento) — pode atualizar o rótulo de
          // forma de pagamento principal com segurança.
          pagamentoField = normalizarFormaPagamento(planoPrincipal.paymentForm);
          parcelasField = formatarParcelas(planoPrincipal.parcelas);
          var grupoEntrada = grupos[1];
          entradaValor = grupoEntrada.total;
          entradaDataField = grupoEntrada.data;
          entradaPgtoField = normalizarFormaPagamento(grupoEntrada.paymentForm);
          temEntradaField = entradaValor > 0 ? 'sim' : '';
        } else if (planoPrincipal.parcelas <= 1) {
          // ⚠️ CORRIGIDO (29/07/2026, caso "Alinne"): só 1 grupo capturado, à
          // vista — sempre conta como entrada (linha abaixo), mas só
          // sobrescreve o RÓTULO de "forma de pagamento principal" se esse
          // grupo cobrir quase o valor todo do orçamento (>=90%). Se for só
          // uma fração pequena (sinal de que é SÓ a entrada, e o
          // parcelamento no cartão não veio nessa consulta — já sabido que
          // isso é inconsistente de execução pra execução), não mexe no
          // rótulo principal — mantém o que já estava salvo (ex: "Cartão de
          // Crédito 12x" de uma importação anterior que capturou o quadro
          // completo), em vez de ficar oscilando pra "PIX à vista" e voltando
          // a cada nova sincronização.
          entradaValor = planoPrincipal.total;
          entradaDataField = planoPrincipal.data;
          entradaPgtoField = normalizarFormaPagamento(planoPrincipal.paymentForm);
          temEntradaField = entradaValor > 0 ? 'sim' : '';
          if (valor > 0 && planoPrincipal.total >= valor * 0.9) {
            pagamentoField = normalizarFormaPagamento(planoPrincipal.paymentForm);
            parcelasField = formatarParcelas(planoPrincipal.parcelas);
          }
        }
      }

      // ⚠️ Descoberto em produção (07/07/2026): parcelamento no cartão pode
      // simplesmente NÃO EXISTIR no /payment/list dessa API (confirmado por
      // teste exaustivo — nem por TreatmentId nem por PatientId), mesmo
      // aparecendo normalmente na tela do Clinicorp. Nesses casos, o total que
      // consigo capturar (entrada) fica bem menor que o valor do orçamento.
      // Em vez de cravar "À vista"/forma de pagamento com confiança quando na
      // verdade só vi uma PARTE do pagamento, aviso na observação — mais
      // honesto que fingir certeza sobre um dado que sei que está incompleto.
      var totalPagamentoCapturado = pagamentosDoTratamento.reduce(function (s, p) { return s + Number(p.Amount || 0); }, 0);
      var pagamentoIncompleto = statusDash === 'Aprovado' && totalPagamentoCapturado > 0 && totalPagamentoCapturado < valor * 0.95;
      var obsPagamentoIncompleto = pagamentoIncompleto
        ? ' ⚠️ Só R$ ' + totalPagamentoCapturado + ' de R$ ' + valor + ' foi encontrado no /payment/list — o restante pode estar parcelado no cartão de um jeito que essa API não expõe. Confira manualmente a forma de pagamento completa.'
        : '';

      var orcamentoPronto = {
        status: statusDash,
        avaliador: avaliador,
        tratamento: tratamento,
        pagamento: pagamentoField,
        parcelas: parcelasField,
        fechData: statusDash === 'Aprovado' ? dataFechamento : '',
        fechValor: statusDash === 'Aprovado' ? valor : 0,
        temEntrada: temEntradaField,
        data: dataOrcamento,
        valor: valor,
        entrada: entradaValor,
        entradaData: entradaDataField,
        entradaPgto: entradaPgtoField,
        obs: 'Importado automaticamente do Clinicorp' + obsExtra + obsPagamentoIncompleto,
        crcParticip: '',
        crcNome: '',
        fechamentos: [],
        _clinicorpId: idUnico,
        _treatmentId: est.TreatmentId || null,
        origemClinicorp: true,
        // Cliente novo no CRM = primeiro orçamento dele, então nunca pode
        // ser "já era paciente antes" (não tem como, já que acabou de ser
        // criado agora). No caso de cliente já existente, isso é
        // recalculado mais abaixo, olhando o histórico real dele.
        pacienteAntigo: false
      };

      // --- CASO 1: telefone não existe em lugar nenhum do CRM — cria o cliente ---
      if (!entrada) {
        // ⚠️ Nunca recria um cliente que a equipe já excluiu manualmente
        // (14/07/2026) — sem isso, todo "Puxar orçamentos" trazia de volta
        // alguém que tinha sido apagado de propósito da aba Clientes.
        if (clientesExcluidos[tel]) return;

        if (novosClientesPorTelefone[tel]) {
          // Já criamos um cliente novo pra esse telefone nesta mesma execução —
          // ⚠️ NOVO (23/07/2026, mesmo caso "Vítor"): antes acrescentava o
          // orçamento sem checar duplicata nenhuma — se o Clinicorp trouxesse
          // 2 registros da MESMA pessoa com o MESMO valor na mesma rodada
          // (cliente ainda nem existia no CRM), os dois entravam juntos.
          // ⚠️ CORRIGIDO (10/08/2026, caso "agosto sumiu inteiro"): o
          // TreatmentId sozinho NÃO é mais suficiente pra bloquear — o
          // Clinicorp reaproveita o mesmo TreatmentId quando um plano de
          // tratamento é revisado/atualizado ao longo do tempo, então uma
          // venda NOVA de verdade (mês diferente) podia ser bloqueada só
          // por compartilhar o TreatmentId de um orçamento antigo. Agora a
          // DATA é sempre obrigatória, mesmo quando o TreatmentId bate —
          // uma duplicata de verdade (o mesmo registro reaparecendo) tem a
          // MESMA data também, nunca só o mesmo identificador.
          var possivelDupNovoCliente = novosClientesPorTelefone[tel].orcamentos.find(function (o) {
            var dataDoExistente = o.data || o.fechData || '';
            var mesmaData = dataDoExistente === dataOrcamento;
            var mesmoTreatmentId = est.TreatmentId && o._treatmentId === est.TreatmentId;
            var mesmoValor = Number(o.valor) === valor;
            return mesmaData && (mesmoTreatmentId || mesmoValor);
          });
          if (possivelDupNovoCliente) {
            possiveisDuplicatas.push({
              nome: nomeClinicorp, telefone: tel, valor: valor, tratamento: tratamento,
              origemConflito: 'outro orçamento do mesmo cliente novo, adicionado nesta mesma sincronização'
            });
            return;
          }
          novosClientesPorTelefone[tel].orcamentos.push(orcamentoPronto);
        } else {
          // ⚠️ IMPORTANTE: NÃO setamos consultaTimestamp aqui. O Clinicorp só nos dá a
          // data do ORÇAMENTO (CreateDate), não a data real de comparecimento numa
          // consulta/avaliação. Inventar uma data de comparecimento contaminaria o
          // relatório "Comparecidos x Agendamento" com informação falsa. Por isso o
          // status geral fica em 'Compareceu' (ou 'Ganho' se já aprovado) SEM data
          // associada — só aparece nas telas que não dependem de consultaTimestamp.
          var statusInicial = statusDash === 'Aprovado' ? 'Ganho' : 'Compareceu';
          novosClientesPorTelefone[tel] = {
            nomeAtual: nomeClinicorp,
            origemAtual: '#Clinicorp Direto',
            statusAtual: statusInicial,
            statusAtualEditedAt: new Date().toISOString(),
            leadImportado: true, // congela o status — não deixa o polling do Cloudia tentar "corrigir" algo que nunca existiu lá
            orcamentos: [orcamentoPronto],
            atividades: [],
            anotacoes: []
          };
        }
        candidatosNovoCliente.push({ tel: tel, nome: nomeClinicorp }); // preview — objeto completo vai depois, ao final
        clientesCriados++;
        novos++;
        return;
      }

      // --- CASO 2: cliente já existe — trata como antes ---
      if (!entrada.orcamentos) entrada.orcamentos = [];
      // ⚠️ CORRIGIDO (10/08/2026, caso "Marcelo Brandão" — causa raiz real do
      // sumiço de agosto inteiro): antes só reconhecia "já importei esse
      // orçamento?" pelo _clinicorpId (que é est.id || est.TreatmentId). O
      // problema: o campo "id" do Clinicorp pode não vir preenchido numa
      // consulta e vir preenchido (ou diferente) noutra — especialmente
      // quando o orçamento é APROVADO depois de já ter sido importado como
      // "Em aberto". Quando isso acontecia, o sistema não reconhecia mais
      // como o mesmo orçamento, caía na checagem de duplicata (que SIM
      // reconhecia pelo TreatmentId, mas só pra BLOQUEAR), e a mudança de
      // status (Em Aberto → Aprovado) era descartada inteira, silenciosamente
      // — nem contava como novo, nem atualizava o que já existia. Agora,
      // se não achar por _clinicorpId, tenta de novo pelo _treatmentId
      // (campo mais estável, não muda entre consultas) antes de desistir.
      // ⚠️ REFORÇADO (11/08/2026): como já sabemos que o Clinicorp pode
      // reaproveitar o mesmo _treatmentId em orçamentos DIFERENTES ao longo
      // do tempo (é por isso que o bloqueio de duplicata agora exige data
      // igual também), esse fallback também exige a MESMA data — sem isso,
      // se a mesma pessoa tiver 2 orçamentos de verdade com o mesmo
      // _treatmentId (um antigo, um novo), corria o risco de atualizar o
      // registro ERRADO.
      var existente = entrada.orcamentos.find(function (o) { return o._clinicorpId === idUnico; });
      if (!existente && est.TreatmentId) {
        existente = entrada.orcamentos.find(function (o) { return o._treatmentId === est.TreatmentId && o.data === dataOrcamento; });
      }
      // ⚠️ CORRIGIDO (14/08/2026, caso "Aline" — orçamento de julho aprovado
      // hoje, sumiu): orçamentos salvos ANTES do campo _treatmentId existir
      // no código nunca tiveram esse campo preenchido (confirmado hoje:
      // afeta ~90% dos orçamentos aprovados). Pra esses, o _clinicorpId
      // ANTIGO já É o TreatmentId de verdade (porque na época o Clinicorp
      // não mandava "id", e o sistema usava TreatmentId no lugar) — então
      // tenta casar o TreatmentId de agora com o _clinicorpId salvo. Se
      // achar por aqui, já aproveita pra preencher o _treatmentId que
      // estava faltando (autocura — a próxima sincronização não precisa
      // mais cair nesse fallback pra essa pessoa).
      if (!existente && est.TreatmentId) {
        existente = entrada.orcamentos.find(function (o) { return !o._treatmentId && o._clinicorpId === est.TreatmentId; });
        if (existente) existente._treatmentId = est.TreatmentId;
      }

      if (existente) {
        // Recalcula o pagamento a cada sync e compara com o que já está salvo —
        // não é só "preencher se estiver vazio": se o valor já salvo estiver
        // ERRADO (ex: bug antigo de agrupamento de pagamento que confundia
        // entrada em PIX com a forma de pagamento principal), corrige também.
        // Só mexe quando ACHOU dado de pagamento nessa execução (pagamentoField
        // não vazio) — nunca apaga um valor existente por falta de dado agora.
        // ⚠️ NOVO (29/07/2026, caso "Alinne"): se alguém da equipe já editou
        // esse orçamento manualmente pelo dashboard (existente.entradaManual),
        // a sincronização NUNCA mais mexe em pagamento/parcelas/entrada dele —
        // o dado digitado à mão vale mais que qualquer recálculo automático,
        // mesmo que a API do Clinicorp traga um valor diferente depois.
        var pagamentoDisponivel = pagamentosDoTratamento.length > 0;
        var pagamentoMudou = pagamentoDisponivel && (
          (!campoOrcamentoManual(existente,'pagamento') && (existente.pagamento || '') !== pagamentoField) ||
          (!campoOrcamentoManual(existente,'parcelas') && (existente.parcelas || '') !== parcelasField) ||
          (!campoOrcamentoManual(existente,'entrada') && Number(existente.entrada || 0) !== entradaValor) ||
          (!campoOrcamentoManual(existente,'entradaData') && (existente.entradaData || '') !== (entradaDataField || '')) ||
          (!campoOrcamentoManual(existente,'entradaPgto') && (existente.entradaPgto || '') !== (entradaPgtoField || ''))
        );

        // Nome do Clinicorp diverge do que já está salvo no CRM (ex: "Carla" salvo
        // vs "Carla Fulana de Tal" no Clinicorp) — corrige pro nome completo sempre
        // que tivermos um nome de verdade vindo de lá (13/07/2026).
        var nomeMudou = nomeClinicorp && nomeClinicorp !== '(sem nome)' && entrada.nomeAtual !== nomeClinicorp;

        // 🔍 DEBUG TEMPORÁRIO (07/07/2026) — remover depois de resolver o
        // problema de pagamento não estar sendo detectado como diferente.
        if (dryRun && debugAmostra.length < 30) {
          debugAmostra.push({
            nome: nomeClinicorp, tel: telResolvido, treatmentId: est.TreatmentId,
            qtdPagamentosAchados: pagamentosDoTratamento.length,
            pagamentoExistente: existente.pagamento, pagamentoCalculado: pagamentoField,
            parcelasExistente: existente.parcelas, parcelasCalculado: parcelasField,
            entradaExistente: existente.entrada, entradaCalculada: entradaValor,
            pagamentoMudou: pagamentoMudou
          });
        }

        // Só atualiza a observação se ela ainda for a gerada automaticamente
        // (evita apagar qualquer nota que alguém da equipe tenha escrito por cima)
        var obsMudou = obsPagamentoIncompleto && (existente.obs || '').indexOf('Importado automaticamente do Clinicorp') === 0 &&
          existente.obs.indexOf('⚠️ Só R$') === -1;

        // Se o orçamento está Aprovado mas o estágio do lead ainda não reflete
        // isso (ficou preso em "Agendou"/"Compareceu" de antes), sobe pra
        // "Ganho" — mesma lógica que já existe pro comparecimento, agora
        // também pro fechamento (14/07/2026).
        var statusGanhoNecessario = statusDash === 'Aprovado' && rankEstagio(entrada.statusAtual) < 4;

        var statusMudouAuto = !campoOrcamentoManual(existente,'status') && existente.status !== statusDash;
        var valorMudouAuto = !campoOrcamentoManual(existente,'valor') && Number(existente.valor || 0) !== Number(valor || 0);
        var fechDataMudouAuto = statusDash === 'Aprovado' && !campoOrcamentoManual(existente,'fechData') &&
          dataFechamento && (existente.fechData || '') !== dataFechamento;
        var fechValorMudouAuto = statusDash === 'Aprovado' && !campoOrcamentoManual(existente,'fechValor') &&
          Number(existente.fechValor || 0) !== Number(valor || 0);

        if (statusMudouAuto || valorMudouAuto || fechDataMudouAuto || fechValorMudouAuto ||
            pagamentoMudou || obsMudou || nomeMudou || statusGanhoNecessario) {
          candidatosAtualizados.push({
            tel: telResolvido,
            clinicorpId: idUnico,
            treatmentId: est.TreatmentId || null,
            data: dataOrcamento,
            status: statusMudouAuto ? statusDash : undefined,
            valor: valorMudouAuto ? valor : undefined,
            fechData: fechDataMudouAuto ? dataFechamento : undefined,
            fechValor: fechValorMudouAuto ? valor : undefined,
            pagamento: (pagamentoDisponivel && !campoOrcamentoManual(existente,'pagamento')) ? pagamentoField : undefined,
            parcelas: (pagamentoDisponivel && !campoOrcamentoManual(existente,'parcelas')) ? parcelasField : undefined,
            entrada: (pagamentoDisponivel && !campoOrcamentoManual(existente,'entrada')) ? entradaValor : undefined,
            entradaData: (pagamentoDisponivel && !campoOrcamentoManual(existente,'entradaData')) ? entradaDataField : undefined,
            entradaPgto: (pagamentoDisponivel && !campoOrcamentoManual(existente,'entradaPgto')) ? entradaPgtoField : undefined,
            temEntrada: (pagamentoDisponivel && !campoOrcamentoManual(existente,'temEntrada')) ? temEntradaField : undefined,
            obs: (obsMudou && !campoOrcamentoManual(existente,'obs')) ? ('Importado automaticamente do Clinicorp' + obsExtra + obsPagamentoIncompleto) : undefined,
            nomeCompleto: nomeMudou ? nomeClinicorp : undefined,
            statusGanho: statusGanhoNecessario
          });
          atualizados++;
        }
        return;
      }

      // ⚠️ REGRA (19/07/2026, pedido explícito do usuário): NUNCA importa um
      // orçamento novo se já existir outro orçamento do MESMO paciente com o
      // MESMO valor — travado de vez, não é mais só um aviso que deixava
      // importar mesmo assim. Só aparece na prévia pra revisão manual; se for
      // um caso legítimo (dois orçamentos diferentes que coincidiram de valor),
      // o usuário cria manualmente pelo card do cliente.
      // Ampliado (19/07/2026, caso "Lisandra"): também bloqueia por
      // TreatmentId igual — é o agrupamento de PLANO DE TRATAMENTO do
      // próprio Clinicorp, então bate mesmo que o valor do orçamento já
      // salvo tenha sido corrigido/atualizado numa sincronização anterior
      // (o que fazia o valor parar de bater exato e o bloqueio por valor
      // sozinho deixar de pegar).
      // ⚠️ CORRIGIDO (30/07/2026, caso "só 10 recompras de 100 esperadas"):
      // a regra abaixo bloqueava por VALOR IGUAL sozinho, sem olhar a data —
      // isso impedia qualquer recompra de tratamento com preço fixo (ex:
      // manutenção que custa sempre o mesmo valor) de ser importada como um
      // segundo orçamento de verdade, porque o valor batia com o primeiro já
      // salvo. Agora, valor igual SÓ conta como duplicata se a DATA também
      // bater — uma duplicata de verdade (mesmo registro do Clinicorp
      // reaparecendo, às vezes com TreatmentId diferente por causa de
      // revisão lá) tem a MESMA data também, não só o mesmo valor. Uma
      // recompra real (outra visita, outro dia) passa a entrar normalmente.
      // ⚠️ CORRIGIDO DE NOVO (10/08/2026, caso "agosto inteiro sumiu"): a
      // exceção "TreatmentId igual bloqueia sozinho, sem precisar de data"
      // era PERIGOSA DEMAIS — descobrimos que o Clinicorp reaproveita o
      // MESMO TreatmentId quando um plano de tratamento é revisado/ampliado
      // ao longo do tempo (ex: paciente volta meses depois e adiciona mais
      // procedimentos ao mesmo plano). Isso bloqueava TODA venda nova ligada
      // a um plano já existente, mesmo sendo uma venda real e recente — foi
      // exatamente o que aconteceu com 16 vendas de agosto. Agora a DATA é
      // SEMPRE obrigatória pra bloquear, mesmo quando o TreatmentId bate —
      // sem exceção nenhuma.
      var possivelDup = entrada.orcamentos.find(function (o) {
        var dataDoExistente = o.data || o.fechData || '';
        var mesmaData = dataDoExistente === dataOrcamento;
        var mesmoTreatmentId = est.TreatmentId && o._treatmentId === est.TreatmentId;
        var mesmoValor = Number(o.valor) === valor;
        return mesmaData && (mesmoTreatmentId || mesmoValor);
      });
      if (!possivelDup) {
        possivelDup = candidatosNovos.find(function (c) {
          var dataDoExistente = c.orcamento.data || c.orcamento.fechData || '';
          var mesmaData = dataDoExistente === dataOrcamento;
          var mesmoTreatmentId = est.TreatmentId && c.orcamento._treatmentId === est.TreatmentId;
          var mesmoValor = Number(c.orcamento.valor) === valor;
          return c.tel === telResolvido && mesmaData && (mesmoTreatmentId || mesmoValor);
        });
        if (possivelDup) possivelDup = possivelDup.orcamento; // normaliza formato pro log abaixo
      }
      if (possivelDup) {
        possiveisDuplicatas.push({
          nome: nomeClinicorp, telefone: telResolvido, valor: valor, tratamento: tratamento,
          origemConflito: possivelDup.origemClinicorp ? 'outro orçamento já importado do Clinicorp (tratamento pode ter sido revisado lá)' : 'orçamento lançado manualmente'
        });
        return; // BLOQUEIA — não entra em candidatosNovos, não é importado
      }

      // ⚠️ NOVO (29/07/2026, pedido do usuário): marca automaticamente se a
      // pessoa já era nossa paciente ANTES desse orçamento — mesmo critério
      // usado no formulário manual (já teve algo Aprovado, com entrada
      // registrada, ou com valor fechado registrado). Necessário porque a
      // sincronização automática não passa por revisão humana — sem isso,
      // todo orçamento importado sozinho ficaria classificado como "lead
      // novo" por padrão, inflando a Taxa de Conversão de novo.
      orcamentoPronto.pacienteAntigo = entrada.orcamentos.some(function (o) {
        return o.status === 'Aprovado' || Number(o.entrada || 0) > 0 || Number(o.fechValor || 0) > 0;
      });

      // Se o nome já salvo no CRM for diferente do nome completo do Clinicorp
      // (ex: "Carla" vs nome completo), atualiza aqui também.
      var nomeMudouLeadExistente = nomeClinicorp && nomeClinicorp !== '(sem nome)' && entrada.nomeAtual !== nomeClinicorp;
      var statusGanhoLeadExistente = statusDash === 'Aprovado' && rankEstagio(entrada.statusAtual) < 4;
      candidatosNovos.push({ tel: telResolvido, orcamento: orcamentoPronto, nome: nomeClinicorp, nomeCompleto: nomeMudouLeadExistente ? nomeClinicorp : undefined, statusGanho: statusGanhoLeadExistente });
      novos++;
    });

    // Monta a lista final de candidatos de cliente novo (um por telefone, já com todos os orçamentos agrupados)
    var candidatosNovoClienteCompleto = Object.keys(novosClientesPorTelefone).map(function (tel) {
      return { tel: tel, cliente: novosClientesPorTelefone[tel] };
    });

    // Aplicação direta (sem passar pela etapa de candidatos) — só usada se dryRun===false E nenhum candidato foi passado.
    if (!dryRun) {
      candidatosNovoClienteCompleto.forEach(function (c) { if (!ccData[c.tel]) ccData[c.tel] = c.cliente; });
      candidatosNovos.forEach(function (c) {
        if (c.nomeCompleto) ccData[c.tel].nomeAtual = c.nomeCompleto;
        if (c.statusGanho) { ccData[c.tel].statusAtual = 'Ganho'; ccData[c.tel].statusAtualEditedAt = new Date().toISOString(); }
        ccData[c.tel].orcamentos.unshift(c.orcamento);
      });
      candidatosAtualizados.forEach(function (c) {
        if (c.nomeCompleto) ccData[c.tel].nomeAtual = c.nomeCompleto;
        if (c.statusGanho) { ccData[c.tel].statusAtual = 'Ganho'; ccData[c.tel].statusAtualEditedAt = new Date().toISOString(); }
        // ⚠️ CORRIGIDO (11/08/2026) — mesmo bug e mesma correção do outro
        // ponto de aplicação: fallback por _treatmentId quando o _clinicorpId
        // não bate mais (Clinicorp trocou/preencheu o "id"), e fechValor
        // atualizado junto (antes ficava travado em 0 pra sempre).
        var existente = ccData[c.tel].orcamentos.find(function (o) { return o._clinicorpId === c.clinicorpId; });
        if (!existente) existente = ccData[c.tel].orcamentos.find(function (o) { return o._treatmentId && o._treatmentId === c.treatmentId && o.data === c.data; });
        if (!existente && c.treatmentId) { existente = ccData[c.tel].orcamentos.find(function (o) { return !o._treatmentId && o._clinicorpId === c.treatmentId; }); if (existente) existente._treatmentId = c.treatmentId; }
        if (existente) {
          if (c.status !== undefined) existente.status = c.status;
          if (c.valor !== undefined) existente.valor = c.valor;
          if (c.fechValor !== undefined) existente.fechValor = c.fechValor;
          if (c.fechData !== undefined) existente.fechData = c.fechData;
          if (c.pagamento !== undefined) existente.pagamento = c.pagamento;
          if (c.parcelas !== undefined) existente.parcelas = c.parcelas;
          if (c.entrada !== undefined) existente.entrada = c.entrada;
          if (c.entradaData !== undefined) existente.entradaData = c.entradaData;
          if (c.entradaPgto !== undefined) existente.entradaPgto = c.entradaPgto;
          if (c.temEntrada !== undefined) existente.temEntrada = c.temEntrada;
          if (c.obs !== undefined) existente.obs = c.obs;
        }
      });
      if (novos > 0 || atualizados > 0) {
        (await supabasePatch(serviceKey, 'crm_sessions?email_clinica=eq.' + encodeURIComponent(CRM_SHARED_KEY), {
          crm_json: JSON.stringify(ccData),
          atualizado_em: new Date().toISOString()
        }));
      }
    }
    } finally {
      lockOrcamentos.releaseLock();
    }

    return ok({
      status: 'ok',
      versaoCodigo: 'fix-pagamento-janela-futura-v3', // marcador só pra confirmar qual versão do código está rodando de fato
      debugAmostra: debugAmostra, // 🔍 DEBUG TEMPORÁRIO — remover depois
      dryRun: !!dryRun,
      periodo: { from: periodoFrom, to: periodoTo },
      totalOrcamentos: estimates.length,
      novos: novos,
      clientesCriados: clientesCriados,
      atualizados: atualizados,
      semTelefone: semTelefone.length,
      detalheSemTelefone: semTelefone.slice(0, 150),
      possiveisDuplicatas: possiveisDuplicatas,
      // Devolvidos pra front-end poder aplicar depois SEM chamar o Clinicorp de novo:
      candidatosNovos: candidatosNovos,
      candidatosAtualizados: candidatosAtualizados,
      candidatosNovoCliente: candidatosNovoClienteCompleto
    });

  } catch (err) {
    return ok({ status: 'erro', mensagem: String(err) });
  }
}

function normalizarTelefoneClinicorp(raw) {
  if (!raw) return null;
  var d = String(raw).replace(/\D/g, '');
  if (!d) return null;
  if (d.length === 12 || d.length === 13) {
    if (d.indexOf('55') === 0) d = d.substring(2);
  }
  return d || null;
}

function normalizarNome(nome) {
  return String(nome || '')
    .toLowerCase()
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .trim()
    .replace(/\s+/g, ' ');
}

function formatarDataISO(d) {
  var tz = Session.getScriptTimeZone();
  return Utilities.formatDate(d, tz, 'yyyy-MM-dd');
}

async function supabaseGet(serviceKey, pathComQuery) {
  var resp = (await UrlFetchApp.fetch(SUPABASE_URL_PAC + '/rest/v1/' + pathComQuery, {
    method: 'get',
    headers: { 'apikey': serviceKey, 'Authorization': 'Bearer ' + serviceKey },
    muteHttpExceptions: true
  }));
  if (resp.getResponseCode() >= 300) {
    throw new Error('Supabase GET falhou (' + resp.getResponseCode() + '): ' + resp.getContentText());
  }
  return JSON.parse(resp.getContentText());
}

async function supabasePatch(serviceKey, pathComQuery, body) {
  var resp = (await UrlFetchApp.fetch(SUPABASE_URL_PAC + '/rest/v1/' + pathComQuery, {
    method: 'patch',
    headers: { 'apikey': serviceKey, 'Authorization': 'Bearer ' + serviceKey, 'Prefer': 'return=minimal' },
    contentType: 'application/json',
    payload: JSON.stringify(body),
    muteHttpExceptions: true
  }));
  if (resp.getResponseCode() >= 300) {
    throw new Error('Supabase PATCH falhou (' + resp.getResponseCode() + '): ' + resp.getContentText());
  }
}
// ===================== ENTRADA =====================
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info, x-motor-chave", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const resp = (c, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
async function autorizado(req) {
  const chave = req.headers.get("x-motor-chave") ?? "";
  if (chave) {
    const r = await fetch(SB_URL + "/rest/v1/rpc/automacao_conferir_chave", { method: "POST", headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + SERVICE_KEY, "Content-Type": "application/json" }, body: JSON.stringify({ p_chave: chave }) }).catch(() => null);
    return !!(r && r.ok && (await r.json().catch(() => false)) === true);
  }
  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return false;
  const r = await fetch(SB_URL + "/rest/v1/rpc/is_equipe_crm", { method: "POST", headers: { apikey: ANON_KEY || SERVICE_KEY, Authorization: auth, "Content-Type": "application/json" }, body: "{}" }).catch(() => null);
  return !!(r && r.ok && (await r.json().catch(() => false)) === true);
}
const ROTINAS = {
  orcamentos: (p) => syncOrcamentosClinicorp(!!p.dryRun, p.candidatos || null, p.from || null, p.to || null),
};
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return resp({ status: "erro", mensagem: "use POST" }, 405);
  if (!(await autorizado(req))) return resp({ status: "erro", mensagem: "Não autorizado." }, 401);
  const p = await req.json().catch(() => ({}));
  const f = ROTINAS[p.acao];
  if (!f) return resp({ status: "erro", mensagem: "ação desconhecida" }, 400);
  SIMULAR = !!p.simular; ESCRITAS = []; CRM_LIDO = null;
  try {
    const out = await f(p);
    let j = null; try { j = JSON.parse(out && out.getContent ? out.getContent() : JSON.stringify(out)); } catch (_e) { j = { status: "erro", mensagem: "resposta inválida" }; }
    j._escritas = ESCRITAS.map((e) => ({ ...e, mudancas: p.detalhe ? e.mudancas : undefined }));
    j._simulado = SIMULAR;
    return resp(j);
  } catch (e) {
    return resp({ status: "erro", mensagem: String(e && e.message || e), _escritas: ESCRITAS });
  }
});
