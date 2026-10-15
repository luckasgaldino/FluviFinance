// Apoio aos testes E2E: reaproveita fixtures e leitura de e-mail da integração.
import AxeBuilder from "@axe-core/playwright";
import { expect, type Page } from "@playwright/test";
import { totp } from "../integration/support";

export * from "../integration/support";

// Código TOTP novo: evita reutilizar o mesmo código dentro da janela de 30 s.
let lastCode = "";
export async function freshTotp(secret: string): Promise<string> {
  let code = totp(secret);
  while (code === lastCode) {
    await new Promise((r) => setTimeout(r, 1000));
    code = totp(secret);
  }
  lastCode = code;
  return code;
}

export async function login(page: Page, email: string, password: string) {
  await page.goto("/entrar");
  await page.getByLabel("E-mail").fill(email);
  await page.getByLabel("Senha").fill(password);
  await page.getByRole("button", { name: "Entrar" }).click();
}

// Sem violações graves ou críticas de acessibilidade (WCAG 2.x A/AA).
export async function expectAccessible(page: Page) {
  const results = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"]).analyze();
  const serious = results.violations.filter((v) => v.impact === "serious" || v.impact === "critical");
  expect(serious.map((v) => `${v.id}: ${v.help}`)).toEqual([]);
}

export async function expectNoHorizontalOverflow(page: Page) {
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(0);
}

// Login de usuário financeiro: espera a sessão estar estabelecida (dashboard no desktop,
// tela inicial discreta no celular) antes de navegar.
export async function loginUser(page: Page, email: string, password: string) {
  await login(page, email, password);
  await expect(page).toHaveURL(/\/(painel|inicio)$/);
}

// Confirma a senha na tela "Área financeira protegida" (segunda barreira do celular).
export async function unlockFinance(page: Page, password: string) {
  await expect(page.getByRole("heading", { name: "Área financeira protegida", level: 1 })).toBeVisible();
  await page.getByRole("form", { name: "Confirmar senha" }).getByLabel("Senha").fill(password);
  await page.getByRole("button", { name: "Desbloquear" }).click();
  await expect(page.getByRole("heading", { name: "Área financeira protegida", level: 1 })).toHaveCount(0);
}
