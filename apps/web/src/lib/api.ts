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
export type Member = { household_id: string; user_id: string; status: "invited" | "active" | "suspended" | "removed" };

export const statusLabel: Record<string, string> = {
  pending: "Pendente",
  active: "Ativo",
  blocked: "Bloqueado",
  suspended: "Suspenso",
  removed: "Removido",
  invited: "Convite pendente",
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
  family_id: string;
  name: string;
  type: AccountType;
  active: boolean;
  balance_cents: number;
};

export type Category = { id: string; name: string; kind: "expense" | "income"; family_id: string | null };

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
  family_id: string;
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
  replaces_transaction_id?: string | null;
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

// Cartões (Marco B)
export type CardPosition = {
  card_id: string;
  family_id: string;
  name: string;
  credit_limit_cents: number;
  debt_total_cents: number;
  closed_remaining_cents: number;
  open_preview_cents: number | null;
  future_installments_cents: number;
  unapplied_credit_cents: number;
  available_limit_cents: number;
};

export type Card = {
  id: string;
  family_id: string;
  account_id: string;
  name: string;
  brand: string | null;
  last_four: string | null;
  credit_limit_cents: number;
  closing_day: number;
  due_day: number;
  closing_day_policy: "current_cycle" | "next_cycle";
  active: boolean;
};

export type CardCycle = {
  cycle_id: string;
  card_id: string;
  starts_on: string;
  closes_on: string;
  due_on: string;
  status: "open" | "closed";
  date_source: "estimated" | "confirmed";
  debits_cents: number;
  credits_cents: number;
  amount_cents: number;
  obligation_id: string | null;
  paid_cents: number;
  remaining_cents: number | null;
  is_paid: boolean;
};

export type Installment = {
  id: string;
  purchase_id: string;
  revision: number;
  sequence: number;
  amount_cents: number;
  billing_cycle_id: string;
  status: "valid" | "superseded";
};

export const cycleLabel = (c: Pick<CardCycle, "status" | "date_source" | "is_paid">) =>
  c.status === "closed" ? (c.is_paid ? "Paga" : "Fechada") : c.date_source === "confirmed" ? "Aberta (confirmada)" : "Aberta (estimada)";

export const cycleBadge = (c: Pick<CardCycle, "status" | "is_paid">) =>
  c.status === "closed" ? (c.is_paid ? "active" : "pending") : "neutral";

/** Converte campos numéricos vindos da API (bigint pode chegar como string) para number. */
export function nums<T extends Record<string, unknown>>(row: T, keys: (keyof T)[]): T {
  const out = { ...row };
  for (const k of keys) if (out[k] !== null && out[k] !== undefined) out[k] = Number(out[k]) as T[keyof T];
  return out;
}
