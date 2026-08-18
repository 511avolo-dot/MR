// عقد مصمّم سير العمل (المُحوِّل): الإسناد بالقاعدة + عدّاد المؤهَّلين + الحفظ يفشل مغلقاً.
// يستخرج كتلة دوال المصمّم من purchase-portal.html ويشغّلها ببيئة مُصغّرة — يمسك أيّ خطأ
// تشغيليّ كان سيُفرِغ الشاشة، ويثبت أنّ مرحلة بلا معتمِد تمنع الحفظ.
import { readFileSync } from 'node:fs';

const src = readFileSync('/home/user/MR/purchase-portal.html', 'utf8');
const START = 'var PA_WF_ROLES=[';
const END = "if(typeof designerHTML==='function'){ var _pa_refDesignerHTML=designerHTML;";
const s = src.indexOf(START);
const e = src.indexOf(END, s);
if (s < 0 || e < 0) { console.error('markers not found', s, e); process.exit(2); }
const block = src.slice(s, e);

const env = `
var USERS={
  khalid:{n:"خالد",active:true,perms:{can_approve_stage:true}},
  sara:{n:"سارة",active:true,perms:{can_approve_finance:true}},
  hani:{n:"هاني",active:true,perms:{can_manage_procurement:true,can_approve_award:true}},
  faisal:{n:"فيصل",active:true,away:true,delegate:"khalid",perms:{can_approve_stage:true}},
  gone:{n:"مغادر",active:false,perms:{can_approve_committee:true}}
};
var DEPTS={OPS:{n:"الصيانة",sector:"الصيانة",mgr:"khalid"},CON:{n:"الإنشاءات",sector:"الإنشاءات",mgr:"faisal"}};
var WORKFLOWS=[{id:"wf1",name:"مسار",priority:10,cond:{},stages:[
  {id:"s1",label:"مدير القسم",type:"dept",sla:24},
  {id:"s2",label:"مالي",type:"finance",sla:24},
  {id:"s3",label:"لجنة",type:"role",role:"can_approve_committee",sla:24},
  {id:"s4",label:"شخص",type:"user",approver:"hani",sla:24}]}];
var AWARD_WF={id:"award",name:"تعميد",stages:[]};
var WF_TAB="wf1";
var DOA=[{max:Infinity,label:"كل الشرائح"}];
function findWF(id){return WORKFLOWS.filter(function(w){return w.id===id;})[0];}
function accessOf(){return {can:{}};}
function uName(u){return (USERS[u]||{}).n||u;}
function esc(x){return String(x==null?"":x);}
function ic(){return "";}
function money(n){return String(n);}
function render(){}
function pa_workflowWriteEnabled(){return true;}
function pa_designAssign(){}
function wfCondText(){return "افتراضي";}
function pickWF(){return WORKFLOWS[0];}
function doaFor(){return DOA[0];}
function setStageLabel(){} function setStageSla(){} function delStage2(){} function addStage2(){}
var document={getElementById:function(){return null;}};
`;

const tail = `
  var wf=findWF("wf1"); var out={};
  out.elig_dept = pa_stageEligible(wf.stages[0]).length;   // خالد + فيصل = 2
  out.elig_fin  = pa_stageEligible(wf.stages[1]).length;   // سارة = 1
  out.elig_comm = pa_stageEligible(wf.stages[2]).length;   // مغادر غير نشط = 0
  out.elig_user = pa_stageEligible(wf.stages[3]).length;   // هاني = 1
  var h=pa_wfHealth(wf);
  out.bad=h.bad.length; out.warn=h.warn.length; out.ok=h.ok;
  out.badWhy=h.bad.map(function(b){return b.i+": "+b.why;});
  out.warnWhy=h.warn.map(function(w){return w.i+": "+w.why;});
  out.tableOk = pa_wfStepTable(wf).indexOf("<table")>=0;
  out.diagOk  = pa_wfDiagram(wf).indexOf("المخطّط")>=0;
  var hp = pa_wfHealthPanel(wf);
  out.saveBlocked = hp.indexOf("disabled aria-disabled")>=0;   // يجب أن يكون الحفظ مُعطَّلاً
  out.simOk   = pa_wfSimPanel().indexOf("pa-sim-amt")>=0;
  // بعد إصلاح مرحلة اللجنة يجب أن يُفتح الحفظ
  wf.stages[2].type="role"; wf.stages[2].role="can_approve_stage";
  var h2=pa_wfHealth(wf); out.afterFix_ok=h2.ok;
  out.afterFix_saveEnabled = pa_wfHealthPanel(wf).indexOf('onclick="pa_saveWorkflow()"')>=0;
  return out;
`;

const fn = new Function(env + block + tail);
const r = fn();
console.log(JSON.stringify(r, null, 1));

const expect = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}: ${JSON.stringify(got)}${ok ? '' : ' (expected ' + JSON.stringify(want) + ')'}`);
  return ok;
};
let all = true;
all &= expect('dept eligible = 2 managers', r.elig_dept, 2);
all &= expect('finance eligible = 1', r.elig_fin, 1);
all &= expect('committee eligible = 0 (inactive holder ignored)', r.elig_comm, 0);
all &= expect('named user eligible = 1', r.elig_user, 1);
all &= expect('health flags 1 broken stage', r.bad, 1);
all &= expect('health not ok', r.ok, false);
all &= expect('save blocked while broken', r.saveBlocked, true);
all &= expect('table renders', r.tableOk, true);
all &= expect('diagram renders', r.diagOk, true);
all &= expect('simulation renders', r.simOk, true);
all &= expect('healthy after fixing committee stage', r.afterFix_ok, true);
all &= expect('save enabled after fix', r.afterFix_saveEnabled, true);
console.log(all ? '\n✅ ALL PASS' : '\n❌ FAILURES');
process.exit(all ? 0 : 1);
