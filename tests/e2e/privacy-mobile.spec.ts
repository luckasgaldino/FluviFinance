// v2.2 §3.2 — privacidade em duas etapas na PWA (celular, 360 px): PRIV-01..05 e 07 pela interface.
// Fase R1: a senha é conferida pelo Auth, mas o estado do desbloqueio ainda é do cliente; os
// testes de API direta (PRIV-09) e do banco entram na fase R3.
import { expect, test, type Page } from "@playwright/test";
import { createActiveUser, expectAccessible, login, PASSWORD, testEmail, unlockFinance } from "./helpers";

test.describe.configure({ mode: "serial" });

const user = testEmail("e2e-priv");

test.beforeAll(async () => {
  await createActiveUser(user);
});

const menu = async (page: Page, item: string) => {
  await page.getByRole("button", { name: "Abrir menu" }).click();
  await page.getByRole("dialog", { name: "Menu" }).getByRole("link", { name: item }).click();
};
const protectedHeading = (page: Page) => page.getByRole("heading", { name: "Área financeira protegida", level: 1 });

async function loginMobile(page: Page) {
  await login(page, user, PASSWORD);
  await expect(page).toHaveURL(/\/inicio$/);
}

test("PRIV-01: após o login abre a tela discreta, sem nenhum valor", async ({ page }) => {
  await loginMobile(page);
  const main = page.getByRole("main");
  await expect(main.getByRole("heading", { level: 1 })).toHaveText("Tudo certo por aqui");
  await expect(main.getByRole("link")).toHaveCount(1);
  await expect(main.getByRole("link", { name: "Novo lançamento" })).toBeVisible();
  await expect(main).not.toContainText("R$");
  await expectAccessible(page);
});

test("Menu abre sem senha; área financeira pede senha; senha errada não libera", async ({ page }) => {
  await loginMobile(page);
  await page.getByRole("button", { name: "Abrir menu" }).click();
  const drawer = page.getByRole("dialog", { name: "Menu" });
  await expect(drawer.getByRole("link", { name: /Visão geral/ })).toBeVisible();
  await expect(drawer.getByText("(protegido)").first()).toBeAttached();
  await expectAccessible(page);
  await page.keyboard.press("Escape");
  await expect(drawer).toBeHidden();

  // PRIV-03
  await menu(page, "Visão geral");
  await expect(protectedHeading(page)).toBeVisible();
  await expect(page.getByRole("main")).not.toContainText("R$");
  await page.getByRole("form", { name: "Confirmar senha" }).getByLabel("Senha").fill("senha-errada-123");
  await page.getByRole("button", { name: "Desbloquear" }).click();
  await expect(page.getByText("Senha incorreta. Nenhuma informação foi liberada.")).toBeVisible();
  await expect(protectedHeading(page)).toBeVisible();
  await expect(page.getByText("Saldo disponível")).toHaveCount(0);
  await expectAccessible(page);
});

test("PRIV-04: senha correta libera todas as telas, inclusive após voltar ao início", async ({ page }) => {
  await loginMobile(page);
  await menu(page, "Visão geral");
  await unlockFinance(page, PASSWORD);
  await expect(page.getByRole("heading", { name: "Visão geral", level: 1 })).toBeVisible();

  for (const [item, heading] of [["Cartões e faturas", "Cartões"], ["Relatórios", "Relatórios"],
    ["Contas e saldos", "Contas"], ["Início", "Tudo certo por aqui"], ["Visão geral", "Visão geral"]]) {
    await menu(page, item);
    await expect(page.getByRole("heading", { name: heading, level: 1 })).toBeVisible();
    await expect(protectedHeading(page)).toHaveCount(0);
  }
});

test("PRIV-02: novo lançamento com a área bloqueada grava sem mostrar saldo", async ({ page }) => {
  await loginMobile(page);
  // prepara uma conta (com a área liberada) e bloqueia manualmente
  await menu(page, "Contas e saldos");
  await unlockFinance(page, PASSWORD);
  await page.getByRole("button", { name: "Nova conta" }).click();
  await page.getByLabel("Nome da conta").fill("Banco Privacidade");
  await page.getByLabel("Saldo inicial (R$)").fill("2.000,00");
  await page.getByLabel("Data de abertura").fill("2026-01-01");
  await page.getByRole("button", { name: "Criar conta" }).click();
  await expect(page.getByRole("listitem", { name: "Banco Privacidade" })).toContainText("R$ 2.000,00");
  await page.getByRole("button", { name: "Bloquear área financeira" }).click();
  await expect(protectedHeading(page)).toBeVisible();

  await menu(page, "Início");
  await page.getByRole("link", { name: "Novo lançamento" }).click();
  await expect(page.getByRole("heading", { name: "Novo lançamento", level: 1 })).toBeVisible();
  await expect(page.getByRole("main")).not.toContainText("R$ 2.000,00");
  await page.getByLabel("Valor (R$)").fill("150,00");
  await page.getByLabel("Descrição").fill("Farmácia");
  await page.getByLabel("Categoria").selectOption({ label: "Saúde" });
  await page.getByLabel("Pagar com").selectOption({ label: "Banco Privacidade" });
  await expectAccessible(page);
  const saved = page.waitForResponse((r) => r.url().includes("/rpc/create_transaction"));
  await page.getByRole("button", { name: "Salvar" }).click();
  const body = await (await saved).json();
  expect(Object.keys(body).sort()).toEqual(["id", "status"]);   // a resposta não traz saldo
  await expect(page.getByText("Lançamento salvo.")).toBeVisible();
  await expect(page.getByRole("main")).not.toContainText("R$ 1.850,00");

  // FIN-01 conferido depois do desbloqueio: 2.000 − 150 = 1.850
  await menu(page, "Contas e saldos");
  await unlockFinance(page, PASSWORD);
  await expect(page.getByRole("listitem", { name: "Banco Privacidade" })).toContainText("R$ 1.850,00");
});

test("PRIV-05: 15 min sem interação bloqueiam as leituras; o login e o lançamento rápido continuam", async ({ page }) => {
  await page.clock.install();
  await loginMobile(page);
  await menu(page, "Visão geral");
  await unlockFinance(page, PASSWORD);
  await expect(page.getByRole("heading", { name: "Visão geral", level: 1 })).toBeVisible();

  // atividade humana renova a janela
  await page.clock.fastForward("10:00");
  await page.getByRole("heading", { name: "Visão geral", level: 1 }).click();
  await page.clock.fastForward("10:00");
  await expect(page.getByRole("heading", { name: "Visão geral", level: 1 })).toBeVisible();

  // página aberta sem interação não renova
  await page.clock.fastForward("15:10");
  await expect(protectedHeading(page)).toBeVisible();
  await expect(page.getByText("Saldo disponível")).toHaveCount(0);

  await menu(page, "Início");
  await page.getByRole("link", { name: "Novo lançamento" }).click();
  await expect(page.getByRole("heading", { name: "Novo lançamento", level: 1 })).toBeVisible();
  await expect(page).not.toHaveURL(/\/entrar$/);
});

test("PRIV-07: sair e entrar de novo exige novo desbloqueio", async ({ page }) => {
  await loginMobile(page);
  await menu(page, "Visão geral");
  await unlockFinance(page, PASSWORD);
  await page.getByRole("button", { name: "Abrir menu" }).click();
  await page.getByRole("dialog", { name: "Menu" }).getByRole("button", { name: "Sair" }).click();
  await expect(page).toHaveURL(/\/entrar$/);

  await loginMobile(page);
  await menu(page, "Visão geral");
  await expect(protectedHeading(page)).toBeVisible();
});
