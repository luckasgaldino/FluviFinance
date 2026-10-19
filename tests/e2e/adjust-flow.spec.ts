// Contas: saldo inicial no início do dia (lançamento do próprio dia conta) e "Atualizar saldo".
import { expect, test, type Page } from "@playwright/test";
import { createFinanceUser, expectAccessible, loginUser, PASSWORD, testEmail } from "./helpers";

const user = testEmail("e2e-ajuste");
const today = () => new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });

test.beforeAll(async () => {
  await createFinanceUser(user);
});

const nav = (page: Page, name: string) =>
  page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name, exact: true }).click();

test("conta aberta hoje: despesa do dia conta; atualizar saldo para mais e para negativo", async ({ page }) => {
  await loginUser(page, user, PASSWORD);
  await nav(page, "Contas e saldos");
  await page.getByRole("button", { name: "Nova conta" }).click();
  await page.getByLabel("Nome da conta").fill("Nubank PF");
  await page.getByLabel("Saldo inicial (R$)").fill("1.000,00");
  await page.getByLabel("Data de abertura").fill(today());
  await page.getByRole("button", { name: "Criar conta" }).click();
  const item = page.getByRole("listitem", { name: "Nubank PF" });
  await expect(item).toContainText("R$ 1.000,00");

  await page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name: "Novo lançamento" }).click();
  await page.getByLabel("Valor (R$)").fill("100,00");
  await page.getByLabel("Descrição").fill("Mercado");
  await page.getByLabel("Categoria").selectOption({ label: "Mercado" });
  await page.getByLabel("Pagar com").selectOption({ label: "Nubank PF" });
  await page.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByText("Lançamento salvo.")).toBeVisible();

  await nav(page, "Contas e saldos");
  await expect(item).toContainText("R$ 900,00");                 // a despesa do dia de abertura conta

  await item.getByRole("button", { name: "Atualizar saldo" }).click();
  const form = page.getByRole("form", { name: "Atualizar saldo de Nubank PF" });
  await expect(form).toContainText("R$ 900,00");
  await expectAccessible(page);
  await form.getByLabel("Saldo real (R$)").fill("1.250,00");
  await form.getByRole("button", { name: "Atualizar saldo" }).click();
  await expect(page.getByText("Saldo atualizado: ajuste de +R$ 350,00 em Nubank PF.")).toBeVisible();
  await expect(item).toContainText("R$ 1.250,00");

  await item.getByRole("button", { name: "Atualizar saldo" }).click();
  await page.getByRole("form", { name: "Atualizar saldo de Nubank PF" }).getByLabel("Saldo real (R$)").fill("-50,00");
  await page.getByRole("form", { name: "Atualizar saldo de Nubank PF" }).getByRole("button", { name: "Atualizar saldo" }).click();
  await expect(page.getByText("ajuste de −R$ 1.300,00")).toBeVisible();
  await expect(item).toContainText("−R$ 50,00");

  await nav(page, "Lançamentos");
  await expect(page.getByRole("list", { name: "Lançamentos" }).getByRole("listitem", { name: "Ajuste de saldo" })).toHaveCount(2);
  await nav(page, "Visão geral");
  await expect(page.locator(".kpi").filter({ hasText: "Receitas do mês" })).toContainText("R$ 0,00");  // ajuste não é receita
});
