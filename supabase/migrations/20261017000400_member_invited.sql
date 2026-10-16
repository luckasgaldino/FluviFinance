-- Remodelagem v2.2 — R5: estado "convidado" do vínculo com a família (§2: entrar numa família
-- exige convite e aceite). Em migration própria: um valor novo de enum não pode ser usado na
-- mesma transação em que é criado. Valor aditivo (não é removido em reversões).
alter type public.member_status add value if not exists 'invited' before 'active';
