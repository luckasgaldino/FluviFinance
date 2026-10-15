// D3 — Rate limiting das operações do Fluvi sob concorrência real (§19.5, §19.8):
// contagem no servidor, requisições paralelas, expiração da janela e HTTP 429.
// As políticas são reduzidas só durante o teste e restauradas ao final.
import { randomUUID } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  accessToken, createActiveUser, enrollTotp, invokeFunction, runId, signIn, sql, testEmail,
} from "./support";

let admin: SupabaseClient;
let adminId: string;
let original: { bucket_kind: string; max_hits: number; window_seconds: number }[];

const setPolicy = (kind: string, max: number, windowSeconds: number) =>
  sql("update private.rate_limit_policies set max_hits = $2, window_seconds = $3 where bucket_kind = $1",
    [kind, max, windowSeconds]);

beforeAll(async () => {
  original = await sql("select bucket_kind, max_hits, window_seconds from private.rate_limit_policies");
  adminId = await createActiveUser(testEmail("rl-admin"));
  await sql("insert into public.administrators (user_id) values ($1)", [adminId]);
  admin = await signIn(testEmail("rl-admin"));
  await enrollTotp(admin);
});

afterAll(async () => {
  for (const p of original) await setPolicy(p.bucket_kind, p.max_hits, p.window_seconds);
  await sql("delete from private.rate_limit_counters where bucket_key = $1 or bucket_key like $2",
    [adminId, `%.${runId}@fluvi.test`]);
  await sql("delete from public.households where name like $1", [`RL ${runId}%`]);
  await sql("delete from auth.users where email like $1", [`%.${runId}@fluvi.test`]);
});

describe("Rate limit das RPCs administrativas", () => {
  it("12 chamadas paralelas com limite 5: exatamente 5 passam, 7 recebem 429", async () => {
    await setPolicy("admin_rpc", 5, 3600);
    const results = await Promise.all(Array.from({ length: 12 }, (_, i) =>
      admin.rpc("admin_create_household", { p_request_id: randomUUID(), p_name: `RL ${runId} ${i}` })));

    const ok = results.filter((r) => !r.error);
    const limited = results.filter((r) => r.error?.code === "PT429");
    expect(ok).toHaveLength(5);
    expect(limited).toHaveLength(7);
    expect(limited.every((r) => r.status === 429)).toBe(true);

    const [{ n }] = await sql<{ n: number }>("select count(*)::int as n from public.households where name like $1", [`RL ${runId}%`]);
    expect(n).toBe(5);
  });

  it("a janela expira e o Admin volta a operar", async () => {
    await sql("delete from private.rate_limit_counters where bucket_key = $1", [adminId]);
    await setPolicy("admin_rpc", 2, 3);
    // alinha ao início de uma janela de 3 s para o teste não depender do relógio
    await new Promise((r) => setTimeout(r, 3000 - (Date.now() % 3000) + 300));
    for (let i = 0; i < 2; i++) {
      expect((await admin.rpc("admin_create_household", { p_request_id: randomUUID(), p_name: `RL ${runId} w${i}` })).error).toBeNull();
    }
    const blocked = await admin.rpc("admin_create_household", { p_request_id: randomUUID(), p_name: `RL ${runId} w2` });
    expect(blocked.error?.code).toBe("PT429");

    await new Promise((r) => setTimeout(r, 3100));
    const again = await admin.rpc("admin_create_household", { p_request_id: randomUUID(), p_name: `RL ${runId} w3` });
    expect(again.error).toBeNull();
  });
});

describe("Rate limit de convites (Edge Function)", () => {
  it("convites repetidos para o mesmo e-mail recebem HTTP 429", async () => {
    await setPolicy("admin_rpc", 120, 600);
    await setPolicy("invite_email", 1, 3600);
    const email = testEmail("rl-convidado");
    const first = await invokeFunction("provision-user", await accessToken(admin), {
      operation_id: randomUUID(), email, display_name: "RL", household_id: null,
    });
    expect(first.status).toBe(200);
    const second = await invokeFunction("provision-user", await accessToken(admin), {
      operation_id: randomUUID(), email, display_name: "RL", household_id: null,
    });
    expect(second.status).toBe(429);
    expect(second.body.error).toBe("rate_limited");
  });
});
