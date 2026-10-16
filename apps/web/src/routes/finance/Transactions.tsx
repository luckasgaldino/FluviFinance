// Lançamentos (FF-02/FF-10): lista por mês, novo lançamento (receita/despesa),
// anulação (erro de registro) e reversão (movimento real contrário).
import { addMonths, businessToday, formatDate, monthLabel, monthRange, monthStart, parseBRL } from "@fluvi/domain";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState, type FormEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router";
import { Alert, Field, MonthNav, PageTitle, StatusBadge } from "../../components/ui";
import { rpc, txnDirection, txnStatusLabel, txnTypeLabel, type Category, type Txn } from "../../lib/api";
import { errorMessage } from "../../lib/errors";
import { useFamilyId } from "../../lib/family";
import { supabase } from "../../lib/supabase";
import { Money, useAccounts } from "./Accounts";

function useCategories() {
  return useQuery({
    queryKey: ["fin", "categories"],
    staleTime: 5 * 60_000,
    queryFn: async () => {
      const { data, error } = await supabase.from("categories").select("id, name, kind, family_id").eq("active", true).order("name");
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
// Edição (FF-02): anula o original e registra o novo numa única operação (histórico preservado)
// ---------------------------------------------------------------------------
const EDITED = "substituído por edição";

function EditPanel({ txn, onClose }: { txn: Txn; onClose: (msg?: string) => void }) {
  const queryClient = useQueryClient();
  const categories = useCategories();
  const accounts = useAccounts();
  const family = useFamilyId();
  const [op] = useState(() => crypto.randomUUID());
  const [error, setError] = useState("");
  const kind = txn.type === "income" ? "income" : "expense";
  const cats = categories.data?.filter((c) => c.kind === kind && (c.family_id === null || c.family_id === family)) ?? [];
  const edit = useMutation({
    mutationFn: (args: Record<string, unknown>) => rpc("edit_transaction", args),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["fin"] });
      onClose("Lançamento editado. O original fica no histórico como editado.");
    },
    onError: (e) => setError(errorMessage(e)),
  });

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const amount = parseBRL(String(f.get("amount")));
    if (amount === null || amount <= 0) return setError("Informe um valor maior que zero, no formato 1.234,56.");
    if (!String(f.get("description")).trim()) return setError("Informe uma descrição.");
    setError("");
    const date = String(f.get("date"));
    edit.mutate({
      p_op: op, p_transaction: txn.id, p_amount_cents: amount, p_description: String(f.get("description")).trim(),
      p_category: String(f.get("category")), p_account: String(f.get("account")), p_local_date: date,
      p_competence_month: `${date.slice(0, 7)}-01`, p_note: txn.note,
    });
  }

  return (
    <form className="card stack" onSubmit={onSubmit} aria-label="Editar lançamento" noValidate>
      <h2>Editar lançamento</h2>
      <p className="muted">O lançamento original continua no histórico como editado; o saldo passa a considerar só a nova versão.</p>
      <div className="row">
        <Field label="Valor (R$)" name="amount" inputMode="decimal" autoComplete="off"
          defaultValue={(txn.amount_cents / 100).toFixed(2).replace(".", ",")} />
        <Field label="Descrição" name="description" maxLength={140} defaultValue={txn.description} />
      </div>
      <div className="row">
        <div className="field">
          <label htmlFor="edit-category">Categoria</label>
          <select id="edit-category" name="category" defaultValue={txn.category_id ?? ""}>
            {cats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </div>
        <div className="field">
          <label htmlFor="edit-account">Conta</label>
          <select id="edit-account" name="account" defaultValue={txn.account_id}>
            {accounts.data?.map((a) => <option key={a.account_id} value={a.account_id}>{a.name}</option>)}
          </select>
        </div>
        <Field label="Data" name="date" type="date" defaultValue={txn.local_date} />
      </div>
      <Alert kind="error">{error}</Alert>
      <div className="row" style={{ alignItems: "center" }}>
        <button className="btn" type="submit" disabled={edit.isPending}>Salvar edição</button>
        <button className="btn secondary" type="button" onClick={() => onClose()}>Cancelar</button>
      </div>
    </form>
  );
}

// ---------------------------------------------------------------------------
// Lista / extrato com filtros (FF-10)
// ---------------------------------------------------------------------------
type KindFilter = "todos" | "receitas" | "despesas" | "cartao" | "transferencias";
const kindMatch: Record<KindFilter, (t: Txn) => boolean> = {
  todos: () => true,
  receitas: (t) => t.type === "income",
  despesas: (t) => t.type === "expense" || t.type === "bill_payment",
  cartao: (t) => t.type === "card_purchase" || t.type === "card_bill_payment",
  transferencias: (t) => t.type === "transfer_in" || t.type === "transfer_out",
};

export function Transactions() {
  const family = useFamilyId();
  const [params, setParams] = useSearchParams();
  const month = monthStart(params.get("mes") ?? businessToday());
  const basis = params.get("base") === "caixa" ? "caixa" : "competencia";
  const [action, setAction] = useState<Action | null>(null);
  const [editing, setEditing] = useState<Txn | null>(null);
  const [feedback, setFeedback] = useState(params.get("ok") ?? "");
  const [accountFilter, setAccountFilter] = useState("");
  const [categoryFilter, setCategoryFilter] = useState("");
  const [kindFilter, setKindFilter] = useState<KindFilter>("todos");
  const categories = useCategories();
  const accounts = useAccounts();

  const txns = useQuery({
    queryKey: ["fin", "txns", family, month, basis],
    enabled: !!family,
    queryFn: async () => {
      const range = monthRange(month);
      let q = supabase.from("transactions")
        .select("id, family_id, type, status, description, amount_cents, category_id, account_id, local_date, occurred_at, competence_month, note, cancel_reason, replaces_transaction_id")
        .eq("family_id", family);
      q = basis === "caixa" ? q.gte("local_date", range.from).lte("local_date", range.to) : q.eq("competence_month", month);
      const { data, error } = await q.order("local_date", { ascending: false }).order("created_at", { ascending: false });
      if (error) throw error;
      return (data as Txn[]).map((t) => ({ ...t, amount_cents: Number(t.amount_cents) }));
    },
  });

  const catName = useMemo(() => new Map(categories.data?.map((c) => [c.id, c.name])), [categories.data]);
  const accName = useMemo(() => new Map(accounts.data?.map((a) => [a.account_id, a.name])), [accounts.data]);
  const go = (delta: number) => setParams({ mes: addMonths(month, delta), base: basis });
  const shown = (txns.data ?? []).filter((t) => kindMatch[kindFilter](t)
    && (!accountFilter || t.account_id === accountFilter) && (!categoryFilter || t.category_id === categoryFilter));
  const usedCategories = [...new Set((txns.data ?? []).map((t) => t.category_id).filter(Boolean))] as string[];
  const clear = () => { setFeedback(""); setAction(null); setEditing(null); };

  return (
    <>
      <PageTitle>Lançamentos</PageTitle>
      <div className="toolbar">
        <Link className="btn" to="/lancamentos/novo">Novo lançamento</Link>
        <Link className="btn secondary" to="/cartoes/compra">Compra no cartão</Link>
      </div>
      {feedback && <Alert kind="success">{feedback}</Alert>}
      {action && <ActionPanel action={action} onClose={(msg) => { setAction(null); if (msg) setFeedback(msg); }} />}
      {editing && <EditPanel txn={editing} onClose={(msg) => { setEditing(null); if (msg) setFeedback(msg); }} />}

      <section className="card stack" aria-labelledby="periodo">
        <h2 id="periodo" className="visually-hidden">Período e filtros</h2>
        <MonthNav label={monthLabel(month).charAt(0).toUpperCase() + monthLabel(month).slice(1)} onPrev={() => go(-1)} onNext={() => go(1)} />
        <fieldset style={{ border: 0, padding: 0, margin: 0 }}>
          <legend className="muted">Agrupar por</legend>
          <div className="row" style={{ alignItems: "center" }}>
            <label className="check"><input type="radio" name="base" checked={basis === "competencia"}
              onChange={() => setParams({ mes: month, base: "competencia" })} /> Competência (consumo)</label>
            <label className="check"><input type="radio" name="base" checked={basis === "caixa"}
              onChange={() => setParams({ mes: month, base: "caixa" })} /> Data do lançamento</label>
          </div>
        </fieldset>
        <div className="row">
          <div className="field">
            <label htmlFor="f-kind">Tipo</label>
            <select id="f-kind" value={kindFilter} onChange={(e) => setKindFilter(e.target.value as KindFilter)}>
              <option value="todos">Todos</option>
              <option value="receitas">Receitas</option>
              <option value="despesas">Despesas</option>
              <option value="cartao">Cartão</option>
              <option value="transferencias">Transferências</option>
            </select>
          </div>
          <div className="field">
            <label htmlFor="f-account">Conta</label>
            <select id="f-account" value={accountFilter} onChange={(e) => setAccountFilter(e.target.value)}>
              <option value="">Todas</option>
              {accounts.data?.map((a) => <option key={a.account_id} value={a.account_id}>{a.name}</option>)}
            </select>
          </div>
          <div className="field">
            <label htmlFor="f-category">Categoria</label>
            <select id="f-category" value={categoryFilter} onChange={(e) => setCategoryFilter(e.target.value)}>
              <option value="">Todas</option>
              {usedCategories.map((id) => <option key={id} value={id}>{catName.get(id) ?? "—"}</option>)}
            </select>
          </div>
        </div>
      </section>

      <section className="card stack" aria-labelledby="lista-lanc">
        <h2 id="lista-lanc">Lançamentos do mês</h2>
        {txns.isError && <Alert kind="error">{errorMessage(txns.error)}</Alert>}
        {txns.isLoading ? <p role="status">Carregando…</p> : shown.length === 0 ? (
          <p className="empty">{txns.data?.length ? "Nenhum lançamento com esses filtros." : "Nenhum lançamento neste mês."}</p>
        ) : (
          <ul className="list" aria-label="Lançamentos">
            {shown.map((t) => {
              const dir = txnDirection[t.type] ?? 1;
              const edited = t.status === "voided" && t.cancel_reason === EDITED;
              const canAct = t.status === "active" && ["income", "expense", "transfer_out", "transfer_in", "refund",
                "bill_payment", "card_bill_payment", "card_purchase"].includes(t.type);
              return (
                <li key={t.id} className={`list-item ${t.status !== "active" ? "inactive" : ""}`} aria-label={t.description}>
                  <div className="meta">
                    {t.type === "card_purchase" ? <Link to={`/compras/${t.id}`}><strong>{t.description}</strong></Link> : <strong>{t.description}</strong>}
                    <span className="muted">
                      {formatDate(t.local_date)} · {txnTypeLabel[t.type]}
                      {t.category_id && ` · ${catName.get(t.category_id) ?? ""}`}
                      {accName.get(t.account_id) && ` · ${accName.get(t.account_id)}`}
                      {t.replaces_transaction_id && " · versão editada"}
                    </span>
                    {t.cancel_reason && !edited && <span className="muted">Motivo: {t.cancel_reason}</span>}
                  </div>
                  <div className="actions">
                    <Money cents={dir * t.amount_cents} signed />
                    {t.status !== "active" && <StatusBadge status="blocked" label={edited ? "Editado" : txnStatusLabel[t.status]} />}
                    {canAct && (t.type === "income" || t.type === "expense") && (
                      <button className="btn secondary" type="button" onClick={() => { clear(); setEditing(t); }}>Editar</button>
                    )}
                    {canAct && (
                      <>
                        <button className="btn secondary" type="button" onClick={() => { clear(); setAction({ kind: "void", txn: t }); }}>
                          Anular
                        </button>
                        {t.type !== "card_purchase" && (
                          <button className="btn secondary" type="button" onClick={() => { clear(); setAction({ kind: "reverse", txn: t }); }}>
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
  const family = useFamilyId();
  const [op] = useState(() => crypto.randomUUID());  // idempotência: repetir o envio não duplica
  const [type, setType] = useState<"expense" | "income">("expense");
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const categories = useCategories();
  const accounts = useAccounts();
  const ownAccounts = accounts.data?.filter((a) => a.active) ?? [];
  const cats = categories.data?.filter((c) => c.kind === type && (c.family_id === null || c.family_id === family)) ?? [];

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
      p_op: op, p_family: family, p_type: type, p_account: String(form.get("account")),
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
            <Alert kind="info">Nenhuma conta cadastrada nesta família. <Link to="/contas">Cadastre uma conta</Link>.</Alert>
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
