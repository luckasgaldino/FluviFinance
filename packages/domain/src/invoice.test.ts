import { describe, expect, it } from "vitest";
import { dueMonthFromFileName, InvoiceFormatError, parseBankAmount, parseInvoiceCsv, parseInvoiceFile, parseInvoiceOfx } from "./invoice";

describe("parseBankAmount", () => {
  it.each([
    ["123.45", 12345], ["-123.45", -12345], ["1234.5", 123450], ["R$ 1.234,56", 123456], ["1234,56", 123456],
    ["1,234.56", 123456], ["0.01", 1], ["(10.00)", -1000],
  ])("%s → %d", (raw, cents) => expect(parseBankAmount(raw)).toBe(cents));
  it("recusa texto", () => expect(parseBankAmount("abc")).toBeNull());
});

describe("parseInvoiceCsv (Nubank)", () => {
  const csv = [
    "date,title,amount",
    "2026-10-10,Mercado Bom Preço,100.00",
    "2026-10-12,Loja TV - Parcela 1/3,200.00",
    "2026-06-20,Notebook - Parcela 4/6,150.00",
    "2026-10-15,\"Restaurante, Bar e Cia\",45.90",
    "2026-10-20,Pagamento recebido,-500.00",
    "2026-10-21,Estorno Loja X,-30.00",
    "2026-10-22,Uber,12.30",
    "2026-10-22,Uber,12.30",
  ].join("\n");
  const { lines } = parseInvoiceCsv(csv);

  it("lê compras, parcelas, pagamento e estorno", () => {
    expect(lines.map((l) => l.kind)).toEqual(
      ["purchase", "installment", "installment", "purchase", "payment", "credit", "purchase", "purchase"]);
  });
  it("separa a parcela da descrição", () => {
    expect(lines[1]).toMatchObject({ description: "Loja TV", k: 1, n: 3, amountCents: 20000 });
    expect(lines[2]).toMatchObject({ description: "Notebook", k: 4, n: 6 });
  });
  it("respeita aspas com vírgula", () => expect(lines[3].description).toBe("Restaurante, Bar e Cia"));
  it("valores sempre positivos; o tipo diz se é débito", () => expect(lines[4].amountCents).toBe(50000));
  it("linhas idênticas no mesmo dia têm chaves diferentes", () => {
    expect(lines[6].key).not.toBe(lines[7].key);
    expect(parseInvoiceCsv(csv).lines.map((l) => l.key)).toEqual(lines.map((l) => l.key));   // estável
  });
  it("formato antigo com categoria, ponto e vírgula e data brasileira", () => {
    const old = parseInvoiceCsv("date;category;title;amount\n10/10/2026;supermercado;Mercado;1.234,56\n");
    expect(old.lines[0]).toMatchObject({ date: "2026-10-10", description: "Mercado", amountCents: 123456 });
  });
  it("recusa formato desconhecido", () => {
    expect(() => parseInvoiceCsv("foo,bar\n1,2")).toThrow(InvoiceFormatError);
  });
  it("aponta a linha ilegível", () => {
    expect(() => parseInvoiceCsv("date,title,amount\n2026-13-99x,Loja,10")).toThrow(/Linha 2/);
  });
});

it("vencimento pelo nome do arquivo do Nubank", () => {
  expect(dueMonthFromFileName("Nubank_2026-11-05.csv")).toBe("2026-11");
  expect(dueMonthFromFileName("fatura.csv")).toBeNull();
});

describe("parseInvoiceOfx (fatura de cartão, estrutura do Nubank; dados fictícios)", () => {
  const trn = (type: string, dt: string, amt: string, id: string, memo: string) =>
    `<STMTTRN>\n<TRNTYPE>${type}</TRNTYPE>\n<DTPOSTED>${dt}000000[-3:BRT]</DTPOSTED>\n<TRNAMT>${amt}</TRNAMT>\n<FITID>${id}</FITID>\n<MEMO>${memo}\n</STMTTRN>`;
  const ofx = [
    "OFXHEADER:100", "DATA:OFXSGML", "VERSION:102", "", "<OFX>", "<CREDITCARDMSGSRSV1>", "<CCSTMTTRNRS>", "<CCSTMTRS>",
    "<BANKTRANLIST>",
    trn("DEBIT", "20261010", "-100.00", "id-mercado", "Mercado Fictício"),
    trn("DEBIT", "20261012", "-200.00", "id-tv", "Loja Fictícia - Parcela 1/3"),
    trn("DEBIT", "20261013", "-350.75", "id-fin", "Parcelamento de Fatura (2/Novembro) - 2/6"),
    trn("CREDIT", "20261020", "500.00", "id-pag", "Pagamento recebido"),
    trn("CREDIT", "20261021", "30.00", "id-est", "Estorno de Loja Fictícia"),
    "</BANKTRANLIST>", "</CCSTMTRS>", "</CCSTMTTRNRS>", "</CREDITCARDMSGSRSV1>", "</OFX>",
  ].join("\r\n");
  const { lines } = parseInvoiceOfx(ofx);

  it("débitos negativos viram compras; créditos viram pagamento/estorno", () => {
    expect(lines.map((l) => l.kind)).toEqual(["purchase", "installment", "installment", "payment", "credit"]);
    expect(lines[0]).toMatchObject({ date: "2026-10-10", amountCents: 10000, description: "Mercado Fictício" });
  });
  it("parcela e FITID como chave", () => {
    expect(lines[1]).toMatchObject({ description: "Loja Fictícia", k: 1, n: 3, key: "ofx|id-tv" });
  });
  it("parcelamento de fatura é dívida rolada, nunca consumo", () => {
    expect(lines[2]).toMatchObject({ kind: "installment", debtOnly: true, k: 2, n: 6, amountCents: 35075 });
    expect(lines[2].description).toBe("Parcelamento de Fatura (2/Novembro)");
  });
  it("detecta o formato pelo conteúdo", () => {
    expect(parseInvoiceFile(ofx).format).toBe("ofx-cartao");
    expect(parseInvoiceFile("date,title,amount\n2026-10-10,X,1.00").lines).toHaveLength(1);
  });
  it("recusa OFX de extrato de conta", () => {
    expect(() => parseInvoiceOfx("<OFX><BANKMSGSRSV1></BANKMSGSRSV1></OFX>")).toThrow(/não é de fatura/);
  });
});

it("OFX com FITID repetido gera chaves distintas e estáveis", () => {
  const t = (id: string, memo: string) => `<STMTTRN>\n<TRNTYPE>DEBIT\n<DTPOSTED>20261010000000[-3:BRT]\n<TRNAMT>-10.00\n<FITID>${id}\n<MEMO>${memo}\n</STMTTRN>`;
  const ofx = `<OFX><CREDITCARDMSGSRSV1>${t("dup", "A")}${t("dup", "B")}${t("uniq", "C")}</CREDITCARDMSGSRSV1></OFX>`;
  const keys = parseInvoiceOfx(ofx).lines.map((l) => l.key);
  expect(keys).toEqual(["ofx|dup", "ofx|dup#2", "ofx|uniq"]);
  expect(parseInvoiceOfx(ofx).lines.map((l) => l.key)).toEqual(keys);
});
