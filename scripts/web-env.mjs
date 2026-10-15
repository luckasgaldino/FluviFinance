#!/usr/bin/env node
// Gera apps/web/.env.local a partir da stack Supabase LOCAL (ignorado pelo git).
// Só a URL da API e a chave pública (anon) — nunca a service_role.
import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const raw = execSync("pnpm exec supabase status -o env", { cwd: root, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
const get = (k) => raw.match(new RegExp(`^${k}="(.*)"$`, "m"))?.[1];
const url = get("API_URL");
const anon = get("ANON_KEY");
if (!url || !anon) throw new Error("stack local não está rodando (pnpm db:start)");
writeFileSync(resolve(root, "apps/web/.env.local"), `VITE_SUPABASE_URL=${url}\nVITE_SUPABASE_ANON_KEY=${anon}\n`);
console.log("apps/web/.env.local gerado para", url);
