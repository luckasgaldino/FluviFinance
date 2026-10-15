// Lê as credenciais da stack Supabase LOCAL e recusa rodar contra qualquer
// outro ambiente: testes de integração nunca tocam dados reais.
import { execSync } from "node:child_process";
import { resolve } from "node:path";

export default function setup() {
  const raw = execSync("pnpm exec supabase status -o env", {
    cwd: resolve(import.meta.dirname, "../.."),
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });
  const vars: Record<string, string> = {};
  for (const line of raw.split(/\r?\n/)) {
    const m = line.match(/^([A-Z_]+)="(.*)"$/);
    if (m) vars[m[1]] = m[2];
  }
  for (const key of ["API_URL", "DB_URL", "ANON_KEY", "SERVICE_ROLE_KEY", "MAILPIT_URL"]) {
    if (!vars[key]) throw new Error(`supabase status sem ${key}: a stack local está rodando?`);
    if (key.endsWith("_URL") && !/^(https?|postgresql):\/\/(postgres:postgres@)?127\.0\.0\.1:/.test(vars[key])) {
      throw new Error(`${key} não aponta para 127.0.0.1 — testes de integração só rodam localmente`);
    }
    process.env[`FLUVI_TEST_${key}`] = vars[key];
  }
}
