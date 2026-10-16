// v2.2 §3.1 + decisão da Etapa 0: no desktop o login (senha recém-digitada) já abre a área
// financeira e o dashboard; após 15 min sem uso a senha é pedida de novo, sem encerrar o login.
import { expect, test } from "@playwright/test";
import { createFinanceUser, expectAccessible, login, PASSWORD, testEmail, unlockFinance } from "./helpers";

const user = testEmail("e2e-priv-desk");

test.beforeAll(async () => {
  await createFinanceUser(user);
});

test("Desktop: login abre o dashboard com sidebar; inatividade pede a senha sem deslogar", async ({ page }) => {
  await page.clock.install();
  await login(page, user, PASSWORD);
  await expect(page).toHaveURL(/\/painel$/);
  await expect(page.getByRole("heading", { name: "Visão geral", level: 1 })).toBeVisible();
  const sidebar = page.getByRole("complementary", { name: "Menu lateral" });
  for (const item of ["Visão geral", "Lançamentos", "Contas e saldos", "Cartões e faturas", "Parcelas", "Relatórios", "Configurações"]) {
    await expect(sidebar.getByRole("link", { name: item })).toBeVisible();
  }
  await expect(sidebar.getByRole("link", { name: "Novo lançamento" })).toBeVisible();
  await expectAccessible(page);

  await page.reload();   // recarregar dentro da janela não pede senha
  await expect(page.getByRole("heading", { name: "Visão geral", level: 1 })).toBeVisible();

  await page.clock.fastForward("15:10");
  await expect(page.getByRole("heading", { name: "Área financeira protegida", level: 1 })).toBeVisible();
  await expect(page).toHaveURL(/\/painel$/);
  await unlockFinance(page, PASSWORD);
  await expect(page.getByRole("heading", { name: "Visão geral", level: 1 })).toBeVisible();

  for (const [item, heading] of [["Parcelas", "Parcelas"], ["Relatórios", "Relatórios"], ["Configurações", "Configurações"]]) {
    await sidebar.getByRole("link", { name: item }).click();
    await expect(page.getByRole("heading", { name: heading, level: 1 })).toBeVisible();
    await expectAccessible(page);
  }
});
