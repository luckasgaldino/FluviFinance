// Compras no cartão e parcelamentos (FF-04/FF-05): nova compra com prévia das
// parcelas (mesma distribuição do banco), detalhe com bruto/estornos/líquido, parcelas por
// fatura, estorno, ajuste de parcelas (§20.4) e anulação.
import { businessToday, formatBRL, formatDate, parseBRL, splitCents } from "@fluvi/domain";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router";
import { Alert, Field, PageTitle, StatusBadge } from "../../components/ui";
import { nums, rpc, txnStatusLabel, type Category, type Installment } from "../../lib/api";
import { errorMessage } from "../../lib/errors";
import { useFamilyId } from "../../lib/family";
import { supabase } from "../../lib/supabase";
import { Money } from "./Accounts";
import { useCardPositions } from "./Cards";

function InstallmentPreview({ amount, n }: { amount: number | null; n: number }) {
  if (!amount || amount <= 0 || !(n >= 1 && n <= 36)) return null;
  const parts = splitCents(amount, n);
  const same = parts.every((p) => p === parts[0]);
  return (
    <p className="muted" aria-live="polite">
      {same ? `${n} × ${formatBRL(parts[0])}` : `${parts.filter((p) => p === parts[0]).length} × ${formatBRL(parts[0])} + ${
        parts.filter((p) => p !== parts[0]).length} × ${formatBRL(parts[parts.length - 1])}`} = {formatBRL(amount)}
    </p>
  );
}

export function NewPurchase() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [params] = useSearchParams();
  const cards = useCardPositions();
  const categories = useQuery({
    queryKey: ["fin", "categories"],
    queryFn: async () => {
      const { data, error } = await supabase.from("categories").select("id, name, kind, family_id").eq("active", true).order("name");
      if (error) throw error;
      return data as Category[];
    },
  });
  const [op] = useState(() => crypto.randomUUID());
  const [amountText, setAmountText] = useState("");
  const [n, setN] = useState(1);
  const [cardId, setCardId] = useState(params.get("cartao") ?? "");
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [error, setError] = useState("");
  const amount = parseBRL(amountText);
  const family = useFamilyId();
  const cats = categories.data?.filter((c) => c.kind === "expense" && (c.family_id === null || c.family_id === family)) ?? [];

  const create = useMutation({
    mutationFn: (args: Record<string, unknown>) => rpc<{ id: string }>("create_card_purchase", args),
    onSuccess: (r) => { void queryClient.invalidateQueries({ queryKey: ["fin"] }); navigate(`/compras/${r.id}?ok=1`); },
    onError: (e) => setError(errorMessage(e)),
  });

  function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const next: Record<string, string> = {};
    if (!cardId) next.card = "Escolha o cartão.";
    if (amount === null || amount <= 0) next.amount = "Informe um valor maior que zero, no formato 1.234,56.";
    if (!(n >= 1 && n <= 36)) next.n = "Parcelas de 1 a 36.";
    if (!String(f.get("description")).trim()) next.description = "Informe uma descrição.";
    if (!f.get("category")) next.category = "Escolha uma categoria.";
    setErrors(next);
    setError("");
    if (Object.keys(next).length) return;
    const date = String(f.get("date"));
    create.mutate({
      p_op: op, p_card: cardId, p_amount_cents: amount, p_installments: n,
      p_description: String(f.get("description")).trim(), p_category: String(f.get("category")),
      p_local_date: date, p_competence_month: `${String(f.get("competence") || date.slice(0, 7))}-01`,
      p_note: String(f.get("note") || "").trim() || null,
    });
  }

  return (
    <>
      <PageTitle>Nova compra no cartão</PageTitle>
      <form className="stack" onSubmit={onSubmit} noValidate>
        <section className="card stack" aria-labelledby="compra-principal">
          <h2 id="compra-principal">Principal</h2>
          <div className="row">
            <div className="field">
              <label htmlFor="pc-card">Cartão</label>
              <select id="pc-card" value={cardId} onChange={(e) => setCardId(e.target.value)}
                aria-invalid={errors.card ? true : undefined} aria-describedby={errors.card ? "pc-card-err" : undefined}>
                <option value="" disabled>{cards.data?.some((c) => c.active !== false) ? "Escolha…" : "Nenhum cartão cadastrado"}</option>
                {cards.data?.filter((c) => c.active !== false).map((c) => <option key={c.card_id} value={c.card_id}>{c.name}</option>)}
              </select>
              {errors.card && <span id="pc-card-err" className="hint error-text">{errors.card}</span>}
            </div>
            <Field label="Valor total (R$)" name="amount" inputMode="decimal" autoComplete="off" placeholder="0,00"
              value={amountText} onChange={(e) => setAmountText(e.target.value)} error={errors.amount} />
            <Field label="Parcelas" name="n" type="number" min={1} max={36} value={n}
              onChange={(e) => setN(Number(e.target.value))} error={errors.n} />
          </div>
          <InstallmentPreview amount={amount} n={n} />
          <div className="row">
            <Field label="Descrição" name="description" required maxLength={140} error={errors.description} />
            <div className="field">
              <label htmlFor="pc-category">Categoria</label>
              <select id="pc-category" name="category" defaultValue="" aria-invalid={errors.category ? true : undefined}
                aria-describedby={errors.category ? "pc-category-err" : undefined}>
                <option value="" disabled>Escolha…</option>
                {cats.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
              {errors.category && <span id="pc-category-err" className="hint error-text">{errors.category}</span>}
            </div>
          </div>
        </section>
        <section className="card stack" aria-labelledby="compra-detalhes">
          <h2 id="compra-detalhes">Detalhes</h2>
          <div className="row">
            <Field label="Data da compra" name="date" type="date" defaultValue={businessToday()} required
              hint="Define a fatura (ciclo estimado). A data real do banco prevalece quando confirmada." />
            <Field label="Competência (mês de consumo)" name="competence" type="month" defaultValue={businessToday().slice(0, 7)} />
          </div>
          <Field label="Observação" name="note" maxLength={500} />
        </section>
        <Alert kind="error">{error}</Alert>
        <div className="row" style={{ alignItems: "center" }}>
          <button className="btn" type="submit" disabled={create.isPending}>Salvar compra</button>
          <Link to="/cartoes">Cancelar</Link>
        </div>
      </form>
    </>
  );
}

type Panel = "refund" | "adjust" | "void" | null;

export function PurchaseDetail() {
  const { id } = useParams();
  const [params] = useSearchParams();
  const queryClient = useQueryClient();
  const [panel, setPanel] = useState<Panel>(null);
  const [feedback, setFeedback] = useState(params.get("ok") ? "Compra salva." : "");
  const [error, setError] = useState("");
  const [op, setOp] = useState(() => crypto.randomUUID());

  const net = useQuery({
    queryKey: ["fin", "purchase", id],
    queryFn: async () => {
      const { data, error } = await supabase.from("v_purchase_net").select("*").eq("transaction_id", id!).maybeSingle();
      if (error) throw error;
      return data ? nums(data as Record<string, unknown>, ["gross_cents", "refunded_cents", "net_cents"]) as {
        transaction_id: string; description: string; local_date: string; status: string;
        gross_cents: number; refunded_cents: number; net_cents: number;
      } : null;
    },
  });
  const installments = useQuery({
    queryKey: ["fin", "purchase-installments", id],
    enabled: !!net.data,
    queryFn: async () => {
      const { data: p } = await supabase.from("card_purchases").select("id, card_id").eq("transaction_id", id!).single();
      const { data, error } = await supabase.from("installments").select("*").eq("purchase_id", p!.id).order("revision").order("sequence");
      if (error) throw error;
      const rows = (data as Installment[]).map((i) => nums(i, ["amount_cents"]));
      const cycleIds = [...new Set(rows.map((r) => r.billing_cycle_id))];
      const { data: cycles } = await supabase.from("billing_cycles").select("id, closes_on, status, date_source").in("id", cycleIds);
      const byId = new Map((cycles ?? []).map((c) => [c.id as string, c]));
      return { cardId: p!.card_id as string, rows: rows.map((r) => ({ ...r, cycle: byId.get(r.billing_cycle_id) })) };
    },
  });

  const act = useMutation({
    mutationFn: ({ fn, args }: { fn: string; args: Record<string, unknown> }) => rpc(fn, args),
    onSuccess: (_d, v) => {
      void queryClient.invalidateQueries({ queryKey: ["fin"] });
      setPanel(null);
      setOp(crypto.randomUUID());
      setFeedback(v.fn === "refund_transaction" ? "Estorno registrado." : v.fn === "adjust_installments" ? "Parcelas ajustadas." : "Compra anulada.");
    },
    onError: (e) => setError(errorMessage(e)),
  });

  if (net.isLoading) return <p role="status">Carregando…</p>;
  if (!net.data) return (<><PageTitle>Compra</PageTitle><Alert kind="error">Compra não encontrada ou sem permissão.</Alert><Link to="/cartoes">Voltar</Link></>);
  const p = net.data;
  const valid = installments.data?.rows.filter((r) => r.status === "valid") ?? [];
  const preserved = valid.filter((r) => r.cycle?.status === "closed" || r.cycle?.date_source === "confirmed");
  const preservedSum = preserved.reduce((a, r) => a + r.amount_cents, 0);

  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError("");
    const f = new FormData(e.currentTarget);
    if (panel === "refund") {
      const v = parseBRL(String(f.get("value")));
      if (v === null || v <= 0) return setError("Informe o valor do estorno.");
      act.mutate({ fn: "refund_transaction", args: { p_op: op, p_transaction: id, p_amount_cents: v, p_refunded_on: String(f.get("date")) } });
    } else if (panel === "adjust") {
      const total = parseBRL(String(f.get("total")));
      if (total === null) return setError("Informe o novo total.");
      act.mutate({ fn: "adjust_installments", args: { p_op: op, p_purchase_transaction: id, p_new_total_cents: total,
        p_remaining_count: Number(f.get("count")), p_reason: String(f.get("reason")).trim() } });
    } else if (panel === "void") {
      const reason = String(f.get("reason")).trim();
      if (reason.length < 3) return setError("Informe o motivo (mínimo de 3 caracteres).");
      act.mutate({ fn: "void_transaction", args: { p_op: op, p_transaction: id, p_reason: reason } });
    }
  }

  return (
    <>
      <PageTitle>{p.description}</PageTitle>
      {feedback && <Alert kind="success">{feedback}</Alert>}
      <section className="card stack" aria-labelledby="valores">
        <h2 id="valores">Valores</h2>
        <dl className="kv">
          <div><dt>Data</dt><dd>{formatDate(p.local_date)}</dd></div>
          <div><dt>Valor bruto</dt><dd><Money cents={p.gross_cents} /></dd></div>
          <div><dt>Estornos</dt><dd><Money cents={p.refunded_cents} /></dd></div>
          <div><dt>Valor líquido</dt><dd><Money cents={p.net_cents} /></dd></div>
          <div><dt>Situação</dt><dd>{txnStatusLabel[p.status] ?? p.status}</dd></div>
        </dl>
      </section>

      {p.status === "active" && (
        <div className="row" style={{ alignItems: "center" }}>
          <button className="btn secondary" type="button" onClick={() => { setError(""); setPanel("refund"); }}>Estornar</button>
          <button className="btn secondary" type="button" onClick={() => { setError(""); setPanel("adjust"); }}>Ajustar parcelas</button>
          <button className="btn secondary" type="button" onClick={() => { setError(""); setPanel("void"); }}>Anular</button>
        </div>
      )}

      {panel && (
        <form className="card stack" onSubmit={submit} noValidate
          aria-label={panel === "refund" ? "Estornar compra" : panel === "adjust" ? "Ajustar parcelas" : "Anular compra"}>
          {panel === "refund" && (<>
            <h2>Estornar compra</h2>
            <p className="muted">O estorno vira crédito na fatura aberta da data informada; se sobrar, abate as faturas seguintes. As parcelas não são canceladas.</p>
            <div className="row">
              <Field label="Valor do estorno (R$)" name="value" inputMode="decimal" />
              <Field label="Data do estorno" name="date" type="date" defaultValue={businessToday()} />
            </div>
          </>)}
          {panel === "adjust" && (<>
            <h2>Ajustar parcelas</h2>
            <p className="muted">
              Parcelas de faturas fechadas ou confirmadas pelo banco são preservadas ({preserved.length} parcela(s), {formatBRL(preservedSum)}).
              O restante do novo total é dividido nas faturas abertas.
            </p>
            <div className="row">
              <Field label="Novo total da compra (R$)" name="total" inputMode="decimal" defaultValue={(p.gross_cents / 100).toFixed(2).replace(".", ",")} />
              <Field label="Parcelas restantes" name="count" type="number" min={0} max={36} defaultValue={Math.max(valid.length - preserved.length, 1)} />
            </div>
            <Field label="Motivo" name="reason" required maxLength={200} />
          </>)}
          {panel === "void" && (<>
            <h2>Anular compra</h2>
            <p className="muted">Só para compra registrada por engano e ainda não faturada. Compra já faturada se corrige com estorno.</p>
            <Field label="Motivo" name="reason" required maxLength={200} />
          </>)}
          <Alert kind="error">{error}</Alert>
          <div className="row" style={{ alignItems: "center" }}>
            <button className="btn" type="submit" disabled={act.isPending}>Confirmar</button>
            <button className="btn secondary" type="button" onClick={() => setPanel(null)}>Cancelar</button>
          </div>
        </form>
      )}

      <section className="card stack" aria-labelledby="parcelas">
        <h2 id="parcelas">Parcelas</h2>
        <ul className="list" aria-label="Parcelas">
          {installments.data?.rows.map((r) => (
            <li key={r.id} className={`list-item ${r.status !== "valid" ? "inactive" : ""}`} aria-label={`Parcela ${r.sequence} revisão ${r.revision}`}>
              <div className="meta">
                <strong>Parcela {r.sequence}</strong>
                <span className="muted">
                  {r.cycle ? `fatura de ${formatDate(r.cycle.closes_on as string)}` : "fatura"}
                  {r.status !== "valid" && " · substituída por ajuste"}
                </span>
              </div>
              <div className="actions">
                <Money cents={r.amount_cents} />
                {r.cycle && (r.cycle.status === "closed"
                  ? <StatusBadge status="pending" label="Faturada" />
                  : r.cycle.date_source === "confirmed" ? <StatusBadge status="neutral" label="Confirmada" /> : null)}
              </div>
            </li>
          ))}
        </ul>
      </section>
      {installments.data && <Link to={`/cartoes/${installments.data.cardId}`}>Voltar para o cartão</Link>}
    </>
  );
}
