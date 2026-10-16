// D5 — Fluxo completo pela interface: Admin com MFA obrigatório, núcleo, convites,
// ativação pelo e-mail, permissões, bloqueio e recuperação de senha.
import { expect, test, type Browser, type Page } from "@playwright/test";
import {
  allowNextEmail, createActiveUser, expectAccessible, freshTotp, login, PASSWORD, runId, sql,
  testEmail, waitForAuthLink,
} from "./helpers";

test.describe.configure({ mode: "serial" });

const adminEmail = testEmail("e2e-admin");
const luckEmail = testEmail("e2e-luck");
const biaEmail = testEmail("e2e-bia");
const householdName = `Família E2E ${runId}`;
let totpSecret = "";

test.beforeAll(async () => {
  const adminId = await createActiveUser(adminEmail);
  await sql("insert into public.administrators (user_id) values ($1)", [adminId]);
});

test.afterAll(async () => {
  await sql("delete from auth.users where email like $1", [`%.${runId}@fluvi.test`]);
  await sql("delete from public.households where name = $1", [householdName]);
});

async function adminPage(browser: Browser, opts: { fakeClock?: boolean } = {}): Promise<Page> {
  const page = await (await browser.newContext()).newPage();
  if (opts.fakeClock) await page.clock.install();
  await login(page, adminEmail, PASSWORD);
  await expect(page).toHaveURL(/\/verificar$/);
  await page.getByLabel("Código do aplicativo autenticador").fill(await freshTotp(totpSecret));
  await page.getByRole("button", { name: "Verificar" }).click();
  await expect(page).toHaveURL(/\/admin\/usuarios$/);
  return page;
}

async function acceptInviteInBrowser(browser: Browser, email: string) {
  const page = await (await browser.newContext()).newPage();
  await page.goto(await waitForAuthLink(email, "invite"));
  await expect(page.getByRole("heading", { name: "Ative sua conta" })).toBeVisible();
  await page.getByLabel("Nova senha").fill(PASSWORD);
  await page.getByLabel("Confirme a senha").fill(PASSWORD);
  await page.getByRole("button", { name: "Salvar senha" }).click();
  // v2.2 FAM-03: a família indicada no convite é aceita no app, com aviso do histórico; a senha
  // recém-definida no desktop libera o dashboard logo em seguida (§3.1)
  await expect(page).toHaveURL(/\/painel$/);
  await expect(page.getByText("todo o histórico financeiro")).toBeVisible();
  await expectAccessible(page);
  await page.getByRole("listitem", { name: householdName }).getByRole("button", { name: "Aceitar" }).click();
  await expect(page.getByRole("heading", { name: "Visão geral", level: 1 })).toBeVisible();
  await expect(page.getByText(email)).toBeVisible();
  return page;
}

test("Admin sem MFA é obrigado a cadastrar TOTP antes de administrar", async ({ page }) => {
  await login(page, adminEmail, PASSWORD);
  await expect(page).toHaveURL(/\/seguranca\/mfa$/);
  await expect(page.getByText("Contas administrativas precisam de verificação em duas etapas")).toBeVisible();
  await expectAccessible(page);

  // não consegue pular a etapa
  await page.goto("/admin/usuarios");
  await expect(page).toHaveURL(/\/seguranca\/mfa$/);

  totpSecret = (await page.getByTestId("totp-secret").textContent())!.trim();
  await page.getByLabel("Código de 6 dígitos").fill(await freshTotp(totpSecret));
  await page.getByRole("button", { name: "Confirmar" }).click();
  await expect(page).toHaveURL(/\/admin\/usuarios$/);
  await expect(page.getByRole("heading", { name: "Usuários" })).toBeVisible();
});

test("Admin cria família e convida Luck e Bia; contas ficam pendentes", async ({ browser }) => {
  const page = await adminPage(browser);
  await page.getByRole("link", { name: "Famílias e membros" }).click();
  await expect(page.getByRole("heading", { name: "Famílias e membros", level: 1 })).toBeVisible();
  await page.getByLabel("Nome da família").fill(householdName);
  await page.getByRole("button", { name: "Criar" }).click();
  await expect(page.getByRole("heading", { name: householdName })).toBeVisible();
  await expectAccessible(page);

  await page.getByRole("link", { name: "Usuários" }).click();
  // espera a navegação: "Nome" também casaria com "Nome da família" da página anterior
  await expect(page.getByRole("heading", { name: "Usuários", level: 1 })).toBeVisible();
  for (const [name, email] of [["Luck", luckEmail], ["Bia", biaEmail]]) {
    await page.getByLabel("Nome", { exact: true }).fill(name);
    await page.getByLabel("E-mail").fill(email);
    await page.getByLabel("Família", { exact: true }).selectOption({ label: householdName });
    await page.getByRole("button", { name: "Enviar convite" }).click();
    // a Edge Function local às vezes passa de 10 s (worker novo + envio do e-mail de convite; G4)
    await expect(page.getByText("Convite enviado")).toBeVisible({ timeout: 30_000 });
    await expect(page.getByRole("listitem", { name })).toContainText("Pendente");
  }
  await expectAccessible(page);
});

// Regressão: a renovação do token trocava a chave do estado de sessão, a página
// desmontava e o formulário era apagado (falha observada no CI em 15/10/2026).
test("Renovação do token não desmonta a página nem apaga formulário em edição", async ({ browser }) => {
  const page = await adminPage(browser, { fakeClock: true });
  const token = () => page.evaluate(() => JSON.parse(localStorage.getItem("fluvi.auth")!).access_token as string);
  await page.getByLabel("Nome", { exact: true }).fill("Rascunho em edição");
  const before = await token();

  await page.clock.fastForward("59:30"); // perto do vencimento (jwt_expiry 3600 s): o SDK renova
  await expect.poll(token, { timeout: 30_000 }).not.toBe(before);

  await expect(page.getByLabel("Nome", { exact: true })).toHaveValue("Rascunho em edição");
  await expect(page).toHaveURL(/\/admin\/usuarios$/);
});

test("Convidados ativam a conta pelo link do e-mail e caem no dashboard", async ({ browser }) => {
  const luck = await acceptInviteInBrowser(browser, luckEmail);
  await expectAccessible(luck);
  await acceptInviteInBrowser(browser, biaEmail);
});

test("Usuário financeiro não acessa o painel administrativo", async ({ page }) => {
  await login(page, luckEmail, PASSWORD);
  await expect(page).toHaveURL(/\/painel$/);
  await page.goto("/admin/usuarios");
  await expect(page).toHaveURL(/\/painel$/);
});

test("Admin bloqueia Luck: sessão aberta cai e novo login é recusado", async ({ browser }) => {
  const luck = await (await browser.newContext()).newPage();
  await login(luck, luckEmail, PASSWORD);
  await expect(luck).toHaveURL(/\/painel$/);

  const page = await adminPage(browser);
  page.once("dialog", (d) => d.accept());
  await page.getByRole("listitem", { name: "Luck" }).getByRole("button", { name: "Bloquear" }).click();
  await expect(page.getByRole("listitem", { name: "Luck" })).toContainText("Bloqueado");

  await luck.reload();
  await expect(luck).not.toHaveURL(/\/painel$/);
  await login(luck, luckEmail, PASSWORD);
  await expect(luck.getByRole("alert")).toHaveText("Conta bloqueada. Procure o administrador.");

  await page.getByRole("link", { name: "Auditoria" }).click();
  await expect(page.getByRole("heading", { name: "Auditoria", level: 1 })).toBeVisible();
  await expect(page.getByRole("list", { name: "Eventos de auditoria" })).toContainText("Perfil · update");
  await expectAccessible(page);
});

test("Bia recupera a senha pelo e-mail", async ({ page }) => {
  await allowNextEmail(biaEmail);
  await page.goto("/esqueci-senha");
  await expectAccessible(page);
  await page.getByLabel("E-mail").fill(biaEmail);
  await page.getByRole("button", { name: "Enviar link" }).click();
  await expect(page.getByText("Se o e-mail estiver cadastrado")).toBeVisible();

  await page.goto(await waitForAuthLink(biaEmail, "recovery", 2));
  await expect(page.getByRole("heading", { name: "Definir nova senha" })).toBeVisible();
  await page.getByLabel("Nova senha").fill(`${PASSWORD}-novo`);
  await page.getByLabel("Confirme a senha").fill(`${PASSWORD}-novo`);
  await page.getByRole("button", { name: "Salvar senha" }).click();
  await expect(page).toHaveURL(/\/painel$/);

  await page.getByRole("button", { name: "Sair" }).click();
  await expect(page).toHaveURL(/\/entrar$/);
  await login(page, biaEmail, PASSWORD);
  await expect(page.getByRole("alert")).toHaveText("E-mail ou senha incorretos.");
  await login(page, biaEmail, `${PASSWORD}-novo`);
  await expect(page).toHaveURL(/\/painel$/);
});

test("Mesma resposta para e-mail inexistente (sem enumeração)", async ({ page }) => {
  await page.goto("/esqueci-senha");
  await page.getByLabel("E-mail").fill(testEmail("ninguem"));
  await page.getByRole("button", { name: "Enviar link" }).click();
  await expect(page.getByText("Se o e-mail estiver cadastrado")).toBeVisible();
});

test("Link de convite já usado mostra erro claro", async ({ page }) => {
  await page.goto(await waitForAuthLink(luckEmail, "invite"));
  await expect(page.getByRole("heading", { name: "Link inválido" })).toBeVisible();
  await expectAccessible(page);
});
