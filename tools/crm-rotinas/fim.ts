
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
