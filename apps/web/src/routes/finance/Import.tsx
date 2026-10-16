// Importar fatura de cartão (Fase 2): o CSV do banco é lido no aparelho (não é enviado nem
// guardado). Prévia com categoria sugerida, deduplicação (linhas já importadas e possíveis
// duplicados de lançamentos manuais) e parcelas reconhecidas. Pagamentos e estornos ficam de fora.
import { dueMonthFromFileName, formatBRL, formatDate, InvoiceFormatError, parseInvoiceCsv, type InvoiceLine } from "@fluvi/domain";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useMemo, useState, type ChangeEvent } from "react";
import { Link, useParams } from "react-router";
import { Alert, PageTitle } from "../../components/ui";
import { rpc, type Card, type Category } from "../../lib/api";
import { errorMessage } from "../../lib/errors";
import { useFamilyId } from "../../lib/family";
import { supabase } from "../../lib/supabase";

type Row = InvoiceLine & { hash: string; include: boolean; category: string; imported: boolean; duplicate: boolean };
type Existing = { id: string; description: string; local_date: string; category_id: string | null; amount: number; imported: boolean };
type ImportResult = { created: number; matched: number; skipped: number; invoice_cents: number; closed: boolean };

// palavras-chave → categoria padrão (o histórico da família tem prioridade)
const KEYWORDS: [RegExp, string][] = [
  [/uber|99 ?(app|pop|taxi)|cabify|posto|shell|ipiranga|petrobras|estacionamento|sem ?parar|veloe|conectcar|pedagio|pedágio/i, "Transporte"],
  [/ifood|rappi|restaurante|lanchonete|padaria|pizzaria|burger|mc ?donald|bk |outback|cafe|café|bar /i, "Alimentação fora"],
  [/mercado|supermerc|atacad|assai|assaí|carrefour|pão de açúcar|pao de acucar|hortifruti|sacolão|sacolao/i, "Mercado"],
  [/farmacia|farmácia|drogaria|droga ?raia|drogasil|pague menos|hospital|clinica|clínica|laborat/i, "Saúde"],
  [/netflix|spotify|disney|hbo|max\.com|prime video|amazon prime|youtube|apple\.com|icloud|google one|deezer|globoplay/i, "Assinaturas"],
  [/iof|juros|encargo|anuidade|tarifa/i, "Impostos e taxas"],
  [/petz|cobasi|pet ?shop|veterin/i, "Pets"],
  [/escola|faculdade|curso|udemy|alura|livraria/i, "Educação"],
  [/cinema|ingresso|show|steam|playstation|xbox|nintendo/i, "Lazer"],
  [/renner|riachuelo|c&a|zara|shein|centauro|netshoes|calçad/i, "Vestuário"],
  [/luz|enel|cemig|copel|sabesp|água|agua|gás|gas |internet|vivo|claro|tim |oi /i, "Contas e serviços"],
];

const norm = (s: string) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/\s+/g, " ").trim();

async function sha256(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const daysApart = (a: string, b: string) => Math.abs(Date.parse(a) - Date.parse(b)) / 86_400_000;

export function ImportInvoice() {
  const { id } = useParams();
  const family = useFamilyId();
  const queryClient = useQueryClient();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [ignored, setIgnored] = useState<InvoiceLine[]>([]);
  const [due, setDue] = useState("");
  const [fileName, setFileName] = useState("");
  const [error, setError] = useState("");
  const [result, setResult] = useState<ImportResult | null>(null);
  const [op, setOp] = useState(() => crypto.randomUUID());

  const card = useQuery({
    queryKey: ["fin", "card", family, id],
    enabled: !!family,
    queryFn: async () => {
      const { data, error } = await supabase.from("credit_cards").select("*").eq("id", id!).eq("family_id", family).maybeSingle();
      if (error) throw error;
      return data as Card | null;
    },
  });
  const categories = useQuery({
    queryKey: ["fin", "categories", "expense", family],
    enabled: !!family,
    queryFn: async () => {
      const { data, error } = await supabase.from("categories").select("id, name, kind, family_id")
        .eq("active", true).eq("kind", "expense").or(`family_id.is.null,family_id.eq.${family}`).order("name");
      if (error) throw error;
      return data as Category[];
    },
  });
  // compras já existentes no cartão: histórico de categorias e detecção de duplicados
  const existing = useQuery({
    queryKey: ["fin", "card-existing", id],
    enabled: !!card.data,
    queryFn: async (): Promise<{ purchases: Existing[]; hashes: Set<string> }> => {
      const [p, l] = await Promise.all([
        supabase.from("card_purchases").select("transaction_id, total_cents, installment_count").eq("card_id", id!),
        supabase.from("card_import_lines").select("line_hash, transaction_id").eq("card_id", id!),
      ]);
      if (p.error) throw p.error;
      if (l.error) throw l.error;
      const ids = (p.data ?? []).map((x) => x.transaction_id as string);
      const byId = new Map((p.data ?? []).map((x) => [x.transaction_id as string, x]));
      const importedTxns = new Set((l.data ?? []).map((x) => x.transaction_id as string));
      const { data: txns, error } = ids.length
        ? await supabase.from("transactions").select("id, description, local_date, category_id, status").in("id", ids)
        : { data: [], error: null };
      if (error) throw error;
      return {
        purchases: (txns ?? []).filter((t) => t.status === "active").map((t) => {
          const pur = byId.get(t.id)!;
          return { id: t.id, description: t.description, local_date: t.local_date, category_id: t.category_id,
            amount: Math.round(Number(pur.total_cents) / Number(pur.installment_count)), imported: importedTxns.has(t.id) };
        }),
        hashes: new Set((l.data ?? []).map((x) => x.line_hash as string)),
      };
    },
  });

  const catByName = useMemo(() => new Map(categories.data?.map((c) => [norm(c.name), c.id])), [categories.data]);
  const fallback = catByName.get(norm("Outros")) ?? categories.data?.[0]?.id ?? "";

  function suggest(description: string): string {
    const past = existing.data?.purchases.find((p) => p.category_id && norm(p.description) === norm(description));
    if (past?.category_id) return past.category_id;
    const hit = KEYWORDS.find(([re]) => re.test(description));
    return (hit && catByName.get(norm(hit[1]))) || fallback;
  }

  async function onFile(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    setError(""); setResult(null); setRows(null);
    if (!file || !card.data) return;
    try {
      const { lines } = parseInvoiceCsv(await file.text());
      setFileName(file.name);
      const debits = lines.filter((l) => l.kind === "purchase" || l.kind === "installment");
      setIgnored(lines.filter((l) => l.kind === "payment" || l.kind === "credit"));
      const latest = debits.map((l) => l.date).sort().at(-1) ?? "";
      const next = latest ? new Date(Date.UTC(Number(latest.slice(0, 4)), Number(latest.slice(5, 7)), 1)).toISOString().slice(0, 7) : "";
      setDue(dueMonthFromFileName(file.name) ?? next);
      const hashes = existing.data?.hashes ?? new Set<string>();
      const manual = existing.data?.purchases.filter((p) => !p.imported) ?? [];
      setRows(await Promise.all(debits.map(async (l) => {
        const hash = await sha256(`${card.data!.id}|${l.key}`);
        const imported = hashes.has(hash);
        const duplicate = !imported && (l.kind === "purchase" || l.k === 1)
          && manual.some((p) => p.amount === l.amountCents && daysApart(p.local_date, l.date) <= 3);
        return { ...l, hash, imported, duplicate, include: !imported && !duplicate, category: suggest(l.description) };
      })));
      setOp(crypto.randomUUID());
    } catch (err) {
      setError(err instanceof InvoiceFormatError ? err.message : "Não foi possível ler o arquivo. Envie o CSV da fatura exportado pelo banco.");
    }
  }

  const selected = rows?.filter((r) => r.include && !r.imported) ?? [];
  const total = selected.reduce((s, r) => s + r.amountCents, 0);
  const update = (hash: string, patch: Partial<Row>) => setRows((rs) => rs?.map((r) => (r.hash === hash ? { ...r, ...patch } : r)) ?? null);

  const run = useMutation({
    mutationFn: () => rpc<ImportResult>("import_card_invoice", {
      p_op: op, p_card: id, p_due_month: `${due}-01`, p_close: true,
      p_lines: selected.map((r) => ({ hash: r.hash, date: r.date, description: r.description, kind: r.kind,
        k: r.k ?? null, n: r.n ?? null, amount_cents: r.amountCents, category: r.category })),
    }),
    onSuccess: (r) => {
      setResult(r);
      setRows(null);
      void queryClient.invalidateQueries({ queryKey: ["fin"] });
    },
    onError: (e) => setError(errorMessage(e)),
  });

  if (card.isLoading) return <p role="status">Carregando…</p>;
  if (!card.data) return <Alert kind="error">Cartão não encontrado ou sem permissão.</Alert>;

  return (
    <>
      <PageTitle>Importar fatura</PageTitle>
      <p className="muted">
        {card.data.name}: envie o CSV da fatura exportado pelo banco. O arquivo é lido no seu aparelho e não é enviado
        nem guardado; só os lançamentos que você confirmar são gravados. Pagamentos e estornos não são importados.
      </p>
      {result && (
        <Alert kind="success">
          Importação concluída: {result.created} lançamento(s) novo(s), {result.matched} parcela(s) reconhecida(s)
          {result.skipped > 0 && `, ${result.skipped} já importado(s)`}. Fatura de {formatBRL(Number(result.invoice_cents))}
          {result.closed ? " fechada e pronta para pagamento." : "."}{" "}
          <Link to={`/cartoes/${id}`}>Ver o cartão</Link>
        </Alert>
      )}
      <section className="card stack" aria-labelledby="arquivo">
        <h2 id="arquivo">Arquivo</h2>
        <div className="field">
          <label htmlFor="invoice-file">Fatura (CSV)</label>
          <input id="invoice-file" type="file" accept=".csv,text/csv" onChange={onFile} disabled={!existing.data || !categories.data} />
          {fileName && <span className="hint">{fileName}</span>}
        </div>
        <Alert kind="error">{error}</Alert>
      </section>

      {rows && (
        <section className="card stack" aria-labelledby="previa">
          <h2 id="previa">Prévia</h2>
          <div className="field">
            <label htmlFor="invoice-due">Vencimento da fatura</label>
            <input id="invoice-due" type="month" value={due} onChange={(e) => setDue(e.target.value)} />
            <span className="hint">Os itens entram na fatura deste vencimento, que é fechada ao final.</span>
          </div>
          <p>
            <strong>{selected.length}</strong> de {rows.length} item(ns) selecionado(s) · total{" "}
            <span className="money">{formatBRL(total)}</span>
            {ignored.length > 0 && <span className="muted"> · {ignored.length} pagamento(s)/estorno(s) ignorado(s)</span>}
          </p>
          <ul className="list" aria-label="Itens da fatura">
            {rows.map((r) => (
              <li key={r.hash} className={`list-item ${r.imported ? "inactive" : ""}`} aria-label={r.title}>
                <label className="check" style={{ alignItems: "flex-start", flex: "1 1 220px" }}>
                  <input type="checkbox" checked={r.include && !r.imported} disabled={r.imported}
                    onChange={(e) => update(r.hash, { include: e.target.checked })} />
                  <span className="meta">
                    <strong>{r.description}</strong>
                    <span className="muted">
                      {formatDate(r.date)}
                      {r.k && ` · parcela ${r.k}/${r.n}`}
                      {r.imported && " · já importado"}
                      {r.duplicate && " · possível duplicado de lançamento manual"}
                    </span>
                  </span>
                </label>
                <div className="actions">
                  <span className="money">{formatBRL(r.amountCents)}</span>
                  {(r.kind === "purchase" || r.k === 1) && !r.imported && (
                    <select aria-label={`Categoria de ${r.description}`} value={r.category}
                      onChange={(e) => update(r.hash, { category: e.target.value })}>
                      {categories.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                    </select>
                  )}
                </div>
              </li>
            ))}
          </ul>
          <p className="muted">
            Parcela 1/n cria a compra inteira e já coloca as próximas parcelas nas faturas seguintes. Parcela de compra
            anterior às faturas importadas entra como saldo anterior (não vira gasto do mês). Parcelas já previstas são
            reconhecidas e não são lançadas de novo.
          </p>
          <div className="row" style={{ alignItems: "center" }}>
            <button className="btn" type="button" disabled={run.isPending || selected.length === 0 || !/^\d{4}-\d{2}$/.test(due)}
              onClick={() => { setError(""); run.mutate(); }}>
              {run.isPending ? "Importando…" : `Importar ${selected.length} item(ns) e fechar a fatura`}
            </button>
            <Link to={`/cartoes/${id}`}>Cancelar</Link>
          </div>
        </section>
      )}
    </>
  );
}
