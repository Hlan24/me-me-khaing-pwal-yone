import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {runInNewContext} from 'node:vm';
import test from 'node:test';

const source=await readFile(new URL('../outputs/pwal-yon-dashboard.html',import.meta.url),'utf8');

test('ships a dedicated later consignment settlement task and server write path',()=>{
  assert.match(source,/id="consignmentSettlementPanel"/);
  assert.match(source,/key:'consignment-settlement',label:'၃ · အပ်ပဲ ဖြတ်ငွေရှင်း'/);
  assert.match(source,/function consignmentSettlementCalculation\(\)/);
  assert.match(source,/financeRpc\('settle_farmer_consignment'/);
  assert.match(source,/from\('consignment_settlements'\)\.select\(CONSIGNMENT_SETTLEMENT_COLUMNS\)/);
  assert.match(source,/data-settle-consignment=/);
  assert.match(source,/data-reprint-consignment-settlement=/);
});

test('later settlement supports partial weight, explicit all-balance choice and one selected debt lot',()=>{
  assert.match(source,/id="consignmentSettlementWeight"[^>]*step="0\.01"/);
  assert.match(source,/id="consignmentSettlementAll"/);
  assert.match(source,/available-settled/);
  assert.match(source,/readSettlementDebtSelection\('consignment',customerId/);
  assert.match(source,/p_debt_advance_lot_id/);
  assert.match(source,/p_debt_principal_kyat/);
  assert.match(source,/p_debt_quantity/);
});

test('consignment settlement receipt is customer-facing and preserves the remaining custody balance',()=>{
  const builder=source.match(/function buildConsignmentSettlementPrintData\(source\)\{[\s\S]*?\n\}\nfunction printConsignmentSettlement/)?.[0]
    .replace(/\nfunction printConsignmentSettlement$/,'');
  assert.ok(builder,'consignment settlement voucher builder is present');
  const context={
    consignmentSettlements:[],
    cropOpsNumber:value=>Number(value)||0,
    mm:value=>String(value),
    viss:value=>(Number(value)/100).toFixed(2),
    signedMoney:value=>`ကျပ် ${Number(value).toLocaleString('en-US')}`,
  };
  const row={
    crop_name_snapshot:'မတ်ပဲ',settled_centi_pyitha:5000,
    lot_after_centi_pyitha:30000,market_price_kyat:100000,
    gross_value_kyat:250000,labour_total_kyat:250,
    commission_total_kyat:5000,freight_kyat:1000,
    total_expense_kyat:6250,debt_principal_kyat:100000,
    debt_interest_kyat:1500,debt_total_kyat:101500,payable_kyat:142250,
  };
  const layout=runInNewContext(`${builder}\nbuildConsignmentSettlementPrintData(${JSON.stringify(row)})`,context);
  assert.equal(layout.type,'အပ်ပဲ ဖြတ်ငွေရှင်း');
  assert.equal(layout.items[0][2],'—','partial custody sale must not invent an actual bag count');
  assert.equal(layout.items[0][3],'50.00');
  assert.equal(layout.items[0][4],'ကျပ် 100,000','receipt price has no /20 technical suffix');
  assert.match(layout.note,/300\.00 ပိဿာ/);
  assert.deepEqual([...layout.adjustments.map(row=>row[0])],['လုပ်သားခ','ပွဲစားခ','ကားခ','အကြွေးအရင်း','အတိုး']);
});
