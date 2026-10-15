// §3.4 — 360 CSS px sem overflow horizontal, com acessibilidade, nas telas do Marco A.
import { expect, test } from "@playwright/test";
import {
  createActiveUser, expectAccessible, expectNoHorizontalOverflow, freshTotp, login, PASSWORD, runId, sql, testEmail,
} from "./helpers";

test.describe.configure({ mode: "serial" });

const userEmail = testEmail("e2e-mobile");
const adminEmail = testEmail("e2e-mobile-admin");

test.beforeAll(async () => {
  await createActiveUser(userEmail);
  const adminId = await createActiveUser(adminEmail);
  await sql("insert into public.administrators (user_id) values ($1)", [adminId]);
});

test.afterAll(async () => {
  await sql("delete from auth.users where email like $1", [`%.${runId}@fluvi.test`]);
});

for (const path of ["/entrar", "/esqueci-senha", "/definir-senha", "/bloqueada"]) {
  test(`tela pública ${path} cabe em 360 px`, async ({ page }) => {
    await page.goto(path);
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await expectAccessible(page);
  });
}

test("início do usuário cabe em 360 px", async ({ page }) => {
  await login(page, userEmail, PASSWORD);
  await expect(page).toHaveURL(/\/inicio$/);
  await expectNoHorizontalOverflow(page);
  await expectAccessible(page);
});

test("telas financeiras (Contas, Lançamentos, Cartões, Compras) cabem em 360 px", async ({ page }) => {
  await login(page, userEmail, PASSWORD);
  await expect(page).toHaveURL(/\/inicio$/);
  for (const [path, heading] of [["/contas", "Contas"], ["/lancamentos", "Lançamentos"], ["/lancamentos/novo", "Novo lançamento"],
    ["/cartoes", "Cartões"], ["/cartoes/compra", "Nova compra no cartão"]]) {
    await page.goto(path);
    await expect(page.getByRole("heading", { name: heading, level: 1 })).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await expectAccessible(page);
  }
});

test("painel administrativo cabe em 360 px", async ({ page }) => {
  await login(page, adminEmail, PASSWORD);
  await expect(page).toHaveURL(/\/seguranca\/mfa$/);
  await expectNoHorizontalOverflow(page);
  const secret = (await page.getByTestId("totp-secret").textContent())!.trim();
  await page.getByLabel("Código de 6 dígitos").fill(await freshTotp(secret));
  await page.getByRole("button", { name: "Confirmar" }).click();

  for (const [link, heading] of [["Usuários", "Usuários"], ["Núcleos e vínculos", "Núcleos e vínculos"],
    ["Permissões", "Permissões"], ["Auditoria", "Auditoria"]]) {
    await page.getByRole("link", { name: link }).click();
    await expect(page.getByRole("heading", { name: heading, level: 1 })).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await expectAccessible(page);
  }
});
