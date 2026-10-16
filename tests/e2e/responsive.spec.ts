// 360 CSS px sem overflow horizontal, com acessibilidade (v2.2: tela discreta, menu em gaveta, áreas protegidas).
import { expect, test } from "@playwright/test";
import {
  createActiveUser, createFinanceUser, expectAccessible, expectNoHorizontalOverflow, freshTotp, login, PASSWORD, sql, testEmail, unlockFinance,
} from "./helpers";

test.describe.configure({ mode: "serial" });

const userEmail = testEmail("e2e-mobile");
const adminEmail = testEmail("e2e-mobile-admin");

test.beforeAll(async () => {
  await createFinanceUser(userEmail);
  const adminId = await createActiveUser(adminEmail);
  await sql("insert into public.administrators (user_id) values ($1)", [adminId]);
});

test.afterAll(async () => {
  // só as identidades desta suíte (sem histórico financeiro); outras suítes da rodada têm razão
  await sql("delete from auth.users where email = any($1)", [[userEmail, adminEmail]]);
});

for (const path of ["/entrar", "/esqueci-senha", "/definir-senha", "/bloqueada"]) {
  test(`tela pública ${path} cabe em 360 px`, async ({ page }) => {
    await page.goto(path);
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await expectAccessible(page);
  });
}

test("início discreto, lançamento rápido, configurações e menu cabem em 360 px", async ({ page }) => {
  await login(page, userEmail, PASSWORD);
  await expect(page).toHaveURL(/\/inicio$/);
  await expectNoHorizontalOverflow(page);
  await expectAccessible(page);
  for (const [path, heading] of [["/novo", "Novo lançamento"], ["/configuracoes", "Configurações"]]) {
    await page.goto(path);
    await expect(page.getByRole("heading", { name: heading, level: 1 })).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await expectAccessible(page);
  }
  await page.getByRole("button", { name: "Abrir menu" }).click();
  await expect(page.getByRole("dialog", { name: "Menu" })).toBeVisible();
  await expectNoHorizontalOverflow(page);
  await expectAccessible(page);
});

test("telas financeiras cabem em 360 px (após o desbloqueio)", async ({ page }) => {
  await login(page, userEmail, PASSWORD);
  await expect(page).toHaveURL(/\/inicio$/);
  await page.goto("/painel");
  await expectNoHorizontalOverflow(page);
  await expectAccessible(page);
  await unlockFinance(page, PASSWORD);
  for (const [path, heading] of [["/painel", "Visão geral"], ["/contas", "Contas"], ["/lancamentos", "Lançamentos"],
    ["/lancamentos/novo", "Novo lançamento"], ["/cartoes", "Cartões"], ["/cartoes/compra", "Nova compra no cartão"],
    ["/parcelas", "Parcelas"], ["/relatorios", "Relatórios"]]) {
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
    ["Auditoria", "Auditoria"]]) {
    await page.getByRole("button", { name: "Abrir menu" }).click();
    await page.getByRole("dialog", { name: "Menu" }).getByRole("link", { name: link }).click();
    await expect(page.getByRole("heading", { name: heading, level: 1 })).toBeVisible();
    await expectNoHorizontalOverflow(page);
    await expectAccessible(page);
  }
});
