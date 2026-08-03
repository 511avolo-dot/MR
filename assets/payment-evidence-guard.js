(function paymentEvidenceGuard(){
  'use strict';

  function pickEvidenceFile(){
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
        else reject(new Error('مستند الدفع مطلوب قبل إنشاء طلب الصرف'));
      }
      input.addEventListener('change',function(){ finish(input.files&&input.files[0]); },{once:true});
      window.addEventListener('focus',function(){
        setTimeout(function(){ if(!settled && !(input.files&&input.files[0])) finish(null); },350);
      },{once:true});
      input.click();
    });
  }

  async function uploadEvidence(reqId,file){
    if(typeof window.pa_docValidate==='function' && !window.pa_docValidate(file)){
      throw new Error('ملف الإثبات غير صالح');
    }
    if(typeof window.pa_docUpload!=='function'){
      throw new Error('خدمة رفع مستندات الدفع غير متاحة');
    }
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

  function install(){
    var original=window.pa_rpc;
    if(typeof original!=='function' || original.__paymentEvidenceWrapped) return false;

    async function wrapped(name,args){
      if(name!=='portal_payment_request'){
        return original.apply(this,arguments);
      }
      var payload=Object.assign({},args||{});
      var details=Object.assign({},payload.p_details||{});
      if(!details.proof_key){
        var file=await pickEvidenceFile();
        details.proof_key=await uploadEvidence(payload.p_request_id,file);
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
