// Real PostgreSQL (PGlite), isolated in memory. Never touches production.
// These tests cover the later sale of all or part of a farmer-owned
// consignment lot. They intentionally verify custody, owned stock, finance,
// debt-offset and cash effects together because the RPC must post atomically.
import {after, before, test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

let db;
const owner=randomUUID(), viewer=randomUUID();
const migration=async name=>(await readFile(
  new URL('../supabase/migrations/'+name,import.meta.url),'utf8'
)).replaceAll('create extension if not exists pgcrypto;','');
const one=async(sql,params=[])=>(await db.query(sql,params)).rows[0];

async function asUser(id=owner,role=null){
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);
  if(role)await db.exec('set role '+role);
}
async function setDate(value){
  await db.exec('reset role');
  await db.query('update public.business_settings set business_date_override=$1',[value]);
  await asUser();
}
async function createConsignment({bags=4,weight=10000,moisture=1000,waste=2000,tare=2000}={}){
  const batch=await one(
    'select * from public.create_weighing_batch($1,$2,$3,$4::uuid)',
    ['F-001','C-001','CONSIGNMENT-SETTLEMENT-TEST',randomUUID()]
  );
  for(let bagNo=1;bagNo<=bags;bagNo++){
    await db.query(
      'select * from public.add_bag_weight($1,$2,$3,$4,$5,$6,$7,$8)',
      [batch.id,randomUUID(),bagNo,weight,null,null,null,
        'CONSIGNMENT-SETTLEMENT-TEST']
    );
  }
  await db.query('select * from public.submit_weighing_batch($1)',[batch.id]);
  const allocation=await one(`select * from public.allocate_weighing_intake(
    $1,'WH-001',$2,$3,$4,0,null,$5
  )`,[batch.id,moisture,waste,tare,randomUUID()]);
  const lot=await one('select * from public.consignment_lots where id=$1',[
    allocation.consignment_lot_id
  ]);
  return {batch,allocation,lot};
}
async function settleConsignment(lotId,{
  request=randomUUID(),weight=10000,price=100000,labour=150,
  commission=2,freight=1000,method='CASH',reference=null,
  debtLot=null,debtPrincipal=null,debtQuantity=null,notes=null
}={}){
  return one(`select * from public.settle_farmer_consignment(
    p_request_id=>$1,p_consignment_lot_id=>$2,
    p_sale_centi_pyitha=>$3,p_market_price_kyat=>$4,
    p_labour_rate_kyat=>$5,p_commission_rate=>$6,p_freight_kyat=>$7,
    p_payment_method=>$8,p_payment_reference=>$9,
    p_debt_advance_lot_id=>$10,p_debt_principal_kyat=>$11,
    p_debt_quantity=>$12,p_notes=>$13
  )`,[request,lotId,weight,price,labour,commission,freight,method,
    reference,debtLot,debtPrincipal,debtQuantity,notes]);
}

before(async()=>{
  db=new PGlite();
  await db.exec("set max_stack_depth='100kB'");
  await db.exec(`create role anon;create role authenticated;create role service_role;
    create schema auth;
    create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}',created_at timestamptz default now());
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    grant usage on schema auth to authenticated,anon,service_role;
    create publication supabase_realtime;`);
  await db.exec(await migration('202608120001_bag_weights_realtime.sql'));
  await db.query("insert into auth.users(id,email) values($1,'owner@test.invalid'),($2,'viewer@test.invalid')",[owner,viewer]);
  await db.query("update public.staff_members set role='owner',active=true where user_id=$1",[owner]);
  await db.query("update public.staff_members set role='viewer',active=true where user_id=$1",[viewer]);
  for(const file of [
    '202608130001_weighing_batches_master_data.sql',
    '202608260001_offline_queue_integrity.sql',
    '202608310001_daily_market_prices.sql',
    '202609010001_weighing_batches_offline_history.sql',
    '202609030001_farmer_bean_consignment.sql',
    '202609040000_business_date_ambiguity.sql',
    '202609040001_split_weighing_intake.sql',
    '202609080001_master_data_stage2.sql',
    '202609100001_owner_finance_ledger.sql',
    '202609150001_crop_sales_day_close.sql',
    '202609230001_consignment_settlement.sql',
    '202609270001_wholesale_sale_buyer_labour.sql'
  ])await db.exec(await migration(file));
  await asUser();
});

after(async()=>{await db?.close()});

test('partial then final settlement transfers custody into owned stock exactly once',async()=>{
  await setDate('2026-09-23');
  const {lot}=await createConsignment();
  assert.equal(Number(lot.original_net_weight_centi_pyitha),35000);
  assert.equal(Number(lot.available_weight_centi_pyitha),35000);

  const partialRequest=randomUUID();
  const partial=await settleConsignment(lot.id,{request:partialRequest});
  assert.match(partial.settlement_ref,/^CS-20260923-\d{6,}$/);
  assert.equal(partial.consignment_lot_id,lot.id);
  assert.equal(Number(partial.settled_centi_pyitha),10000);
  assert.equal(Number(partial.remaining_centi_pyitha),25000);
  assert.equal(Number(partial.gross_value_kyat),500000);
  assert.equal(Number(partial.total_expense_kyat),11500);
  assert.equal(Number(partial.payable_kyat),488500);
  assert.equal(Number(partial.stock_after_centi_pyitha)-Number(partial.stock_before_centi_pyitha),10000);
  assert.equal(partial.idempotent,false);

  const partialRow=await one('select * from public.consignment_settlements where id=$1',[partial.settlement_id]);
  assert.equal(Number(partialRow.original_lot_centi_pyitha),35000);
  assert.equal(Number(partialRow.lot_before_centi_pyitha),35000);
  assert.equal(Number(partialRow.settled_centi_pyitha),10000);
  assert.equal(Number(partialRow.lot_after_centi_pyitha),25000);
  const partialLot=await one('select available_weight_centi_pyitha,status from public.consignment_lots where id=$1',[lot.id]);
  assert.equal(Number(partialLot.available_weight_centi_pyitha),25000);
  assert.equal(partialLot.status,'OPEN');
  const movement=await one('select * from public.consignment_movements where request_id=$1',[partialRequest]);
  assert.equal(movement.movement_type,'SALE_TRANSFER');
  assert.equal(Number(movement.quantity_centi_pyitha),10000);
  assert.equal(Number(movement.balance_after_centi_pyitha),25000);
  const stock=await one('select * from public.crop_stock_movements where transaction_id=$1',[partialRow.transaction_id]);
  assert.equal(stock.movement_type,'PURCHASE_IN');
  assert.equal(Number(stock.quantity_delta_centi_pyitha),10000);
  const cash=await one('select * from public.cash_ledger_entries where transaction_id=$1',[partialRow.transaction_id]);
  assert.equal(cash.direction,'OUT');
  assert.equal(cash.category,'FARMER_PAYOUT');
  assert.equal(Number(cash.amount_kyat),488500);

  const final=await settleConsignment(lot.id,{weight:25000,freight:0});
  assert.equal(Number(final.remaining_centi_pyitha),0);
  assert.equal(Number(final.stock_after_centi_pyitha)-Number(final.stock_before_centi_pyitha),25000);
  const closed=await one('select available_weight_centi_pyitha,status from public.consignment_lots where id=$1',[lot.id]);
  assert.equal(Number(closed.available_weight_centi_pyitha),0);
  assert.equal(closed.status,'CLOSED');
  assert.equal((await one('select count(*)::int n from public.consignment_settlements where consignment_lot_id=$1',[lot.id])).n,2);
  assert.equal(Number((await one("select sum(quantity_centi_pyitha)::bigint n from public.consignment_movements where lot_id=$1 and movement_type='SALE_TRANSFER'",[lot.id])).n),35000);
});

test('idempotent retry is side-effect free and changed, zero, oversale or closed-lot attempts fail',async()=>{
  await setDate('2026-10-01');
  const {lot}=await createConsignment();
  const request=randomUUID();
  const first=await settleConsignment(lot.id,{request,weight:5000,freight:0});
  const before=await one(`select
    (select count(*) from public.finance_transactions where request_id=$1)::int tx,
    (select count(*) from public.consignment_settlements where consignment_lot_id=$2)::int settlements,
    (select count(*) from public.consignment_movements where request_id=$1)::int movements,
    (select count(*) from public.crop_stock_movements where transaction_id=(select transaction_id from public.consignment_settlements where id=$3))::int stock,
    (select count(*) from public.cash_ledger_entries where transaction_id=(select transaction_id from public.consignment_settlements where id=$3))::int cash`,
  [request,lot.id,first.settlement_id]);
  const retry=await settleConsignment(lot.id,{request,weight:5000,freight:0});
  assert.equal(retry.settlement_id,first.settlement_id);
  assert.equal(retry.settlement_ref,first.settlement_ref);
  assert.equal(retry.idempotent,true);
  assert.deepEqual(await one(`select
    (select count(*) from public.finance_transactions where request_id=$1)::int tx,
    (select count(*) from public.consignment_settlements where consignment_lot_id=$2)::int settlements,
    (select count(*) from public.consignment_movements where request_id=$1)::int movements,
    (select count(*) from public.crop_stock_movements where transaction_id=(select transaction_id from public.consignment_settlements where id=$3))::int stock,
    (select count(*) from public.cash_ledger_entries where transaction_id=(select transaction_id from public.consignment_settlements where id=$3))::int cash`,
  [request,lot.id,first.settlement_id]),before);
  await assert.rejects(
    settleConsignment(lot.id,{request,weight:5001,freight:0}),
    /different consignment settlement data|different settlement data/i
  );
  await assert.rejects(settleConsignment(lot.id,{weight:0}),/positive|invalid/i);
  await assert.rejects(settleConsignment(lot.id,{weight:30001}),/available|exceed/i);
  await assert.rejects(settleConsignment(lot.id,{method:'BANK'}),/reference/i);

  await settleConsignment(lot.id,{weight:30000,freight:0});
  await assert.rejects(settleConsignment(lot.id,{weight:1}),/open|available|closed/i);
  const unchanged=await one('select status,available_weight_centi_pyitha from public.consignment_lots where id=$1',[lot.id]);
  assert.equal(unchanged.status,'CLOSED');
  assert.equal(Number(unchanged.available_weight_centi_pyitha),0);
});

test('cash debt offset uses exact half-month interest and never records fake cash-in',async()=>{
  await setDate('2026-10-01');
  const advance=await one(`select * from public.issue_advance(
    p_request_id=>$1,p_customer_id=>'F-001',p_advance_type=>'CASH',
    p_principal_kyat=>100000,p_monthly_interest_rate=>3,
    p_product_id=>null,p_quantity=>null,p_unit_price_kyat=>null,
    p_location_id=>null,p_notes=>null
  )`,[randomUUID()]);
  const debtLot=await one('select * from public.advance_lots where advance_ref=$1',[advance.advance_ref]);
  await setDate('2026-10-17');
  const {lot}=await createConsignment();
  const saved=await settleConsignment(lot.id,{
    weight:35000,labour:0,commission:0,freight:0,
    debtLot:debtLot.id,debtPrincipal:100000
  });
  assert.equal(Number(saved.debt_principal_kyat),100000);
  assert.equal(Number(saved.debt_interest_kyat),3000);
  assert.equal(Number(saved.debt_total_kyat),103000);
  assert.equal(Number(saved.payable_kyat),1647000);
  const settlement=await one('select * from public.consignment_settlements where id=$1',[saved.settlement_id]);
  const repayment=await one('select * from public.advance_repayments where transaction_id=$1',[settlement.transaction_id]);
  assert.equal(repayment.payment_method,'OFFSET');
  assert.equal(Number(repayment.elapsed_days),16);
  assert.equal(Number(repayment.half_month_steps),2);
  assert.equal(Number(repayment.principal_kyat),100000);
  assert.equal(Number(repayment.interest_kyat),3000);
  assert.equal((await one('select status from public.advance_lots where id=$1',[debtLot.id])).status,'PAID');
  const cashRows=(await db.query('select direction,category,amount_kyat from public.cash_ledger_entries where transaction_id=$1',[settlement.transaction_id])).rows;
  assert.equal(cashRows.length,1);
  assert.equal(cashRows[0].direction,'OUT');
  assert.equal(cashRows[0].category,'FARMER_PAYOUT');
  assert.equal(Number(cashRows[0].amount_kyat),1647000);
});

test('goods debt offset can select two bags from an eight-bag advance at issue-time price',async()=>{
  await setDate('2026-11-01');
  await one(`select * from public.record_stock_receipt(
    p_request_id=>$1,p_supplier_name=>'Test Supplier',
    p_product_id=>'P-002',p_location_id=>'WH-001',p_quantity=>10,
    p_unit_cost_kyat=>70000,p_payment_method=>'CASH',
    p_payment_reference=>null,p_notes=>null
  )`,[randomUUID()]);
  const advance=await one(`select * from public.issue_advance(
    p_request_id=>$1,p_customer_id=>'F-001',p_advance_type=>'GOODS',
    p_principal_kyat=>null,p_monthly_interest_rate=>3,
    p_product_id=>'P-002',p_quantity=>8,p_unit_price_kyat=>72000,
    p_location_id=>'WH-001',p_notes=>'8 bags fertilizer'
  )`,[randomUUID()]);
  const debtLot=await one('select * from public.advance_lots where advance_ref=$1',[advance.advance_ref]);
  await setDate('2026-11-17');
  const {lot}=await createConsignment();
  const saved=await settleConsignment(lot.id,{
    weight:35000,labour:0,commission:0,freight:0,
    debtLot:debtLot.id,debtQuantity:2
  });
  assert.equal(Number(saved.debt_principal_kyat),144000);
  assert.equal(Number(saved.debt_interest_kyat),4320);
  assert.equal(Number(saved.debt_total_kyat),148320);
  const remaining=await one('select * from public.advance_lots where id=$1',[debtLot.id]);
  assert.equal(Number(remaining.remaining_quantity),6);
  assert.equal(Number(remaining.remaining_principal_kyat),432000);
  assert.equal(remaining.status,'PARTIAL');
  const settlement=await one('select * from public.consignment_settlements where id=$1',[saved.settlement_id]);
  assert.equal(Number(settlement.debt_selected_quantity),2);
  assert.equal(Number(settlement.debt_remaining_quantity),6);
});

test('open farmer-owned consignment is custody, not a pending day-close settlement',async()=>{
  await setDate('2026-12-01');
  const {lot}=await createConsignment();
  assert.equal(lot.status,'OPEN');
  const preview=await one('select * from public.get_day_close_preview()');
  assert.equal(Number(preview.pending_draft_batches),0);
  assert.equal(Number(preview.pending_unallocated_batches),0);
  assert.equal(Number(preview.pending_settlements),0);
  assert.equal(Number(preview.pending_total),0);
});

test('consignment settlements are owner-readable, immutable and reject direct browser writes',async()=>{
  await asUser(viewer,'authenticated');
  assert.equal((await db.query('select * from public.consignment_settlements')).rows.length,0);
  await assert.rejects(
    db.query('insert into public.consignment_settlements default values'),
    /permission denied|row-level security/i
  );
  await asUser(owner,'authenticated');
  const saved=await one('select id from public.consignment_settlements limit 1');
  await assert.rejects(
    db.query("update public.consignment_settlements set notes='tampered' where id=$1",[saved.id]),
    /permission denied|immutable|cannot/i
  );
  const transfer=await one("select id from public.consignment_movements where movement_type='SALE_TRANSFER' limit 1");
  await assert.rejects(
    db.query('delete from public.consignment_movements where id=$1',[transfer.id]),
    /permission denied|immutable|cannot/i
  );
  await asUser();
});
