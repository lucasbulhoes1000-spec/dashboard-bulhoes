// Gera o módulo "legado" (código do Apps Script adaptado) para a função crm-rotinas
const acorn=require('acorn'),walk=require('acorn-walk'),fs=require('fs');
const src=fs.readFileSync('/home/claude/apps-script/Codigo.gs','utf8');
const ast=acorn.parse(src,{ecmaVersion:2020,allowReturnOutsideFunction:true});
const decl={};for(const n of ast.body){if(n.type==='FunctionDeclaration')decl[n.id.name]=n;else if(n.type==='VariableDeclaration')for(const d of n.declarations)decl[d.id.name]=n;}
const roots=process.argv.slice(2);
const SHIMS=new Set(['UrlFetchApp','PropertiesService','CacheService','Utilities','Session','Logger','LockService','ContentService','SpreadsheetApp','ScriptApp','MailApp']);
const IO_DIRETO=new Set(['supabaseGet','supabasePatch','supabaseUpsert','supabasePost','supabaseDelete']);
// dependências
const usados=new Set();const fila=[...roots];
while(fila.length){const k=fila.pop();if(usados.has(k)||!decl[k])continue;usados.add(k);
  walk.full(decl[k],n=>{if(n.type==='Identifier'&&decl[n.name]&&!usados.has(n.name))fila.push(n.name);});}
// quem faz I/O (direto ou indireto)
const chama={};for(const k of usados){chama[k]=new Set();walk.full(decl[k],n=>{if(n.type==='CallExpression'){const c=n.callee;
  if(c.type==='Identifier')chama[k].add(c.name);
  if(c.type==='MemberExpression'&&c.object.type==='Identifier'&&c.object.name==='UrlFetchApp')chama[k].add('UrlFetchApp');
  if(c.type==='MemberExpression'&&c.object.type==='Identifier'&&(c.object.name==='CacheService'))chama[k].add('CacheService');}});}
const io=new Set();let mudou=true;
while(mudou){mudou=false;for(const k of usados){if(io.has(k))continue;for(const c of chama[k]){if(IO_DIRETO.has(c)||c==='UrlFetchApp'||io.has(c)){io.add(k);mudou=true;break;}}}}
// edições: async nas funções de I/O, await nas chamadas de I/O
const ed=[];const problemas=[];
for(const k of usados){const n=decl[k];if(n.type!=='FunctionDeclaration')continue;
  if(io.has(k))ed.push([n.start,'async ']);
  walk.ancestor(n,{CallExpression(c,anc){
    const cal=c.callee;let ehIO=false;
    if(cal.type==='Identifier'&&(io.has(cal.name)||IO_DIRETO.has(cal.name)))ehIO=true;
    if(cal.type==='MemberExpression'&&cal.object.type==='Identifier'&&cal.object.name==='UrlFetchApp')ehIO=true;
    if(cal.type==='MemberExpression'&&cal.object.type==='MemberExpression'&&cal.object.object&&cal.object.object.name==='CacheService')ehIO=true;
    if(!ehIO)return;
    // função mais próxima que contém a chamada
    let f=null;for(let i=anc.length-2;i>=0;i--){const a=anc[i];if(/Function/.test(a.type)){f=a;break;}}
    if(f!==n)problemas.push(k+': chamada de I/O dentro de função interna (linha '+src.slice(0,c.start).split('\n').length+')');
    ed.push([c.start,'(await ']);ed.push([c.end,')']);
  }});
}
let partes=[];
const ordem=[...usados].map(k=>decl[k]).filter((n,i,a)=>a.indexOf(n)===i).sort((a,b)=>a.start-b.start);
for(const n of ordem){let txt=src.slice(n.start,n.end);
  const eds=ed.filter(e=>e[0]>=n.start&&e[0]<=n.end).sort((a,b)=>b[0]-a[0]||(a[1]===')'?-1:1));
  for(const [p,t] of eds){const q=p-n.start;txt=txt.slice(0,q)+t+txt.slice(q);}
  partes.push(txt);}
let out=partes.join('\n\n');
// datas: meia-noite de Brasília (o Apps Script roda no fuso da clínica)
out=out.replace(/new Date\(([^()]*?) \+ 'T00:00:00'\)/g,"new Date($1 + 'T00:00:00-03:00')");
out=out.replace(/new Date\(([^()]*?) \+ 'T12:00'\)/g,"new Date($1 + 'T12:00:00-03:00')");
fs.writeFileSync('legado.js',out);
const multi=[...out.matchAll(/new Date\(([^()]|\([^()]*\))*,([^()]|\([^()]*\))*\)/g)].map(m=>m[0]);
console.log(JSON.stringify({funcoes:[...usados].length,io:[...io],problemas,datasComVariosArgs:multi,shims:[...new Set([...out.matchAll(/\b(UrlFetchApp|PropertiesService|CacheService|Utilities|Session|Logger|LockService|ContentService|SpreadsheetApp|ScriptApp|MailApp)\.\w+/g)].map(m=>m[0]))]},null,1));
