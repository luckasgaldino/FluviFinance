# Evidência — Fase 2, parte 2: importação de fatura de cartão

**Data:** 16/10/2026 · **Branch:** `fase2/importar-fatura`
**Escopo combinado com o responsável:** ele envia só **faturas de cartão** (as antigas e as novas quando fecharem). **Pagamentos e saldos ficam com ele**: a importação não lança pagamento nem mexe em conta.

## O que entrou

- **Leitura no aparelho** (`packages/domain/src/invoice.ts`). O CSV de fatura do Nubank é lido ali; **o arquivo não é enviado nem guardado**. Aceita:
  - `date,title,amount` e `date,category,title,amount`;
  - vírgula ou ponto e vírgula como separador, valor com ponto ou vírgula, data ISO ou dd/mm/aaaa, aspas.

  O leitor também:
  - reconhece "Parcela k/n";
  - separa pagamentos e estornos, que são ignorados;
  - gera uma chave estável por linha;
  - tira o vencimento do nome do arquivo (`Nubank_AAAA-MM-DD.csv`).
- **Migration `20261017000900_card_invoice_import.sql`:** tabela `card_import_lines`, que só pode ser lida pela família, não aceita escrita direta e não deixa apagar. RPC `import_card_invoice(cartão, vencimento, linhas)` numa única operação idempotente, que exige desbloqueio. Tratamento de cada linha:
  - **compra comum:** compra no cartão na **fatura escolhida**, com consumo na competência;
  - **parcela 1/n:** compra parcelada inteira; as próximas parcelas já ficam nas faturas seguintes;
  - **parcela k/n já prevista:** **reconhecida**, nada é lançado de novo;
  - **parcela k/n de compra anterior ao histórico:** **saldo anterior** só com as parcelas restantes (dívida, não consumo);
  - **mesma linha reenviada:** ignorada;
  - **linha nova em fatura que já está fechada no app:** recusada;
  - ao final, a fatura é **fechada** e fica pronta para pagamento.
- **Tela "Importar fatura"** (na tela do cartão):
  - vencimento pré-preenchido;
  - categoria sugerida pelo histórico da família e por palavras-chave;
  - linhas já importadas desmarcadas;
  - **possível duplicado** de lançamento manual (mesmo valor, até 3 dias de diferença) desmarcado;
  - total do que vai entrar;
  - resumo depois de importar.

## Testes

| Suíte | Resultado |
|---|---|
| Unitários | **51/51** (18 novos do leitor: valores, formatos, parcelas, aspas, pagamentos, chaves estáveis, erros) |
| pgTAP | nova `14_fase2_import` (24): duas faturas seguidas (criar, reconhecer parcelas, saldo anterior), consumo correto, dívida e EQ-1, fechamento, reimportação, validações, atomicidade, desbloqueio, isolamento |
| E2E | novo `import-flow`: prévia, pagamento ignorado, possível duplicado desmarcado, categoria sugerida, importação, reimportação sem gravar nada |

**Bateria local:** pgTAP **461/461** (14 arquivos), integração 58/58, E2E **59/59**, unitários **51/51**, build e `db lint` sem avisos, restauração **PASS** (461 pgTAP).
