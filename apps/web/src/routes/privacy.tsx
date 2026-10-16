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
import { useFamily } from "../lib/family";
import { useFinanceLock } from "../lib/finance-lock";
import { useSession } from "../lib/session";

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

  const { active, loading } = useFamily();
  if (!unlocked) return <UnlockScreen />;
  if (!loading && !active) return <NoFamily />;
  return <>{children ?? <Outlet />}</>;
}

export function NoFamily() {
  return (
    <Alert kind="info">
      Você ainda não faz parte de uma família. Peça ao administrador para vincular sua conta.
    </Alert>
  );
}

function UnlockScreen() {
  const { unlock, ready } = useFinanceLock();
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
    else if (result === "limited") setError("Muitas tentativas em pouco tempo. Aguarde um pouco e tente novamente.");
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
        <button className="btn block" type="submit" disabled={busy || !ready}>{busy ? "Confirmando…" : "Desbloquear"}</button>
        <Link to="/inicio" style={{ textAlign: "center" }}>Voltar ao início</Link>
      </form>
    </section>
  );
}

// ---------------------------------------------------------------------------
// Novo lançamento rápido: grava sem desbloqueio e nunca mostra valores já cadastrados.
// Despesa é todo custo; a forma de pagamento decide o efeito: conta → sai do caixa agora;
// cartão → vira dívida da fatura (parcelável), sem sair do caixa até o pagamento.
// As opções trazem só apelidos (nada de saldo, limite ou final do cartão).
// ---------------------------------------------------------------------------
type Kind = "expense" | "income" | "transfer";
type Option = { id: string; name: string };
type QuickOptions = { accounts: Option[]; cards: Option[]; categories: (Option & { kind: "expense" | "income" })[] };

const kinds: { value: Kind; label: string }[] = [
  { value: "expense", label: "Despesa" },
  { value: "income", label: "Receita" },
  { value: "transfer", label: "Transferência" },
];

function useQuickOptions(family: string) {
  return useQuery({
    queryKey: ["quick", "options", family],
    enabled: !!family,
    staleTime: 60_000,
    // só apelidos, sem saldo, limite ou final do cartão; funciona com a área financeira bloqueada
    queryFn: () => rpc<QuickOptions>("quick_entry_options", { p_family: family }),
  });
}

type Group = { label?: string; prefix?: string; options: Option[] };

function Select({ id, label, name, groups, error, loading, value, onChange }: {
  id: string; label: string; name: string; groups: Group[]; error?: string; loading?: boolean;
  value?: string; onChange?: (v: string) => void;
}) {
  const empty = groups.every((g) => g.options.length === 0);
  const items = (g: Group) => g.options.map((o) => <option key={o.id} value={`${g.prefix ?? ""}${o.id}`}>{o.name}</option>);
  const control = onChange ? { value: value ?? "", onChange: (e: { target: { value: string } }) => onChange(e.target.value) } : { defaultValue: "" };
  return (
    <div className="field">
      <label htmlFor={id}>{label}</label>
      <select id={id} name={name} aria-invalid={error ? true : undefined} aria-describedby={error ? `${id}-err` : undefined} {...control}>
        <option value="" disabled>{!empty ? "Escolha…" : loading ? "Carregando…" : "Nenhuma opção cadastrada"}</option>
        {groups.map((g, i) => (g.label
          ? g.options.length > 0 && <optgroup key={i} label={g.label}>{items(g)}</optgroup>
          : items(g)))}
      </select>
      {error && <span id={`${id}-err`} className="hint error-text">{error}</span>}
    </div>
  );
}

export function QuickEntry() {
  const { active, loading: familyLoading } = useFamily();
  const family = active?.family_id ?? "";
  const options = useQuickOptions(family);
  const [kind, setKind] = useState<Kind>("expense");
  const [op, setOp] = useState(() => crypto.randomUUID());  // idempotência: repetir o envio não duplica
  const [formKey, setFormKey] = useState(0);
  const [amountText, setAmountText] = useState("");
  const [payWith, setPayWith] = useState("");  // "acc:<id>" ou "card:<id>"
  const [n, setN] = useState(1);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const [saved, setSaved] = useState("");
  const amount = parseBRL(amountText);
  const onCard = kind === "expense" && payWith.startsWith("card:");
  const cats = options.data?.categories.filter((c) => c.kind === (kind === "income" ? "income" : "expense")) ?? [];

  const save = useMutation({
    mutationFn: ({ fn, args }: { fn: string; args: Record<string, unknown> }) => rpc(fn, args),
    onSuccess: () => {
      // a resposta traz só o identificador; nada de saldo é exibido
      setSaved(kind === "transfer" ? "Transferência registrada." : "Lançamento salvo.");
      setOp(crypto.randomUUID());
      setAmountText("");
      setPayWith("");
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
    if (kind === "expense" && !payWith) next.pay = "Escolha a conta ou o cartão.";
    if (kind === "income" && !get("account")) next.account = "Escolha a conta.";
    if (onCard && !(n >= 1 && n <= 36)) next.n = "Parcelas de 1 a 36.";
    if (kind === "transfer" && !get("from")) next.from = "Escolha a conta de origem.";
    if (kind === "transfer" && !get("to")) next.to = "Escolha a conta de destino.";
    if (kind === "transfer" && get("from") && get("from") === get("to")) next.to = "Escolha uma conta diferente da origem.";
    setErrors(next);
    setError("");
    setSaved("");
    if (Object.keys(next).length) return;
    const date = get("date");
    const competence = `${date.slice(0, 7)}-01`;
    if (onCard) {
      save.mutate({ fn: "create_card_purchase", args: {
        p_op: op, p_card: payWith.slice("card:".length), p_amount_cents: amount, p_installments: n,
        p_description: get("description"), p_category: get("category"), p_local_date: date, p_competence_month: competence,
      } });
    } else if (kind === "transfer") {
      save.mutate({ fn: "transfer_funds", args: {
        p_op: op, p_from_account: get("from"), p_to_account: get("to"), p_amount_cents: amount, p_executed_on: date,
        p_description: get("description") || "Transferência",
      } });
    } else {
      save.mutate({ fn: "create_transaction", args: {
        p_op: op, p_family: family, p_type: kind,
        p_account: kind === "expense" ? payWith.slice("acc:".length) : get("account"),
        p_amount_cents: amount, p_description: get("description"), p_category: get("category"), p_local_date: date,
        p_competence_month: competence,
      } });
    }
  }

  const accounts = options.data?.accounts ?? [];
  const loading = options.isLoading;
  const parts = onCard && amount && amount > 0 && n >= 1 && n <= 36 ? splitCents(amount, n) : null;

  return (
    <>
      <PageTitle>Novo lançamento</PageTitle>
      {!familyLoading && !active && <NoFamily />}
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
            <Select id="q-category" label="Categoria" name="category" groups={[{ options: cats }]} error={errors.category} loading={loading} />
          )}
          {kind === "expense" && (
            <Select id="q-pay" label="Pagar com" name="pay" value={payWith} onChange={setPayWith} error={errors.pay} loading={loading}
              groups={[{ label: "Contas", prefix: "acc:", options: accounts },
                { label: "Cartões de crédito", prefix: "card:", options: options.data?.cards ?? [] }]} />
          )}
          {kind === "income" && (
            <Select id="q-account" label="Conta" name="account" groups={[{ options: accounts }]} error={errors.account} loading={loading} />
          )}
          {kind === "transfer" && (
            <>
              <Select id="q-from" label="Da conta" name="from" groups={[{ options: accounts }]} error={errors.from} loading={loading} />
              <Select id="q-to" label="Para a conta" name="to" groups={[{ options: accounts }]} error={errors.to} loading={loading} />
            </>
          )}
        </div>
        <div className="row">
          <Field label="Data" name="date" type="date" defaultValue={businessToday()} required />
          {onCard && (
            <Field label="Parcelas" name="n" type="number" min={1} max={36} value={n}
              onChange={(e) => setN(Number(e.target.value))} error={errors.n} />
          )}
        </div>
        {onCard && <p className="muted">No cartão, a despesa entra na fatura e só sai da conta quando a fatura for paga.</p>}
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
