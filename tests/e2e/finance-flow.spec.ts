// Marco B — telas de Contas e Lançamentos (FIN-02, FIN-04): fluxo pela interface,
// anulação × reversão, validação de valor, isolamento e acessibilidade.
// Identidades fictícias com histórico financeiro não são apagadas (razão somente-acréscimo).
import { expect, test } from "@playwright/test";
import { createActiveUser, expectAccessible, loginUser, PASSWORD, testEmail } from "./helpers";

test.describe.configure({ mode: "serial" });

const owner = testEmail("e2e-fin");
const other = testEmail("e2e-fin-outro");
let accountUrl = "";

test.beforeAll(async () => {
  await createActiveUser(owner);
  await createActiveUser(other);
});

test("Contas: criar conta com saldo inicial", async ({ page }) => {
  await loginUser(page, owner, PASSWORD);
  await page.getByRole("navigation").getByRole("link", { name: "Contas e saldos", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Contas", level: 1 })).toBeVisible();
  await expect(page.getByText("Nenhuma conta cadastrada")).toBeVisible();
  await expectAccessible(page);

  await page.getByRole("button", { name: "Nova conta" }).click();
  await page.getByLabel("Nome da conta").fill("Banco E2E");
  await page.getByLabel("Saldo inicial (R$)").fill("1.000,00");
  await page.getByLabel("Data de abertura").fill("2026-01-01");
  await expectAccessible(page);
  await page.getByRole("button", { name: "Criar conta" }).click();
  await expect(page.getByRole("listitem", { name: "Banco E2E" })).toContainText("R$ 1.000,00");
});

test("Lançamentos: valor inválido é recusado no formulário", async ({ page }) => {
  await loginUser(page, owner, PASSWORD);
  await page.goto("/lancamentos/novo");
  await expect(page.getByRole("heading", { name: "Novo lançamento", level: 1 })).toBeVisible();
  await page.getByLabel("Valor (R$)").fill("12,345");
  await page.getByRole("button", { name: "Salvar lançamento" }).click();
  await expect(page.getByText("Informe um valor maior que zero, no formato 1.234,56.")).toBeVisible();
  await expect(page.getByLabel("Valor (R$)")).toHaveAttribute("aria-invalid", "true");
  await expectAccessible(page);
});

test("Lançamentos: despesa reduz o saldo e aparece no extrato", async ({ page }) => {
  await loginUser(page, owner, PASSWORD);
  await page.goto("/lancamentos/novo");
  await page.getByLabel("Valor (R$)").fill("70,00");
  await page.getByLabel("Descrição").fill("Mercado do mês");
  await page.getByLabel("Categoria").selectOption({ label: "Mercado" });
  await page.getByLabel("Conta", { exact: true }).selectOption({ label: "Banco E2E" });
  await page.getByRole("button", { name: "Salvar lançamento" }).click();

  await expect(page).toHaveURL(/\/lancamentos\?/);
  await expect(page.getByText("Lançamento salvo.")).toBeVisible();
  await expect(page.getByRole("listitem", { name: "Mercado do mês" })).toContainText("−R$ 70,00");
  await expectAccessible(page);

  await page.getByRole("navigation").getByRole("link", { name: "Contas e saldos", exact: true }).click();
  await expect(page.getByRole("listitem", { name: "Banco E2E" })).toContainText("R$ 930,00");
  await page.getByRole("link", { name: "Banco E2E" }).click();
  accountUrl = page.url();
  await expect(page.getByRole("list", { name: "Movimentos" })).toContainText("Mercado do mês");
  await expectAccessible(page);
});

test("Anulação: registro por engano volta o saldo e preserva o histórico", async ({ page }) => {
  await loginUser(page, owner, PASSWORD);
  await page.goto("/lancamentos");
  const item = page.getByRole("listitem", { name: "Mercado do mês" });
  await item.getByRole("button", { name: "Anular" }).click();
  const panel = page.getByRole("form", { name: "Anular lançamento" });
  await expect(panel).toBeVisible();
  await expectAccessible(page);
  await panel.getByLabel("Motivo").fill("lançado em duplicidade");
  await panel.getByRole("button", { name: "Confirmar anulação" }).click();
  await expect(page.getByText("Lançamento anulado.")).toBeVisible();
  await expect(item).toContainText("Anulado");
  await expect(item).toContainText("Motivo: lançado em duplicidade");

  await page.goto(accountUrl);
  await expect(page.getByText("R$ 1.000,00").first()).toBeVisible();
  await expect(page.getByRole("list", { name: "Movimentos" })).toContainText("compensação de anulação");
});

test("Reversão: receita devolvida entra como movimento real contrário", async ({ page }) => {
  await loginUser(page, owner, PASSWORD);
  await page.goto("/lancamentos/novo");
  await page.getByLabel("Receita").check();
  await page.getByLabel("Valor (R$)").fill("50,00");
  await page.getByLabel("Descrição").fill("Freela");
  await page.getByLabel("Categoria").selectOption({ label: "Renda extra" });
  await page.getByLabel("Conta", { exact: true }).selectOption({ label: "Banco E2E" });
  await page.getByRole("button", { name: "Salvar lançamento" }).click();
  const item = page.getByRole("listitem", { name: "Freela", exact: true });
  await expect(item).toContainText("+R$ 50,00");

  await item.getByRole("button", { name: "Reverter" }).click();
  const panel = page.getByRole("form", { name: "Reverter lançamento" });
  await panel.getByLabel("Motivo").fill("cliente estornou o pagamento");
  await panel.getByRole("button", { name: "Confirmar reversão" }).click();
  await expect(page.getByText("Reversão registrada.")).toBeVisible();
  await expect(item).toContainText("Revertido");
  await expect(page.getByRole("listitem", { name: "Reversão: Freela" })).toBeVisible();

  await page.getByRole("navigation").getByRole("link", { name: "Contas e saldos", exact: true }).click();
  await expect(page.getByRole("listitem", { name: "Banco E2E" })).toContainText("R$ 1.000,00");
});

test("Isolamento: outro titular não abre a conta nem vê os lançamentos", async ({ page }) => {
  await loginUser(page, other, PASSWORD);
  await page.goto(accountUrl);
  await expect(page.getByText("Conta não encontrada ou sem permissão.")).toBeVisible();
  await page.goto("/lancamentos");
  await expect(page.getByText("Nenhum lançamento neste mês.")).toBeVisible();
});
