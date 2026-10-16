// Leitura de fatura de cartão exportada pelo banco. Roda no aparelho: o arquivo não é enviado
// nem guardado; só os lançamentos confirmados na prévia são gravados.
// Formatos aceitos: OFX de fatura de cartão (Nubank) e CSV "date,title,amount" ou
// "date,category,title,amount" (separador vírgula ou ponto e vírgula; valor com ponto ou vírgula;
// data AAAA-MM-DD ou DD/MM/AAAA).

export type InvoiceLine = {
  /** posição no arquivo */
  index: number;
  date: string;                 // AAAA-MM-DD
  title: string;                // como veio do banco
  description: string;          // sem o sufixo de parcela
  amountCents: number;          // sempre positivo; o tipo diz se é débito na fatura
  kind: "purchase" | "installment" | "payment" | "credit";
  k?: number;
  n?: number;
  /** parcelamento da fatura anterior: dívida rolada, nunca consumo novo */
  debtOnly?: boolean;
  /** chave estável para deduplicação (FITID no OFX; data, título, valor e ocorrência no CSV) */
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
// "Parcelamento de Fatura (…) - 2/6": a fatura anterior parcelada (dívida rolada, já consumida)
const FINANCING = /^(Parcelamento de Fatura.*?)\s*[-–—]\s*(\d{1,2})\s*\/\s*(\d{1,2})\s*$/i;

/** Classifica uma linha; `amount` positivo = débito na fatura, negativo = crédito. */
function classify(index: number, date: string, title: string, amount: number, key: string): InvoiceLine {
  const financing = title.match(FINANCING);
  if (financing && amount > 0) {
    return { index, date, title, description: financing[1].trim(), amountCents: amount, kind: "installment",
      k: Number(financing[2]), n: Number(financing[3]), debtOnly: true, key };
  }
  const parcel = amount > 0 ? title.match(PARCEL) : null;
  const description = (parcel ? title.replace(PARCEL, "").trim() : title) || title;
  const kind: InvoiceLine["kind"] = amount < 0
    ? (/pagamento/i.test(title) ? "payment" : "credit")
    : parcel ? "installment" : "purchase";
  return { index, date, title, description, amountCents: Math.abs(amount), kind,
    ...(parcel ? { k: Number(parcel[1]), n: Number(parcel[2]) } : {}), key };
}

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
    lines.push(classify(idx, date, title, amount, `${base}|${occurrence}`));
  });
  return { lines, format: header.join(",") };
}

const ofxField = (block: string, tag: string) =>
  block.match(new RegExp(`<${tag}>([^<\\r\\n]*)`, "i"))?.[1]?.trim() ?? "";

/** OFX de fatura de cartão: débitos (compras) vêm negativos; créditos (pagamento, estorno) positivos. */
export function parseInvoiceOfx(text: string): ParsedInvoice {
  if (!/<CREDITCARDMSGSRSV1>/i.test(text)) {
    throw new InvoiceFormatError("Este OFX não é de fatura de cartão. Envie o OFX da fatura (não o do extrato da conta).");
  }
  const blocks = text.split(/<STMTTRN>/i).slice(1).map((b) => b.split(/<\/STMTTRN>/i)[0]);
  const seen = new Map<string, number>();
  const fitSeen = new Map<string, number>();
  const lines = blocks.map((b, idx) => {
    const dt = ofxField(b, "DTPOSTED").match(/^(\d{4})(\d{2})(\d{2})/);
    const raw = parseBankAmount(ofxField(b, "TRNAMT"));
    const title = ofxField(b, "MEMO") || ofxField(b, "NAME");
    if (!dt || raw === null || !title) throw new InvoiceFormatError(`Lançamento ${idx + 1} do OFX não pôde ser lido.`);
    const date = `${dt[1]}-${dt[2]}-${dt[3]}`;
    const fitid = ofxField(b, "FITID");
    // o banco às vezes repete o FITID: a repetição ganha um sufixo (estável na reexportação)
    const fitCount = fitid ? (fitSeen.get(fitid) ?? 0) + 1 : 0;
    if (fitid) fitSeen.set(fitid, fitCount);
    const base = `${date}|${title}|${raw}`;
    const occurrence = (seen.get(base) ?? 0) + 1;
    seen.set(base, occurrence);
    return classify(idx, date, title, -raw,
      fitid ? (fitCount > 1 ? `ofx|${fitid}#${fitCount}` : `ofx|${fitid}`) : `${base}|${occurrence}`);
  }).filter((l) => l.amountCents !== 0);
  return { lines, format: "ofx-cartao" };
}

/** Escolhe o leitor pelo conteúdo (OFX ou CSV). */
export function parseInvoiceFile(text: string): ParsedInvoice {
  return /<OFX>/i.test(text) ? parseInvoiceOfx(text) : parseInvoiceCsv(text);
}

/** Vencimento (AAAA-MM) pelo nome do arquivo do Nubank: "Nubank_2026-11-05.csv" ou ".ofx". */
export function dueMonthFromFileName(name: string): string | null {
  const m = name.match(/(\d{4})-(\d{2})-\d{2}/);
  return m ? `${m[1]}-${m[2]}` : null;
}
