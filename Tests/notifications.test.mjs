/* Checks the contract the page hands to Swift for the peloton reminders.
   The HTML file is loaded as-is: the REAL code is what gets tested.

   Swift is unforgiving and mute: one `at` it cannot read back, and the
   reminder vanishes without a word (`guard let date = formatter.date(from:)` in
   NotificationScheduler). No error, no log — just a notification that will
   never ring. That seam is the one this file keeps watch over. */
import fs from "node:fs";
import vm from "node:vm";

const html=fs.readFileSync(process.argv[2],"utf8");
const js=html.match(/<script[^>]*>([\s\S]*?)<\/script>/)[1];
const sandbox={console,TextDecoder,atob,Date,Math,JSON,Set,Map,setInterval:()=>0,clearInterval:()=>{}};
sandbox.globalThis=sandbox;
vm.createContext(sandbox);
vm.runInContext(js,sandbox);
const D=sandbox.__DUEL;

let failures=0;
const check=(name,ok)=>{console.log((ok?"  ok   ":"  FAIL ")+"  "+name);if(!ok)failures++};

/* Dates are pinned to TODAY, never hard-coded: `buildNotifPlan` reads the real
   clock, so a hard-dated log would stop proving anything the day it slipped
   into the past. Computed in LOCAL time like `d2s`, not in UTC: otherwise the
   test is off by a day depending on the time zone and the hour. */
const day=n=>{const d=new Date();d.setDate(d.getDate()+n);
  return d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")
        +"-"+String(d.getDate()).padStart(2,"0")};
const ev=(order,id,kind,data)=>({id,order,device:"mac",time:"",kind,data});
const journal=exam=>[
  ev(1,"n1","pelotonStarted",{start:day(-14),exam,seed:42}),
  ev(2,"n2","onboardingFinished",{}),
  ev(3,"n3","sessionLogged",{id:"s1",date:day(-3),min:90,mat:"fr",type:"exercices",chap:"f1",manual:false}),
  ev(4,"n4","chapterStatusSet",{id:"f1",status:2,date:day(-3)}),
];
const poser=exam=>{D.state=D.project(journal(exam));D.clearCaches()};
const planFor=(exam,horizon)=>{poser(exam);
  return D.buildNotifPlan(horizon===undefined?10:horizon)};

/* Distant written exams: the common case, every day except the very end. */
const plan=planFor(day(200));

check("a plan is produced",plan.length>0);

/* ---- the guard: who is entitled to receive reminders ------------------------
   `pushPlanToNative` is the ONLY path by which a plan leaves for Swift, and
   `state.started` is its only lock: neither the bridge nor Swift knows that a
   peloton was never started. We watch the real send rather than the shape of
   the plan, by swapping out the piece of bridge exposed to Swift. */
const envoiReel=sandbox.Peloton.scheduleNotifications;
let envoye;
sandbox.Peloton.scheduleNotifications=p=>{envoye=p};

envoye=undefined;D.pushPlanToNative();
check("peloton started: the plan really does leave, and it is the 10-day one",
  JSON.stringify(envoye)===JSON.stringify(D.buildNotifPlan(10)));

/* A peloton that was never started. We give it a future exam date: the one
   `emptyState()` carries is frozen at 2027-04-06, and once that day is past the
   skeleton has not a single rival day left to unroll — the assertion below
   would then prove nothing at all. This is test scaffolding, not a workaround:
   we want a peloton that is not started AND a race still under way. */
const jamaisDemarre=D.project([]);
jamaisDemarre.exam=day(200);
D.state=jamaisDemarre;D.clearCaches();
envoye=undefined;D.pushPlanToNative();
check("peloton never started: nothing leaves",envoye===undefined);
// Without this last line, the previous one could go green for the wrong
// reason — an empty plan rather than a guard that holds.
check("…and it really is the guard holding it back: the plan would be there",
  D.buildNotifPlan(10).length>0);

sandbox.Peloton.scheduleNotifications=envoiReel;
poser(day(200));   // put the ordinary scaffolding back for what follows

/* ---- the shape, word for word what `NotificationScheduler.Item` decodes ---- */
check("every reminder is exactly { at, title, body }",
  plan.every(p=>Object.keys(p).sort().join(",")==="at,body,title"));
check("`at` in yyyy-MM-dd'T'HH:mm format, the only one Swift reads back",
  plan.every(p=>/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(p.at)));
check("no impossible time (the DateFormatter would refuse in silence)",
  plan.every(p=>{const[h,m]=p.at.slice(11).split(":").map(Number);return h<24&&m<60}));
check("title and body non-empty: a mute notification serves no purpose",
  plan.every(p=>typeof p.title==="string"&&p.title.length>0
               &&typeof p.body==="string"&&p.body.length>0));

/* Swift discards any `date <= now`, without a word. A same-day reminder that
   has already gone by is therefore not merely useless: it has spent one of the
   two daily slots, and the rival whose session was still ahead will not ring.
   That is what the `!(i===0&&sessDue(...))` guard in buildNotifPlan protects. */
const maintenant=(()=>{const n=new Date();return n.getHours()*60+n.getMinutes()})();
const minutes=p=>{const[h,m]=p.at.slice(11).split(":").map(Number);return h*60+m};
check("no same-day reminder has already passed (Swift would drop them silently)",
  plan.filter(p=>p.at.slice(0,10)===day(0)).every(p=>minutes(p)>maintenant));

/* ---- the bounds ---- */
// iOS accepts only 64 pending reminders per app, and drops the surplus without
// warning: the cap of 60 keeps a margin, and it must never give way. We put it
// under strain with a wide horizon — at 10 days the plan is too short to
// reach it, and the bound would prove nothing.
check("cap of 60 reminders respected",plan.length<=60);
check("cap holds even on a horizon that overflows it",
  planFor(day(200),60).length<=60);
check("plan sorted chronologically",
  plan.every((p,i)=>i===0||plan[i-1].at<=p.at));
check("nothing beyond the requested horizon",
  plan.every(p=>p.at.slice(0,10)<=day(10)));
check("shorter horizon: the plan really does shorten",
  planFor(day(200),3).every(p=>p.at.slice(0,10)<=day(3)));

/* ---- what the plan promises the user ---- */
/* The names are read from the app, never spelled out here: a test that hard-codes
   them fails the day somebody is renamed, which is a false alarm about the plan. */
const RIVAL_NAMES=D.RKEYS.map(k=>D.RIVALS[k].name);
check("rival sessions feed the plan",
  plan.some(p=>RIVAL_NAMES.some(n=>p.title.includes(n))));
check("the end-of-horizon alert is there: we do not go dark in silence",
  plan.some(p=>p.title==="Le peloton continue sans toi"));

/* Rebuilt on every action and every launch: two calls in a row must give the
   same plan, otherwise the reminders would dance at every gesture.
   We reset the scaffolding explicitly: without that, the comparison would
   silently depend on the state left behind by the previous assertion. */
poser(day(200));
check("deterministic plan: rebuilding it does not make it drift",
  JSON.stringify(D.buildNotifPlan(10))===JSON.stringify(plan));

/* ---- the end of the race ----------------------------------------------------
   Rival sessions cease at the written-exam date (`if(d>=state.exam)break`).
   This used to need a filter: a second loop emitted "X te double aujourd'hui"
   on the horizon rather than on the exam date, so one alert could outlive the
   exams. Those alerts are gone — a date eight weeks out, about an overtake
   with no consequence — and with them the exception. */
check("no rival session after the written exams",
  planFor(day(4)).every(p=>p.at.slice(0,10)<day(4)));
check("exams today: not a single reminder left",
  planFor(day(0)).length===0);

console.log(failures?`\n${failures} failure(s)`:"\nThe notification contract holds.");
process.exit(failures?1:0);
