// Fase R1 — dados FICTÍCIOS de demonstração para desenhar Visão geral, Parcelas e Relatórios.
// Nada aqui vem do banco nem representa pessoas reais; a integração chega na fase R4.
import { addMonths, businessToday, monthStart } from "@fluvi/domain";

export type DemoAccount = { name: string; type: string; balance: number };
export type DemoCard = { name: string; current: number; dueDay: number; limit: number; next: number };
export type DemoPurchase = { description: string; card: string; total: number; count: number; paid: number; firstMonth: string };

const today = monthStart(businessToday());

export const demo = {
  accounts: [
    { name: "Conta corrente", type: "Conta bancária", balance: 482035 },
    { name: "Reserva", type: "Poupança", balance: 1230000 },
    { name: "Carteira", type: "Dinheiro", balance: 18000 },
  ] satisfies DemoAccount[],
  incomeMonth: 980000,
  expenseMonth: 643090,
  categories: [
    { name: "Moradia", cents: 210000 },
    { name: "Mercado", cents: 138040 },
    { name: "Educação", cents: 90000 },
    { name: "Transporte", cents: 64000 },
    { name: "Saúde", cents: 52000 },
    { name: "Outros", cents: 48000 },
    { name: "Lazer", cents: 41050 },
  ],
  cards: [
    { name: "Cartão principal", current: 214530, dueDay: 15, limit: 1200000, next: 168020 },
    { name: "Cartão reserva", current: 86000, dueDay: 5, limit: 500000, next: 42000 },
  ] satisfies DemoCard[],
  purchases: [
    { description: "Televisão", card: "Cartão principal", total: 120000, count: 6, paid: 3, firstMonth: addMonths(today, -3) },
    { description: "Geladeira", card: "Cartão principal", total: 389900, count: 10, paid: 3, firstMonth: addMonths(today, -3) },
    { description: "Curso de idiomas", card: "Cartão reserva", total: 180000, count: 12, paid: 1, firstMonth: addMonths(today, -1) },
    { description: "Óculos", card: "Cartão reserva", total: 64000, count: 4, paid: 0, firstMonth: today },
  ] satisfies DemoPurchase[],
  evolution: [-5, -4, -3, -2, -1, 0].map((d, i) => ({
    month: addMonths(today, d),
    income: [920000, 940000, 935000, 960000, 980000, 980000][i],
    expense: [710000, 655000, 698000, 602000, 671500, 643090][i],
  })),
};

export const totalBalance = demo.accounts.reduce((s, a) => s + a.balance, 0);

/** Parcela mensal de uma compra (mesma regra do banco: o resto vai para as primeiras). */
export function installmentAt(p: DemoPurchase, seq: number): number {
  const base = Math.floor(p.total / p.count);
  return base + (seq <= p.total - base * p.count ? 1 : 0);
}

/** Compromissos futuros por mês (parcelas ainda a faturar), próximos `months` meses. */
export function futureByMonth(months = 12) {
  return Array.from({ length: months }, (_, i) => {
    const month = addMonths(today, i + 1);
    const items = demo.purchases.flatMap((p) => {
      const seq = monthsBetween(p.firstMonth, month) + 1;
      return seq > p.paid && seq <= p.count && seq >= 1 ? [{ ...p, seq, cents: installmentAt(p, seq) }] : [];
    });
    return { month, items, cents: items.reduce((s, x) => s + x.cents, 0) };
  });
}

function monthsBetween(a: string, b: string) {
  const [ya, ma] = a.split("-").map(Number);
  const [yb, mb] = b.split("-").map(Number);
  return (yb - ya) * 12 + (mb - ma);
}

export const remainingOf = (p: DemoPurchase) => {
  let s = 0;
  for (let k = p.paid + 1; k <= p.count; k++) s += installmentAt(p, k);
  return s;
};
