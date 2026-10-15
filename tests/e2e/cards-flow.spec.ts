// Marco B — telas de Cartões e Compras (FIN-03): cadastro, posições, compra parcelada com
// prévia, estorno, ajuste de parcelas, anulação, validação, isolamento e acessibilidade.
import { expect, test, type Page } from "@playwright/test";
import { createActiveUser, expectAccessible, loginUser, PASSWORD, testEmail } from "./helpers";

test.describe.configure({ mode: "serial" });

const owner = testEmail("e2e-card");
const other = testEmail("e2e-card-outro");
let cardUrl = "";
let purchaseUrl = "";

test.beforeAll(async () => {
  await createActiveUser(owner);
  await createActiveUser(other);
});

const nav = (page: Page, name: string) =>
  page.getByRole("navigation").getByRole("link", { name, exact: true }).click();

const position = (page: Page, label: string) =>
  page.getByRole("region", { name: "Posição do cartão" }).locator("dl > div").filter({ hasText: label }).first();

test("Cartões: dígitos inválidos são recusados e o cartão é criado", async ({ page }) => {
  await loginUser(page, owner, PASSWORD);
  await nav(page, "Cartões e faturas");
  await expect(page.getByText("Nenhum cartão cadastrado.")).toBeVisible();
  await page.getByRole("button", { name: "Novo cartão" }).click();
  await page.getByLabel("Nome do cartão").fill("Visa E2E");
  await page.getByLabel("4 últimos dígitos (opcional)").fill("12a4");
  await page.getByLabel("Dia de fechamento").fill("5");
  await page.getByLabel("Dia de vencimento").fill("15");
  await page.getByLabel("Limite (R$)").fill("5.000,00");
  await page.getByRole("button", { name: "Criar cartão" }).click();
  await expect(page.getByText("Informe só os 4 últimos dígitos do cartão.")).toBeVisible();
  await expectAccessible(page);

  await page.getByLabel("4 últimos dígitos (opcional)").fill("1234");
  await page.getByRole("button", { name: "Criar cartão" }).click();
  await expect(page.getByRole("listitem", { name: "Visa E2E" })).toContainText("R$ 5.000,00");
  await page.getByRole("link", { name: "Visa E2E" }).click();
  cardUrl = page.url();
  await expect(page.getByText("final 1234 · fecha dia 5, vence dia 15")).toBeVisible();
  await expectAccessible(page);
});

test("Compra 6x: prévia das parcelas, posições e faturas", async ({ page }) => {
  await loginUser(page, owner, PASSWORD);
  await page.goto("/cartoes/compra");
  await page.getByLabel("Cartão", { exact: true }).selectOption({ label: "Visa E2E" });
  await page.getByLabel("Valor total (R$)").fill("100,00");
  await page.getByLabel("Parcelas").fill("3");
  await expect(page.getByText("1 × R$ 33,34 + 2 × R$ 33,33 = R$ 100,00")).toBeVisible();
  await page.getByLabel("Valor total (R$)").fill("1.200,00");
  await page.getByLabel("Parcelas").fill("6");
  await expect(page.getByText("6 × R$ 200,00 = R$ 1.200,00")).toBeVisible();
  await page.getByLabel("Descrição").fill("TV");
  await page.getByLabel("Categoria").selectOption({ label: "Lazer" });
  await expectAccessible(page);
  await page.getByRole("button", { name: "Salvar compra" }).click();

  await expect(page.getByText("Compra salva.")).toBeVisible();
  purchaseUrl = page.url().replace(/\?.*$/, "");
  await expect(page.getByRole("list", { name: "Parcelas" }).getByRole("listitem")).toHaveCount(6);
  await expect(page.getByRole("list", { name: "Parcelas" })).toContainText("R$ 200,00");
  await expectAccessible(page);

  await page.goto(cardUrl);
  await expect(position(page, "Dívida total")).toContainText("R$ 1.200,00");
  await expect(position(page, "Limite disponível")).toContainText("R$ 3.800,00");
  await expect(page.getByRole("list", { name: "Faturas" }).getByRole("listitem")).toHaveCount(6);
  await expect(page.getByRole("list", { name: "Faturas" })).toContainText("Aberta (estimada)");
});

test("Estorno reduz o líquido e a dívida, sem cancelar parcelas", async ({ page }) => {
  await loginUser(page, owner, PASSWORD);
  await page.goto(purchaseUrl);
  await page.getByRole("button", { name: "Estornar" }).click();
  const form = page.getByRole("form", { name: "Estornar compra" });
  await form.getByLabel("Valor do estorno (R$)").fill("100,00");
  await form.getByRole("button", { name: "Confirmar" }).click();
  await expect(page.getByText("Estorno registrado.")).toBeVisible();
  const values = page.getByRole("region", { name: "Valores" });
  await expect(values).toContainText("R$ 1.100,00");
  await expect(page.getByRole("list", { name: "Parcelas" }).getByRole("listitem")).toHaveCount(6);

  await page.goto(cardUrl);
  await expect(position(page, "Dívida total")).toContainText("R$ 1.100,00");
});

test("Ajuste de parcelas: nova revisão fecha com o total", async ({ page }) => {
  await loginUser(page, owner, PASSWORD);
  await page.goto(purchaseUrl);
  await page.getByRole("button", { name: "Ajustar parcelas" }).click();
  const form = page.getByRole("form", { name: "Ajustar parcelas" });
  await expect(form).toContainText("são preservadas (0 parcela(s), R$ 0,00)");
  await form.getByLabel("Novo total da compra (R$)").fill("1.100,00");
  await form.getByLabel("Parcelas restantes").fill("4");
  await form.getByLabel("Motivo").fill("renegociação com o banco");
  await expectAccessible(page);
  await form.getByRole("button", { name: "Confirmar" }).click();
  await expect(page.getByText("Parcelas ajustadas.")).toBeVisible();
  const list = page.getByRole("list", { name: "Parcelas" });
  await expect(list.locator(".list-item:not(.inactive)")).toHaveCount(4);
  await expect(list.locator(".list-item.inactive")).toHaveCount(6);
  await expect(list).toContainText("R$ 275,00");

  await page.goto(cardUrl);
  await expect(position(page, "Dívida total")).toContainText("R$ 1.000,00");   // 1.100 − 100 de estorno
});

test("Anulação de compra lançada por engano devolve a dívida", async ({ page }) => {
  await loginUser(page, owner, PASSWORD);
  await page.goto("/cartoes/compra");
  await page.getByLabel("Cartão", { exact: true }).selectOption({ label: "Visa E2E" });
  await page.getByLabel("Valor total (R$)").fill("50,00");
  await page.getByLabel("Descrição").fill("Engano");
  await page.getByLabel("Categoria").selectOption({ label: "Mercado" });
  await page.getByRole("button", { name: "Salvar compra" }).click();
  await expect(page.getByText("Compra salva.")).toBeVisible();

  await page.getByRole("button", { name: "Anular" }).click();
  const form = page.getByRole("form", { name: "Anular compra" });
  await form.getByLabel("Motivo").fill("lançada por engano");
  await form.getByRole("button", { name: "Confirmar" }).click();
  await expect(page.getByText("Compra anulada.")).toBeVisible();
  await expect(page.getByRole("region", { name: "Valores" })).toContainText("Anulado");

  await page.goto(cardUrl);
  await expect(position(page, "Dívida total")).toContainText("R$ 1.000,00");
  await expect(page.getByRole("listitem", { name: "Engano" })).toContainText("anulada");
});

test("Isolamento: outro titular não abre o cartão nem a compra", async ({ page }) => {
  await loginUser(page, other, PASSWORD);
  await page.goto(cardUrl);
  await expect(page.getByText("Cartão não encontrado ou sem permissão.")).toBeVisible();
  await page.goto(purchaseUrl);
  await expect(page.getByText("Compra não encontrada ou sem permissão.")).toBeVisible();
});
