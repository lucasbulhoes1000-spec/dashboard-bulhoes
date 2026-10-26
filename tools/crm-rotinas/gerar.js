// Gera o módulo "legado" (código do Apps Script adaptado) para a função crm-rotinas.
// Uso: node gerar.js <funções raiz...>   (lê /home/claude/apps-script/Codigo.gs)
const acorn=require('acorn'),walk=require('acorn-walk'),fs=require('fs');
const src=fs.readFileSync(process.env.CODIGO_GS||'/home/claude/apps-script/Codigo.gs','utf8');
const ast=acorn.parse(src,{ecmaVersion:2020,allowReturnOutsideFunction:true});
const decl={};for(const n of ast.body){if(n.type==='FunctionDeclaration')decl[n.id.name]=n;else if(n.type==='VariableDeclaration')for(const d of n.declarations)decl[d.id.name]=n;}
const roots=process.argv.slice(2);
const IO_DIRETO=new Set(['supabaseGet','supabasePatch','supabaseUpsert','supabasePost','supabaseDelete']);
const ehFn=n=>/Function/.test(n.type);
// dependências
const usados=new Set();const fila=[...roots];
while(fila.length){const k=fila.pop();if(usados.has(k)||!decl[k])continue;usados.add(k);
  walk.full(decl[k],n=>{if(n.type==='Identifier'&&decl[n.name]&&!usados.has(n.name))fila.push(n.name);});}
const nos=[...new Set([...usados].map(k=>decl[k]))].sort((a,b)=>a.start-b.start);
// funções internas nomeadas (function x(){} dentro de outra) também podem fazer I/O
const nomeDe=new Map();// nó de função -> nome (top-level ou interna)
for(const n of nos){if(n.type==='FunctionDeclaration')nomeDe.set(n,n.id.name);
  walk.full(n,m=>{if(m!==n&&m.type==='FunctionDeclaration')nomeDe.set(m,'interna:'+m.id.name+'@'+m.start);});}
const internasPorNome={};for(const [m,nm] of nomeDe)if(nm.startsWith('interna:'))(internasPorNome[m.id.name]=internasPorNome[m.id.name]||[]).push(m);
function ehChamadaIO(c,io){const cal=c.callee;
  if(cal.type==='Identifier'&&(IO_DIRETO.has(cal.name)||io.has(cal.name)))return true;
  if(cal.type==='MemberExpression'&&cal.object.type==='Identifier'&&cal.object.name==='UrlFetchApp')return true;
  return false;}
// fixpoint: nomes (top-level ou internos) que fazem I/O
const io=new Set();let mudou=true;
while(mudou){mudou=false;
  for(const [fnode,nm] of nomeDe){const nome=fnode.id.name;if(io.has(nome))continue;
    let faz=false;walk.ancestor(fnode,{CallExpression(c,anc){if(faz)return;if(!ehChamadaIO(c,io))return;
      // conta se a chamada está nesta função (ou em callback de forEach dentro dela)
      faz=true;}});
    if(faz){io.add(nome);mudou=true;}}}
// edições de texto
const ed=[];const problemas=[];
function fnMaisProxima(anc){for(let i=anc.length-2;i>=0;i--)if(ehFn(anc[i]))return [anc[i],i];return [null,-1];}
for(const n of nos){
  walk.ancestor(n,{CallExpression(c,anc){
    if(!ehChamadaIO(c,io))return;
    ed.push([c.start,'(await ']);ed.push([c.end,')']);
    // sobe pelas funções: cada uma precisa ser async; callback de forEach vira for...of
    let i=anc.length-1;
    while(true){
      let f=null,fi=-1;for(let j=i-1;j>=0;j--)if(ehFn(anc[j])){f=anc[j];fi=j;break;}
      if(!f)break;
      if(f.type==='FunctionDeclaration'){ if(!f.async&&!f._async){f._async=true;ed.push([f.start,'async '])} break; }
      // função anônima: é callback de .forEach(...)?
      const pai=anc[fi-1];
      if(pai&&pai.type==='CallExpression'&&pai.callee.type==='MemberExpression'&&pai.callee.property.name==='forEach'&&pai.arguments[0]===f&&!f._virouFor){
        f._virouFor=true;
        const exprArr=src.slice(pai.callee.object.start,pai.callee.object.end);
        const ps=f.params.map(p=>src.slice(p.start,p.end));
        const cab=ps.length>=2?`for (const [${ps[1]}, ${ps[0]}] of (${exprArr}).entries()) `:`for (const ${ps[0]||'_x'} of (${exprArr})) `;
        // troca "X.forEach(function (a) {" por "for (const a of X) {" e o ")" final
        ed.push([pai.start,'\u0000DEL'+(f.body.start-pai.start)+'\u0000'+cab]);
        ed.push([f.body.end,'\u0000DEL'+(pai.end-f.body.end)+'\u0000']);
        // return no nível do callback vira continue
        walk.ancestor(f.body,{ReturnStatement(r,a2){const [ff]=fnMaisProxima(a2.concat([r]));if(ff===null||ff===f){
          if(r.argument)problemas.push('return com valor em forEach virando for (linha '+src.slice(0,r.start).split('\n').length+')');
          ed.push([r.start,'\u0000DEL'+(r.end-r.start)+'\u0000continue;']);}}});
        i=fi; continue; // a função de fora também precisa ser async
      }
      if(!f.async&&!f._async){problemas.push('I/O dentro de função anônima que não é forEach (linha '+src.slice(0,c.start).split('\n').length+')');}
      break;
    }
  }});
}
let partes=[];
for(const n of nos){let txt=src.slice(n.start,n.end);
  const eds=ed.filter(e=>e[0]>=n.start&&e[0]<=n.end).sort((a,b)=>b[0]-a[0]||(a[1]===')'?-1:1));
  for(const [p,t] of eds){const q=p-n.start;
    const m=/^\u0000DEL(\d+)\u0000([\s\S]*)$/.exec(t);
    if(m)txt=txt.slice(0,q)+m[2]+txt.slice(q+Number(m[1]));else txt=txt.slice(0,q)+t+txt.slice(q);}
  partes.push(txt);}
let out=partes.join('\n\n');
out=out.replace(/new Date\(([^()]*?) \+ 'T00:00:00'\)/g,"new Date($1 + 'T00:00:00-03:00')");
out=out.replace(/new Date\(([^()]*?) \+ 'T12:00'\)/g,"new Date($1 + 'T12:00:00-03:00')");
fs.writeFileSync('legado.js',out);
const multi=[...out.matchAll(/new Date\(([^()]|\([^()]*\))*,([^()]|\([^()]*\))*\)/g)].map(m=>m[0]);
const sheet=[...out.matchAll(/SpreadsheetApp|ScriptApp|MailApp|DriveApp/g)].length;
console.log(JSON.stringify({funcoes:usados.size,io:[...io],problemas,datasComVariosArgs:multi,usaPlanilha:sheet},null,1));
