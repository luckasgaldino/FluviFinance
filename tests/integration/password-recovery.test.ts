// D2 — Recuperação de senha (§19.5, §19.8): fluxo completo pelo e-mail (Mailpit),
// token de uso único e expirável, sem enumeração de contas, e bloqueio que
// continua valendo depois da troca de senha (D4: negação após o Auth emitir token).
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  allowNextEmail, anonClient, createActiveUser, mailCount, PASSWORD, runId, sessionFromLink, signIn, sql,
  testEmail, waitForAuthLink,
} from "./support";

const email = testEmail("recupera");
const NEW_PASSWORD = "Nova-Senha-Fluvi-2026";
let userId: string;

beforeAll(async () => {
  userId = await createActiveUser(email);
});

afterAll(async () => {
  await sql("delete from auth.users where email like $1", [`%.${runId}@fluvi.test`]);
});

describe("Recuperação de senha", () => {
  it("resposta idêntica para e-mail existente e inexistente (sem enumeração)", async () => {
    const ghost = testEmail("fantasma");
    const existing = await anonClient().auth.resetPasswordForEmail(email);
    const missing = await anonClient().auth.resetPasswordForEmail(ghost);
    expect(existing.error).toBeNull();
    expect(missing.error).toBeNull();
    expect(existing.data).toEqual(missing.data);

    await waitForAuthLink(email, "recovery", 1);
    expect(await mailCount(ghost)).toBe(0);
  });

  it("link do e-mail permite definir nova senha; a antiga deixa de valer", async () => {
    const link = await waitForAuthLink(email, "recovery", 1);
    const session = await sessionFromLink(link);
    const { error } = await session.auth.updateUser({ password: NEW_PASSWORD });
    expect(error).toBeNull();

    await expect(signIn(email, PASSWORD)).rejects.toThrow();
    const client = await signIn(email, NEW_PASSWORD);
    expect((await client.rpc("whoami")).data).toMatchObject({ user_id: userId, status: "active" });
  });

  it("o mesmo link não funciona duas vezes", async () => {
    const link = await waitForAuthLink(email, "recovery", 1);
    await expect(sessionFromLink(link)).rejects.toThrow();
  });

  it("link expirado é recusado", async () => {
    await allowNextEmail(email);
    const before = await mailCount(email);
    expect((await anonClient().auth.resetPasswordForEmail(email)).error).toBeNull();
    const link = await waitForAuthLink(email, "recovery", before + 1);
    // envelhece o token além de otp_expiry (3600 s)
    await sql("update auth.users set recovery_sent_at = now() - interval '2 hours' where id = $1", [userId]);
    await expect(sessionFromLink(link)).rejects.toThrow();
  });

  it("senha nova fraca é recusada pela política", async () => {
    await allowNextEmail(email);
    const before = await mailCount(email);
    expect((await anonClient().auth.resetPasswordForEmail(email)).error).toBeNull();
    const session = await sessionFromLink(await waitForAuthLink(email, "recovery", before + 1));
    const { error } = await session.auth.updateUser({ password: "curta" });
    expect(error?.code).toBe("weak_password");
  });

  it("pedidos repetidos em sequência são limitados pelo Auth (abuso)", async () => {
    await allowNextEmail(email);
    expect((await anonClient().auth.resetPasswordForEmail(email)).error).toBeNull();
    const burst = await anonClient().auth.resetPasswordForEmail(email);
    expect(burst.error?.code).toBe("over_email_send_rate_limit");
  });

  it("usuário bloqueado não obtém sessão pelo link de recuperação (D4)", async () => {
    await sql("update public.profiles set status = 'blocked', status_changed_at = now() where user_id = $1", [userId]);
    await allowNextEmail(email);
    const before = await mailCount(email);
    // mesma resposta de sempre (sem revelar o bloqueio a quem pede)
    expect((await anonClient().auth.resetPasswordForEmail(email)).error).toBeNull();
    await expect(sessionFromLink(await waitForAuthLink(email, "recovery", before + 1))).rejects.toThrow();
    await expect(signIn(email, NEW_PASSWORD)).rejects.toThrow(/bloqueada/i);
  });
});
