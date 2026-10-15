// Privacidade móvel (v2.2 §3.2): tela inicial discreta, novo lançamento rápido sem desbloqueio
// e confirmação de senha para as áreas financeiras.
import { businessToday, formatBRL, parseBRL, splitCents } from "@fluvi/domain";
import { useMutation, useQuery } from "@tanstack/react-query";
import { useEffect, useState, type FormEvent, type ReactNode } from "react";
import { Link, Navigate, Outlet } from "react-router";
import { IconLock, IconPlus } from "../components/icons";
import { Alert, Field, PageTitle } from "../components/ui";
import { rpc } from "../lib/api";
import { isDesktop } from "../lib/device";
import { errorMessage } from "../lib/errors";
import { useFinanceLock } from "../lib/finance-lock";
import { useSession } from "../lib/session";
import { supabase } from "../lib/supabase";

// ---------------------------------------------------------------------------
// Tela inicial discreta: nenhum dado financeiro, só a ação principal.
// ---------------------------------------------------------------------------
export function DiscreetHome() {
  if (isDesktop()) return <Navigate to="/painel" replace />;
  return (
    <section className="discreet" aria-labelledby="inicio-titulo">
      <div className="inner">
        <div className="orb"><img src="/favicon.svg" alt="" /></div>
        <PageTitle><span id="inicio-titulo">Tudo certo por aqui</span></PageTitle>
        <p className="muted">Registre um gasto ou uma receita em poucos toques. Para ver saldos e relatórios, use o menu.</p>
        <Link className="cta" to="/novo"><IconPlus />Novo lançamento</Link>
      </div>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Área protegida: sem desbloqueio, o conteúdo nem é montado (nenhuma consulta sai).
// ---------------------------------------------------------------------------
export function RequireUnlock({ children }: { children?: ReactNode }) {
  const { unlocked, touch } = useFinanceLock();

  // Só atividade humana na área protegida renova a janela de 15 minutos.
  useEffect(() => {
    if (!unlocked) return;
    const events = ["pointerdown", "keydown", "wheel", "touchstart"] as const;
    events.forEach((e) => window.addEventListener(e, touch, { passive: true }));
    return () => events.forEach((e) => window.removeEventListener(e, touch));
  }, [unlocked, touch]);

  if (!unlocked) return <UnlockScreen />;
  return <>{children ?? <Outlet />}</>;
}

function UnlockScreen() {
  const { unlock } = useFinanceLock();
  const { session } = useSession();
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const form = e.currentTarget;
    const password = String(new FormData(form).get("password"));
    if (!password) return setError("Informe sua senha.");
    setBusy(true);
    setError("");
    const result = await unlock(password);
    setBusy(false);
    form.reset();
    if (result === "wrong") setError("Senha incorreta. Nenhuma informação foi liberada.");
    else if (result === "error") setError("Não foi possível confirmar agora. Tente novamente em instantes.");
  }

  return (
    <section className="unlock" aria-labelledby="desbloqueio-titulo">
      <div className="orb"><IconLock /></div>
      <PageTitle><span id="desbloqueio-titulo">Área financeira protegida</span></PageTitle>
      <p className="muted">
        Para ver saldos, lançamentos e relatórios, confirme a mesma senha usada para entrar.
        Seu login continua ativo.
      </p>
      <form className="card stack" onSubmit={onSubmit} noValidate aria-label="Confirmar senha">
        <input type="email" name="username" autoComplete="username" value={session?.user.email ?? ""} readOnly hidden />
        <Field label="Senha" name="password" type="password" autoComplete="current-password" required />
        <Alert kind="error">{error}</Alert>
        <button className="btn block" type="submit" disabled={busy}>{busy ? "Confirmando…" : "Desbloquear"}</button>
        <Link to="/inicio" style={{ textAlign: "center" }}>Voltar ao início</Link>
      </form>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Novo lançamento rápido: grava sem desbloqueio e nunca mostra valores já cadastrados.
// As opções trazem só apelidos (nada de saldo, limite ou final do cartão).
// ---------------------------------------------------------------------------
type Kind = "expense" | "income" | "card" | "transfer";
type Option = { id: string; name: string };
type QuickOptions = { accounts: Option[]; cards: Option[]; categories: (Option & { kind: "expense" | "income" })[] };

const kinds: { value: Kind; label: string }[] = [
  { value: "expense", label: "Despesa" },
  { value: "income", label: "Receita" },
  { value: "card", label: "Cartão" },
  { value: "transfer", label: "Transferência" },
];

function useQuickOptions(userId: string | undefined) {
  return useQuery({
    queryKey: ["quick", "options", userId],
    enabled: !!userId,
    staleTime: 60_000,
    queryFn: async (): Promise<QuickOptions> => {
      const [acc, cards, cats] = await Promise.all([
        supabase.from("financial_accounts").select("id, name").eq("owner_user_id", userId!).eq("active", true)
          .neq("type", "credit_card").order("name"),
        supabase.from("credit_cards").select("id, name").eq("owner_user_id", userId!).eq("active", true).order("name"),
        supabase.from("categories").select("id, name, kind").eq("active", true).order("name"),
      ]);
      for (const r of [acc, cards, cats]) if (r.error) throw r.error;
      return { accounts: acc.data as Option[], cards: cards.data as Option[], categories: cats.data as QuickOptions["categories"] };
    },
  });
}

function Select({ id, label, name, options, error, placeholder, loading }: {
  id: string; label: string; name: string; options: Option[]; error?: string; placeholder: string; loading?: boolean;
}) {
  return (
    <div className="field">
      <label htmlFor={id}>{label}</label>
      <select id={id} name={name} defaultValue="" aria-invalid={error ? true : undefined}
        aria-describedby={error ? `${id}-err` : undefined}>
        <option value="" disabled>{options.length ? placeholder : loading ? "Carregando…" : "Nenhuma opção cadastrada"}</option>
        {options.map((o) => <option key={o.id} value={o.id}>{o.name}</option>)}
      </select>
      {error && <span id={`${id}-err`} className="hint error-text">{error}</span>}
    </div>
  );
}

export function QuickEntry() {
  const { me } = useSession();
  const options = useQuickOptions(me?.user_id);
  const [kind, setKind] = useState<Kind>("expense");
  const [op, setOp] = useState(() => crypto.randomUUID());  // idempotência: repetir o envio não duplica
  const [formKey, setFormKey] = useState(0);
  const [amountText, setAmountText] = useState("");
  const [n, setN] = useState(1);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const [saved, setSaved] = useState("");
  const amount = parseBRL(amountText);
  const cats = options.data?.categories.filter((c) => c.kind === (kind === "income" ? "income" : "expense")) ?? [];

  const save = useMutation({
    mutationFn: ({ fn, args }: { fn: string; args: Record<string, unknown> }) => rpc(fn, args),
    onSuccess: () => {
      // a resposta traz só o identificador; nada de saldo é exibido
      setSaved(kind === "transfer" ? "Transferência registrada." : "Lançamento salvo.");
      setOp(crypto.randomUUID());
      setAmountText("");
      setN(1);
      setFormKey((k) => k + 1);
    },
    onError: (e) => setError(errorMessage(e)),
  });

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const get = (k: string) => String(f.get(k) ?? "").trim();
    const next: Record<string, string> = {};
    if (amount === null || amount <= 0) next.amount = "Informe um valor maior que zero, no formato 1.234,56.";
    if (kind !== "transfer" && !get("description")) next.description = "Informe uma descrição.";
    if (kind !== "transfer" && !get("category")) next.category = "Escolha uma categoria.";
    if ((kind === "expense" || kind === "income") && !get("account")) next.account = "Escolha a conta.";
    if (kind === "card" && !get("card")) next.card = "Escolha o cartão.";
    if (kind === "card" && !(n >= 1 && n <= 36)) next.n = "Parcelas de 1 a 36.";
    if (kind === "transfer" && !get("from")) next.from = "Escolha a conta de origem.";
    if (kind === "transfer" && !get("to")) next.to = "Escolha a conta de destino.";
    if (kind === "transfer" && get("from") && get("from") === get("to")) next.to = "Escolha uma conta diferente da origem.";
    setErrors(next);
    setError("");
    setSaved("");
    if (Object.keys(next).length) return;
    const date = get("date");
    const competence = `${date.slice(0, 7)}-01`;
    if (kind === "card") {
      save.mutate({ fn: "create_card_purchase", args: {
        p_op: op, p_card: get("card"), p_amount_cents: amount, p_installments: n, p_description: get("description"),
        p_category: get("category"), p_local_date: date, p_competence_month: competence,
      } });
    } else if (kind === "transfer") {
      save.mutate({ fn: "transfer_funds", args: {
        p_op: op, p_from_account: get("from"), p_to_account: get("to"), p_amount_cents: amount, p_executed_on: date,
        p_description: get("description") || "Transferência",
      } });
    } else {
      save.mutate({ fn: "create_transaction", args: {
        p_op: op, p_owner: me?.user_id, p_type: kind, p_account: get("account"), p_amount_cents: amount,
        p_description: get("description"), p_category: get("category"), p_local_date: date, p_competence_month: competence,
      } });
    }
  }

  const accounts = options.data?.accounts ?? [];
  const parts = kind === "card" && amount && amount > 0 && n >= 1 && n <= 36 ? splitCents(amount, n) : null;

  return (
    <>
      <PageTitle>Novo lançamento</PageTitle>
      {saved && <Alert kind="success">{saved}</Alert>}
      <form key={formKey} className="card stack" onSubmit={onSubmit} noValidate aria-label="Novo lançamento">
        <fieldset className="segmented" style={{ margin: 0 }}>
          <legend className="visually-hidden">Tipo de lançamento</legend>
          {kinds.map((k) => (
            <label key={k.value}>
              <input type="radio" name="kind" value={k.value} checked={kind === k.value}
                onChange={() => { setKind(k.value); setErrors({}); setSaved(""); }} />
              <span>{k.label}</span>
            </label>
          ))}
        </fieldset>
        <Field label="Valor (R$)" name="amount" inputMode="decimal" autoComplete="off" placeholder="0,00"
          value={amountText} onChange={(e) => setAmountText(e.target.value)} error={errors.amount} />
        <Field label={kind === "transfer" ? "Descrição (opcional)" : "Descrição"} name="description" maxLength={140}
          autoComplete="off" error={errors.description} />
        <div className="row">
          {kind !== "transfer" && (
            <Select id="q-category" label="Categoria" name="category" options={cats} error={errors.category} placeholder="Escolha…" loading={options.isLoading} />
          )}
          {(kind === "expense" || kind === "income") && (
            <Select id="q-account" label="Conta" name="account" options={accounts} error={errors.account} placeholder="Escolha…" loading={options.isLoading} />
          )}
          {kind === "card" && (
            <Select id="q-card" label="Cartão" name="card" options={options.data?.cards ?? []} error={errors.card} placeholder="Escolha…" loading={options.isLoading} />
          )}
          {kind === "transfer" && (
            <>
              <Select id="q-from" label="Da conta" name="from" options={accounts} error={errors.from} placeholder="Escolha…" loading={options.isLoading} />
              <Select id="q-to" label="Para a conta" name="to" options={accounts} error={errors.to} placeholder="Escolha…" loading={options.isLoading} />
            </>
          )}
        </div>
        <div className="row">
          <Field label="Data" name="date" type="date" defaultValue={businessToday()} required />
          {kind === "card" && (
            <Field label="Parcelas" name="n" type="number" min={1} max={36} value={n}
              onChange={(e) => setN(Number(e.target.value))} error={errors.n} />
          )}
        </div>
        {parts && (
          <p className="muted" aria-live="polite">
            {parts.every((p) => p === parts[0]) ? `${n} × ${formatBRL(parts[0])}`
              : `${parts.filter((p) => p === parts[0]).length} × ${formatBRL(parts[0])} + ${
                parts.filter((p) => p !== parts[0]).length} × ${formatBRL(parts[parts.length - 1])}`} = {formatBRL(amount!)}
          </p>
        )}
        {options.isError && <Alert kind="error">{errorMessage(options.error)}</Alert>}
        <Alert kind="error">{error}</Alert>
        <button className="btn block" type="submit" disabled={save.isPending}>{save.isPending ? "Salvando…" : "Salvar"}</button>
        <Link to="/inicio" style={{ textAlign: "center" }}>Voltar ao início</Link>
      </form>
    </>
  );
}
