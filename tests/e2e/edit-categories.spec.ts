// v2.2 R4b — categoria da família (FF-08), extrato com filtros (FF-10) e edição com histórico (FF-02).
import { expect, test, type Page } from "@playwright/test";
import { createFinanceUser, expectAccessible, loginUser, PASSWORD, testEmail } from "./helpers";

test.describe.configure({ mode: "serial" });

const user = testEmail("e2e-r4b");

test.beforeAll(async () => {
  await createFinanceUser(user);
});

const nav = (page: Page, name: string) =>
  page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name, exact: true }).click();

test("categoria da família, filtro no extrato e edição com histórico", async ({ page }) => {
  await loginUser(page, user, PASSWORD);
  await nav(page, "Contas e saldos");
  await page.getByRole("button", { name: "Nova conta" }).click();
  await page.getByLabel("Nome da conta").fill("Banco R4b");
  await page.getByLabel("Saldo inicial (R$)").fill("1.000,00");
  await page.getByLabel("Data de abertura").fill("2026-01-01");
  await page.getByRole("button", { name: "Criar conta" }).click();
  await expect(page.getByRole("listitem", { name: "Banco R4b" })).toContainText("R$ 1.000,00");

  await nav(page, "Configurações");
  const form = page.getByRole("form", { name: "Nova categoria" });
  await form.getByLabel("Nova categoria").fill("Feira livre");
  await form.getByRole("button", { name: "Adicionar" }).click();
  await expect(page.getByRole("list", { name: "Categorias da família" })).toContainText("Feira livre");
  await form.getByLabel("Nova categoria").fill("mercado");
  await form.getByRole("button", { name: "Adicionar" }).click();
  await expect(page.getByText("Categoria já existe.")).toBeVisible();
  await expectAccessible(page);

  for (const [desc, cat, amount] of [["Feira de sábado", "Feira livre", "70,00"], ["Padaria", "Mercado", "20,00"]]) {
    await page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name: "Novo lançamento" }).click();
    await page.getByLabel("Valor (R$)").fill(amount);
    await page.getByLabel("Descrição").fill(desc);
    await page.getByLabel("Categoria").selectOption({ label: cat });
    await page.getByLabel("Pagar com").selectOption({ label: "Banco R4b" });
    await page.getByRole("button", { name: "Salvar" }).click();
    await expect(page.getByText("Lançamento salvo.")).toBeVisible();
  }

  await nav(page, "Lançamentos");
  await expect(page.getByRole("list", { name: "Lançamentos" }).getByRole("listitem")).toHaveCount(2);
  await page.getByLabel("Categoria", { exact: true }).selectOption({ label: "Feira livre" });
  await expect(page.getByRole("list", { name: "Lançamentos" }).getByRole("listitem")).toHaveCount(1);
  await expectAccessible(page);

  await page.getByRole("listitem", { name: "Feira de sábado" }).getByRole("button", { name: "Editar" }).click();
  const edit = page.getByRole("form", { name: "Editar lançamento" });
  await expect(edit.getByLabel("Valor (R$)")).toHaveValue("70,00");
  await edit.getByLabel("Valor (R$)").fill("50,00");
  await expectAccessible(page);
  await edit.getByRole("button", { name: "Salvar edição" }).click();
  await expect(page.getByText("Lançamento editado.")).toBeVisible();
  const items = page.getByRole("list", { name: "Lançamentos" }).getByRole("listitem", { name: "Feira de sábado" });
  await expect(items).toHaveCount(2);
  await expect(items.filter({ hasText: "Editado" })).toContainText("R$ 70,00");
  await expect(items.filter({ hasText: "versão editada" })).toContainText("R$ 50,00");

  await nav(page, "Contas e saldos");
  await expect(page.getByRole("listitem", { name: "Banco R4b" })).toContainText("R$ 930,00");   // 1.000 − 50 − 20

  await nav(page, "Configurações");
  await page.getByRole("listitem", { name: "Feira livre" }).getByRole("button", { name: "Arquivar" }).click();
  await expect(page.getByRole("listitem", { name: "Feira livre" })).toContainText("arquivada");
  await page.getByRole("complementary", { name: "Menu lateral" }).getByRole("link", { name: "Novo lançamento" }).click();
  await expect(page.getByLabel("Categoria").locator("option", { hasText: "Mercado" })).toHaveCount(1);
  await expect(page.getByLabel("Categoria").locator("option", { hasText: "Feira livre" })).toHaveCount(0);
});
