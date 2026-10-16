// Apoio aos testes de integração: clientes reais (Auth, PostgREST, Edge Functions)
// contra a stack local. Nenhum dado real; e-mails em @fluvi.test.
import { createHmac, randomUUID } from "node:crypto";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import pg from "pg";

export const env = {
  apiUrl: process.env.FLUVI_TEST_API_URL!,
  dbUrl: process.env.FLUVI_TEST_DB_URL!,
  anonKey: process.env.FLUVI_TEST_ANON_KEY!,
  serviceKey: process.env.FLUVI_TEST_SERVICE_ROLE_KEY!,
  mailpitUrl: process.env.FLUVI_TEST_MAILPIT_URL!,
};

export const runId = randomUUID().slice(0, 8);
export const testEmail = (name: string) => `${name}.${runId}@fluvi.test`;
export const PASSWORD = "Fluvi-Teste-2026-Forte";

const noPersist = { auth: { persistSession: false, autoRefreshToken: false } };

export const anonClient = () => createClient(env.apiUrl, env.anonKey, noPersist);
export const serviceClient = () => createClient(env.apiUrl, env.serviceKey, noPersist);

// Acesso direto ao Postgres local, apenas para preparar fixtures privilegiadas
// (ex.: o primeiro Admin, que em produção é provisionado manualmente).
export async function sql<T = Record<string, unknown>>(text: string, params: unknown[] = []): Promise<T[]> {
  const client = new pg.Client({ connectionString: env.dbUrl });
  await client.connect();
  try {
    return (await client.query(text, params)).rows as T[];
  } finally {
    await client.end();
  }
}

export async function signIn(email: string, password = PASSWORD): Promise<SupabaseClient> {
  const client = anonClient();
  const { error } = await client.auth.signInWithPassword({ email, password });
  if (error) throw new Error(`login falhou para ${email}: ${error.message}`);
  return client;
}

export async function accessToken(client: SupabaseClient): Promise<string> {
  const { data } = await client.auth.getSession();
  if (!data.session) throw new Error("sem sessão");
  return data.session.access_token;
}

// TOTP (RFC 6238, SHA-1, 30 s, 6 dígitos) — o mesmo algoritmo de um app autenticador.
export function totp(base32Secret: string, now = Date.now()): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const ch of base32Secret.replace(/=+$/, "").toUpperCase()) {
    const v = alphabet.indexOf(ch);
    if (v < 0) continue;
    bits += v.toString(2).padStart(5, "0");
  }
  const key = Buffer.from(bits.match(/.{8}/g)!.map((b) => parseInt(b, 2)));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(now / 1000 / 30)));
  const hmac = createHmac("sha1", key).update(counter).digest();
  const offset = hmac[hmac.length - 1] & 0x0f;
  const code = (hmac.readUInt32BE(offset) & 0x7fffffff) % 1_000_000;
  return code.toString().padStart(6, "0");
}

// Cadastra fator TOTP e eleva a sessão para aal2. Devolve o segredo para logins futuros.
export async function enrollTotp(client: SupabaseClient): Promise<{ factorId: string; secret: string }> {
  const { data, error } = await client.auth.mfa.enroll({ factorType: "totp", friendlyName: `t-${runId}` });
  if (error) throw error;
  const verify = await client.auth.mfa.challengeAndVerify({ factorId: data.id, code: totp(data.totp.secret) });
  if (verify.error) throw verify.error;
  return { factorId: data.id, secret: data.totp.secret };
}

export async function elevate(client: SupabaseClient, factorId: string, secret: string): Promise<void> {
  const { error } = await client.auth.mfa.challengeAndVerify({ factorId, code: totp(secret) });
  if (error) throw error;
}

export async function invokeFunction(name: string, token: string | null, body: unknown) {
  const res = await fetch(`${env.apiUrl}/functions/v1/${name}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: env.anonKey,
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let json: unknown = null;
  try {
    json = JSON.parse(text);
  } catch {
    json = text;
  }
  return { status: res.status, body: json as Record<string, unknown> };
}

type MailSummary = { ID: string; Created: string };

async function searchMail(email: string): Promise<MailSummary[]> {
  const res = await fetch(`${env.mailpitUrl}/api/v1/search?query=${encodeURIComponent(`to:"${email}"`)}`);
  return ((await res.json()) as { messages?: MailSummary[] }).messages ?? [];
}

export async function mailCount(email: string): Promise<number> {
  return (await searchMail(email)).length;
}

// Espera até existirem `minCount` e-mails para `email` e devolve o link de
// verificação do mais recente, exigindo o tipo pedido (invite, recovery, magiclink).
// O Mailpit lista do mais novo para o mais antigo.
export async function waitForAuthLink(email: string, type: string, minCount = 1): Promise<string> {
  for (let i = 0; i < 40; i++) {
    const messages = await searchMail(email);
    if (messages.length >= minCount) {
      const msg = (await (await fetch(`${env.mailpitUrl}/api/v1/message/${messages[0].ID}`)).json()) as { HTML: string; Text: string };
      const link = (msg.HTML + msg.Text).match(/https?:\/\/[^\s"'<>]+\/auth\/v1\/verify[^\s"'<>]+/)?.[0]?.replaceAll("&amp;", "&");
      if (link && new URL(link).searchParams.get("type") === type) return link;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`e-mail do tipo ${type} não chegou para ${email}`);
}

// Aceita o convite como um usuário real: lê o e-mail no Mailpit, segue o link
// de verificação e define a senha com a sessão obtida.
export async function acceptInvite(email: string, password = PASSWORD): Promise<void> {
  const client = await sessionFromLink(await waitForAuthLink(email, "invite"));
  const { error } = await client.auth.updateUser({ password });
  if (error) throw error;
}

// [auth.email] max_frequency = 60s: simula a passagem do intervalo entre e-mails
// legítimos ao mesmo destinatário (o teste de abuso NÃO usa isto).
export async function allowNextEmail(email: string): Promise<void> {
  await sql("update auth.users set recovery_sent_at = null, confirmation_sent_at = null where email = $1", [email]);
}

// Fixture: usuário financeiro já ativo (equivalente a convite aceito), sem passar por e-mail.
export async function createActiveUser(email: string, password = PASSWORD): Promise<string> {
  const { data, error } = await serviceClient().auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw error;
  await sql(
    `update public.profiles
        set provisioned_at = now(), status = 'active', activation_completed_at = now()
      where user_id = $1`,
    [data.user.id],
  );
  return data.user.id;
}

// v2.2: dados financeiros pertencem a uma família. Cria a família com os membros ativos;
// sem `id`, gera um novo.
export async function createFamily(name: string, members: string[], id?: string): Promise<string> {
  const [row] = await sql<{ id: string }>(
    "insert into public.households (id, name) values (coalesce($1::uuid, gen_random_uuid()), $2) returning id",
    [id ?? null, name.slice(0, 80)],
  );
  for (const user of members) {
    await sql("insert into public.household_members (household_id, user_id) values ($1, $2)", [row.id, user]);
  }
  return row.id;
}

// Usuário financeiro de teste com família própria (mesmo UUID do usuário, para fixtures legíveis).
export async function createFinanceUser(email: string, password = PASSWORD): Promise<string> {
  const id = await createActiveUser(email, password);
  await createFamily(`Família ${email.split("@")[0]}`, [id], id);
  return id;
}

// Segue um link de verificação do Auth (convite, magic link) e devolve um
// cliente com a sessão obtida, como o navegador faria.
export async function sessionFromLink(link: string): Promise<SupabaseClient> {
  const verify = await fetch(link, { redirect: "manual" });
  const location = verify.headers.get("location") ?? "";
  const fragment = new URLSearchParams(location.split("#")[1] ?? "");
  const access_token = fragment.get("access_token");
  const refresh_token = fragment.get("refresh_token");
  if (!access_token || !refresh_token) throw new Error("verificação do link não devolveu sessão");

  const client = anonClient();
  const { error } = await client.auth.setSession({ access_token, refresh_token });
  if (error) throw error;
  return client;
}
