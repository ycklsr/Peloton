/* Checks the properties that make synchronisation unbreakable.
   The HTML file is loaded as-is: the REAL code is what gets tested. */
import fs from "node:fs";
import vm from "node:vm";

const html=fs.readFileSync(process.argv[2],"utf8");
const js=html.match(/<script[^>]*>([\s\S]*?)<\/script>/)[1];
const sandbox={console,TextDecoder,atob,Date,Math,JSON,Set,Map,setInterval:()=>0,clearInterval:()=>{}};
sandbox.globalThis=sandbox;
vm.createContext(sandbox);
vm.runInContext(js,sandbox);
const {project}=sandbox.__DUEL;

let failures=0;
const check=(name,ok)=>{console.log((ok?"  ok   ":"  FAIL ")+"  "+name);if(!ok)failures++};

/* ---- a test log: two devices that worked in parallel ---- */
const ev=(order,device,id,kind,data)=>({id,order,device,time:"",kind,data});
const A=[
  ev(1,"mac","a1","pelotonStarted",{start:"2026-08-01",exam:"2027-04-06",seed:42}),
  ev(2,"mac","a2","onboardingFinished",{}),
  ev(3,"mac","a3","sessionLogged",{id:"s1",date:"2026-08-02",min:60,mat:"fr",type:"cours",chap:null,manual:false}),
  ev(4,"mac","a4","chapterStatusSet",{id:"f1",status:1,date:"2026-08-02"}),
  ev(7,"mac","a5","chapterStatusSet",{id:"f1",status:0,date:"2026-08-05"}),
  ev(8,"mac","a6","settingChanged",{key:"refTotal",value:1200}),
];
const B=[   // the same evening, on the iPhone, without having seen the Mac
  ev(3,"phone","b1","sessionLogged",{id:"s2",date:"2026-08-02",min:45,mat:"ma",type:"exercices",chap:null,manual:false}),
  ev(4,"phone","b2","chapterStatusSet",{id:"m1",status:2,date:"2026-08-02"}),
  ev(5,"phone","b3","annaleLogged",{id:"an1",date:"2026-08-03",e1:11,e2:null}),
  ev(6,"phone","b4","sessionDeleted",{id:"s1"}),     // deletes a session logged on the Mac
];
const sortLog=l=>[...l].sort((x,y)=>x.order-y.order||(x.device<y.device?-1:x.device>y.device?1:0)||(x.id<y.id?-1:1));
const merge=(...ls)=>{const seen=new Set();return sortLog(ls.flat().filter(e=>seen.has(e.id)?false:seen.add(e.id)))};

const both=merge(A,B);
const sA=project(both), sB=project(merge(B,A));

check("convergence: merge order has no effect",
  JSON.stringify(sA)===JSON.stringify(sB));
check("idempotence: re-merging a known log changes nothing",
  JSON.stringify(project(merge(both,B,A,both)))===JSON.stringify(sA));
check("no work lost: the iPhone session survives",
  sA.sessions.some(s=>s.id==="s2"));
check("deletion honoured everywhere: the erased session stays gone",
  !sA.sessions.some(s=>s.id==="s1"));
check("annale from the iPhone kept", sA.annales.length===1);
check("chapter: the most recent downgrade wins", sA.chaps.f1.s===0);
check("chapter: touches from both devices are brought together",
  sA.chaps.f1.touches.join(",")==="2026-08-02,2026-08-05");
check("chapter from the other device kept", sA.chaps.m1.s===2);
check("synced setting applied", sA.refTotal===1200);
check("a single peloton despite two creations",
  project(merge(both,[ev(1,"phone","b9","pelotonStarted",{start:"2026-08-01",exam:"2027-04-06",seed:99})])).seed===42);

/* ---- reset: it propagates, and nothing rises from the dead ---- */
const afterReset=merge(both,[ev(20,"mac","r1","pelotonReset",{})]);
const sR=project(afterReset);
check("reset: everything that came before is undone",
  !sR.started&&sR.sessions.length===0&&sR.annales.length===0);
check("reset: old facts re-imported afterwards stay without effect",
  project(merge(afterReset,A,B)).sessions.length===0);
check("after the reset, starting over is possible",
  project(merge(afterReset,[ev(21,"mac","r2","pelotonStarted",{start:"2026-09-01",exam:"2027-04-06",seed:7})])).seed===7);

/* ---- legacy file migration: two devices, one single outcome ---- */
const legacy=JSON.stringify({v:2,start:"2026-08-01",exam:"2027-04-06",seed:5,
  sessions:[{id:"old1",date:"2026-08-01",min:30,mat:"fr",type:"cours"}],
  chaps:{f1:{s:2,touches:["2026-08-01"]}},annales:[],adj:[],milestones:{},
  onboarded:true,baseRate:9,theme:"dark",deletedIds:[]});
const toEvents=drafts=>drafts.map(d=>({id:d.pinned.id,order:d.pinned.order,device:d.pinned.device,time:"",kind:d.kind,data:d.data}));
const imported=toEvents(sandbox.__DUEL.LEGACY.toEvents(legacy));
check("legacy import: the facts come out identical from one device to the next",
  JSON.stringify(imported)===JSON.stringify(toEvents(sandbox.__DUEL.LEGACY.toEvents(legacy))));
const sL=project(sortLog(imported));
check("import: session, chapter, settings and onboarding carried over",
  sL.started&&sL.sessions.length===1&&sL.chaps.f1.s===2&&sL.theme==="dark"&&sL.onboarded);
check("import run twice: no duplicates",
  project(merge(imported,imported)).sessions.length===1);

console.log(failures?`\n${failures} failure(s)`:"\nAll properties hold.");
process.exit(failures?1:0);
