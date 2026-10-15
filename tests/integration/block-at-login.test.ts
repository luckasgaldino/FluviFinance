// D4 — Bloqueio também no login (§19.2, §19.8), com o Supabase Auth real:
// distingue negação na EMISSÃO do token (hook) da negação APÓS o Auth (RLS).
import { randomUUID } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  allowNextEmail, anonClient, createActiveUser, enrollTotp, mailCount, PASSWORD, runId, serviceClient,
  sessionFromLink, signIn, sql, testEmail, waitForAuthLink,
} from "./support";

const userEmail = testEmail("bloq");
let admin: SupabaseClient;
let user: SupabaseClient;
let userId: string;

const setStatus = (status: "blocked" | "active") =>
  admin.rpc("admin_set_user_status", { p_request_id: randomUUID(), p_user_id: userId, p_status: status });

beforeAll(async () => {
  const adminId = await createActiveUser(testEmail("bloq-admin"));
  await sql("insert into public.administrators (user_id) values ($1)", [adminId]);
  admin = await signIn(testEmail("bloq-admin"));
  await enrollTotp(admin);
  userId = await createActiveUser(userEmail);
  user = await signIn(userEmail);
});

afterAll(async () => {
  await sql("delete from auth.users where email like $1", [`%.${runId}@fluvi.test`]);
});

describe("Bloqueio no login", () => {
  it("antes do bloqueio: login e refresh funcionam", async () => {
    expect((await user.auth.refreshSession()).error).toBeNull();
    expect((await user.rpc("whoami")).data).toMatchObject({ status: "active" });
  });

  it("após o bloqueio: o access token já emitido é negado pela RLS (negação após o Auth)", async () => {
    expect((await setStatus("blocked")).error).toBeNull();
    expect((await user.rpc("whoami")).data).toMatchObject({ status: "blocked", is_financial_user: false });
    expect((await user.rpc("accessible_owners", { p_scope: "all", p_operation: "read" })).data).toEqual([]);
  });

  it("após o bloqueio: refresh falha (sessões encerradas)", async () => {
    const { error } = await user.auth.refreshSession();
    expect(error).not.toBeNull();
  });

  it("após o bloqueio: novo login por senha é recusado na emissão do token", async () => {
    const { data, error } = await anonClient().auth.signInWithPassword({ email: userEmail, password: PASSWORD });
    expect(data.session).toBeNull();
    expect(error?.message).toMatch(/bloqueada/i);
  });

  it("após o bloqueio: caminhos alternativos (magic link, recuperação) não emitem sessão", async () => {
    const { data, error } = await serviceClient().auth.admin.generateLink({ type: "magiclink", email: userEmail });
    if (error) throw error;
    await expect(sessionFromLink(data.properties.action_link)).rejects.toThrow();

    await allowNextEmail(userEmail);
    const before = await mailCount(userEmail);
    expect((await anonClient().auth.resetPasswordForEmail(userEmail)).error).toBeNull();
    await expect(sessionFromLink(await waitForAuthLink(userEmail, "recovery", before + 1))).rejects.toThrow();
  });

  it("reativação permite entrar de novo", async () => {
    expect((await setStatus("active")).error).toBeNull();
    const again = await signIn(userEmail);
    expect((await again.rpc("whoami")).data).toMatchObject({ status: "active", is_financial_user: true });
  });
});
