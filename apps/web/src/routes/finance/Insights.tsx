// Visão geral (FF-06), Parcelas (FF-05) e Relatórios (FF-07) da família ativa.
// Definições do banco (family_overview/installments/report), sem dupla contagem:
// consumo (competência), caixa (saldo das contas) e compromissos (faturas e parcelas a faturar).
import { addMonths, businessToday, formatBRL, monthLabel, monthStart } from "@fluvi/domain";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router";
import { IconPlus } from "../../components/icons";
import { Alert, PageTitle } from "../../components/ui";
import { rpc } from "../../lib/api";
import { errorMessage } from "../../lib/errors";
import { useFamilyId } from "../../lib/family";

type Named = { name: string; cents: number };
type MonthValue = { month: string; cents: number };
type MonthFlow = { month: string; income_cents: number; consumption_cents: number };
type Overview = {
  month: string;
  balance_cents: number;
  income_cents: number;
  consumption_cents: number;
  categories: Named[];
  cards: { card_id: string; name: string; due_day: number; current_cents: number; closed_open_cents: number; debt_cents: number }[];
  evolution: MonthFlow[];
  future: MonthValue[];
};
type Installments = {
  purchases: { transaction_id: string; description: string; card: string; total_cents: number; count: number;
    billed: number; remaining_cents: number; next_cents: number | null }[];
  months: MonthValue[];
};
type Report = { from: string; to: string; categories: Named[]; months: MonthFlow[]; by_author: Named[]; commitments: MonthValue[] };

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const thisMonth = () => monthStart(businessToday());
const sum = (xs: { cents: number }[]) => xs.reduce((s, x) => s + Number(x.cents), 0);

function Bars({ rows, label, tone }: { rows: Named[]; label: string; tone?: "in" | "out" }) {
  if (rows.length === 0) return <p className="empty">Nada no período.</p>;
  const max = Math.max(...rows.map((r) => Number(r.cents)), 1);
  return (
    <ul className="bars" aria-label={label}>
      {rows.map((r) => (
        <li key={r.name} className="bar-row">
          <span>{r.name}</span>
          <span className="money">{formatBRL(Number(r.cents))}</span>
          <span className="track" aria-hidden="true">
            <span className={`fill ${tone ?? ""}`} style={{ display: "block", width: `${(Number(r.cents) / max) * 100}%` }} />
          </span>
        </li>
      ))}
    </ul>
  );
}

function Flow({ months, label }: { months: MonthFlow[]; label: string }) {
  const max = Math.max(...months.flatMap((m) => [Number(m.income_cents), Number(m.consumption_cents)]), 1);
  return (
    <>
      <p className="legend" aria-hidden="true"><span><i className="in" />Receitas</span><span><i className="out" />Consumo</span></p>
      <ul className="bars" aria-label={label}>
        {months.map((m) => (
          <li key={m.month} className="bar-row stacked">
            <span>{cap(monthLabel(m.month))}</span>
            <span className="muted" style={{ fontSize: "0.85rem" }}>
              Receitas <span className="money">{formatBRL(Number(m.income_cents))}</span> · Consumo <span className="money">{formatBRL(Number(m.consumption_cents))}</span>
            </span>
            <span className="track" aria-hidden="true"><span className="fill in" style={{ display: "block", width: `${(Number(m.income_cents) / max) * 100}%` }} /></span>
            <span className="track" aria-hidden="true"><span className="fill out" style={{ display: "block", width: `${(Number(m.consumption_cents) / max) * 100}%` }} /></span>
          </li>
        ))}
      </ul>
    </>
  );
}

function MonthNav({ month, onChange }: { month: string; onChange: (m: string) => void }) {
  return (
    <div className="row" style={{ alignItems: "center", marginBottom: 16 }}>
      <button className="btn secondary" type="button" onClick={() => onChange(addMonths(month, -1))} aria-label="Mês anterior">‹</button>
      <strong style={{ textAlign: "center" }} aria-live="polite">{cap(monthLabel(month))}</strong>
      <button className="btn secondary" type="button" onClick={() => onChange(addMonths(month, 1))} aria-label="Próximo mês">›</button>
    </div>
  );
}

const monthsAsBars = (xs: MonthValue[]) => xs.map((m) => ({ name: cap(monthLabel(m.month)), cents: Number(m.cents) }));

// ---------------------------------------------------------------------------
// Visão geral
// ---------------------------------------------------------------------------
export function Overview() {
  const family = useFamilyId();
  const [month, setMonth] = useState(thisMonth);
  const q = useQuery({
    queryKey: ["fin", "overview", family, month],
    enabled: !!family,
    queryFn: () => rpc<Overview>("family_overview", { p_family: family, p_month: month }),
  });
  const o = q.data;
  const future12 = o ? sum(o.future) : 0;
  const bills = o ? o.cards.reduce((s, c) => s + Number(c.current_cents) + Number(c.closed_open_cents), 0) : 0;

  return (
    <>
      <div className="page-head">
        <PageTitle>Visão geral</PageTitle>
        <Link className="btn gradient" to="/novo"><IconPlus />Novo lançamento</Link>
      </div>
      <MonthNav month={month} onChange={setMonth} />
      {q.isError && <Alert kind="error">{errorMessage(q.error)}</Alert>}
      {q.isLoading || !o ? <p role="status">Carregando…</p> : (
        <>
          <dl className="kpis">
            <div className="kpi"><dt>Saldo disponível</dt><dd>{formatBRL(Number(o.balance_cents))}<span className="sub">soma das contas da família, hoje</span></dd></div>
            <div className="kpi"><dt>Receitas do mês</dt><dd>{formatBRL(Number(o.income_cents))}</dd></div>
            <div className="kpi"><dt>Consumo do mês</dt><dd>{formatBRL(Number(o.consumption_cents))}<span className="sub">despesas e compras no cartão, pela competência</span></dd></div>
            <div className="kpi"><dt>Faturas a pagar</dt><dd>{formatBRL(bills)}<span className="sub">dívida do cartão; ainda não saiu do caixa</span></dd></div>
          </dl>
          <div className="grid-2">
            <section className="card" aria-labelledby="ov-cat">
              <h2 id="ov-cat">Consumo por categoria</h2>
              <Bars rows={o.categories} label="Consumo por categoria" tone="out" />
            </section>
            <section className="card" aria-labelledby="ov-evo">
              <h2 id="ov-evo">Evolução mensal</h2>
              <Flow months={o.evolution} label="Receitas e consumo por mês" />
            </section>
            <section className="card" aria-labelledby="ov-cards">
              <h2 id="ov-cards">Cartões</h2>
              {o.cards.length === 0 ? <p className="empty">Nenhum cartão cadastrado.</p> : (
                <ul className="list" aria-label="Faturas dos cartões">
                  {o.cards.map((c) => (
                    <li key={c.card_id} className="list-item">
                      <div className="meta">
                        <Link to={`/cartoes/${c.card_id}`}><strong>{c.name}</strong></Link>
                        <span className="muted">vence dia {c.due_day} · dívida total {formatBRL(Number(c.debt_cents))}</span>
                      </div>
                      <div className="meta" style={{ alignItems: "flex-end" }}>
                        <span className="money">{formatBRL(Number(c.current_cents))}</span>
                        <span className="muted" style={{ fontSize: "0.85rem" }}>fatura atual</span>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </section>
            <section className="card" aria-labelledby="ov-future">
              <h2 id="ov-future">Parcelas futuras</h2>
              <p className="big money">{formatBRL(future12)}</p>
              <p className="muted">a faturar nos próximos 12 meses</p>
              <Bars rows={monthsAsBars(o.future.slice(0, 4))} label="Próximos meses" />
              <Link to="/parcelas">Ver todas as parcelas</Link>
            </section>
          </div>
        </>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
// Parcelas
// ---------------------------------------------------------------------------
export function InstallmentsPage() {
  const family = useFamilyId();
  const q = useQuery({
    queryKey: ["fin", "installments", family],
    enabled: !!family,
    queryFn: () => rpc<Installments>("family_installments", { p_family: family }),
  });
  const d = q.data;
  return (
    <>
      <PageTitle>Parcelas</PageTitle>
      <p className="muted">
        A parcela que vence não é uma despesa nova: o gasto entrou no mês da compra. Aqui você vê quanto das
        próximas faturas já está comprometido.
      </p>
      {q.isError && <Alert kind="error">{errorMessage(q.error)}</Alert>}
      {q.isLoading || !d ? <p role="status">Carregando…</p> : (
        <>
          <section className="card" aria-labelledby="parc-compras">
            <h2 id="parc-compras">Compras parceladas</h2>
            {d.purchases.length === 0 ? <p className="empty">Nenhuma compra parcelada com parcelas a faturar.</p> : (
              <ul className="list" aria-label="Compras parceladas">
                {d.purchases.map((p) => (
                  <li key={p.transaction_id} className="list-item" aria-label={p.description}>
                    <div className="meta">
                      <Link to={`/compras/${p.transaction_id}`}><strong>{p.description}</strong></Link>
                      <span className="muted">
                        {p.card} · {p.billed} de {p.count} faturadas
                        {p.next_cents !== null && ` · próxima ${formatBRL(Number(p.next_cents))}`}
                      </span>
                    </div>
                    <div className="meta" style={{ alignItems: "flex-end" }}>
                      <span className="money">{formatBRL(Number(p.remaining_cents))}</span>
                      <span className="muted" style={{ fontSize: "0.85rem" }}>a faturar de {formatBRL(Number(p.total_cents))}</span>
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </section>
          <section className="card" aria-labelledby="parc-meses">
            <h2 id="parc-meses">Por mês de vencimento</h2>
            <Bars rows={monthsAsBars(d.months)} label="Parcelas por mês" />
          </section>
        </>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
// Relatórios
// ---------------------------------------------------------------------------
type Tab = "categorias" | "fluxo" | "autoria" | "compromissos";
const periods = [
  { value: 1, label: "Este mês" },
  { value: 3, label: "3 meses" },
  { value: 6, label: "6 meses" },
  { value: 12, label: "12 meses" },
];

function toCsv(rows: (string | number)[][]) {
  return rows.map((r) => r.map((v) => (typeof v === "string" && /[;"\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v)).join(";")).join("\n");
}
const reais = (cents: number) => (Number(cents) / 100).toFixed(2).replace(".", ",");

export function Reports() {
  const family = useFamilyId();
  const [tab, setTab] = useState<Tab>("categorias");
  const [span, setSpan] = useState(3);
  const to = thisMonth();
  const from = addMonths(to, -(span - 1));
  const q = useQuery({
    queryKey: ["fin", "report", family, from, to],
    enabled: !!family,
    queryFn: () => rpc<Report>("family_report", { p_family: family, p_from: from, p_to: to }),
  });
  const r = q.data;

  function exportCsv() {
    if (!r) return;
    const rows: (string | number)[][] =
      tab === "categorias" ? [["Categoria", "Consumo (R$)"], ...r.categories.map((c) => [c.name, reais(c.cents)])]
      : tab === "fluxo" ? [["Mês", "Receitas (R$)", "Consumo (R$)"], ...r.months.map((m) => [m.month.slice(0, 7), reais(m.income_cents), reais(m.consumption_cents)])]
      : tab === "autoria" ? [["Quem lançou", "Consumo (R$)"], ...r.by_author.map((a) => [a.name, reais(a.cents)])]
      : [["Mês", "Parcelas a faturar (R$)"], ...r.commitments.map((m) => [m.month.slice(0, 7), reais(m.cents)])];
    const url = URL.createObjectURL(new Blob(["﻿" + toCsv(rows)], { type: "text/csv;charset=utf-8" }));
    const a = Object.assign(document.createElement("a"), { href: url, download: `fluvifiance-${tab}-${from.slice(0, 7)}-a-${to.slice(0, 7)}.csv` });
    a.click();
    URL.revokeObjectURL(url);
  }

  const tabs: { value: Tab; label: string }[] = [
    { value: "categorias", label: "Categorias" },
    { value: "fluxo", label: "Receitas × consumo" },
    { value: "autoria", label: "Por quem lançou" },
    { value: "compromissos", label: "Compromissos" },
  ];

  return (
    <>
      <div className="page-head">
        <PageTitle>Relatórios</PageTitle>
        <button className="btn secondary" type="button" onClick={exportCsv} disabled={!r}>Exportar CSV</button>
      </div>
      <fieldset className="segmented" style={{ marginBottom: 12 }}>
        <legend className="visually-hidden">Período</legend>
        {periods.map((p) => (
          <label key={p.value}>
            <input type="radio" name="period" checked={span === p.value} onChange={() => setSpan(p.value)} />
            <span>{p.label}</span>
          </label>
        ))}
      </fieldset>
      <fieldset className="segmented" style={{ marginBottom: 16 }}>
        <legend className="visually-hidden">Relatório</legend>
        {tabs.map((t) => (
          <label key={t.value}>
            <input type="radio" name="report" checked={tab === t.value} onChange={() => setTab(t.value)} />
            <span>{t.label}</span>
          </label>
        ))}
      </fieldset>
      {q.isError && <Alert kind="error">{errorMessage(q.error)}</Alert>}
      {q.isLoading || !r ? <p role="status">Carregando…</p> : (
        <section className="card" aria-labelledby="rel-titulo">
          {tab === "categorias" && (
            <>
              <h2 id="rel-titulo">Consumo por categoria (competência)</h2>
              <p className="muted">Total no período: <span className="money">{formatBRL(sum(r.categories))}</span></p>
              <Bars rows={r.categories} label="Consumo por categoria" tone="out" />
            </>
          )}
          {tab === "fluxo" && (
            <>
              <h2 id="rel-titulo">Receitas × consumo</h2>
              <Flow months={r.months} label="Receitas e consumo por mês" />
            </>
          )}
          {tab === "autoria" && (
            <>
              <h2 id="rel-titulo">Consumo por quem lançou</h2>
              <p className="muted">Os dados são da família; aqui só se mostra quem registrou cada gasto.</p>
              <Bars rows={r.by_author} label="Consumo por quem lançou" />
            </>
          )}
          {tab === "compromissos" && (
            <>
              <h2 id="rel-titulo">Compromissos futuros (12 meses)</h2>
              <p className="muted">Parcelas já contratadas, por mês de vencimento da fatura. Não somam de novo como consumo.</p>
              <Bars rows={monthsAsBars(r.commitments)} label="Compromissos por mês" />
            </>
          )}
        </section>
      )}
    </>
  );
}
