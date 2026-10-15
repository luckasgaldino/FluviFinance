// provision-user — Admin (com MFA) convida um usuário financeiro.
//
// Contrato (Especificação v1.0, §11):
//   POST { operation_id: uuid, email, display_name, household_id?: uuid, redirect_to?: url }
//   200  { user_id, household_id, status } — mesma resposta ao repetir operation_id;
//        status fica 'pending' até o convidado comprovar o e-mail e definir senha (B8)
//   400  entrada inválida | 401 sem sessão | 403 não é Admin aal2
//   409  operation_conflict | operation_in_progress | already_provisioned | identity_conflict
//
// A autorização é decidida pelo banco (whoami → private.is_admin), com o JWT do
// chamador. A chave service_role só existe aqui, no servidor.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.117.2";
import { corsHeaders, HttpError, isUuid, json } from "../_shared/http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

type Input = {
  operation_id: string;
  email: string;
  display_name: string;
  household_id: string | null;
  redirect_to?: string;
};

function parseInput(body: unknown): Input {
  if (typeof body !== "object" || body === null) {
    throw new HttpError(400, "invalid_body", "corpo JSON obrigatório");
  }
  const b = body as Record<string, unknown>;
  if (!isUuid(b.operation_id)) throw new HttpError(400, "invalid_operation_id", "operation_id deve ser UUID");
  const email = typeof b.email === "string" ? b.email.trim().toLowerCase() : "";
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
    throw new HttpError(400, "invalid_email", "e-mail inválido");
  }
  const displayName = typeof b.display_name === "string" ? b.display_name.trim() : "";
  if (displayName.length < 1 || displayName.length > 80) {
    throw new HttpError(400, "invalid_display_name", "display_name deve ter 1 a 80 caracteres");
  }
  const householdId = b.household_id ?? null;
  if (householdId !== null && !isUuid(householdId)) {
    throw new HttpError(400, "invalid_household_id", "household_id deve ser UUID");
  }
  if (b.redirect_to !== undefined && typeof b.redirect_to !== "string") {
    throw new HttpError(400, "invalid_redirect_to", "redirect_to inválido");
  }
  return {
    operation_id: b.operation_id,
    email,
    display_name: displayName,
    household_id: householdId as string | null,
    redirect_to: b.redirect_to as string | undefined,
  };
}

async function requireAdmin(authorization: string): Promise<string> {
  const caller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await caller.rpc("whoami");
  if (error || !data) throw new HttpError(401, "unauthenticated", "sessão inválida");
  if (data.can_administer !== true) {
    throw new HttpError(403, "forbidden", "requer Admin ativo com MFA");
  }
  return data.user_id as string;
}

function rpcError(error: { code?: string; message: string }): HttpError {
  if (error.code === "23505") return new HttpError(409, "operation_conflict", "operation_id já usado com outro conteúdo");
  if (error.code === "55P03") return new HttpError(409, "operation_in_progress", "operação em andamento");
  if (error.code === "PT429") return new HttpError(429, "rate_limited", "limite de requisições excedido");
  if (error.code === "42501") return new HttpError(403, "forbidden", "operação não autorizada");
  if (error.code === "23503" || error.code === "P0002") return new HttpError(400, "invalid_reference", "referência inexistente");
  return new HttpError(500, "internal", "falha ao provisionar");
}

// B13 / §19.2: só reaproveita identidade pendente criada por ESTA operação
// (vínculo gravado no perfil quando o usuário Auth nasceu). Nunca toma posse
// de identidade de terceiro.
async function findOrInvite(service: SupabaseClient, input: Input): Promise<string> {
  const { data: identity, error: identityError } = await service.rpc("service_provision_identity", {
    p_request_id: input.operation_id,
    p_email: input.email,
  });
  if (identityError) throw rpcError(identityError);
  switch (identity.state) {
    case "linked_pending":
      return identity.user_id;
    case "active":
      throw new HttpError(409, "already_provisioned", "usuário já provisionado");
    case "conflict":
      throw new HttpError(409, "identity_conflict", "identidade existente não pertence a esta operação");
  }

  const { data, error } = await service.auth.admin.inviteUserByEmail(input.email, {
    data: { display_name: input.display_name, fluvi_provision_operation_id: input.operation_id },
    redirectTo: input.redirect_to,
  });
  if (error || !data.user) {
    throw new HttpError(502, "invite_failed", "falha ao enviar convite");
  }
  return data.user.id;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, 405, { error: "method_not_allowed" });

  const requestId = crypto.randomUUID();
  try {
    const authorization = req.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) throw new HttpError(401, "unauthenticated", "sessão ausente");

    const input = parseInput(await req.json().catch(() => null));
    const actorId = await requireAdmin(authorization);

    const service = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const payload = {
      email: input.email,
      display_name: input.display_name,
      household_id: input.household_id,
    };

    // Fase 1: reserva o operation_id antes de qualquer efeito externo (e-mail).
    const { data: begin, error: beginError } = await service.rpc("service_provision_begin", {
      p_request_id: input.operation_id,
      p_actor_id: actorId,
      p_payload: payload,
    });
    if (beginError) throw rpcError(beginError);
    if (begin.state === "done") return json(req, 200, begin.result);

    const userId = await findOrInvite(service, input);

    const { data: result, error } = await service.rpc("service_provision_profile", {
      p_request_id: input.operation_id,
      p_actor_id: actorId,
      p_user_id: userId,
      p_display_name: input.display_name,
      p_household_id: input.household_id,
      p_payload: payload,
    });
    if (error) throw rpcError(error);
    return json(req, 200, result);
  } catch (e) {
    const err = e instanceof HttpError ? e : new HttpError(500, "internal", "erro interno");
    // Log sem e-mail, JWT ou corpo da requisição.
    console.error(JSON.stringify({ fn: "provision-user", request_id: requestId, status: err.status, code: err.code }));
    return json(req, err.status, { error: err.code, message: err.message, request_id: requestId });
  }
});
