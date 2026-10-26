# Gerador da função crm-rotinas

`crm-rotinas/index.ts` é montado assim (Codigo.gs = código do Apps Script):

    npm i acorn@8.12.1 acorn-walk@8.3.4
    node gerar.js <funções raiz...>      # gera legado.js a partir do Codigo.gs
    cat prelude.ts legado.js fim.ts > ../../supabase/functions/crm-rotinas/index.ts

O gerador copia as funções pedidas e tudo de que elas dependem, põe `await` nas
chamadas externas e acerta as datas para o fuso de Brasília. O `prelude.ts`
imita o ambiente do Apps Script e transforma a gravação do CRM em patch.
