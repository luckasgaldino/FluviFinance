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

## OFX do Nubank (arquivo real enviado pelo responsável em 16/10)

O arquivo foi inspecionado **só na estrutura**: tags, formatos e contagens, com dígitos e textos mascarados. Nenhum valor ou descrição foi lido ou copiado, e os testes usam um OFX **fictício** de mesma estrutura. O que se aprendeu:

- OFX de **fatura de cartão** (`CREDITCARDMSGSRSV1`), SGML com tags fechadas, `DTPOSTED` em `AAAAMMDDhhmmss[-3:BRT]`.
- **Compras vêm negativas** (`DEBIT`); pagamento e estorno vêm positivos (`CREDIT`).
- O `FITID` serve de chave de deduplicação, mas **o banco às vezes o repete**: 47 FITIDs para 48 lançamentos. A repetição ganha um sufixo estável (`#2`).
- **"Parcelamento de Fatura (…) - k/n"** é a fatura anterior parcelada: **dívida rolada, nunca consumo novo**. Ela entra sempre como saldo anterior, inclusive na parcela 1. Migration `20261017001000_import_financing.sql`.
- Conferência no arquivo real, só com contagens: 48 lidos (35 compras, 10 parcelas, 1 parcelamento de fatura, 1 pagamento, 1 estorno), 48 chaves únicas, vencimento 2026-01 pelo nome do arquivo.

**Correções encontradas pelos testes:**
- reenviar o arquivo logo após importar usava a lista antiga do cache e não marcava "já importado" (o servidor já ignorava). Agora a tela relê o estado no momento em que o arquivo é escolhido;
- a sugestão de categoria podia sair vazia se o arquivo fosse escolhido antes de as categorias carregarem. Agora ela é calculada com os dados atualizados.

**Deploy:** a execução automatizada de deploy desta branch aplicou no fluvi-dev **as duas migrações** (`…0900` e `…1000`, que já estava pronta na pasta), com backup e restauração antes (`2026-10-16T14-11-38-686Z`, PASS com 437 pgTAP) e **pgTAP hospedado 464/464 PASS**. A publicação do site ficou para depois do commit desta correção.
