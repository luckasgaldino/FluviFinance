#!/usr/bin/env node
// Backup criptografado do banco Fluvi (D1).
//
//   node scripts/backup.mjs --new-key            gera uma chave (guarde fora do repositório)
//   node scripts/backup.mjs                      backup do banco LOCAL (container supabase_db_fluvi)
//   FLUVI_BACKUP_DB_URL=... node scripts/backup.mjs --remote
//                                                backup de projeto remoto (URL só por variável de ambiente)
//
// Opções: --out <dir> (padrão: backups/) · --keep <n> (padrão: 14 backups locais)
// Requer FLUVI_BACKUP_KEY (base64, 32 bytes). Saída: <ts>.dump.enc + <ts>.manifest.json.
import { randomBytes } from "node:crypto";
import { mkdirSync, readdirSync, unlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import { pathToFileURL } from "node:url";
import { dump, encrypt, LOCAL_DB_CONTAINER, loadKey, pgVersion, SCHEMAS, sha256, snapshot } from "./lib/backup-core.mjs";

export function createBackup({ target, outDir = "backups", key = loadKey(), keep = 14 }) {
  mkdirSync(outDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const plain = dump(target);
  const blob = encrypt(plain, key);

  const manifest = {
    format: "fluvi-backup/1",
    created_at: new Date().toISOString(),
    source: target.container ? `local:${target.container}` : "remote",  // nunca a URL/credencial
    schemas: SCHEMAS,
    pg_version: pgVersion(target),
    cipher: "aes-256-gcm",
    plain_bytes: plain.length,
    plain_sha256: sha256(plain),
    encrypted_sha256: sha256(blob),
    snapshot: snapshot(target),
    storage_bytes: "não aplicável: Storage desligado no Marco A (incluir com os anexos no Marco B)",
  };

  const file = join(outDir, `${stamp}.dump.enc`);
  const manifestFile = join(outDir, `${stamp}.manifest.json`);
  writeFileSync(file, blob);
  writeFileSync(manifestFile, JSON.stringify(manifest, null, 2));

  // retenção local simples: mantém os N mais recentes
  const manifests = readdirSync(outDir).filter((f) => f.endsWith(".manifest.json")).sort();
  for (const old of manifests.slice(0, Math.max(0, manifests.length - keep))) {
    unlinkSync(join(outDir, old));
    try { unlinkSync(join(outDir, old.replace(".manifest.json", ".dump.enc"))); } catch { /* já removido */ }
  }
  return { file: resolve(file), manifestFile: resolve(manifestFile), manifest };
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { values } = parseArgs({
    options: {
      "new-key": { type: "boolean" },
      remote: { type: "boolean" },
      out: { type: "string", default: "backups" },
      keep: { type: "string", default: "14" },
    },
  });
  if (values["new-key"]) {
    console.log(randomBytes(32).toString("base64"));
    process.exit(0);
  }
  let target = { container: LOCAL_DB_CONTAINER };
  if (values.remote) {
    if (!process.env.FLUVI_BACKUP_DB_URL) throw new Error("--remote exige FLUVI_BACKUP_DB_URL");
    target = { url: process.env.FLUVI_BACKUP_DB_URL };
  }
  const { file, manifest } = createBackup({ target, outDir: values.out, keep: Number(values.keep) });
  console.log(`backup: ${file}`);
  console.log(`bytes: ${manifest.plain_bytes} · sha256(plain): ${manifest.plain_sha256.slice(0, 16)}… · migrations: ${manifest.snapshot["migrations:versions"]}`);
}
