// meta-assinatura-app (12/11/2026): consulta e cadastra a assinatura de avisos (webhook)
// do Instagram no app Bulhões CRM, usando os segredos que já estão na Supabase.
// Só o Lucas (gestão) pode chamar. Nenhum segredo sai na resposta.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const APP_ID = "2152669228663129";
const GESTAO = ["lucasbulhoes1000@gmail.com"];
const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const u = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { Authorization: req.headers.get("Authorization") ?? "", apikey: ANON } });
  const user = u.ok ? await u.json() : null;
  if (!user?.email || !GESTAO.includes(String(user.email).toLowerCase())) return json({ ok: false, erro: "só a gestão" }, 403);
  const segredo = Deno.env.get("WA_APP_SECRET") ?? "";
  const verify = Deno.env.get("WA_VERIFY_TOKEN") ?? "";
  if (!segredo || !verify) return json({ ok: false, erro: "faltam WA_APP_SECRET ou WA_VERIFY_TOKEN" }, 500);
  const tok = `${APP_ID}|${segredo}`;
  const { acao } = await req.json().catch(() => ({ acao: "" }));
  const ler = async () => (await fetch(`https://graph.facebook.com/v21.0/${APP_ID}/subscriptions?access_token=${encodeURIComponent(tok)}`)).json();
  const antes = await ler();
  if (acao !== "assinar_instagram") return json({ ok: true, assinaturas: antes });
  const corpo = new URLSearchParams({
    object: "instagram",
    callback_url: `${SUPABASE_URL}/functions/v1/whatsapp-webhook`,
    fields: "messages,messaging_postbacks,message_reactions,messaging_seen",
    include_values: "true",
    verify_token: verify,
    access_token: tok,
  });
  const r = await (await fetch(`https://graph.facebook.com/v21.0/${APP_ID}/subscriptions`, { method: "POST", body: corpo })).json();
  return json({ ok: r?.success === true, resposta: r, depois: await ler() });
});
