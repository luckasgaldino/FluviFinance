// Bootstrap do primeiro Admin sob concorrência real (§19.6 item 3, §19.9):
// duas conexões disputam private.bootstrap_first_admin para alvos diferentes.
// Precisa de banco sem Admin gravado; senão o teste é pulado, nunca dado como aprovado.
import { randomUUID } from "node:crypto";
import pg from "pg";
import { afterAll, expect, it } from "vitest";
import { env, runId, sql } from "./support";

const emails = [`conc1.${runId}@fluvi.test`, `conc2.${runId}@fluvi.test`];

afterAll(async () => {
  await sql("delete from auth.users where email = any($1)", [emails]);
});

it("concorrência não cria dois Admins: a segunda execução espera a trava e é negada", async (ctx) => {
  const [{ n }] = await sql<{ n: number }>("select count(*)::int as n from public.administrators");
  if (n > 0) ctx.skip("banco local já tem Admin gravado; rode após `pnpm db:reset`");

  const [id1, id2] = [randomUUID(), randomUUID()];
  await sql(
    `insert into auth.users (id, instance_id, aud, role, email) values
       ($1, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', $3),
       ($2, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', $4)`,
    [id1, id2, ...emails],
  );

  const a = new pg.Client({ connectionString: env.dbUrl });
  const b = new pg.Client({ connectionString: env.dbUrl });
  await a.connect();
  await b.connect();
  try {
    // A executa e mantém a transação aberta, segurando a trava
    await a.query("begin");
    await a.query("select private.bootstrap_first_admin($1)", [emails[0]]);

    // B dispara em paralelo, para outro alvo
    const raceB = b.query("select private.bootstrap_first_admin($1)", [emails[1]]).then(
      () => null,
      (e: Error) => e,
    );
    await new Promise((r) => setTimeout(r, 500));
    const [{ waiting }] = await sql<{ waiting: number }>(
      "select count(*)::int as waiting from pg_locks where locktype = 'advisory' and not granted",
    );
    expect(waiting).toBe(1);

    await a.query("commit");
    const errorB = await raceB;
    expect(errorB?.message).toMatch(/já existe Admin/);

    const admins = await sql<{ user_id: string }>("select user_id from public.administrators");
    expect(admins.map((r) => r.user_id)).toEqual([id1]);
  } finally {
    await a.end();
    await b.end();
  }
});
