// D7 — Verificações no Supabase HOSPEDADO (projeto de desenvolvimento), para o que a
// stack local não aplica ou não comprova (§19.5, §19.7, §19.8 D3/D4).
// Usa apenas identidades fictícias (@fluvi.test), removidas ao final.
//   FLUVI_REMOTE_URL, FLUVI_REMOTE_ANON_KEY, FLUVI_REMOTE_SERVICE_KEY: do projeto dev
//   pnpm --filter @fluvi/tests test:remote
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const url = process.env.FLUVI_REMOTE_URL ?? "";
const anonKey = process.env.FLUVI_REMOTE_ANON_KEY ?? "";
const serviceKey = process.env.FLUVI_REMOTE_SERVICE_KEY ?? "";
if (!/^https:\/\/[a-z]{20}\.supabase\.co$/.test(url) || !anonKey || !serviceKey) {
  throw new Error("defina FLUVI_REMOTE_URL/ANON_KEY/SERVICE_KEY do projeto de DESENVOLVIMENTO");
}

const noPersist = { auth: { persistSession: false, autoRefreshToken: false } };
const anon = () => createClient(url, anonKey, noPersist);
const service = createClient(url, serviceKey, noPersist);
const run = randomUUID().slice(0, 8);
const email = `remoto.${run}@fluvi.test`;
const PASSWORD = "Fluvi-Remoto-2026-Forte";
let userId = "";

beforeAll(async () => {
  const { data, error } = await service.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
  if (error) throw error;
  userId = data.user.id;
  // fixture: equivalente a convite aceito (service_role ignora a RLS)
  const upd = await service.from("profiles")
    .update({ provisioned_at: new Date().toISOString(), status: "active", activation_completed_at: new Date().toISOString() })
    .eq("user_id", userId);
  if (upd.error) throw upd.error;
});

afterAll(async () => {
  if (userId) await service.auth.admin.deleteUser(userId);
});

describe("Supabase Auth hospedado", () => {
  it("cadastro público está desativado", async () => {
    const { error } = await anon().auth.signUp({ email: `intruso.${run}@fluvi.test`, password: PASSWORD });
    expect(error?.code).toBe("signup_disabled");
  });

  it("senha fora da política é recusada", async () => {
    const { error } = await service.auth.admin.updateUserById(userId, { password: "curta" });
    expect(error).not.toBeNull();
  });

  it("login de usuário ativo funciona e o banco o reconhece", async () => {
    const client = anon();
    const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD });
    expect(error).toBeNull();
    expect((await client.rpc("whoami")).data).toMatchObject({ user_id: userId, status: "active" });
  });

  it("Edge Function administrativa recusa usuário comum", async () => {
    const client = anon();
    await client.auth.signInWithPassword({ email, password: PASSWORD });
    const { error } = await client.functions.invoke("provision-user", {
      body: { operation_id: randomUUID(), email: `x.${run}@fluvi.test`, display_name: "X", household_id: null },
    });
    expect((error as { context?: Response })?.context?.status).toBe(403);
  });

  it("bloqueado: o hook recusa a emissão de token (D4)", async () => {
    const upd = await service.from("profiles").update({ status: "blocked" }).eq("user_id", userId);
    expect(upd.error).toBeNull();
    const { data, error } = await anon().auth.signInWithPassword({ email, password: PASSWORD });
    expect(data.session).toBeNull();
    expect(error?.message).toMatch(/bloqueada/i);
  });

  it("tentativas de login em rajada são limitadas (D3, HTTP 429)", async () => {
    const statuses: number[] = [];
    for (let i = 0; i < 60 && !statuses.includes(429); i++) {
      const { error } = await anon().auth.signInWithPassword({ email: `ninguem.${run}@fluvi.test`, password: "Errada-123456" });
      statuses.push(error?.status ?? 200);
    }
    expect(statuses).toContain(429);
    console.info(`limite atingido após ${statuses.indexOf(429)} tentativas`);
  }, 120_000);
});
