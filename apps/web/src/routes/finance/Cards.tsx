// Cartões e faturas (FF-04): cadastro, posições (§5.5), ciclos e regras (§20.9), da família ativa.
import { businessToday, formatBRL, formatDate, parseBRL } from "@fluvi/domain";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Link, useParams } from "react-router";
import { Alert, Field, PageTitle, StatusBadge } from "../../components/ui";
import {
  cycleBadge, cycleLabel, nums, rpc,
  type Card, type CardCycle, type CardPosition,
} from "../../lib/api";
import { errorMessage } from "../../lib/errors";
import { useFamilyId } from "../../lib/family";
import { supabase } from "../../lib/supabase";
import { Money, useAccounts } from "./Accounts";

const positionKeys: (keyof CardPosition)[] = ["credit_limit_cents", "debt_total_cents", "closed_remaining_cents",
  "open_preview_cents", "future_installments_cents", "unapplied_credit_cents", "available_limit_cents"];

export function useCardPositions() {
  const family = useFamilyId();
  return useQuery({
    queryKey: ["fin", "card-positions", family],
    enabled: !!family,
    queryFn: async () => {
      const { data, error } = await supabase.from("v_card_position").select("*").eq("family_id", family).order("name");
      if (error) throw error;
      return (data as CardPosition[]).map((p) => nums(p, positionKeys));
    },
  });
}

function PositionGrid({ p }: { p: CardPosition }) {
  const rows: [string, number | null][] = [
    ["Dívida total", p.debt_total_cents],
    ["Faturas fechadas em aberto", p.closed_remaining_cents],
    ["Prévia da fatura atual", p.open_preview_cents ?? 0],
    ["Parcelas futuras", p.future_installments_cents],
    ["Crédito ainda não aplicado", p.unapplied_credit_cents],
    ["Limite", p.credit_limit_cents],
    ["Limite disponível", p.available_limit_cents],
  ];
  return (
    <dl className="kv">
      {rows.map(([k, v]) => (
        <div key={k}>
          <dt>{k}</dt>
          <dd>
            <Money cents={v ?? 0} />
            {k === "Limite disponível" && (v ?? 0) < 0 && <span className="badge blocked">Acima do limite</span>}
          </dd>
        </div>
      ))}
    </dl>
  );
}

function NewCardForm({ onDone }: { onDone: () => void }) {
  const queryClient = useQueryClient();
  const family = useFamilyId();
  const [op] = useState(() => crypto.randomUUID());
  const [error, setError] = useState("");
  const create = useMutation({
    mutationFn: (args: Record<string, unknown>) => rpc("create_card", args),
    onSuccess: () => { void queryClient.invalidateQueries({ queryKey: ["fin"] }); onDone(); },
    onError: (e) => setError(errorMessage(e)),
  });

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const limit = parseBRL(String(f.get("limit") || "0"));
    const close = Number(f.get("closing"));
    const due = Number(f.get("due"));
    const four = String(f.get("four") || "").trim();
    if (limit === null) return setError("Limite inválido. Use o formato 1.234,56.");
    if (!(close >= 1 && close <= 31) || !(due >= 1 && due <= 31)) return setError("Dias de fechamento e vencimento devem estar entre 1 e 31.");
    if (four && !/^\d{4}$/.test(four)) return setError("Informe só os 4 últimos dígitos do cartão.");
    setError("");
    create.mutate({
      p_op: op, p_family: family, p_name: String(f.get("name")).trim(),
      p_closing_day: close, p_due_day: due, p_limit_cents: limit,
      p_policy: String(f.get("policy")), p_brand: String(f.get("brand") || "").trim() || null, p_last_four: four || null,
    });
  }

  return (
    <section className="card stack" aria-labelledby="novo-cartao">
      <h2 id="novo-cartao">Novo cartão</h2>
      <form className="stack" onSubmit={onSubmit} noValidate>
        <div className="row">
          <Field label="Nome do cartão" name="name" required maxLength={60} />
          <Field label="Bandeira (opcional)" name="brand" maxLength={30} />
          <Field label="4 últimos dígitos (opcional)" name="four" inputMode="numeric" maxLength={4}
            hint="Nunca informe o número completo nem o código de segurança." />
        </div>
        <div className="row">
          <Field label="Dia de fechamento" name="closing" type="number" min={1} max={31} required />
          <Field label="Dia de vencimento" name="due" type="number" min={1} max={31} required />
          <Field label="Limite (R$)" name="limit" inputMode="decimal" defaultValue="0,00" />
        </div>
        <div className="row">
          <div className="field">
            <label htmlFor="card-policy">Compra no dia do fechamento</label>
            <select id="card-policy" name="policy" defaultValue="current_cycle">
              <option value="current_cycle">Entra na fatura que fecha nesse dia</option>
              <option value="next_cycle">Entra na fatura seguinte</option>
            </select>
          </div>
        </div>
        <Alert kind="error">{error}</Alert>
        <div className="row" style={{ alignItems: "center" }}>
          <button className="btn" type="submit" disabled={create.isPending}>Criar cartão</button>
          <button className="btn secondary" type="button" onClick={onDone}>Cancelar</button>
        </div>
      </form>
    </section>
  );
}

export function Cards() {
  const positions = useCardPositions();
  const [creating, setCreating] = useState(false);
  return (
    <>
      <PageTitle>Cartões</PageTitle>
      <div className="row" style={{ alignItems: "center" }}>
        {!creating && <button className="btn" type="button" onClick={() => setCreating(true)}>Novo cartão</button>}
        <Link className="btn secondary" to="/cartoes/compra">Nova compra no cartão</Link>
      </div>
      {creating && <NewCardForm onDone={() => setCreating(false)} />}
      {positions.isError && <Alert kind="error">{errorMessage(positions.error)}</Alert>}
      {positions.isLoading ? <p role="status">Carregando…</p> : positions.data?.length === 0 ? (
        <p className="empty">Nenhum cartão cadastrado.</p>
      ) : (
        <ul className="list" aria-label="Cartões">
          {positions.data?.map((p) => (
            <li key={p.card_id} className="list-item" aria-label={p.name}>
              <div className="meta">
                <Link to={`/cartoes/${p.card_id}`}><strong>{p.name}</strong></Link>
                <span className="muted">
                  Dívida <Money cents={p.debt_total_cents} /> · disponível <Money cents={p.available_limit_cents} />
                </span>
              </div>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

function RulesForm({ card, onDone }: { card: Card; onDone: (msg: string) => void }) {
  const queryClient = useQueryClient();
  const [op] = useState(() => crypto.randomUUID());
  const [error, setError] = useState("");
  const update = useMutation({
    mutationFn: (args: Record<string, unknown>) => rpc<{ review_items: unknown[]; recalculated_cycles: number }>("update_card_rules", args),
    onSuccess: (r) => {
      void queryClient.invalidateQueries({ queryKey: ["fin"] });
      const n = r.review_items?.length ?? 0;
      onDone(`Regras salvas. ${r.recalculated_cycles} fatura(s) aberta(s) recalculada(s).` +
        (n ? ` ${n} compra(s) ficaram fora da nova janela e foram marcadas para revisão (não foram movidas).` : ""));
    },
    onError: (e) => setError(errorMessage(e)),
  });
  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const limit = parseBRL(String(f.get("limit")));
    if (limit === null) return setError("Limite inválido.");
    update.mutate({ p_op: op, p_card: card.id, p_closing_day: Number(f.get("closing")), p_due_day: Number(f.get("due")),
      p_policy: String(f.get("policy")), p_limit_cents: limit });
  }
  return (
    <form className="card stack" onSubmit={onSubmit} aria-label="Regras do cartão" noValidate>
      <h2>Regras do cartão</h2>
      <p className="muted">Mudanças valem para faturas abertas e estimadas; faturas fechadas ou confirmadas pelo banco não mudam. Nenhuma compra muda de fatura.</p>
      <div className="row">
        <Field label="Dia de fechamento" name="closing" type="number" min={1} max={31} defaultValue={card.closing_day} />
        <Field label="Dia de vencimento" name="due" type="number" min={1} max={31} defaultValue={card.due_day} />
        <Field label="Limite (R$)" name="limit" inputMode="decimal"
          defaultValue={(Number(card.credit_limit_cents) / 100).toFixed(2).replace(".", ",")} />
      </div>
      <div className="field">
        <label htmlFor="rules-policy">Compra no dia do fechamento</label>
        <select id="rules-policy" name="policy" defaultValue={card.closing_day_policy}>
          <option value="current_cycle">Entra na fatura que fecha nesse dia</option>
          <option value="next_cycle">Entra na fatura seguinte</option>
        </select>
      </div>
      <Alert kind="error">{error}</Alert>
      <div><button className="btn" type="submit" disabled={update.isPending}>Salvar regras</button></div>
    </form>
  );
}

// Pagamento de fatura (FF-04, FIN-03): integral ou parcial, a partir de uma conta da família.
// Reduz caixa e dívida; não é consumo novo (a compra já entrou na competência).
function PayBillForm({ cycle, onDone }: { cycle: CardCycle; onDone: (msg?: string) => void }) {
  const queryClient = useQueryClient();
  const accounts = useAccounts();
  const [op] = useState(() => crypto.randomUUID());
  const [error, setError] = useState("");
  const remaining = cycle.remaining_cents ?? 0;
  const pay = useMutation({
    mutationFn: (args: Record<string, unknown>) => rpc("settle_obligation", args),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["fin"] });
      onDone("Pagamento registrado.");
    },
    onError: (e) => setError(errorMessage(e)),
  });

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const amount = parseBRL(String(f.get("amount")));
    if (amount === null || amount <= 0) return setError("Informe um valor maior que zero, no formato 1.234,56.");
    if (amount > remaining) return setError(`O valor não pode passar do saldo da fatura (${formatBRL(remaining)}).`);
    if (!f.get("account")) return setError("Escolha a conta de pagamento.");
    setError("");
    pay.mutate({ p_op: op, p_obligation: cycle.obligation_id, p_account: String(f.get("account")),
      p_amount_cents: amount, p_paid_on: String(f.get("date")) });
  }

  return (
    <form className="card stack" onSubmit={onSubmit} noValidate aria-label="Pagar fatura">
      <h3>Pagar fatura que vence em {formatDate(cycle.due_on)}</h3>
      <p className="muted">Saldo da fatura: <Money cents={remaining} />. O pagamento sai da conta e reduz a dívida do cartão.</p>
      <div className="row">
        <Field label="Valor (R$)" name="amount" inputMode="decimal" autoComplete="off"
          defaultValue={(remaining / 100).toFixed(2).replace(".", ",")} />
        <div className="field">
          <label htmlFor="pay-account">Conta</label>
          <select id="pay-account" name="account" defaultValue="">
            <option value="" disabled>{accounts.data?.length ? "Escolha…" : "Nenhuma conta cadastrada"}</option>
            {accounts.data?.filter((a) => a.active).map((a) => <option key={a.account_id} value={a.account_id}>{a.name}</option>)}
          </select>
        </div>
        <Field label="Data do pagamento" name="date" type="date" defaultValue={businessToday()} />
      </div>
      <Alert kind="error">{error}</Alert>
      <div className="row" style={{ alignItems: "center" }}>
        <button className="btn" type="submit" disabled={pay.isPending}>Confirmar pagamento</button>
        <button className="btn secondary" type="button" onClick={() => onDone()}>Cancelar</button>
      </div>
    </form>
  );
}

// Saldo anterior (implantação na data de corte): dívida que o cartão já tinha antes de a família
// começar a usar o FluviFinance. Entra nas faturas e na dívida; não é gasto do mês nem sai do caixa.
type OpeningKind = "fechada" | "aberta" | "parcelas";
const openingKinds: { value: OpeningKind; label: string; hint: string }[] = [
  { value: "fechada", label: "Fatura fechada a pagar", hint: "Fatura que já fechou no banco e ainda não foi paga." },
  { value: "aberta", label: "Fatura aberta até hoje", hint: "O que já foi gasto na fatura atual antes de você começar a lançar aqui." },
  { value: "parcelas", label: "Parcelas de compra antiga", hint: "Parcelas que ainda vão cair de compras feitas antes do início." },
];

function OpeningBalanceForm({ card, onDone }: { card: Card; onDone: (msg?: string) => void }) {
  const queryClient = useQueryClient();
  const [kind, setKind] = useState<OpeningKind>("fechada");
  const [op, setOp] = useState(() => crypto.randomUUID());
  const [error, setError] = useState("");
  const thisMonth = businessToday().slice(0, 7);
  const save = useMutation({
    mutationFn: (args: Record<string, unknown>) => rpc("create_card_opening_balance", args),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["fin"] });
      setOp(crypto.randomUUID());
      onDone("Saldo anterior registrado. Ele entra nas faturas e na dívida, sem virar gasto do mês.");
    },
    onError: (e) => setError(errorMessage(e)),
  });

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const cents = parseBRL(String(f.get("amount")));
    const n = kind === "parcelas" ? Number(f.get("n")) : 1;
    const due = String(f.get("due"));
    if (cents === null || cents <= 0) return setError("Informe um valor maior que zero, no formato 1.234,56.");
    if (!(n >= 1 && n <= 36)) return setError("Parcelas de 1 a 36.");
    if (!/^\d{4}-\d{2}$/.test(due)) return setError("Informe o mês de vencimento.");
    setError("");
    const fallback = kind === "fechada" ? `Fatura anterior (vence ${due.slice(5)}/${due.slice(0, 4)})`
      : kind === "aberta" ? "Fatura aberta antes do início" : "Parcelas de compra anterior";
    save.mutate({ p_op: op, p_card: card.id, p_description: String(f.get("description") || "").trim() || fallback,
      p_installment_cents: cents, p_installments: n, p_first_due_month: `${due}-01` });
  }

  const current = openingKinds.find((k) => k.value === kind)!;
  return (
    <form className="card stack" onSubmit={onSubmit} noValidate aria-label="Saldo anterior do cartão">
      <h2>Saldo anterior do cartão</h2>
      <p className="muted">Use ao começar: registra a dívida que o cartão já tinha. Não conta como gasto do mês nem sai do saldo das contas.</p>
      <fieldset className="segmented grid-2" style={{ margin: 0 }}>
        <legend className="visually-hidden">O que registrar</legend>
        {openingKinds.map((k) => (
          <label key={k.value}>
            <input type="radio" name="opening-kind" checked={kind === k.value} onChange={() => { setKind(k.value); setError(""); }} />
            <span>{k.label}</span>
          </label>
        ))}
      </fieldset>
      <p className="muted">{current.hint}</p>
      <Field label="Descrição (opcional)" name="description" maxLength={140} />
      <div className="row">
        <Field label={kind === "parcelas" ? "Valor de cada parcela (R$)" : "Valor (R$)"} name="amount" inputMode="decimal" autoComplete="off" placeholder="0,00" />
        {kind === "parcelas" && <Field label="Parcelas restantes" name="n" type="number" min={1} max={36} defaultValue={1} />}
        <Field label={kind === "parcelas" ? "Vencimento da próxima parcela" : "Vencimento da fatura"} name="due" type="month"
          defaultValue={thisMonth} hint={`Este cartão vence no dia ${card.due_day}.`} />
      </div>
      <Alert kind="error">{error}</Alert>
      <div className="row" style={{ alignItems: "center" }}>
        <button className="btn" type="submit" disabled={save.isPending}>Registrar</button>
        <button className="btn secondary" type="button" onClick={() => onDone()}>Cancelar</button>
      </div>
    </form>
  );
}

export function CardDetail() {
  const { id } = useParams();
  const [editing, setEditing] = useState(false);
  const [paying, setPaying] = useState<CardCycle | null>(null);
  const [opening, setOpening] = useState(false);
  const [feedback, setFeedback] = useState("");
  const family = useFamilyId();
  const card = useQuery({
    queryKey: ["fin", "card", family, id],
    enabled: !!family,
    queryFn: async () => {
      const { data, error } = await supabase.from("credit_cards").select("*")
        .eq("id", id!).eq("family_id", family).maybeSingle();
      if (error) throw error;
      return data as Card | null;
    },
  });
  const position = useQuery({
    queryKey: ["fin", "card-position", id],
    enabled: !!card.data,
    queryFn: async () => {
      const { data, error } = await supabase.from("v_card_position").select("*").eq("card_id", id!).single();
      if (error) throw error;
      return nums(data as CardPosition, positionKeys);
    },
  });
  const cycles = useQuery({
    queryKey: ["fin", "card-cycles", id],
    enabled: !!card.data,
    queryFn: async () => {
      const { data, error } = await supabase.from("v_card_cycles").select("*").eq("card_id", id!).order("closes_on");
      if (error) throw error;
      return (data as CardCycle[]).map((c) => nums(c, ["debits_cents", "credits_cents", "amount_cents", "paid_cents", "remaining_cents"]));
    },
  });
  const purchases = useQuery({
    queryKey: ["fin", "card-purchases", id],
    enabled: !!card.data,
    queryFn: async () => {
      const { data, error } = await supabase.from("card_purchases")
        .select("transaction_id, total_cents, installment_count").eq("card_id", id!);
      if (error) throw error;
      const ids = (data ?? []).map((p) => p.transaction_id as string);
      const { data: txns } = ids.length
        ? await supabase.from("transactions").select("id, description, local_date, status").in("id", ids).order("local_date", { ascending: false })
        : { data: [] };
      const byId = new Map((data ?? []).map((p) => [p.transaction_id as string, p]));
      return (txns ?? []).map((t) => ({ ...t, total_cents: Number(byId.get(t.id)!.total_cents), n: Number(byId.get(t.id)!.installment_count) }));
    },
  });

  if (card.isLoading) return <p role="status">Carregando…</p>;
  if (!card.data) {
    return (<><PageTitle>Cartão</PageTitle><Alert kind="error">Cartão não encontrado ou sem permissão.</Alert><Link to="/cartoes">Voltar para cartões</Link></>);
  }
  const c = card.data;
  return (
    <>
      <PageTitle>{c.name}</PageTitle>
      <p className="muted">
        {c.brand && `${c.brand} · `}{c.last_four && `final ${c.last_four} · `}fecha dia {c.closing_day}, vence dia {c.due_day}
      </p>
      {feedback && <Alert kind="success">{feedback}</Alert>}
      <section className="card stack" aria-labelledby="posicao">
        <h2 id="posicao">Posição do cartão</h2>
        {position.data && <PositionGrid p={position.data} />}
      </section>
      <div className="row" style={{ alignItems: "center" }}>
        <Link className="btn" to={`/cartoes/compra?cartao=${c.id}`}>Nova compra</Link>
        <Link className="btn secondary" to={`/cartoes/${c.id}/importar`}>Importar fatura</Link>
        {!editing && <button className="btn secondary" type="button" onClick={() => { setFeedback(""); setEditing(true); }}>Editar regras</button>}
        {!opening && <button className="btn secondary" type="button" onClick={() => { setFeedback(""); setOpening(true); }}>Saldo anterior</button>}
      </div>
      {editing && <RulesForm card={c} onDone={(msg) => { setEditing(false); setFeedback(msg); }} />}
      {opening && <OpeningBalanceForm card={c} onDone={(msg) => { setOpening(false); if (msg) setFeedback(msg); }} />}

      <section className="card stack" aria-labelledby="faturas">
        <h2 id="faturas">Faturas</h2>
        {cycles.data?.length === 0 && <p className="empty">Nenhuma fatura ainda.</p>}
        <ul className="list" aria-label="Faturas">
          {cycles.data?.map((y) => (
            <li key={y.cycle_id} className="list-item" aria-label={`Fatura ${formatDate(y.closes_on)}`}>
              <div className="meta">
                <strong>Fecha {formatDate(y.closes_on)} · vence {formatDate(y.due_on)}</strong>
                <span className="muted">
                  {formatDate(y.starts_on)} a {formatDate(y.closes_on)}
                  {y.credits_cents > 0 && <> · créditos <Money cents={y.credits_cents} /></>}
                  {y.status === "closed" && <> · pago <Money cents={y.paid_cents} /></>}
                </span>
              </div>
              <div className="actions">
                <Money cents={y.status === "closed" ? y.remaining_cents ?? 0 : y.amount_cents} />
                <StatusBadge status={cycleBadge(y)} label={cycleLabel(y)} />
                {y.status === "closed" && (y.remaining_cents ?? 0) > 0 && y.obligation_id && (
                  <button className="btn secondary" type="button" onClick={() => { setFeedback(""); setPaying(y); }}>Pagar</button>
                )}
              </div>
            </li>
          ))}
        </ul>
        {paying && <PayBillForm cycle={paying} onDone={(msg) => { setPaying(null); if (msg) setFeedback(msg); }} />}
      </section>

      <section className="card stack" aria-labelledby="compras">
        <h2 id="compras">Compras</h2>
        {purchases.data?.length === 0 && <p className="empty">Nenhuma compra neste cartão.</p>}
        <ul className="list" aria-label="Compras do cartão">
          {purchases.data?.map((p) => (
            <li key={p.id} className={`list-item ${p.status !== "active" ? "inactive" : ""}`} aria-label={p.description}>
              <div className="meta">
                <Link to={`/compras/${p.id}`}><strong>{p.description}</strong></Link>
                <span className="muted">{formatDate(p.local_date)} · {p.n}x{p.status !== "active" && " · anulada"}</span>
              </div>
              <Money cents={p.total_cents} />
            </li>
          ))}
        </ul>
      </section>
      <Link to="/cartoes">Voltar para cartões</Link>
    </>
  );
}
