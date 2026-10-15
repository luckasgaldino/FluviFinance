// Marco B — Lançamentos (FIN-04): lista por mês, novo lançamento (receita/despesa),
// anulação (erro de registro) e reversão (movimento real contrário).
import { addMonths, businessToday, formatDate, monthLabel, monthRange, monthStart, parseBRL } from "@fluvi/domain";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState, type FormEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router";
import { Alert, Field, PageTitle, StatusBadge } from "../../components/ui";
import { owners, rpc, txnDirection, txnStatusLabel, txnTypeLabel, type Category, type Txn } from "../../lib/api";
import { errorMessage } from "../../lib/errors";
import { useSession } from "../../lib/session";
import { supabase } from "../../lib/supabase";
import { Money, useAccounts, useOwnerNames } from "./Accounts";

function useCategories() {
  return useQuery({
    queryKey: ["fin", "categories"],
    staleTime: 5 * 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.from("categories").select("id, name, kind, owner_user_id").eq("active", true).order("name");
      if (error) throw error;
      return data as Category[];
    },
  });
}

const nowTime = () =>
  new Date().toLocaleTimeString("pt-BR", { timeZone: "America/Sao_Paulo", hour: "2-digit", minute: "2-digit" });

// ---------------------------------------------------------------------------
// Ações: anular × reverter
// ---------------------------------------------------------------------------
type Action = { kind: "void" | "reverse"; txn: Txn };

function ActionPanel({ action, onClose }: { action: Action; onClose: (msg?: string) => void }) {
  const queryClient = useQueryClient();
  const [op] = useState(() => crypto.randomUUID());
  const [error, setError] = useState("");
  const isVoid = action.kind === "void";
  const run = useMutation({
    mutationFn: (args: Record<string, unknown>) => rpc(isVoid ? "void_transaction" : "reverse_transaction", args),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["fin"] });
      onClose(isVoid ? "Lançamento anulado." : "Reversão registrada.");
    },
    onError: (e) => setError(errorMessage(e)),
  });

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    const reason = String(form.get("reason")).trim();
    if (reason.length < 3) return setError("Informe o motivo (mínimo de 3 caracteres).");
    run.mutate(isVoid
      ? { p_op: op, p_transaction: action.txn.id, p_reason: reason }
      : { p_op: op, p_transaction: action.txn.id, p_reason: reason, p_reversed_on: String(form.get("date")) });
  }

  return (
    <form className="card stack" onSubmit={onSubmit} aria-label={isVoid ? "Anular lançamento" : "Reverter lançamento"} noValidate>
      <h2>{isVoid ? "Anular lançamento" : "Reverter lançamento"}</h2>
      <p className="muted">
        {isVoid
          ? "Use quando o lançamento foi registrado por engano. A correção vale desde a data original; o histórico é preservado."
          : "Use quando houve um movimento real contrário (dinheiro devolvido). A reversão entra na data em que aconteceu."}
      </p>
      <p><strong>{action.txn.description}</strong> · <Money cents={action.txn.amount_cents} /> · {formatDate(action.txn.local_date)}</p>
      <Field label="Motivo" name="reason" required maxLength={200} />
      {!isVoid && <Field label="Data da reversão" name="date" type="date" defaultValue={businessToday()} required />}
      <Alert kind="error">{error}</Alert>
      <div className="row" style={{ alignItems: "center" }}>
        <button className={`btn ${isVoid ? "danger" : ""}`} type="submit" disabled={run.isPending}>
          {isVoid ? "Confirmar anulação" : "Confirmar reversão"}
        </button>
        <button className="btn secondary" type="button" onClick={() => onClose()}>Cancelar</button>
      </div>
    </form>
  );
}

// ---------------------------------------------------------------------------
// Lista
// ---------------------------------------------------------------------------
export function Transactions() {
  const { session, me } = useSession();
  const [params, setParams] = useSearchParams();
  const month = monthStart(params.get("mes") ?? businessToday());
  const basis = params.get("base") === "caixa" ? "caixa" : "competencia";
  const [action, setAction] = useState<Action | null>(null);
  const [feedback, setFeedback] = useState(params.get("ok") ?? "");
  const categories = useCategories();
  const accounts = useAccounts();
  const names = useOwnerNames();

  const txns = useQuery({
    queryKey: ["fin", "txns", session?.user.id, month, basis],
    queryFn: async () => {
      const range = monthRange(month);
      let q = supabase.from("transactions")
        .select("id, owner_user_id, type, status, description, amount_cents, category_id, account_id, local_date, occurred_at, competence_month, note, cancel_reason");
      q = basis === "caixa" ? q.gte("local_date", range.from).lte("local_date", range.to) : q.eq("competence_month", month);
      const { data, error } = await q.order("local_date", { ascending: false }).order("created_at", { ascending: false });
      if (error) throw error;
      return (data as Txn[]).map((t) => ({ ...t, amount_cents: Number(t.amount_cents) }));
    },
  });

  const catName = useMemo(() => new Map(categories.data?.map((c) => [c.id, c.name])), [categories.data]);
  const accName = useMemo(() => new Map(accounts.data?.map((a) => [a.account_id, a.name])), [accounts.data]);
  const go = (delta: number) => setParams({ mes: addMonths(month, delta), base: basis });

  return (
    <>
      <PageTitle>Lançamentos</PageTitle>
      <div className="row" style={{ alignItems: "center" }}>
        <Link className="btn" to="/lancamentos/novo">Novo lançamento</Link>
      </div>
      {feedback && <Alert kind="success">{feedback}</Alert>}
      {action && <ActionPanel action={action} onClose={(msg) => { setAction(null); if (msg) setFeedback(msg); }} />}

      <section className="card stack" aria-labelledby="periodo">
        <h2 id="periodo" className="visually-hidden">Período</h2>
        <div className="row" style={{ alignItems: "center" }}>
          <button className="btn secondary" type="button" onClick={() => go(-1)} aria-label="Mês anterior">‹</button>
          <strong style={{ textAlign: "center", textTransform: "capitalize" }} aria-live="polite">{monthLabel(month)}</strong>
          <button className="btn secondary" type="button" onClick={() => go(1)} aria-label="Próximo mês">›</button>
        </div>
        <fieldset style={{ border: 0, padding: 0, margin: 0 }}>
          <legend className="muted">Agrupar por</legend>
          <div className="row" style={{ alignItems: "center" }}>
            <label className="check"><input type="radio" name="base" checked={basis === "competencia"}
              onChange={() => setParams({ mes: month, base: "competencia" })} /> Competência (consumo)</label>
            <label className="check"><input type="radio" name="base" checked={basis === "caixa"}
              onChange={() => setParams({ mes: month, base: "caixa" })} /> Data do lançamento</label>
          </div>
        </fieldset>
      </section>

      <section className="card stack" aria-labelledby="lista-lanc">
        <h2 id="lista-lanc">Lançamentos do mês</h2>
        {txns.isError && <Alert kind="error">{errorMessage(txns.error)}</Alert>}
        {txns.isLoading ? <p role="status">Carregando…</p> : txns.data?.length === 0 ? (
          <p className="empty">Nenhum lançamento neste mês.</p>
        ) : (
          <ul className="list" aria-label="Lançamentos">
            {txns.data?.map((t) => {
              const dir = txnDirection[t.type] ?? 1;
              const canAct = t.status === "active" && ["income", "expense", "transfer_out", "transfer_in", "refund",
                "bill_payment", "card_bill_payment", "card_purchase"].includes(t.type);
              return (
                <li key={t.id} className={`list-item ${t.status !== "active" ? "inactive" : ""}`} aria-label={t.description}>
                  <div className="meta">
                    <strong>{t.description}</strong>
                    <span className="muted">
                      {formatDate(t.local_date)} · {txnTypeLabel[t.type]}
                      {t.category_id && ` · ${catName.get(t.category_id) ?? ""}`}
                      {accName.get(t.account_id) && ` · ${accName.get(t.account_id)}`}
                      {t.owner_user_id !== me?.user_id && ` · de ${names.data?.get(t.owner_user_id) ?? "outro titular"}`}
                    </span>
                    {t.cancel_reason && <span className="muted">Motivo: {t.cancel_reason}</span>}
                  </div>
                  <div className="actions">
                    <Money cents={dir * t.amount_cents} signed />
                    {t.status !== "active" && <StatusBadge status="blocked" label={txnStatusLabel[t.status]} />}
                    {canAct && (
                      <>
                        <button className="btn secondary" type="button" onClick={() => { setFeedback(""); setAction({ kind: "void", txn: t }); }}>
                          Anular
                        </button>
                        {t.type !== "card_purchase" && (
                          <button className="btn secondary" type="button" onClick={() => { setFeedback(""); setAction({ kind: "reverse", txn: t }); }}>
                            Reverter
                          </button>
                        )}
                      </>
                    )}
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </>
  );
}

// ---------------------------------------------------------------------------
// Novo lançamento (receita/despesa) — campos agrupados (§3.3)
// ---------------------------------------------------------------------------
export function NewTransaction() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const { me } = useSession();
  const [op] = useState(() => crypto.randomUUID());  // idempotência: repetir o envio não duplica
  const [type, setType] = useState<"expense" | "income">("expense");
  const [owner, setOwner] = useState<string>("");
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const creatable = useQuery({ queryKey: ["fin", "owners", "transactions", "create"], queryFn: () => owners("transactions", "create") });
  const categories = useCategories();
  const accounts = useAccounts();
  const titular = owner || me?.user_id || "";
  const ownAccounts = accounts.data?.filter((a) => a.owner_user_id === titular && a.active) ?? [];
  const cats = categories.data?.filter((c) => c.kind === type && (c.owner_user_id === null || c.owner_user_id === titular)) ?? [];

  const create = useMutation({
    mutationFn: (args: Record<string, unknown>) => rpc("create_transaction", args),
    onSuccess: (_d, args) => {
      void queryClient.invalidateQueries({ queryKey: ["fin"] });
      navigate(`/lancamentos?mes=${String(args.p_competence_month)}&ok=${encodeURIComponent("Lançamento salvo.")}`);
    },
    onError: (e) => setError(errorMessage(e)),
  });

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = new FormData(e.currentTarget);
    const amount = parseBRL(String(form.get("amount")));
    const next: Record<string, string> = {};
    if (amount === null || amount <= 0) next.amount = "Informe um valor maior que zero, no formato 1.234,56.";
    if (!String(form.get("description")).trim()) next.description = "Informe uma descrição.";
    if (!form.get("category")) next.category = "Escolha uma categoria.";
    if (!form.get("account")) next.account = "Escolha a conta.";
    setErrors(next);
    setError("");
    if (Object.keys(next).length) return;
    const date = String(form.get("date"));
    create.mutate({
      p_op: op, p_owner: titular, p_type: type, p_account: String(form.get("account")),
      p_amount_cents: amount, p_description: String(form.get("description")).trim(),
      p_category: String(form.get("category")), p_local_date: date,
      p_competence_month: `${String(form.get("competence") || date.slice(0, 7))}-01`,
      p_note: String(form.get("note") || "").trim() || null,
      p_local_time: String(form.get("time") || "") || null,
    });
  }

  return (
    <>
      <PageTitle>Novo lançamento</PageTitle>
      <form className="stack" onSubmit={onSubmit} noValidate>
        <section className="card stack" aria-labelledby="principal">
          <h2 id="principal">Principal</h2>
          <fieldset style={{ border: 0, padding: 0, margin: 0 }}>
            <legend className="field" style={{ fontWeight: 600 }}>Tipo</legend>
            <div className="row" style={{ alignItems: "center" }}>
              <label className="check"><input type="radio" name="type" checked={type === "expense"} onChange={() => setType("expense")} /> Despesa</label>
              <label className="check"><input type="radio" name="type" checked={type === "income"} onChange={() => setType("income")} /> Receita</label>
            </div>
          </fieldset>
          <div className="row">
            <Field label="Valor (R$)" name="amount" inputMode="decimal" autoComplete="off" required error={errors.amount}
              placeholder="0,00" />
            <Field label="Descrição" name="description" required maxLength={140} error={errors.description} />
          </div>
          <div className="row">
            <div className="field">
              <label htmlFor="txn-category">Categoria</label>
              <select id="txn-category" name="category" defaultValue="" aria-invalid={errors.category ? true : undefined}
                aria-describedby={errors.category ? "txn-category-err" : undefined}>
                <option value="" disabled>Escolha…</option>
                {cats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
              {errors.category && <span id="txn-category-err" className="hint error-text">{errors.category}</span>}
            </div>
            <div className="field">
              <label htmlFor="txn-account">Conta</label>
              <select id="txn-account" name="account" defaultValue="" aria-invalid={errors.account ? true : undefined}
                aria-describedby={errors.account ? "txn-account-err" : undefined}>
                <option value="" disabled>{ownAccounts.length ? "Escolha…" : "Nenhuma conta disponível"}</option>
                {ownAccounts.map((a) => <option key={a.account_id} value={a.account_id}>{a.name}</option>)}
              </select>
              {errors.account && <span id="txn-account-err" className="hint error-text">{errors.account}</span>}
            </div>
          </div>
          {ownAccounts.length === 0 && accounts.isSuccess && (
            <Alert kind="info">Nenhuma conta deste titular disponível para você. <Link to="/contas">Cadastre uma conta</Link>.</Alert>
          )}
        </section>

        <section className="card stack" aria-labelledby="detalhes">
          <h2 id="detalhes">Detalhes</h2>
          <div className="row">
            <Field label="Data" name="date" type="date" defaultValue={businessToday()} required />
            <Field label="Hora" name="time" type="time" defaultValue={nowTime()} />
            <Field label="Competência (mês de consumo)" name="competence" type="month" defaultValue={businessToday().slice(0, 7)}
              hint="Por padrão, o mês da data." />
          </div>
          {(creatable.data?.length ?? 0) > 1 && (
            <div className="field">
              <label htmlFor="txn-owner">Titular</label>
              <select id="txn-owner" value={titular} onChange={(e) => setOwner(e.target.value)}>
                {creatable.data?.map((o) => <option key={o.owner_user_id} value={o.owner_user_id}>{o.display_name}</option>)}
              </select>
            </div>
          )}
        </section>

        <section className="card stack" aria-labelledby="adicionais">
          <h2 id="adicionais">Adicionais</h2>
          <Field label="Observação" name="note" maxLength={500} />
          <p className="muted">Localização e anexo chegam na versão mobile (Marco C).</p>
        </section>

        <Alert kind="error">{error}</Alert>
        <div className="row" style={{ alignItems: "center" }}>
          <button className="btn" type="submit" disabled={create.isPending}>Salvar lançamento</button>
          <Link to="/lancamentos">Cancelar</Link>
        </div>
      </form>
    </>
  );
}
