// Contas e saldos (FF-03): saldos da família ativa, nova conta com abertura e extrato.
import { businessToday, formatBRL, formatDate, parseBRL } from "@fluvi/domain";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Link, useParams } from "react-router";
import { Alert, Field, PageTitle } from "../../components/ui";
import {
  accountTypeLabel, rpc, txnTypeLabel,
  type AccountBalance, type AccountType, type LedgerEntry, type Txn,
} from "../../lib/api";
import { errorMessage } from "../../lib/errors";
import { useFamilyId } from "../../lib/family";
import { supabase } from "../../lib/supabase";

export function useAccounts() {
  const family = useFamilyId();
  return useQuery({
    queryKey: ["fin", "accounts", family],
    enabled: !!family,
    queryFn: async () => {
      const { data, error } = await supabase.from("v_account_balances")
        .select("account_id, family_id, name, type, active, balance_cents")
        .eq("family_id", family).neq("type", "credit_card").order("name");
      if (error) throw error;
      return (data as AccountBalance[]).map((a) => ({ ...a, balance_cents: Number(a.balance_cents) }));
    },
  });
}

export function Money({ cents, signed = false }: { cents: number; signed?: boolean }) {
  // sinal sempre em texto (nunca só pela cor)
  const text = signed && cents > 0 ? `+${formatBRL(cents)}` : formatBRL(cents);
  return <span className={`money ${cents < 0 ? "negative" : ""}`}>{text}</span>;
}

function NewAccountForm({ onDone }: { onDone: () => void }) {
  const queryClient = useQueryClient();
  const family = useFamilyId();
  const [op] = useState(() => crypto.randomUUID());
  const [error, setError] = useState("");
  const create = useMutation({
    mutationFn: (args: Record<string, unknown>) => rpc("create_account", args),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["fin"] });
      onDone();
    },
    onError: (e) => setError(errorMessage(e)),
  });

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    const opening = parseBRL(String(form.get("opening") || "0"));
    if (opening === null) return setError("Saldo inicial inválido. Use o formato 1.234,56.");
    setError("");
    create.mutate({
      p_op: op,
      p_family: family,
      p_name: String(form.get("name")).trim(),
      p_type: String(form.get("type")) as AccountType,
      p_opening_date: String(form.get("opening_date")),
      p_opening_balance_cents: opening,
    });
  }

  return (
    <section className="card stack" aria-labelledby="nova-conta">
      <h2 id="nova-conta">Nova conta</h2>
      <form className="stack" onSubmit={onSubmit} noValidate>
        <div className="row">
          <Field label="Nome da conta" name="name" required maxLength={60} />
          <div className="field">
            <label htmlFor="acc-type">Tipo</label>
            <select id="acc-type" name="type" defaultValue="checking">
              {(["checking", "savings", "cash"] as AccountType[]).map((t) => <option key={t} value={t}>{accountTypeLabel[t]}</option>)}
            </select>
          </div>
        </div>
        <div className="row">
          <Field label="Saldo inicial (R$)" name="opening" inputMode="decimal" defaultValue="0,00"
            hint="Saldo no fim do dia de abertura. Não conta como receita." />
          <Field label="Data de abertura" name="opening_date" type="date" defaultValue={businessToday()} required />
        </div>
        <Alert kind="error">{error}</Alert>
        <div className="row" style={{ alignItems: "center" }}>
          <button className="btn" type="submit" disabled={create.isPending}>Criar conta</button>
          <button className="btn secondary" type="button" onClick={onDone}>Cancelar</button>
        </div>
      </form>
    </section>
  );
}

export function Accounts() {
  const accounts = useAccounts();
  const [creating, setCreating] = useState(false);

  return (
    <>
      <PageTitle>Contas</PageTitle>
      {!creating && <div><button className="btn" type="button" onClick={() => setCreating(true)}>Nova conta</button></div>}
      {creating && <NewAccountForm onDone={() => setCreating(false)} />}
      <section className="card stack" aria-labelledby="saldos">
        <h2 id="saldos">Saldos de hoje</h2>
        {accounts.isError && <Alert kind="error">{errorMessage(accounts.error)}</Alert>}
        {accounts.isLoading ? <p role="status">Carregando…</p> : accounts.data?.length === 0 ? (
          <p className="empty">Nenhuma conta cadastrada. Crie a primeira para começar a lançar.</p>
        ) : (
          <ul className="list" aria-label="Contas">
            {accounts.data?.map((a) => (
              <li key={a.account_id} className="list-item" aria-label={a.name}>
                <div className="meta">
                  <Link to={`/contas/${a.account_id}`}><strong>{a.name}</strong></Link>
                  <span className="muted">{accountTypeLabel[a.type]}</span>
                </div>
                <Money cents={a.balance_cents} />
              </li>
            ))}
          </ul>
        )}
      </section>
    </>
  );
}


export function AccountDetail() {
  const { id } = useParams();
  const family = useFamilyId();
  // só a família ativa: uma conta de outra família do mesmo usuário não aparece aqui
  const account = useQuery({
    queryKey: ["fin", "account", family, id],
    enabled: !!family,
    queryFn: async () => {
      const { data, error } = await supabase.from("v_account_balances")
        .select("account_id, family_id, name, type, active, balance_cents")
        .eq("account_id", id!).eq("family_id", family).maybeSingle();
      if (error) throw error;
      return data as AccountBalance | null;
    },
  });
  const entries = useQuery({
    queryKey: ["fin", "ledger", id],
    enabled: !!account.data,
    queryFn: async () => {
      const { data, error } = await supabase.from("ledger_entries")
        .select("id, transaction_id, amount_cents, kind, posted_on, recorded_at")
        .eq("account_id", id!).order("posted_on", { ascending: false }).order("id", { ascending: false }).limit(200);
      if (error) throw error;
      const rows = (data as LedgerEntry[]).map((e) => ({ ...e, amount_cents: Number(e.amount_cents) }));
      // descrições só aparecem para quem também pode ler lançamentos (escopo transactions)
      const ids = [...new Set(rows.map((r) => r.transaction_id))];
      const { data: txns } = ids.length
        ? await supabase.from("transactions").select("id, description, type, status").in("id", ids)
        : { data: [] };
      const byId = new Map((txns as Pick<Txn, "id" | "description" | "type" | "status">[] ?? []).map((t) => [t.id, t]));
      return rows.map((r) => ({ ...r, txn: byId.get(r.transaction_id) }));
    },
  });

  if (account.isLoading) return <p role="status">Carregando…</p>;
  if (!account.data) {
    return (
      <>
        <PageTitle>Conta</PageTitle>
        <Alert kind="error">Conta não encontrada ou sem permissão.</Alert>
        <Link to="/contas">Voltar para contas</Link>
      </>
    );
  }
  const a = account.data;
  return (
    <>
      <PageTitle>{a.name}</PageTitle>
      <section className="card stack" aria-labelledby="saldo-atual">
        <h2 id="saldo-atual">Saldo de hoje</h2>
        <p className="big"><Money cents={Number(a.balance_cents)} /></p>
        <span className="muted">{accountTypeLabel[a.type]}</span>
      </section>
      <section className="card stack" aria-labelledby="extrato">
        <h2 id="extrato">Extrato (data financeira)</h2>
        {entries.data?.length === 0 && <p className="empty">Nenhum movimento após a abertura.</p>}
        <ul className="list" aria-label="Movimentos">
          {entries.data?.map((e) => (
            <li key={e.id} className="list-item">
              <div className="meta">
                <strong>{e.txn?.description ?? "Movimento"}</strong>
                <span className="muted">
                  {formatDate(e.posted_on)}
                  {e.txn && ` · ${txnTypeLabel[e.txn.type]}`}
                  {e.kind === "void" && " · compensação de anulação"}
                </span>
              </div>
              <Money cents={e.amount_cents} signed />
            </li>
          ))}
        </ul>
      </section>
      <Link to="/contas">Voltar para contas</Link>
    </>
  );
}
