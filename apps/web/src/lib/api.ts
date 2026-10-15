// Chamadas ao backend. Erros são relançados com o código original para
// errorMessage() traduzir; nada de dados sensíveis em logs.
import { supabase } from "./supabase";

export async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data as T;
}

export async function provisionUser(body: {
  operation_id: string;
  email: string;
  display_name: string;
  household_id: string | null;
  redirect_to: string;
}): Promise<{ user_id: string; status: string }> {
  const { data, error } = await supabase.functions.invoke("provision-user", { body });
  if (error) {
    const response = (error as { context?: Response }).context;
    const payload = response ? await response.json().catch(() => null) : null;
    throw payload ?? error;
  }
  return data;
}

export const redirectTo = (path: string) => `${window.location.origin}${path}`;

export type AdminUser = {
  user_id: string;
  email: string;
  display_name: string;
  status: "pending" | "active" | "blocked";
  is_admin: boolean;
  provisioned_at: string | null;
  activation_completed_at: string | null;
  last_sign_in_at: string | null;
  has_mfa: boolean;
};

export type Household = { id: string; name: string; active: boolean };
export type Member = { household_id: string; user_id: string; status: "active" | "suspended" | "removed" };
export type Grant = {
  id: string;
  household_id: string;
  owner_user_id: string;
  grantee_user_id: string;
  resource_scope: Scope;
  can_read: boolean;
  can_create: boolean;
  can_update: boolean;
  can_cancel: boolean;
  revision: number;
};
export type Scope = "all" | "accounts" | "cards" | "transactions" | "goals" | "reports";

export const scopeLabel: Record<Scope, string> = {
  all: "Tudo",
  accounts: "Contas",
  cards: "Cartões",
  transactions: "Lançamentos",
  goals: "Metas",
  reports: "Relatórios",
};

export const statusLabel: Record<string, string> = {
  pending: "Pendente",
  active: "Ativo",
  blocked: "Bloqueado",
  suspended: "Suspenso",
  removed: "Removido",
};
