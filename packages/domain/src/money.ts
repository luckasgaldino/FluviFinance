// Dinheiro em centavos inteiros (bigint no banco; number seguro aqui).
// Nunca usa ponto flutuante para valores monetários (§6): a entrada é tratada como texto.

const MAX_CENTS = Number.MAX_SAFE_INTEGER;

/**
 * Converte o texto digitado pelo usuário (padrão brasileiro) em centavos.
 * Aceita "1.234,56", "1234,5", "1234", "R$ 12,30", " 0,99 ".
 * Recusa: vazio, negativo, mais de 2 casas decimais, separadores ambíguos, letras.
 * Devolve null quando o texto não é um valor válido.
 */
export function parseBRL(input: string): number | null {
  const s = input.replace(/\s|R\$/g, "");
  if (!/^\d{1,3}(\.\d{3})*(,\d{1,2})?$|^\d+(,\d{1,2})?$/.test(s)) return null;
  const [intPart, decPart = ""] = s.replace(/\./g, "").split(",");
  const cents = BigInt(intPart) * 100n + BigInt(decPart.padEnd(2, "0"));
  if (cents > BigInt(MAX_CENTS)) return null;
  return Number(cents);
}

/** Formata centavos como moeda brasileira: 123456 → "R$ 1.234,56"; −500 → "−R$ 5,00". */
export function formatBRL(cents: number): string {
  if (!Number.isSafeInteger(cents)) throw new RangeError("centavos devem ser inteiro seguro");
  const sign = cents < 0 ? "−" : "";
  const abs = BigInt(Math.abs(cents));
  const int = (abs / 100n).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  const dec = (abs % 100n).toString().padStart(2, "0");
  return `${sign}R$ ${int},${dec}`;
}

/** Mesma distribuição do banco (MB-05): quociente para todas, resto nas primeiras. */
export function splitCents(total: number, parts: number): number[] {
  if (!Number.isSafeInteger(total) || total <= 0) throw new RangeError("total inválido");
  if (!Number.isInteger(parts) || parts < 1 || parts > 48) throw new RangeError("parcelas devem ser de 1 a 48");
  const q = Math.floor(total / parts);
  const r = total % parts;
  return Array.from({ length: parts }, (_, i) => q + (i < r ? 1 : 0));
}
