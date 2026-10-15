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

// ---------------------------------------------------------------------------
// Marco B — finanças
// ---------------------------------------------------------------------------
export type AccountType = "checking" | "savings" | "cash" | "credit_card";
export const accountTypeLabel: Record<AccountType, string> = {
  checking: "Conta corrente",
  savings: "Poupança / reserva",
  cash: "Dinheiro / carteira",
  credit_card: "Cartão de crédito",
};

export type AccountBalance = {
  account_id: string;
  owner_user_id: string;
  name: string;
  type: AccountType;
  active: boolean;
  balance_cents: number;
};

export type Owner = { owner_user_id: string; display_name: string; is_self: boolean };

export type Category = { id: string; name: string; kind: "expense" | "income"; owner_user_id: string | null };

export type TxnType =
  | "income" | "expense" | "card_purchase" | "card_bill_payment" | "bill_payment"
  | "transfer_out" | "transfer_in" | "refund" | "reversal" | "installment_adjustment";

export const txnTypeLabel: Record<TxnType, string> = {
  income: "Receita",
  expense: "Despesa",
  card_purchase: "Compra no cartão",
  card_bill_payment: "Pagamento de fatura",
  bill_payment: "Pagamento de conta",
  transfer_out: "Transferência enviada",
  transfer_in: "Transferência recebida",
  refund: "Estorno",
  reversal: "Reversão",
  installment_adjustment: "Ajuste de parcelas",
};

export const txnStatusLabel: Record<string, string> = { active: "Ativo", voided: "Anulado", reversed: "Revertido" };

export type Txn = {
  id: string;
  owner_user_id: string;
  type: TxnType;
  status: "active" | "voided" | "reversed";
  description: string;
  amount_cents: number;
  category_id: string | null;
  account_id: string;
  local_date: string;
  occurred_at: string | null;
  competence_month: string;
  note: string | null;
  cancel_reason: string | null;
};

export type LedgerEntry = {
  id: number;
  transaction_id: string;
  amount_cents: number;
  kind: "normal" | "void";
  posted_on: string;
  recorded_at: string;
};

// sinal de cada tipo do ponto de vista de quem vê a lista (entrada +, saída −)
export const txnDirection: Partial<Record<TxnType, 1 | -1>> = {
  income: 1, transfer_in: 1, refund: 1,
  expense: -1, card_purchase: -1, card_bill_payment: -1, bill_payment: -1, transfer_out: -1,
};

export const owners = (scope: Scope, operation: "read" | "create") =>
  rpc<Owner[]>("accessible_owners", { p_scope: scope, p_operation: operation });
