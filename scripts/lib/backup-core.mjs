// Núcleo de backup/restauração do Fluvi (D1, §10.1 item 5, §19.8).
// Sem dependências externas: usa o pg_dump/psql da imagem Supabase via Docker.
import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { spawnSync } from "node:child_process";

// Imagem idêntica à do banco local (ADR-0001). Mudou a versão do banco → mudar aqui.
export const PG_IMAGE = "public.ecr.aws/supabase/postgres:17.6.1.171";
export const LOCAL_DB_CONTAINER = "supabase_db_fluvi";
export const SCHEMAS = ["auth", "public", "private", "supabase_migrations"];
// Extensões de que o schema depende e que o pg_dump por schema não recria.
export const REQUIRED_EXTENSIONS = ["btree_gist"];

const MAGIC = Buffer.from("FLVB1");

export function run(cmd, args, { input, allowFail = false, shell = false } = {}) {
  const res = spawnSync(cmd, args, { input, shell, maxBuffer: 1024 * 1024 * 1024, encoding: input ? undefined : "buffer" });
  if (res.error) throw res.error;
  if (res.status !== 0 && !allowFail) {
    throw new Error(`${cmd} ${args.slice(0, 3).join(" ")}… falhou (${res.status}): ${res.stderr?.toString().trim()}`);
  }
  return res;
}

export const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

export const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

export function loadKey() {
  const raw = process.env.FLUVI_BACKUP_KEY;
  if (!raw) throw new Error("FLUVI_BACKUP_KEY ausente (base64 de 32 bytes). Gere com: node scripts/backup.mjs --new-key");
  const key = Buffer.from(raw, "base64");
  if (key.length !== 32) throw new Error("FLUVI_BACKUP_KEY precisa ter 32 bytes (base64)");
  return key;
}

// Formato: "FLVB1" | iv(12) | tag(16) | ciphertext
export function encrypt(plain, key) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const ct = Buffer.concat([cipher.update(plain), cipher.final()]);
  return Buffer.concat([MAGIC, iv, cipher.getAuthTag(), ct]);
}

export function decrypt(blob, key) {
  if (!blob.subarray(0, MAGIC.length).equals(MAGIC)) throw new Error("arquivo não é um backup Fluvi (FLVB1)");
  const iv = blob.subarray(5, 17);
  const tag = blob.subarray(17, 33);
  const decipher = createDecipheriv("aes-256-gcm", key, iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(blob.subarray(33)), decipher.final()]);
}

// Alvo: { container } (banco local em Docker) ou { url } (projeto remoto).
// psql devolve linhas como arrays de colunas (separador |).
export function psql(target, sql, { user = "supabase_admin" } = {}) {
  const common = ["-v", "ON_ERROR_STOP=1", "-q", "-tA", "-F", "|"];
  const args = target.container
    ? ["exec", "-i", target.container, "psql", "-U", user, "-d", "postgres", ...common]
    : ["run", "--rm", "-i", "--entrypoint", "psql", PG_IMAGE, "--dbname", target.url, ...common];
  const out = run("docker", args, { input: sql }).stdout.toString().trim();
  return out ? out.split("\n").map((l) => l.split("|")) : [];
}

// Fotografia do banco usada para comparar origem e restauração.
export const SNAPSHOT_SQL = `
select 'rows', table_schema || '.' || table_name,
       (xpath('/row/n/text()', query_to_xml(format('select count(*) as n from %I.%I', table_schema, table_name), false, true, '')))[1]::text
  from information_schema.tables
 where table_type = 'BASE TABLE' and table_schema in ('public', 'private', 'supabase_migrations')
    or (table_schema = 'auth' and table_name in ('users', 'identities', 'mfa_factors'))
union all
select 'digest', 'public.' || c.relname,
       md5(coalesce((xpath('/row/d/text()', query_to_xml(
         format('select string_agg(md5(t::text), '''' order by md5(t::text)) as d from public.%I t', c.relname),
         false, true, '')))[1]::text, ''))
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r'
union all
select 'migrations', 'versions', string_agg(version, ',' order by version) from supabase_migrations.schema_migrations
union all
select 'rls_disabled', 'public', coalesce(string_agg(c.relname, ',' order by c.relname), '')
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
union all
select 'policies', 'public', count(*)::text from pg_policies where schemaname = 'public'
union all
select 'functions', 'public+private',
       md5(string_agg(p.proname || ':' || md5(pg_get_functiondef(p.oid)), ',' order by p.proname, p.oid))
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname in ('public', 'private') and p.prokind = 'f'
union all
select 'auth_triggers', 'auth.users', string_agg(tgname, ',' order by tgname)
  from pg_trigger where tgrelid = 'auth.users'::regclass and not tgisinternal;
`;

export function snapshot(target) {
  const snap = {};
  for (const [kind, name, value] of psql(target, SNAPSHOT_SQL)) {
    snap[`${kind}:${name}`] = value ?? "";
  }
  return snap;
}

export function diffSnapshots(expected, actual) {
  const keys = new Set([...Object.keys(expected), ...Object.keys(actual)]);
  return [...keys].sort().filter((k) => expected[k] !== actual[k])
    .map((k) => ({ key: k, expected: expected[k], actual: actual[k] }));
}

export function pgVersion(target) {
  return psql(target, "show server_version")[0][0];
}

export function dump(target) {
  const schemaArgs = SCHEMAS.flatMap((s) => ["-n", s]);
  const args = target.container
    ? ["exec", target.container, "pg_dump", "-U", "supabase_admin", "-d", "postgres", "-Fc", ...schemaArgs]
    : ["run", "--rm", "--entrypoint", "pg_dump", PG_IMAGE, "--dbname", target.url, "-Fc", ...schemaArgs];
  return run("docker", args).stdout;
}
