// Leitura de fatura de cartão exportada pelo banco (CSV). Roda no aparelho: o arquivo não é
// enviado nem guardado; só os lançamentos confirmados na prévia são gravados.
// Formatos aceitos (Nubank): "date,title,amount" e "date,category,title,amount"; separador
// vírgula ou ponto e vírgula; valor com ponto ou vírgula decimal; data AAAA-MM-DD ou DD/MM/AAAA.

export type InvoiceLine = {
  /** posição no arquivo (para a chave de deduplicação) */
  index: number;
  date: string;                 // AAAA-MM-DD
  title: string;                // como veio do banco
  description: string;          // sem o sufixo "Parcela k/n"
  amountCents: number;          // positivo = débito na fatura
  kind: "purchase" | "installment" | "payment" | "credit";
  k?: number;
  n?: number;
  /** texto estável para a chave de deduplicação (data, título, valor e ocorrência) */
  key: string;
};

export type ParsedInvoice = { lines: InvoiceLine[]; format: string };

export class InvoiceFormatError extends Error {}

function splitCsv(text: string, sep: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let cell = "";
  let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (quoted) {
      if (ch === '"' && text[i + 1] === '"') { cell += '"'; i++; }
      else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"') quoted = true;
    else if (ch === sep) { row.push(cell); cell = ""; }
    else if (ch === "\n" || ch === "\r") {
      if (ch === "\r" && text[i + 1] === "\n") i++;
      row.push(cell); cell = "";
      if (row.some((c) => c.trim() !== "")) rows.push(row);
      row = [];
    } else cell += ch;
  }
  row.push(cell);
  if (row.some((c) => c.trim() !== "")) rows.push(row);
  return rows;
}

/** Valor do banco em centavos: "123.45", "-1234.5", "R$ 1.234,56", "1234,56". */
export function parseBankAmount(raw: string): number | null {
  let s = raw.replace(/R\$|\s/g, "");
  const negative = s.startsWith("-") || /^\(.*\)$/.test(s);
  s = s.replace(/^[-+(]|\)$/g, "");
  if (/^\d{1,3}(\.\d{3})*,\d{1,2}$|^\d+,\d{1,2}$/.test(s)) s = s.replace(/\./g, "").replace(",", ".");
  else if (/^\d{1,3}(,\d{3})*\.\d{1,2}$/.test(s)) s = s.replace(/,/g, "");
  if (!/^\d+(\.\d{1,2})?$/.test(s)) return null;
  const [int, frac = ""] = s.split(".");
  const cents = Number(int) * 100 + Number((frac + "00").slice(0, 2));
  return negative ? -cents : cents;
}

function parseBankDate(raw: string): string | null {
  const s = raw.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
  const m = s.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);
  return m ? `${m[3]}-${m[2]}-${m[1]}` : null;
}

const PARCEL = /\s*[-–—]?\s*Parcela\s+(\d{1,2})\s*\/\s*(\d{1,2})\s*$/i;

export function parseInvoiceCsv(text: string): ParsedInvoice {
  const clean = text.replace(/^﻿/, "");
  const firstLine = clean.split(/\r?\n/, 1)[0] ?? "";
  const sep = (firstLine.match(/;/g)?.length ?? 0) > (firstLine.match(/,/g)?.length ?? 0) ? ";" : ",";
  const rows = splitCsv(clean, sep);
  if (rows.length === 0) throw new InvoiceFormatError("Arquivo vazio.");
  const header = rows[0].map((h) => h.trim().toLowerCase());
  const col = (...names: string[]) => header.findIndex((h) => names.includes(h));
  const iDate = col("date", "data");
  const iTitle = col("title", "descrição", "descricao", "lançamento", "lancamento", "estabelecimento");
  const iAmount = col("amount", "valor", "valor (r$)");
  if (iDate < 0 || iTitle < 0 || iAmount < 0) {
    throw new InvoiceFormatError("Formato não reconhecido: esperado um CSV de fatura com data, descrição e valor.");
  }

  const seen = new Map<string, number>();
  const lines: InvoiceLine[] = [];
  rows.slice(1).forEach((r, idx) => {
    const date = parseBankDate(r[iDate] ?? "");
    const title = (r[iTitle] ?? "").trim();
    const amount = parseBankAmount(r[iAmount] ?? "");
    if (!date || !title || amount === null) {
      throw new InvoiceFormatError(`Linha ${idx + 2} não pôde ser lida (data, descrição ou valor).`);
    }
    if (amount === 0) return;
    const base = `${date}|${title}|${amount}`;
    const occurrence = (seen.get(base) ?? 0) + 1;
    seen.set(base, occurrence);
    const parcel = title.match(PARCEL);
    const description = parcel ? title.replace(PARCEL, "").trim() : title;
    const kind: InvoiceLine["kind"] = amount < 0
      ? (/pagamento/i.test(title) ? "payment" : "credit")
      : parcel ? "installment" : "purchase";
    lines.push({
      index: idx, date, title, description: description || title, amountCents: Math.abs(amount), kind,
      ...(parcel ? { k: Number(parcel[1]), n: Number(parcel[2]) } : {}),
      key: `${base}|${occurrence}`,
    });
  });
  return { lines, format: header.join(",") };
}

/** Vencimento (AAAA-MM) pelo nome do arquivo do Nubank: "Nubank_2026-11-05.csv". */
export function dueMonthFromFileName(name: string): string | null {
  const m = name.match(/(\d{4})-(\d{2})-\d{2}/);
  return m ? `${m[1]}-${m[2]}` : null;
}
