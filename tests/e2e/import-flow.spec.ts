// Fase 2 — importar fatura (CSV do Nubank) pela interface: prévia, categoria sugerida, possível
// duplicado de lançamento manual, pagamento ignorado, reimportação sem duplicar.
import { expect, test, type Page } from "@playwright/test";
import { createFinanceUser, expectAccessible, loginUser, PASSWORD, testEmail } from "./helpers";

test.describe.configure({ mode: "serial" });

const user = testEmail("e2e-import");
const today = () => new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
const nextMonth = () => {
  const [y, m] = today().split("-").map(Number);
  return new Date(Date.UTC(y, m, 1)).toISOString().slice(0, 7);
};
const csv = () => [
  "date,title,amount",
  `${today()},Mercado Bom Preço,100.00`,
  `${today()},Loja TV - Parcela 1/3,200.00`,
  `${today()},Notebook - Parcela 4/6,150.00`,
  `${today()},Padaria Central,45.90`,
  `${today()},Pagamento recebido,-500.00`,
].join("\n");

test.beforeAll(async () => {
  await createFinanceUser(user);
});

const nav = (page: Page, name: string) =>
  page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name, exact: true }).click();

async function openImport(page: Page) {
  await nav(page, "Cartões e faturas");
  await page.getByRole("link", { name: "Nubank" }).click();
  await page.getByRole("link", { name: "Importar fatura" }).click();
  await expect(page.getByRole("heading", { name: "Importar fatura", level: 1 })).toBeVisible();
  await page.getByLabel("Fatura (OFX ou CSV)").setInputFiles({
    name: `Nubank_${nextMonth()}-15.csv`, mimeType: "text/csv", buffer: Buffer.from(csv()),
  });
}

test("importar fatura: prévia, duplicado manual, pagamento ignorado e reimportação", async ({ page }) => {
  await loginUser(page, user, PASSWORD);
  await nav(page, "Cartões e faturas");
  await page.getByRole("button", { name: "Novo cartão" }).click();
  await page.getByLabel("Nome do cartão").fill("Nubank");
  await page.getByLabel("Dia de fechamento").fill("5");
  await page.getByLabel("Dia de vencimento").fill("15");
  await page.getByLabel("Limite (R$)").fill("10.000,00");
  await page.getByRole("button", { name: "Criar cartão" }).click();
  await expect(page.getByRole("listitem", { name: "Nubank" })).toBeVisible();

  // compra lançada à mão antes da fatura chegar
  await page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name: "Novo lançamento" }).click();
  await page.getByLabel("Valor (R$)").fill("45,90");
  await page.getByLabel("Descrição").fill("Padaria");
  await page.getByLabel("Categoria").selectOption({ label: "Alimentação fora" });
  await page.getByLabel("Pagar com").selectOption({ label: "Nubank" });
  await page.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByText("Lançamento salvo.")).toBeVisible();

  await openImport(page);
  const items = page.getByRole("list", { name: "Itens da fatura" });
  await expect(items.getByRole("listitem")).toHaveCount(4);                      // pagamento fica de fora
  await expect(page.getByText("1 pagamento(s)/estorno(s) ignorado(s)")).toBeVisible();
  await expect(page.getByLabel("Vencimento da fatura")).toHaveValue(nextMonth());  // pelo nome do arquivo
  const padaria = items.getByRole("listitem", { name: "Padaria Central" });
  await expect(padaria).toContainText("possível duplicado");
  await expect(padaria.getByRole("checkbox")).not.toBeChecked();
  await expect(items.getByRole("listitem", { name: "Mercado Bom Preço" }).getByRole("combobox")).toHaveValue(
    await page.getByLabel("Categoria de Mercado Bom Preço").locator("option", { hasText: /^Mercado$/ }).getAttribute("value") ?? "");
  await expect(items.getByRole("listitem", { name: "Notebook - Parcela 4/6" })).toContainText("parcela 4/6");
  await expectAccessible(page);

  await page.getByRole("button", { name: "Importar 3 item(ns) e fechar a fatura" }).click();
  await expect(page.getByText("Importação concluída: 3 lançamento(s) novo(s), 0 parcela(s) reconhecida(s)")).toBeVisible();

  // reenviar o mesmo arquivo: tudo já importado, nada a gravar
  await page.getByLabel("Fatura (OFX ou CSV)").setInputFiles({
    name: `Nubank_${nextMonth()}-15.csv`, mimeType: "text/csv", buffer: Buffer.from(csv()),
  });
  await expect(items.getByRole("listitem").filter({ hasText: "já importado" })).toHaveCount(3);
  await expect(page.getByRole("button", { name: "Importar 0 item(ns) e fechar a fatura" })).toBeDisabled();

  // a compra parcelada já ocupa as próximas faturas; o saldo anterior não é consumo
  await nav(page, "Parcelas");
  await expect(page.getByRole("list", { name: "Compras parceladas" })).toContainText("Loja TV");
  await expect(page.getByRole("list", { name: "Compras parceladas" })).toContainText("Notebook");
});
