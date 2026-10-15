// Datas de negócio em America/Sao_Paulo (F1). Datas sem hora são strings ISO (YYYY-MM-DD),
// nunca convertidas artificialmente entre fusos (§7.1).

export const BUSINESS_TZ = "America/Sao_Paulo";

/** "Hoje" de negócio (YYYY-MM-DD) no fuso de São Paulo. */
export function businessToday(now: Date = new Date()): string {
  return now.toLocaleDateString("sv-SE", { timeZone: BUSINESS_TZ });
}

/** Primeiro dia do mês (competência) de uma data ISO. */
export function monthStart(isoDate: string): string {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(isoDate)) throw new RangeError("data ISO inválida");
  return `${isoDate.slice(0, 7)}-01`;
}

/** Intervalo [início, fim] do mês de uma data ISO. */
export function monthRange(isoDate: string): { from: string; to: string } {
  const [y, m] = isoDate.split("-").map(Number);
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return { from: `${isoDate.slice(0, 7)}-01`, to: `${isoDate.slice(0, 7)}-${String(last).padStart(2, "0")}` };
}

/** Rótulo de mês em português: "2026-10-01" → "outubro de 2026". */
export function monthLabel(isoDate: string): string {
  const [y, m] = isoDate.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, 15)).toLocaleDateString("pt-BR", { month: "long", year: "numeric", timeZone: "UTC" });
}

/** Data ISO → "dd/mm/aaaa" sem passar por fuso. */
export function formatDate(isoDate: string): string {
  const [y, m, d] = isoDate.slice(0, 10).split("-");
  return `${d}/${m}/${y}`;
}

/** Soma meses a uma data ISO de dia 1 (competência). */
export function addMonths(monthIso: string, delta: number): string {
  const [y, m] = monthIso.split("-").map(Number);
  const d = new Date(Date.UTC(y, m - 1 + delta, 1));
  return d.toISOString().slice(0, 10);
}
