// E2E do Fluvi contra a stack Supabase LOCAL e o Vite em 127.0.0.1:5173.
// Fluxos completos no desktop; layout e acessibilidade também a 360 px (§3.4).
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "e2e",
  fullyParallel: false,
  workers: 1,
  timeout: 90_000,
  expect: { timeout: 10_000 },
  reporter: [["list"]],
  globalSetup: "./integration/global-setup.ts",
  use: {
    baseURL: "http://127.0.0.1:5173",
    locale: "pt-BR",
    trace: "retain-on-failure",
  },
  webServer: {
    command: "node scripts/web-env.mjs && pnpm --filter @fluvi/web dev",
    cwd: "..",
    url: "http://127.0.0.1:5173",
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  },
  projects: [
    { name: "desktop", use: { ...devices["Desktop Chrome"] }, testIgnore: /responsive\.spec\.ts/ },
    { name: "mobile-360", use: { ...devices["Desktop Chrome"], viewport: { width: 360, height: 740 }, isMobile: true, hasTouch: true }, testMatch: /responsive\.spec\.ts/ },
  ],
});
