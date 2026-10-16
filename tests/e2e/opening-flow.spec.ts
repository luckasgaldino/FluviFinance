// Fase 2 — implantação na data de corte pela interface: saldo anterior do cartão entra na dívida
// e nas faturas, sem virar gasto do mês (consumo) nem sair do caixa.
import { expect, test, type Page } from "@playwright/test";
import { createFinanceUser, expectAccessible, loginUser, PASSWORD, testEmail } from "./helpers";

const user = testEmail("e2e-corte");

test.beforeAll(async () => {
  await createFinanceUser(user);
});

const nav = (page: Page, name: string) =>
  page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name, exact: true }).click();

// mês seguinte (AAAA-MM) no fuso de São Paulo: a fatura que vence nele ainda está aberta
function nextMonth(): string {
  const [y, m] = new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" }).split("-").map(Number);
  const d = new Date(Date.UTC(y, m, 1));
  return d.toISOString().slice(0, 7);
}

test("saldo anterior do cartão: fatura aberta e parcelas antigas viram dívida, não consumo", async ({ page }) => {
  await loginUser(page, user, PASSWORD);
  await nav(page, "Cartões e faturas");
  await page.getByRole("button", { name: "Novo cartão" }).click();
  await page.getByLabel("Nome do cartão").fill("Nubank");
  await page.getByLabel("Dia de fechamento").fill("5");
  await page.getByLabel("Dia de vencimento").fill("15");
  await page.getByLabel("Limite (R$)").fill("10.000,00");
  await page.getByRole("button", { name: "Criar cartão" }).click();
  await page.getByRole("link", { name: "Nubank" }).click();

  const register = async (kind: string, amount: string, n?: string) => {
    await page.getByRole("button", { name: "Saldo anterior" }).click();
    const form = page.getByRole("form", { name: "Saldo anterior do cartão" });
    await form.getByRole("radio", { name: kind }).check({ force: true });
    await form.getByLabel(/^Valor/).fill(amount);
    if (n) await form.getByLabel("Parcelas restantes").fill(n);
    await form.getByLabel(/^Vencimento/).fill(nextMonth());
    await expectAccessible(page);
    await form.getByRole("button", { name: "Registrar" }).click();
    await expect(page.getByText("Saldo anterior registrado.")).toBeVisible();
  };
  await register("Fatura aberta até hoje", "300,00");
  await register("Parcelas de compra antiga", "200,00", "3");

  const position = page.getByRole("region", { name: "Posição do cartão" });
  await expect(position.locator("dl > div").filter({ hasText: "Dívida total" })).toContainText("R$ 900,00");

  await nav(page, "Visão geral");
  await expect(page.locator(".kpi").filter({ hasText: "Consumo do mês" })).toContainText("R$ 0,00");
  await nav(page, "Parcelas");
  await expect(page.getByRole("list", { name: "Compras parceladas" })).toContainText("R$ 600,00");
});
