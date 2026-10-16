// v2.2 §5/§7 — PWA instalável SEM cache de dados financeiros: manifest, ícones, metadados de
// iOS e service worker que não intercepta requisições; nada fica no Cache Storage.
import { expect, test } from "@playwright/test";
import { createFinanceUser, loginUser, PASSWORD, testEmail } from "./helpers";

const user = testEmail("e2e-pwa");

test.beforeAll(async () => {
  await createFinanceUser(user);
});

test("manifest, ícones e metadados de iOS", async ({ page, request }) => {
  const manifest = await (await request.get("/manifest.webmanifest")).json();
  expect(manifest).toMatchObject({ name: "FluviFinance", display: "standalone", start_url: "/", lang: "pt-BR" });
  for (const icon of manifest.icons as { src: string }[]) {
    const res = await request.get(icon.src);
    expect(res.status(), icon.src).toBe(200);
    expect(res.headers()["content-type"]).toContain("image/png");
  }
  expect((await request.get("/apple-touch-icon.png")).status()).toBe(200);

  await page.goto("/entrar");
  await expect(page.locator('link[rel="manifest"]')).toHaveAttribute("href", "/manifest.webmanifest");
  await expect(page.locator('meta[name="apple-mobile-web-app-capable"]')).toHaveAttribute("content", "yes");
});

test("o service worker não intercepta requisições e limpa caches", async ({ request }) => {
  const sw = await (await request.get("/sw.js")).text();
  expect(sw).not.toMatch(/addEventListener\(\s*["']fetch["']/);
  expect(sw).toContain("caches.delete");
});

test("nada é guardado no Cache Storage depois de usar a área financeira", async ({ page }) => {
  await loginUser(page, user, PASSWORD);
  for (const path of ["/painel", "/contas", "/lancamentos", "/relatorios"]) {
    await page.goto(path);
    await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  }
  expect(await page.evaluate(async () => (await caches.keys()).length)).toBe(0);
  expect(await page.evaluate(() => Object.keys(localStorage).filter((k) => !/^(fluvi\.auth|fluvi\.family)$/.test(k)))).toEqual([]);
});
