// ぺたろぐ AI function
// - only signed-in users can call it
// - prompts are fixed here on the server (it is not a general-purpose AI proxy)
// - per-user and whole-app daily caps (change with the AI_USER_DAILY / AI_GLOBAL_DAILY secrets)
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

const USER_DAILY = Math.max(1, Number(Deno.env.get("AI_USER_DAILY") ?? 20) || 20);
const GLOBAL_DAILY = Math.max(1, Number(Deno.env.get("AI_GLOBAL_DAILY") ?? 200) || 200);
const MODEL_MAIN = Deno.env.get("AI_MODEL_MAIN") ?? "claude-sonnet-5";
const MODEL_QUICK = Deno.env.get("AI_MODEL_QUICK") ?? "claude-haiku-4-5-20251001";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const GENRES = ["駅", "イベント", "観光地", "商業施設", "道の駅", "博物館・美術館", "寺社", "鉄道・乗り物", "その他"];
const REFS = "500円玉=2.65cm、100円玉=2.26cm、10円玉=2.35cm、1円玉=2cm、カード（横の長さ）=8.56cm、カード（縦の長さ）=5.4cm";
const clip = (v: unknown, n: number) => String(v ?? "").replace(/[\u0000-\u001f]/g, " ").slice(0, n);

type Img = { type: string; data: string };
function cleanImages(raw: unknown, max: number): Img[] {
  if (!Array.isArray(raw)) return [];
  const out: Img[] = [];
  for (const x of raw.slice(0, max)) {
    const type = String((x as Img)?.type ?? "");
    const data = String((x as Img)?.data ?? "");
    if (!/^image\/(png|jpeg|webp)$/.test(type)) continue;
    if (!data || data.length > 2_800_000 || !/^[A-Za-z0-9+/=]+$/.test(data)) continue;
    out.push({ type, data });
  }
  return out;
}

function buildTask(task: string, args: Record<string, unknown>, images: Img[]) {
  if (task === "identify") {
    if (!images.length) return null;
    const extra = clip(args.refs, 300); const digital = args.digital === true;
    const head = digital
      ? `1枚目は、アプリやWebに表示されたデジタルスタンプ（スマホ画面のスクリーンショット）から切り抜いた画像です。${images.length > 1 ? "2枚目は切り抜く前のスクリーンショットです。アプリ名や地名などの文字も手がかりにしてください。" : ""}`
      : `1枚目は紙に押されたスタンプを切り抜いた画像です。${images.length > 1 ? "2枚目は切り抜く前の元の写真です。" : ""}`;
    const size = digital
      ? "2) デジタルスタンプなので実寸はありません。size_cm と size_ref は null にします。"
      : `2) 元の写真に大きさの基準になる物（${REFS}${extra ? "、" + extra : ""} など）が写っていれば、それとの比率からスタンプの実寸（最も長い辺または直径、cm）を見積もってください。基準物が写っていなければ size_cm は null。`;
    return {
      model: MODEL_MAIN, images,
      prompt: `あなたは日本の記念スタンプ（駅スタンプ、イベント、観光地、道の駅、商業施設、博物館などのスタンプ、デジタルスタンプラリーのスタンプ）に詳しい鑑定係です。
${head}
1) スタンプの文字・図柄・形式から、どこのスタンプかを推定してください。読めない文字を創作せず、わからない項目は null にします。
${size}
次の形のJSONだけを返してください:
{"name":"スタンプの名前（例: 東京駅 / 道の駅 ○○）","place":"押せる場所（駅名・施設名）","pref":"都道府県名","cat":"${GENRES.join(" | ")} のどれか","lat":数値かnull,"lng":数値かnull,"text":"読み取れた文字","confidence":0〜1,"reason":"判断の根拠を1文","size_cm":数値かnull,"size_ref":"使った基準物の名前かnull"}
lat/lng はその施設のおおよその代表座標にしてください。`,
    };
  }
  if (task === "goshuin") {
    if (!images.length) return null;
    return {
      model: MODEL_MAIN, images: images.slice(0, 1),
      prompt: `この画像は日本の寺社でいただいた御朱印のページです。墨書きの文字や朱印から、どこの寺社かを推定してください。読めない文字を創作せず、わからない項目は null にします。
JSONだけを返す: {"name":"寺社名","place":"寺社名または場所","pref":"都道府県名","lat":数値かnull,"lng":数値かnull,"text":"読み取れた文字","confidence":0〜1,"reason":"判断の根拠を1文"}`,
    };
  }
  if (task === "geocode") {
    const q = clip(args.q, 200).trim();
    if (!q) return null;
    return {
      model: MODEL_QUICK, images: [],
      prompt: `次の日本の住所または施設名の、おおよその緯度経度を答えてください。確信がなければ confidence を低くし、まったくわからなければ lat と lng を null にします。
入力: ${q}
JSONだけを返す: {"lat":数値かnull,"lng":数値かnull,"pref":"都道府県名かnull","label":"特定した場所の名前","confidence":0〜1}`,
    };
  }
  if (task === "summary") {
    const spots = Array.isArray(args.spots) ? args.spots.slice(0, 20).map((s) => "- " + clip(s, 120)) : [];
    if (spots.length < 1) return null;
    const tags = Array.isArray(args.tags)
      ? args.tags.slice(0, 12).map((t) => Array.isArray(t) ? clip(t[0], 20) + "×" + (Number(t[1]) || 1) : clip(t, 20)).join("、")
      : "";
    return {
      model: MODEL_QUICK, images: [],
      prompt: `駅スタンプの置き場所について、複数の人が書いたメモとタグがあります。共通点をもとに「どこに・何時まであるか」を1〜2文の日本語でまとめてください。食い違う点があれば「〜という情報もあります」と添えます。書かれていないことは足さないでください。
駅: ${clip(args.station, 40)}駅（${clip(args.line, 40)}）
タグ: ${tags || "なし"}
メモ:
${spots.join("\n")}
JSONだけを返す: {"summary":"まとめ"}`,
    };
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  // who is calling?
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "login_required" }, 401);
  const { data: u, error: ue } = await admin.auth.getUser(token);
  if (ue || !u?.user) return json({ error: "login_required" }, 401);
  const uid = u.user.id;

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "bad_request" }, 400); }
  const task = String(body.task ?? "");

  if (task === "status") {
    const { data } = await admin.from("ai_usage").select("count")
      .eq("user_id", uid).eq("day", new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10)).maybeSingle();
    return json({ ok: true, used: data?.count ?? 0, limit: USER_DAILY, ready: !!Deno.env.get("ANTHROPIC_API_KEY") });
  }

  const job = buildTask(task, (body.args ?? {}) as Record<string, unknown>, cleanImages(body.images, 2));
  if (!job) return json({ error: "bad_request" }, 400);

  const key = Deno.env.get("ANTHROPIC_API_KEY");
  if (!key) return json({ error: "not_configured" }, 503);

  const { data: left, error: qe } = await admin.rpc("ai_take", { p_user: uid, p_limit: USER_DAILY, p_global: GLOBAL_DAILY });
  if (qe) return json({ error: "server" }, 500);
  if (left === -1) return json({ error: "user_limit", limit: USER_DAILY }, 429);
  if (left === -2) return json({ error: "global_limit" }, 429);

  const content: unknown[] = job.images.map((im) => ({ type: "image", source: { type: "base64", media_type: im.type, data: im.data } }));
  content.push({ type: "text", text: job.prompt });

  let r: Response;
  try {
    r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01" },
      body: JSON.stringify({ model: job.model, max_tokens: 900, messages: [{ role: "user", content }] }),
    });
  } catch {
    await admin.rpc("ai_refund", { p_user: uid });
    return json({ error: "network" }, 502);
  }
  if (!r.ok) {
    await admin.rpc("ai_refund", { p_user: uid });
    const detail = await r.text().catch(() => "");
    console.error("anthropic", r.status, detail.slice(0, 300));
    return json({ error: r.status === 401 ? "bad_key" : r.status === 429 ? "busy" : "upstream" }, 502);
  }
  const j = await r.json();
  const text = (j.content ?? []).map((x: { text?: string }) => x.text ?? "").join("");
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) return json({ error: "parse" }, 502);
  try {
    return json({ ok: true, result: JSON.parse(m[0]), remaining: left });
  } catch {
    return json({ error: "parse" }, 502);
  }
});
