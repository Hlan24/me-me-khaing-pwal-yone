import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

const html = await readFile(new URL('../public/pwal-yon-dashboard.html',import.meta.url),'utf8');
const code = html.slice(html.indexOf('function computeIntakeSplit('),html.indexOf('\nfunction consignmentCalculation('));
const {computeIntakeSplit} = vm.runInNewContext(code+';({computeIntakeSplit})');
const base = {gross:35000,bags:12,moisture:0,waste:0,tareEach:0,sale:5000};
test('350 net splits into 50 reserved plus 300 custody',()=>{
  const q=computeIntakeSplit(base);assert.equal(q.valid,true);assert.equal(q.sale,5000);assert.equal(q.consigned,30000);
});
test('deduct once before splitting: 350 gross minus 3 yields 50 plus 297',()=>{
  const q=computeIntakeSplit({...base,bags:10,tareEach:20,moisture:50,waste:50});
  assert.equal(q.valid,true);assert.equal(q.net,34700);assert.equal(q.consigned,29700);
});
test('all-sale and all-custody use the same split invariant',()=>{
  assert.equal(computeIntakeSplit({...base,sale:35000}).consigned,0);
  assert.equal(computeIntakeSplit({...base,sale:0}).consigned,35000);
});
for(const [label,change] of Object.entries({oversell:{sale:35001},negativeSale:{sale:-1},blank:{sale:NaN},fractionalCenti:{sale:5000.5},noNet:{moisture:35000},emptyBags:{bags:0},unsafe:{tareEach:Number.MAX_SAFE_INTEGER}})){
  test('rejects invalid split: '+label,()=>assert.equal(computeIntakeSplit({...base,...change}).valid,false));
}
test('centi parser keeps blank as undecided, accepts two decimal places only',()=>{
  const code=html.match(/function centiFromPyithaInput\(input\)\{[^\n]+/)[0];
  const parse=vm.runInNewContext(code+';centiFromPyithaInput');
  assert.ok(Number.isNaN(parse({value:''})));assert.equal(parse({value:'50.01'}),5001);assert.ok(Number.isNaN(parse({value:'0.001'})));
});
test('removes pre-weighing commercial choice and keeps sale pending',()=>{
  assert.doesNotMatch(html,/name="mobileIntakeMode"/);
  assert.match(html,/function currentIntakeMode\(\)\{return 'UNALLOCATED'/);
  assert.match(html,/p_sale_centi_pyitha:quote.sale/);
  assert.match(html,/sale_reserved_centi_pyitha\)\/100/);
  assert.match(html,/id="labourWeightBasis"/);
  assert.match(html,/id="intakeHistoryPanel"/);
});

function salePreview(basis){
  const context={};
  for(const match of html.matchAll(/\bid="([^"]+)"/g))context[match[1]]={value:'0',checked:false,disabled:false,style:{},checkValidity:()=>true};
  Object.assign(context,{
    activeIntakeAllocation:()=>({net_centi_pyitha:35000,sale_reserved_centi_pyitha:5000,consigned_centi_pyitha:30000,moisture_centi_pyitha:0,waste_centi_pyitha:0,tare_centi_pyitha:200}),
    bagTotals:()=>({total:35200,count:10}),customerInfo:()=>({id:'F-001',divisor:20}),numberValue:x=>Number(x.value),
    farmerDebt:{},batchFinalized:true,isChiliCrop:()=>false,settlementSettled:false,
    mm:x=>String(x),viss:x=>String(x/100),signedMoney:x=>String(x)
  });
  context.labourWeightBasis.value=basis;context.labourRate.value='150';context.marketPrice.value='100000';
  const code=html.match(/function settlementCalculation\(\)\{[^\n]+/)[0];
  const result=vm.runInNewContext(code+';settlementCalculation()',context);
  return{result,context};
}
test('sale preview prices only 50, with explicitly chosen labour basis',()=>{
  const sale=salePreview('SALE'),all=salePreview('RECEIPT');
  assert.equal(sale.result.net,50);assert.equal(sale.result.grossValue,250000);assert.equal(sale.result.labour,250);
  assert.equal(all.result.labour,1750);assert.equal(all.result.net,50);
  assert.equal(sale.result.valid,false);assert.equal(sale.context.finalizeSettlement.disabled,true);
  assert.equal(sale.context.settleMoisture.disabled,true);assert.equal(sale.context.tarePerBag.disabled,true);
  assert.match(sale.context.settleAllocationSummary.textContent,/350.*50.*300/);
});
test('preview controls unlock without unlocking financial writes and receipt stays neutral',()=>{
  assert.match(html,/unlockSettlement\(\);applyPilotWriteGuards\(\)/);
  const print=html.match(/printLiveBatch.onclick=[^\n]+/)[0];assert.doesNotMatch(print,/ချက်ချင်းရောင်းရန်/);
  assert.match(print,/အိတ်ချိန်လက်ခံမှုသာ/);
  assert.match(html,/finally\{consignmentSaving=false;[^\n]*consignmentCalculation\(\)/);
});
