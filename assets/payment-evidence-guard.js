(function paymentEvidenceGuard(){
  'use strict';

  function pickEvidenceFile(message){
    return new Promise(function(resolve, reject){
      var input=document.createElement('input');
      input.type='file';
      input.accept='application/pdf,image/jpeg,image/png,.pdf,.jpg,.jpeg,.png';
      input.style.position='fixed';
      input.style.inset='auto';
      input.style.width='1px';
      input.style.height='1px';
      input.style.opacity='0';
      input.setAttribute('aria-hidden','true');
      document.body.appendChild(input);
      var settled=false;
      function finish(file){
        if(settled) return;
        settled=true;
        try{ input.remove(); }catch(_e){}
        if(file) resolve(file);
        else reject(new Error(message||'مستند الدفع مطلوب'));
      }
      input.addEventListener('change',function(){ finish(input.files&&input.files[0]); },{once:true});
      window.addEventListener('focus',function(){
        setTimeout(function(){ if(!settled && !(input.files&&input.files[0])) finish(null); },350);
      },{once:true});
      input.click();
    });
  }

  async function uploadEvidence(reqId,file,stage){
    if(typeof window.pa_docValidate==='function' && !window.pa_docValidate(file)){
      throw new Error('ملف الإثبات غير صالح');
    }
    if(typeof window.pa_docUpload!=='function'){
      throw new Error('خدمة رفع مستندات الدفع غير متاحة');
    }
    if(stage==='execution') return window.pa_docUpload('pay',reqId,file);
    try{
      return await window.pa_docUpload('inst',reqId,file);
    }catch(firstError){
      try{
        return await window.pa_docUpload('pay',reqId,file);
      }catch(_secondError){
        throw firstError;
      }
    }
  }

  function findRequestIdForPayment(paymentId){
    var id=String(paymentId==null?'':paymentId);
    var rows=Array.isArray(window.REQS)?window.REQS:[];
    for(var i=0;i<rows.length;i+=1){
      var req=rows[i]||{};
      var proc=req.proc||{};
      var candidates=[];
      if(proc.payment) candidates.push(proc.payment);
      if(Array.isArray(proc.payments)) candidates=candidates.concat(proc.payments);
      if(proc.paymentsBySupplier&&typeof proc.paymentsBySupplier==='object') candidates=candidates.concat(Object.values(proc.paymentsBySupplier));
      if(candidates.some(function(p){ return p&&String(p._id!=null?p._id:p.id)===id; })) return req.id;
    }
    if(typeof window.CURRENT==='string' && window.CURRENT) return window.CURRENT;
    return '';
  }

  function install(){
    var original=window.pa_rpc;
    if(typeof original!=='function' || original.__paymentEvidenceWrapped) return false;

    async function wrapped(name,args){
      var payload=Object.assign({},args||{});
      var isRequest=name==='portal_payment_request';
      var isExecution=name==='portal_payment_transition' && payload.p_action==='disburse';
      if(!isRequest && !isExecution) return original.apply(this,arguments);

      var details=Object.assign({},payload.p_details||{});
      if(!details.proof_key){
        var reqId=isRequest?payload.p_request_id:findRequestIdForPayment(payload.p_payment_id);
        if(!reqId) throw new Error('تعذّر تحديد الطلب المرتبط بالصرف — أعد فتح الطلب ثم نفّذ الصرف');
        var message=isExecution?'سند تنفيذ الصرف مطلوب قبل تسجيل «تم الصرف»':'مستند الدفع مطلوب قبل إنشاء طلب الصرف';
        var file=await pickEvidenceFile(message);
        details.proof_key=await uploadEvidence(reqId,file,isExecution?'execution':'request');
      }
      payload.p_details=details;
      return original.call(this,name,payload);
    }
    wrapped.__paymentEvidenceWrapped=true;
    wrapped.__original=original;
    window.pa_rpc=wrapped;
    return true;
  }

  if(!install()){
    var tries=0;
    var timer=setInterval(function(){
      tries+=1;
      if(install()||tries>80) clearInterval(timer);
    },50);
  }
})();
