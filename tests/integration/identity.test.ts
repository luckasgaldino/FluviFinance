// Marco A — isolamento ponta a ponta com serviços reais da stack local:
// Supabase Auth (senha, convite por e-mail, magic link, MFA TOTP), PostgREST com
// JWTs reais e a Edge Function provision-user. Complementa os testes pgTAP.
// Especificação v1.1: §5, §19.2, §19.3, §19.7, §19.9.
import { randomUUID } from "node:crypto";
import type { SupabaseClient } from "@supabase/supabase-js";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  acceptInvite, accessToken, anonClient, enrollTotp, invokeFunction, PASSWORD,
  runId, serviceClient, sessionFromLink, signIn, sql, testEmail,
} from "./support";

const emails = {
  admin: testEmail("admin"),
  luck: testEmail("luck"),
  bia: testEmail("bia"),
  dora: testEmail("dora"),
  eva: testEmail("eva"),
  terceiro: testEmail("terceiro"),
};

let admin: SupabaseClient;
let luck: SupabaseClient;
let bia: SupabaseClient;
let householdId: string;
const ids: Record<string, string> = {};
const luckOperation = randomUUID();

const provision = async (body: Record<string, unknown>) =>
  invokeFunction("provision-user", await accessToken(admin), body);

beforeAll(async () => {
  // Fixture do primeiro Admin já ativado (o bootstrap real é testado no pgTAP).
  const { data, error } = await serviceClient().auth.admin.createUser({
    email: emails.admin,
    password: PASSWORD,
    email_confirm: true,
  });
  if (error) throw error;
  ids.admin = data.user.id;
  await sql(
    `update public.profiles
        set provisioned_at = now(), status = 'active', activation_completed_at = now()
      where user_id = $1`,
    [ids.admin],
  );
  await sql("insert into public.administrators (user_id) values ($1)", [ids.admin]);
  admin = await signIn(emails.admin);
});

afterAll(async () => {
  // Remove identidades desta execução (perfis, papéis, vínculos e grants em cascata)
  // e o núcleo criado. A auditoria permanece (append-only).
  await sql("delete from auth.users where email like $1", [`%.${runId}@fluvi.test`]);
  if (householdId) await sql("delete from public.households where id = $1", [householdId]);
});

describe("Auth (§19.7)", () => {
  it("cadastro público está desativado", async () => {
    const { error } = await anonClient().auth.signUp({ email: testEmail("intruso"), password: PASSWORD });
    expect(error?.code).toBe("signup_disabled");
  });

  it("login por e-mail e senha continua funcionando", async () => {
    const { data } = await admin.auth.getSession();
    expect(data.session?.user.email).toBe(emails.admin);
  });

  it("requisição sem sessão é recusada pela Edge Function", async () => {
    const res = await invokeFunction("provision-user", null, {});
    expect(res.status).toBe(401);
  });
});

describe("Admin sem MFA (aal1)", () => {
  it("não administra: whoami.can_administer = false", async () => {
    const { data } = await admin.rpc("whoami");
    expect(data).toMatchObject({ aal: "aal1", is_admin_identity: true, can_administer: false });
  });

  it("não lê núcleos pela API", async () => {
    const { data, error } = await admin.from("households").select("id");
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("não provisiona usuários", async () => {
    const res = await provision({ operation_id: randomUUID(), email: testEmail("x"), display_name: "X", household_id: null });
    expect(res.status).toBe(403);
  });
});

describe("Admin com MFA (aal2) provisiona por convite real", () => {
  beforeAll(async () => {
    await enrollTotp(admin);
    const { data, error } = await admin.rpc("admin_create_household", {
      p_request_id: randomUUID(), p_name: `Família ${runId}`,
    });
    if (error) throw error;
    householdId = data.household_id;
  });

  it("sessão elevada para aal2 pode administrar", async () => {
    const { data } = await admin.rpc("whoami");
    expect(data).toMatchObject({ aal: "aal2", can_administer: true, is_financial_user: false });
  });

  it("valida a entrada", async () => {
    const res = await provision({ operation_id: "nao-uuid", email: "invalido", display_name: "" });
    expect(res.status).toBe(400);
  });

  it("convida Luck: perfil fica pending (convite não ativa — B8)", async () => {
    const body = { operation_id: luckOperation, email: emails.luck, display_name: "Luck", household_id: householdId };
    const first = await provision(body);
    expect(first.status).toBe(200);
    expect(first.body.status).toBe("pending");
    ids.luck = first.body.user_id as string;

    const again = await provision(body);
    expect(again.status).toBe(200);
    expect(again.body).toEqual(first.body);
    const rows = await sql<{ n: number }>("select count(*)::int as n from auth.users where email = $1", [emails.luck]);
    expect(rows[0].n).toBe(1);
  });

  it("operation_id reutilizado com outro conteúdo é 409", async () => {
    const res = await provision({
      operation_id: luckOperation, email: testEmail("outro"), display_name: "Outro", household_id: householdId,
    });
    expect(res.status).toBe(409);
    expect(res.body.error).toBe("operation_conflict");
  });

  it("convida Bia", async () => {
    const res = await provision({ operation_id: randomUUID(), email: emails.bia, display_name: "Bia", household_id: householdId });
    expect(res.status).toBe(200);
    ids.bia = res.body.user_id as string;
  });

  it("pendente que obtém sessão por magic link continua sem acesso (§19.9)", async () => {
    const res = await provision({ operation_id: randomUUID(), email: emails.dora, display_name: "Dora", household_id: householdId });
    expect(res.status).toBe(200);

    const { data, error } = await serviceClient().auth.admin.generateLink({ type: "magiclink", email: emails.dora });
    if (error) throw error;
    const dora = await sessionFromLink(data.properties.action_link);

    expect((await dora.rpc("whoami")).data).toMatchObject({ status: "pending", is_financial_user: false });
    expect((await dora.rpc("my_families")).data).toEqual([]);
    expect((await dora.from("households").select("id")).data).toEqual([]);
    expect((await dora.from("profiles").select("display_name")).data).toEqual([{ display_name: "Dora" }]);
  });

  it("Luck e Bia aceitam o convite pelo e-mail, definem senha e ficam active", async () => {
    await acceptInvite(emails.luck);
    await acceptInvite(emails.bia);
    luck = await signIn(emails.luck);
    bia = await signIn(emails.bia);
    const { data } = await luck.rpc("whoami");
    expect(data).toMatchObject({ user_id: ids.luck, status: "active", is_financial_user: true, can_administer: false });
  });
});

describe("Retomada de provisionamento (B13)", () => {
  it("reaproveita somente a identidade pendente criada pela mesma operação", async () => {
    // Simula falha entre o convite e a conclusão: operação reservada + usuário Auth vinculado.
    const operation = randomUUID();
    const payload = { email: emails.eva, display_name: "Eva", household_id: householdId };
    const begin = await serviceClient().rpc("service_provision_begin", {
      p_request_id: operation, p_actor_id: ids.admin, p_payload: payload,
    });
    expect(begin.data).toEqual({ state: "new" });
    const invited = await serviceClient().auth.admin.inviteUserByEmail(emails.eva, {
      data: { display_name: "Eva", fluvi_provision_operation_id: operation },
    });
    if (invited.error) throw invited.error;

    const retry = await provision({ operation_id: operation, ...payload });
    expect(retry.status).toBe(200);
    expect(retry.body.user_id).toBe(invited.data.user.id);
    const rows = await sql<{ n: number }>("select count(*)::int as n from auth.users where email = $1", [emails.eva]);
    expect(rows[0].n).toBe(1);
  });

  it("identidade pendente de outra origem não é tomada: 409 identity_conflict", async () => {
    const other = await serviceClient().auth.admin.inviteUserByEmail(emails.terceiro);
    if (other.error) throw other.error;
    const res = await provision({ operation_id: randomUUID(), email: emails.terceiro, display_name: "T", household_id: householdId });
    expect(res.status).toBe(409);
    expect(res.body.error).toBe("identity_conflict");
    const prof = await sql<{ provisioned_at: string | null }>(
      "select provisioned_at from public.profiles where user_id = $1", [other.data.user.id]);
    expect(prof[0].provisioned_at).toBeNull();
  });

  it("e-mail de usuário ativo: 409 already_provisioned", async () => {
    const res = await provision({ operation_id: randomUUID(), email: emails.bia, display_name: "Bia", household_id: householdId });
    expect(res.status).toBe(409);
    expect(res.body.error).toBe("already_provisioned");
  });
});

describe("Isolamento entre Luck e Bia via PostgREST", () => {
  it("Luck não usa a Edge Function administrativa", async () => {
    const res = await invokeFunction("provision-user", await accessToken(luck), {
      operation_id: randomUUID(), email: testEmail("y"), display_name: "Y", household_id: householdId,
    });
    expect(res.status).toBe(403);
  });

  it("Luck vê apenas nomes de membros ativos do próprio núcleo e nada administrativo", async () => {
    const profiles = await luck.from("profiles").select("display_name").order("display_name");
    // Dora e Eva são membros do núcleo, mas ainda pending: não aparecem (B4)
    expect(profiles.data?.map((p) => p.display_name)).toEqual(["Bia", "Luck"]);
    expect((await luck.from("administrators").select("user_id")).data).toEqual([]);
    expect((await luck.from("admin_operations").select("request_id")).data).toEqual([]);
  });

  it("Luck não altera autorizações nem chama funções de serviço", async () => {
    const direct = await luck.from("data_grants").insert({
      household_id: householdId, owner_user_id: ids.bia, grantee_user_id: ids.luck,
      resource_scope: "all", can_read: true,
    });
    expect(direct.error?.code).toBe("42501");

    const rpc = await luck.rpc("admin_set_data_grant", {
      p_request_id: randomUUID(), p_household_id: householdId, p_owner: ids.bia, p_grantee: ids.luck,
      p_scope: "all", p_can_read: true, p_can_create: true, p_can_update: true, p_can_cancel: true,
    });
    expect(rpc.error?.code).toBe("42501");

    const service = await luck.rpc("service_provision_begin", {
      p_request_id: randomUUID(), p_actor_id: ids.admin, p_payload: {},
    });
    expect(service.error).not.toBeNull();
  });

  it("v2.2: Luck e Bia, membros ativos do mesmo núcleo, compartilham a mesma família", async () => {
    const families = async (c: SupabaseClient) =>
      ((await c.rpc("my_families")).data as { family_id: string }[] | null)?.map((f) => f.family_id);
    expect(await families(luck)).toEqual([householdId]);
    expect(await families(bia)).toEqual([householdId]);
  });

  it("v2.2: não há permissão individual; suspender o vínculo corta a família com o MESMO token", async () => {
    const tokenBefore = await accessToken(luck);
    const grant = await admin.rpc("admin_set_data_grant", {
      p_request_id: randomUUID(), p_household_id: householdId, p_owner: ids.bia, p_grantee: ids.luck,
      p_scope: "transactions", p_can_read: true, p_can_create: false, p_can_update: false, p_can_cancel: false,
      p_expected_revision: 0,
    });
    expect(grant.error?.code).toBe("42501");

    const suspendRequest = randomUUID();
    const suspend = await admin.rpc("admin_set_household_member", {
      p_request_id: suspendRequest, p_household_id: householdId, p_user_id: ids.luck, p_status: "suspended",
    });
    expect(suspend.error).toBeNull();
    expect(await accessToken(luck)).toBe(tokenBefore);
    expect((await luck.rpc("my_families")).data).toEqual([]);
    expect((await bia.rpc("my_families")).data).toHaveLength(1);

    const back = await admin.rpc("admin_set_household_member", {
      p_request_id: randomUUID(), p_household_id: householdId, p_user_id: ids.luck, p_status: "active",
    });
    expect(back.error).toBeNull();
    expect((await luck.rpc("my_families")).data).toHaveLength(1);

    const audit = await admin.from("audit_events").select("actor_id, action").eq("request_id", suspendRequest);
    expect(audit.data).toEqual([{ actor_id: ids.admin, action: "update" }]);
  });

  it("metadata editado pelo próprio usuário não concede papel de Admin", async () => {
    const upd = await luck.auth.updateUser({ data: { role: "admin", is_admin: true, status: "active" } });
    expect(upd.error).toBeNull();
    await luck.auth.refreshSession();
    const { data } = await luck.rpc("whoami");
    expect(data).toMatchObject({ is_admin_identity: false, can_administer: false });
    const attempt = await luck.rpc("admin_create_household", { p_request_id: randomUUID(), p_name: "Hack" });
    expect(attempt.error?.code).toBe("42501");
  });

  it("membro bloqueado: a família continua para os demais e o bloqueado perde tudo, com sessões abertas (B1, B9)", async () => {
    const block = await admin.rpc("admin_set_user_status", {
      p_request_id: randomUUID(), p_user_id: ids.bia, p_status: "blocked",
    });
    expect(block.error).toBeNull();

    expect((await luck.rpc("my_families")).data).toHaveLength(1);
    expect((await bia.rpc("whoami")).data).toMatchObject({ status: "blocked", is_financial_user: false });
    expect((await bia.rpc("my_families")).data).toEqual([]);
  });

  it("Admin não pertence a nenhuma família financeira", async () => {
    const { data } = await admin.rpc("my_families");
    expect(data).toEqual([]);
  });
});
