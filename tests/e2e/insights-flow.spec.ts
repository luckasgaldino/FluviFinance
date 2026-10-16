// v2.2 R4 — Visão geral, Parcelas, Relatórios (CSV) e pagamento de fatura com dados reais,
// pela interface: números conhecidos, sem dupla contagem (FIN-01..03, FF-05..07).
import { readFileSync } from "node:fs";
import { expect, test, type Page } from "@playwright/test";
import { createFinanceUser, expectAccessible, loginUser, PASSWORD, sql, testEmail } from "./helpers";

test.describe.configure({ mode: "serial" });

const user = testEmail("e2e-r4");
let family = "";

test.beforeAll(async () => {
  family = await createFinanceUser(user);
});

const nav = (page: Page, name: string) =>
  page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name, exact: true }).click();
const kpi = (page: Page, label: string) => page.locator(".kpi").filter({ hasText: label });

async function quick(page: Page, kind: "Despesa" | "Receita", amount: string, desc: string, category: string, pay: string, n?: string) {
  await page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name: "Novo lançamento" }).click();
  await page.getByRole("radio", { name: kind }).check({ force: true });
  await page.getByLabel("Valor (R$)").fill(amount);
  await page.getByLabel("Descrição").fill(desc);
  await page.getByLabel("Categoria").selectOption({ label: category });
  await page.getByLabel(kind === "Despesa" ? "Pagar com" : "Conta").selectOption({ label: pay });
  if (n) await page.getByLabel("Parcelas").fill(n);
  await page.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByText("Lançamento salvo.")).toBeVisible();
}

test("Dados reais: lançamentos, Visão geral, Parcelas e Relatórios", async ({ page }) => {
  await loginUser(page, user, PASSWORD);
  await nav(page, "Contas e saldos");
  await page.getByRole("button", { name: "Nova conta" }).click();
  await page.getByLabel("Nome da conta").fill("Banco R4");
  await page.getByLabel("Saldo inicial (R$)").fill("2.000,00");
  await page.getByLabel("Data de abertura").fill("2026-01-01");
  await page.getByRole("button", { name: "Criar conta" }).click();
  await expect(page.getByRole("listitem", { name: "Banco R4" })).toContainText("R$ 2.000,00");

  await nav(page, "Cartões e faturas");
  await page.getByRole("button", { name: "Novo cartão" }).click();
  await page.getByLabel("Nome do cartão").fill("Cartão R4");
  await page.getByLabel("Dia de fechamento").fill("5");
  await page.getByLabel("Dia de vencimento").fill("15");
  await page.getByLabel("Limite (R$)").fill("5.000,00");
  await page.getByRole("button", { name: "Criar cartão" }).click();
  await expect(page.getByRole("listitem", { name: "Cartão R4" })).toBeVisible();

  await quick(page, "Despesa", "150,00", "Farmácia", "Saúde", "Banco R4");
  await quick(page, "Receita", "1.000,00", "Salário", "Salário", "Banco R4");
  await quick(page, "Despesa", "600,00", "Geladeira", "Moradia", "Cartão R4", "6");

  await nav(page, "Visão geral");
  await expect(kpi(page, "Saldo disponível")).toContainText("R$ 2.850,00");      // FIN-01/02: compra não sai do caixa
  await expect(kpi(page, "Receitas do mês")).toContainText("R$ 1.000,00");
  await expect(kpi(page, "Consumo do mês")).toContainText("R$ 750,00");          // 150 + 600, sem somar parcelas
  await expect(page.getByRole("list", { name: "Consumo por categoria" })).toContainText("Moradia");
  await expect(page.getByRole("list", { name: "Faturas dos cartões" })).toContainText("Cartão R4");
  await expectAccessible(page);

  await nav(page, "Parcelas");
  await expect(page.getByRole("listitem", { name: "Geladeira" })).toContainText("R$ 600,00");
  await expect(page.getByRole("listitem", { name: "Geladeira" })).toContainText("0 de 6 faturadas");
  await expectAccessible(page);

  await nav(page, "Relatórios");
  await expect(page.getByText("Total no período:")).toContainText("R$ 750,00");
  const download = page.waitForEvent("download");
  await page.getByRole("button", { name: "Exportar CSV" }).click();
  const csv = readFileSync(await (await download).path(), "utf8");
  expect(csv).toContain("Moradia;600,00");
  expect(csv).toContain("Saúde;150,00");
  await page.getByRole("radio", { name: "Por quem lançou" }).check({ force: true });
  await expect(page.getByRole("list", { name: "Consumo por quem lançou" })).toContainText("R$ 750,00");
  await expectAccessible(page);
});

test("FIN-03 pela interface: pagar R$ 100 da fatura reduz caixa e dívida, sem mudar o consumo", async ({ page }) => {
  // fecha a primeira fatura do cartão como o job diário faria
  await sql(`select private.close_cycle(c.id) from public.billing_cycles c
              join public.credit_cards k on k.id = c.card_id
             where k.family_id = $1 and c.status = 'open'
             order by c.closes_on limit 1`, [family]);
  await loginUser(page, user, PASSWORD);
  await nav(page, "Cartões e faturas");
  await page.getByRole("link", { name: "Cartão R4" }).click();
  await page.getByRole("button", { name: "Pagar" }).first().click();
  const form = page.getByRole("form", { name: "Pagar fatura" });
  await expect(form.getByLabel("Valor (R$)")).toHaveValue("100,00");
  await form.getByLabel("Conta").selectOption({ label: "Banco R4" });
  await expectAccessible(page);
  await form.getByRole("button", { name: "Confirmar pagamento" }).click();
  await expect(page.getByText("Pagamento registrado.")).toBeVisible();

  await nav(page, "Visão geral");
  await expect(kpi(page, "Saldo disponível")).toContainText("R$ 2.750,00");
  await expect(kpi(page, "Consumo do mês")).toContainText("R$ 750,00");
});
