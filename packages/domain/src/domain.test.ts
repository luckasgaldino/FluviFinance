import { describe, expect, it } from "vitest";
import { addMonths, businessToday, formatBRL, formatDate, monthLabel, monthRange, monthStart, parseBRL, splitCents } from "./index";

describe("parseBRL", () => {
  it.each([
    ["1.234,56", 123456], ["1234,56", 123456], ["1234,5", 123450], ["1234", 123400],
    ["0,99", 99], ["R$ 12,30", 1230], [" 70 ", 7000], ["1.000.000,00", 100000000], ["0", 0],
  ])("%s → %d centavos", (input, cents) => expect(parseBRL(input)).toBe(cents));

  it.each(["", "abc", "-10", "1,234", "12,345", "1.23,45", "1,2,3", "12.5", "1e3", "١٢"])("recusa %s", (input) =>
    expect(parseBRL(input)).toBeNull());

  it("não perde centavos em valores que o float erra (0,1 + 0,2)", () => {
    expect(parseBRL("0,10")! + parseBRL("0,20")!).toBe(30);
  });

  it("recusa valores além do inteiro seguro", () => {
    expect(parseBRL("999999999999999999999")).toBeNull();
  });
});

describe("formatBRL", () => {
  it.each([[123456, "R$ 1.234,56"], [5, "R$ 0,05"], [0, "R$ 0,00"], [-500, "−R$ 5,00"], [100000000, "R$ 1.000.000,00"]])(
    "%d → %s", (cents, text) => expect(formatBRL(cents)).toBe(text));
  it("ida e volta", () => expect(parseBRL(formatBRL(987654))).toBe(987654));
});

describe("splitCents (igual ao banco, MB-05)", () => {
  it("R$ 100 em 3x = 33,34 + 33,33 + 33,33", () => expect(splitCents(10000, 3)).toEqual([3334, 3333, 3333]));
  it("R$ 1.200 em 6x = 6 × 200", () => expect(splitCents(120000, 6)).toEqual(Array(6).fill(20000)));
  it("soma sempre igual ao total", () => {
    for (const [t, n] of [[1, 1], [7, 3], [99999, 48], [80000, 3]]) {
      expect(splitCents(t, n).reduce((a, b) => a + b, 0)).toBe(t);
    }
  });
  it("recusa parcelas fora de 1..48", () => expect(() => splitCents(100, 49)).toThrow());
});

describe("datas de negócio (America/Sao_Paulo)", () => {
  it("hoje no fuso de São Paulo, não em UTC", () => {
    // 02:00 UTC de 16/10 ainda é 15/10 em São Paulo (UTC−3)
    expect(businessToday(new Date("2026-10-16T02:00:00Z"))).toBe("2026-10-15");
  });
  it("competência e mês", () => {
    expect(monthStart("2026-10-15")).toBe("2026-10-01");
    expect(monthRange("2028-02-10")).toEqual({ from: "2028-02-01", to: "2028-02-29" });
    expect(addMonths("2026-12-01", 1)).toBe("2027-01-01");
    expect(addMonths("2026-01-01", -1)).toBe("2025-12-01");
    expect(monthLabel("2026-10-01")).toBe("outubro de 2026");
    expect(formatDate("2026-10-02")).toBe("02/10/2026");
  });
});
