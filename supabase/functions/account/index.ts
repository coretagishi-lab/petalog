// ぺたろぐ account deletion: removes the caller's files, records, shares and login.
import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
function secretKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  try {
    const j = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}");
    return j.default ?? (Object.values(j)[0] as string) ?? "";
  } catch { return ""; }
}
const admin = createClient(SUPABASE_URL, secretKey(), { auth: { persistSession: false, autoRefreshToken: false } });

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function wipeFolder(bucket: string, uid: string) {
  for (let round = 0; round < 50; round++) {
    const { data, error } = await admin.storage.from(bucket).list(uid, { limit: 1000 });
    if (error) throw error;
    if (!data || !data.length) return;
    const paths = data.map((f) => `${uid}/${f.name}`);
    const { error: re } = await admin.storage.from(bucket).remove(paths);
    if (re) throw re;
    if (data.length < 1000) return;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "login_required" }, 401);
  const { data: u, error: ue } = await admin.auth.getUser(token);
  if (ue || !u?.user) return json({ error: "login_required" }, 401);
  const uid = u.user.id;

  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty */ }
  if (body.action !== "delete" || body.confirm !== "削除") return json({ error: "bad_request" }, 400);

  try {
    await wipeFolder("cuts", uid);
    await wipeFolder("photos", uid);
  } catch (e) {
    console.error("storage wipe", e);
    return json({ error: "storage" }, 500);
  }
  // table rows go with the user (on delete cascade)
  const { error: de } = await admin.auth.admin.deleteUser(uid);
  if (de) { console.error("delete user", de); return json({ error: "server" }, 500); }
  return json({ ok: true });
});
