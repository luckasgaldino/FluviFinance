#!/usr/bin/env node
// Exercício de backup e restauração (D1, §10.1 item 5, §19.8) — somente dados fictícios.
//
//   pnpm backup:drill                        exercício completo com fixtures fictícias
//   pnpm backup:drill --backup <arq.enc>     restaura e verifica um backup existente (sem semear)
//   --keep-container                         não remove o container restaurado ao final
//   --tests a,b                              arquivos pgTAP a rodar (padrão: todos); use a versão de testes
//                                            compatível com o schema do backup (ex.: backup anterior a uma migration)
//
// Etapas: semear fixtures → backup criptografado → container ISOLADO (sem Auth, sem
// e-mail, sem Edge Functions) → decifrar e restaurar → comparar fotografias →
// testar acesso/isolamento no restaurado → pgTAP no restaurado → limpar.
import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { createBackup } from "./backup.mjs";
import {
  decrypt, diffSnapshots, LOCAL_DB_CONTAINER, PG_IMAGE, psql, run, sha256, sleep, snapshot,
} from "./lib/backup-core.mjs";

const RESTORE_CONTAINER = "fluvi_restore_drill";
const RESTORE_PORT = 55433;
const ROOT = resolve(import.meta.dirname, "..");

const { values } = parseArgs({
  options: { backup: { type: "string" }, "keep-container": { type: "boolean" }, tests: { type: "string" } },
});

const report = { started_at: new Date().toISOString(), steps: [], result: "FAIL" };
const step = (name, data = {}) => {
  report.steps.push({ at: new Date().toISOString(), name, ...data });
  console.log(`✔ ${name}${Object.keys(data).length ? " " + JSON.stringify(data) : ""}`);
};

const tag = randomBytes(3).toString("hex");
const ids = {};
const source = { container: LOCAL_DB_CONTAINER };
const restored = { container: RESTORE_CONTAINER };

function seedFixtures() {
  const [[n]] = psql(source, "select count(*) from public.administrators");
  if (Number(n) > 0) {
    throw new Error("o banco local já tem Admin gravado; rode `pnpm db:reset` antes do exercício");
  }
  const rows = psql(source, `
    begin;
    insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data) values
      (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'drill-admin.${tag}@fluvi.test', '{"display_name":"Admin Drill"}'),
      (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'drill-luck.${tag}@fluvi.test',  '{"display_name":"Luck Drill"}'),
      (gen_random_uuid(), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'drill-bia.${tag}@fluvi.test',   '{"display_name":"Bia Drill"}');
    update public.profiles p set provisioned_at = now()
      from auth.users u where u.id = p.user_id and u.email like 'drill-%.${tag}@fluvi.test';
    -- senha fictícia sem uso: só satisfaz a regra de ativação
    update auth.users set email_confirmed_at = now(), encrypted_password = 'drill-fixture-sem-login'
     where email like 'drill-%.${tag}@fluvi.test';
    insert into public.administrators (user_id)
      select id from auth.users where email = 'drill-admin.${tag}@fluvi.test';
    insert into public.households (name) values ('Família Drill ${tag}');
    insert into public.household_members (household_id, user_id)
      select h.id, u.id from public.households h, auth.users u
       where h.name = 'Família Drill ${tag}' and u.email in ('drill-luck.${tag}@fluvi.test', 'drill-bia.${tag}@fluvi.test');
    commit;
    select split_part(u.email, '.', 1), u.id, p.status from auth.users u join public.profiles p on p.user_id = u.id
     where u.email like 'drill-%.${tag}@fluvi.test';
  `);
  for (const [name, id, status] of rows) {
    if (status !== "active") throw new Error(`fixture ${name} não ativou (status ${status})`);
    ids[name.replace("drill-", "")] = id;
  }
}

function cleanupFixtures() {
  psql(source, `
    delete from auth.users where email like 'drill-%.${tag}@fluvi.test';
    delete from public.households where name = 'Família Drill ${tag}';
  `);
}

function startIsolatedContainer() {
  run("docker", ["rm", "-f", RESTORE_CONTAINER], { allowFail: true });
  // sem rede para o mundo além da porta local; sem Auth/Edge/SMTP: não envia nada
  run("docker", ["run", "-d", "--name", RESTORE_CONTAINER, "-e", "POSTGRES_PASSWORD=postgres",
    "-p", `127.0.0.1:${RESTORE_PORT}:5432`, PG_IMAGE]);
  for (let i = 0; i < 90; i++) {
    const ready = run("docker", ["exec", RESTORE_CONTAINER, "pg_isready", "-U", "postgres", "-h", "localhost"], { allowFail: true });
    if (ready.status === 0) {
      // a imagem reinicia uma vez após os scripts de init; confirma estabilidade
      sleep(3000);
      if (run("docker", ["exec", RESTORE_CONTAINER, "pg_isready", "-U", "postgres", "-h", "localhost"], { allowFail: true }).status === 0) return;
    }
    sleep(1000);
  }
  throw new Error("container de restauração não ficou pronto");
}

function restore(plain, extensions = []) {
  // extensões exigidas pelo schema (o dump por schema não as recria)
  for (const ext of extensions) psql(restored, `create extension if not exists ${ext} with schema extensions;`);
  run("docker", ["exec", "-i", RESTORE_CONTAINER, "sh", "-c", "cat > /tmp/restore.dump"], { input: plain });
  run("docker", ["exec", RESTORE_CONTAINER, "pg_restore", "-U", "supabase_admin", "-d", "postgres",
    "--clean", "--if-exists", "--exit-on-error", "/tmp/restore.dump"]);
  run("docker", ["exec", RESTORE_CONTAINER, "rm", "-f", "/tmp/restore.dump"]);
}

// Acesso no banco restaurado, com JWT simulado: o isolamento por família (v2.2) precisa
// sobreviver ao restore — membros acessam a família, o Admin não acessa finanças.
function accessChecks() {
  const as = (sub, aal, sql) => `
    select set_config('request.jwt.claims', '{"sub":"${sub}","role":"authenticated","aal":"${aal}"}', true);
    set local role authenticated;
    ${sql}
    reset role;`;
  const family = `(select id from public.households where name = 'Família Drill ${tag}')`;
  const rows = psql(restored, `
    begin;
    ${as(ids.luck, "aal1", `select 'luck_families', count(*) from public.my_families();
                            select 'luck_access', private.can_access_family(${family}, 'transactions', 'read')::text;`)}
    ${as(ids.bia, "aal1", `select 'bia_families', count(*) from public.my_families();`)}
    ${as(ids.admin, "aal2", `select 'admin_financial', count(*) from public.my_families();
                             select 'admin_access', private.can_access_family(${family}, 'transactions', 'read')::text;
                             select 'admin_can_administer', (public.whoami() ->> 'can_administer');`)}
    ${as(ids.admin, "aal1", `select 'admin_aal1_households', count(*) from public.households;`)}
    rollback;
  `).filter((r) => r.length === 2 && !r[0].startsWith("set") && r[0] !== "");

  const got = Object.fromEntries(rows);
  const expected = {
    luck_families: "1", luck_access: "true", bia_families: "1",
    admin_financial: "0", admin_access: "false", admin_can_administer: "true", admin_aal1_households: "0",
  };
  const failures = Object.entries(expected).filter(([k, v]) => got[k] !== v)
    .map(([k, v]) => `${k}: esperado ${v}, obtido ${got[k]}`);

  const anon = run("docker", ["exec", "-i", RESTORE_CONTAINER, "psql", "-U", "supabase_admin", "-d", "postgres",
    "-v", "ON_ERROR_STOP=1", "-tA"], { input: "set role anon; select count(*) from public.profiles;", allowFail: true });
  if (anon.status === 0) failures.push("anon conseguiu ler profiles no banco restaurado");

  if (failures.length) throw new Error(`isolamento no restaurado falhou: ${failures.join("; ")}`);
  return { ...got, anon_profiles: "negado" };
}

function pgtapOnRestored() {
  const cli = join(ROOT, "node_modules", "supabase", "dist", "supabase.js");
  const files = values.tests ? values.tests.split(",").map((t) => t.trim()) : [];
  const out = run(process.execPath, [cli, "test", "db", "--db-url",
    `postgresql://postgres:postgres@127.0.0.1:${RESTORE_PORT}/postgres?sslmode=disable`, ...files], { allowFail: true });
  const text = out.stdout.toString() + out.stderr.toString();
  const tests = text.match(/Tests=(\d+)/)?.[1];
  if (out.status !== 0 || !/Result: PASS/.test(text)) {
    throw new Error(`pgTAP no restaurado falhou:\n${text.split("\n").filter((l) => /not ok|Failed|ERROR/.test(l)).join("\n")}`);
  }
  return { tests: Number(tests) };
}

let seeded = false;
try {
  const key = process.env.FLUVI_BACKUP_KEY ? Buffer.from(process.env.FLUVI_BACKUP_KEY, "base64") : randomBytes(32);
  if (key.length !== 32) throw new Error("FLUVI_BACKUP_KEY precisa ter 32 bytes (base64)");
  report.key = process.env.FLUVI_BACKUP_KEY ? "FLUVI_BACKUP_KEY" : "chave efêmera do exercício (descartada)";

  let file, manifest;
  if (values.backup) {
    file = resolve(values.backup);
    manifest = JSON.parse(readFileSync(file.replace(/\.dump\.enc$/, ".manifest.json"), "utf8"));
    step("backup existente selecionado", { file });
  } else {
    seedFixtures();
    seeded = true;
    step("fixtures fictícias semeadas", { tag });
    ({ file, manifest } = createBackup({ target: source, outDir: join(ROOT, "backups"), key }));
    step("backup criptografado gerado", { bytes: manifest.plain_bytes, sha256: manifest.plain_sha256.slice(0, 16) });
  }

  const blob = readFileSync(file);
  if (sha256(blob) !== manifest.encrypted_sha256) throw new Error("hash do arquivo cifrado não confere com o manifesto");
  const plain = decrypt(blob, key);
  if (sha256(plain) !== manifest.plain_sha256) throw new Error("hash do dump decifrado não confere com o manifesto");
  step("integridade conferida (sha256 + tag GCM)");

  startIsolatedContainer();
  step("container isolado pronto", { container: RESTORE_CONTAINER, port: RESTORE_PORT });

  const t0 = Date.now();
  restore(plain, manifest.required_extensions ?? []);
  report.restore_seconds = Math.round((Date.now() - t0) / 100) / 10;
  step("restauração concluída", { seconds: report.restore_seconds });

  const diff = diffSnapshots(manifest.snapshot, snapshot(restored));
  if (diff.length) throw new Error(`fotografia do restaurado difere da origem: ${JSON.stringify(diff, null, 2)}`);
  step("fotografia idêntica à origem", { itens: Object.keys(manifest.snapshot).length });

  if (seeded) step("isolamento de acesso preservado", accessChecks());
  step("pgTAP no banco restaurado", pgtapOnRestored());

  report.result = "PASS";
} catch (e) {
  report.error = e.message;
  console.error(`✘ ${e.message}`);
  process.exitCode = 1;
} finally {
  if (seeded) {
    cleanupFixtures();
    step("fixtures removidas da origem");
  }
  if (!values["keep-container"]) {
    run("docker", ["rm", "-f", RESTORE_CONTAINER], { allowFail: true });
    step("container de restauração removido");
  }
  report.finished_at = new Date().toISOString();
  mkdirSync(join(ROOT, "backups"), { recursive: true });
  const reportFile = join(ROOT, "backups", `drill-${report.started_at.replace(/[:.]/g, "-")}.json`);
  writeFileSync(reportFile, JSON.stringify(report, null, 2));
  console.log(`${report.result} — relatório: ${reportFile}`);
}
