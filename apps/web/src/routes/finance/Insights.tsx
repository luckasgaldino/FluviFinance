// Visão geral (FF-06), Parcelas (FF-05) e Relatórios (FF-07) — fase R1 com dados FICTÍCIOS
// de demonstração (lib/demo). Definições sem dupla contagem: consumo (competência), caixa e
// dívida/compromissos aparecem separados.
import { formatBRL, monthLabel } from "@fluvi/domain";
import { useState } from "react";
import { Link } from "react-router";
import { IconPlus } from "../../components/icons";
import { PageTitle } from "../../components/ui";
import { demo, futureByMonth, installmentAt, remainingOf, totalBalance } from "../../lib/demo";

const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

function DemoBanner() {
  return (
    <p className="demo-banner muted">
      <span className="badge demo">Demonstração</span>
      Valores fictícios para validar o visual. Os dados reais da família entram na próxima fase.
    </p>
  );
}

function Bars({ rows, label, tone }: { rows: { name: string; cents: number }[]; label: string; tone?: "in" | "out" }) {
  const max = Math.max(...rows.map((r) => r.cents), 1);
  return (
    <ul className="bars" aria-label={label}>
      {rows.map((r) => (
        <li key={r.name} className="bar-row">
          <span>{r.name}</span>
          <span className="money">{formatBRL(r.cents)}</span>
          <span className="track" aria-hidden="true">
            <span className={`fill ${tone ?? ""}`} style={{ display: "block", width: `${(r.cents / max) * 100}%` }} />
          </span>
        </li>
      ))}
    </ul>
  );
}

function Evolution() {
  const max = Math.max(...demo.evolution.flatMap((m) => [m.income, m.expense]));
  return (
    <>
      <p className="legend" aria-hidden="true"><span><i className="in" />Receitas</span><span><i className="out" />Despesas</span></p>
      <ul className="bars" aria-label="Receitas e despesas por mês">
        {demo.evolution.map((m) => (
          <li key={m.month} className="bar-row stacked">
            <span>{cap(monthLabel(m.month))}</span>
            <span className="muted" style={{ fontSize: "0.85rem" }}>
              Receitas <span className="money">{formatBRL(m.income)}</span> · Despesas <span className="money">{formatBRL(m.expense)}</span>
            </span>
            <span className="track" aria-hidden="true"><span className="fill in" style={{ display: "block", width: `${(m.income / max) * 100}%` }} /></span>
            <span className="track" aria-hidden="true"><span className="fill out" style={{ display: "block", width: `${(m.expense / max) * 100}%` }} /></span>
          </li>
        ))}
      </ul>
    </>
  );
}

export function Overview() {
  const future = futureByMonth(12);
  const futureTotal = future.reduce((s, m) => s + m.cents, 0);
  const currentBills = demo.cards.reduce((s, c) => s + c.current, 0);
  return (
    <>
      <div className="page-head">
        <PageTitle>Visão geral</PageTitle>
        <Link className="btn gradient" to="/novo"><IconPlus />Novo lançamento</Link>
      </div>
      <DemoBanner />
      <dl className="kpis">
        <div className="kpi"><dt>Saldo disponível</dt><dd>{formatBRL(totalBalance)}<span className="sub">soma das contas da família</span></dd></div>
        <div className="kpi"><dt>Receitas do mês</dt><dd>{formatBRL(demo.incomeMonth)}</dd></div>
        <div className="kpi"><dt>Despesas do mês</dt><dd>{formatBRL(demo.expenseMonth)}<span className="sub">consumo, inclui compras no cartão</span></dd></div>
        <div className="kpi"><dt>Faturas atuais</dt><dd>{formatBRL(currentBills)}<span className="sub">dívida, ainda não saiu do caixa</span></dd></div>
      </dl>
      <div className="grid-2">
        <section className="card" aria-labelledby="ov-cat">
          <h2 id="ov-cat">Despesas por categoria</h2>
          <Bars rows={demo.categories} label="Despesas por categoria" tone="out" />
        </section>
        <section className="card" aria-labelledby="ov-evo">
          <h2 id="ov-evo">Evolução mensal</h2>
          <Evolution />
        </section>
        <section className="card" aria-labelledby="ov-cards">
          <h2 id="ov-cards">Cartões</h2>
          <ul className="list" aria-label="Faturas dos cartões">
            {demo.cards.map((c) => (
              <li key={c.name} className="list-item">
                <div className="meta"><strong>{c.name}</strong><span className="muted">vence dia {c.dueDay} · próxima {formatBRL(c.next)}</span></div>
                <span className="money">{formatBRL(c.current)}</span>
              </li>
            ))}
          </ul>
        </section>
        <section className="card" aria-labelledby="ov-future">
          <h2 id="ov-future">Parcelas futuras</h2>
          <p className="big money">{formatBRL(futureTotal)}</p>
          <p className="muted">comprometidos nos próximos 12 meses</p>
          <Bars rows={future.slice(0, 4).map((m) => ({ name: cap(monthLabel(m.month)), cents: m.cents }))} label="Próximos meses" />
          <Link to="/parcelas">Ver todas as parcelas</Link>
        </section>
      </div>
    </>
  );
}

export function InstallmentsPage() {
  const future = futureByMonth(12);
  return (
    <>
      <PageTitle>Parcelas</PageTitle>
      <DemoBanner />
      <p className="muted">
        A parcela que vence não é uma despesa nova: o gasto entrou no mês da compra. Aqui você vê quanto das
        próximas faturas já está comprometido.
      </p>
      <section className="card" aria-labelledby="parc-compras">
        <h2 id="parc-compras">Compras parceladas</h2>
        <ul className="list" aria-label="Compras parceladas">
          {demo.purchases.map((p) => (
            <li key={p.description} className="list-item">
              <div className="meta">
                <strong>{p.description}</strong>
                <span className="muted">{p.card} · {p.paid} de {p.count} faturadas · parcela {formatBRL(installmentAt(p, p.paid + 1))}</span>
              </div>
              <div className="meta" style={{ alignItems: "flex-end" }}>
                <span className="money">{formatBRL(remainingOf(p))}</span>
                <span className="muted" style={{ fontSize: "0.85rem" }}>a faturar de {formatBRL(p.total)}</span>
              </div>
            </li>
          ))}
        </ul>
      </section>
      <section className="card" aria-labelledby="parc-meses">
        <h2 id="parc-meses">Por mês</h2>
        <Bars rows={future.filter((m) => m.cents > 0).map((m) => ({ name: cap(monthLabel(m.month)), cents: m.cents }))}
          label="Parcelas por mês" />
      </section>
    </>
  );
}

type Tab = "categorias" | "fluxo" | "compromissos";

function toCsv(rows: (string | number)[][]) {
  return rows.map((r) => r.map((v) => (typeof v === "string" && /[;"\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v)).join(";")).join("\n");
}

export function Reports() {
  const [tab, setTab] = useState<Tab>("categorias");
  const future = futureByMonth(12);
  const cents = (v: number) => (v / 100).toFixed(2).replace(".", ",");

  function exportCsv() {
    const rows: (string | number)[][] =
      tab === "categorias" ? [["Categoria", "Valor (R$)"], ...demo.categories.map((c) => [c.name, cents(c.cents)])]
      : tab === "fluxo" ? [["Mês", "Receitas (R$)", "Despesas (R$)"], ...demo.evolution.map((m) => [m.month.slice(0, 7), cents(m.income), cents(m.expense)])]
      : [["Mês", "Parcelas (R$)"], ...future.map((m) => [m.month.slice(0, 7), cents(m.cents)])];
    const url = URL.createObjectURL(new Blob(["﻿" + toCsv(rows)], { type: "text/csv;charset=utf-8" }));
    const a = Object.assign(document.createElement("a"), { href: url, download: `fluvifiance-${tab}-demo.csv` });
    a.click();
    URL.revokeObjectURL(url);
  }

  const tabs: { value: Tab; label: string }[] = [
    { value: "categorias", label: "Categorias" },
    { value: "fluxo", label: "Receitas × despesas" },
    { value: "compromissos", label: "Compromissos" },
  ];

  return (
    <>
      <div className="page-head">
        <PageTitle>Relatórios</PageTitle>
        <button className="btn secondary" type="button" onClick={exportCsv}>Exportar CSV</button>
      </div>
      <DemoBanner />
      <fieldset className="segmented" style={{ marginBottom: 16 }}>
        <legend className="visually-hidden">Relatório</legend>
        {tabs.map((t) => (
          <label key={t.value}>
            <input type="radio" name="report" checked={tab === t.value} onChange={() => setTab(t.value)} />
            <span>{t.label}</span>
          </label>
        ))}
      </fieldset>
      <section className="card" aria-labelledby="rel-titulo">
        {tab === "categorias" && (
          <>
            <h2 id="rel-titulo">Consumo por categoria (competência)</h2>
            <Bars rows={demo.categories} label="Consumo por categoria" tone="out" />
          </>
        )}
        {tab === "fluxo" && (
          <>
            <h2 id="rel-titulo">Receitas × despesas</h2>
            <Evolution />
          </>
        )}
        {tab === "compromissos" && (
          <>
            <h2 id="rel-titulo">Compromissos futuros (12 meses)</h2>
            <p className="muted">Dívida já contratada em parcelas — não soma de novo como consumo.</p>
            <Bars rows={future.map((m) => ({ name: cap(monthLabel(m.month)), cents: m.cents }))} label="Compromissos por mês" />
          </>
        )}
      </section>
    </>
  );
}
