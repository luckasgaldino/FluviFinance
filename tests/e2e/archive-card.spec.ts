// Excluir (arquivar) e reativar cartão; com dívida em aberto o app recusa e explica.
import { expect, test, type Page } from "@playwright/test";
import { createFinanceUser, expectAccessible, loginUser, PASSWORD, testEmail } from "./helpers";

const user = testEmail("e2e-excluir");

test.beforeAll(async () => {
  await createFinanceUser(user);
});

const nav = (page: Page, name: string) =>
  page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name, exact: true }).click();

async function newCard(page: Page, name: string) {
  await nav(page, "Cartões e faturas");
  await page.getByRole("button", { name: "Novo cartão" }).click();
  await page.getByLabel("Nome do cartão").fill(name);
  await page.getByLabel("Dia de fechamento").fill("5");
  await page.getByLabel("Dia de vencimento").fill("15");
  await page.getByLabel("Limite (R$)").fill("1.000,00");
  await page.getByRole("button", { name: "Criar cartão" }).click();
  await expect(page.getByRole("list", { name: "Cartões", exact: true }).getByRole("listitem", { name })).toBeVisible();
}

test("excluir cartão sem dívida, reativar, e recusa com dívida", async ({ page }) => {
  await loginUser(page, user, PASSWORD);
  await newCard(page, "Cartão de teste");
  await newCard(page, "Cartão com compra");

  // compra no segundo cartão
  await page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name: "Novo lançamento" }).click();
  await page.getByLabel("Valor (R$)").fill("50,00");
  await page.getByLabel("Descrição").fill("Livro");
  await page.getByLabel("Categoria").selectOption({ label: "Educação" });
  await page.getByLabel("Pagar com").selectOption({ label: "Cartão com compra" });
  await page.getByRole("button", { name: "Salvar" }).click();
  await expect(page.getByText("Lançamento salvo.")).toBeVisible();

  page.on("dialog", (d) => d.accept());
  await nav(page, "Cartões e faturas");
  await page.getByRole("link", { name: "Cartão com compra" }).click();
  await page.getByRole("button", { name: "Excluir cartão" }).click();
  await expect(page.getByText("Cartão com dívida em aberto: pague as faturas ou anule os lançamentos antes de excluir.")).toBeVisible();

  await nav(page, "Cartões e faturas");
  await page.getByRole("link", { name: "Cartão de teste" }).click();
  await page.getByRole("button", { name: "Excluir cartão" }).click();
  await expect(page.getByText("Cartão excluído. O histórico das compras continua guardado.")).toBeVisible();
  await expect(page.getByRole("list", { name: "Cartões", exact: true }).getByRole("listitem", { name: "Cartão de teste" })).toHaveCount(0);
  await expect(page.getByRole("list", { name: "Cartões excluídos" })).toContainText("Cartão de teste");
  await expectAccessible(page);

  await page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name: "Novo lançamento" }).click();
  await expect(page.getByLabel("Pagar com").locator("option", { hasText: "Cartão de teste" })).toHaveCount(0);

  await nav(page, "Cartões e faturas");
  await page.getByRole("list", { name: "Cartões excluídos" }).getByRole("button", { name: "Reativar" }).click();
  await expect(page.getByText("Cartão reativado.")).toBeVisible();
  await expect(page.getByRole("list", { name: "Cartões", exact: true }).getByRole("listitem", { name: "Cartão de teste" })).toBeVisible();
});
