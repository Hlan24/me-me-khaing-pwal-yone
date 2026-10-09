// Real PostgreSQL (PGlite), isolated in memory. Never touches production.
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
const iso=value=>value instanceof Date?value.toISOString().slice(0,10):String(value);

async function asUser(id=owner,role=null){
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[id]);
  if(role)await db.exec('set role '+role);
}
async function setDate(value){
  await asUser();
  await db.query('update public.business_settings set business_date_override=$1',[value]);
  await asUser();
}
async function receipt({crop='C-001',bags=4,weight=10000,submit=true}={}){
  const batch=await one(
    'select * from public.create_weighing_batch($1,$2,$3,$4::uuid)',
    ['F-001',crop,'CROP-OPS-TEST',randomUUID()]
  );
  for(let bagNo=1;bagNo<=bags;bagNo++){
    await db.query(
      'select * from public.add_bag_weight($1,$2,$3,$4,$5,$6,$7,$8)',
      [batch.id,randomUUID(),bagNo,weight,crop==='C-004'?'DRY':null,
        crop==='C-004'?10:null,crop==='C-004'?'A':null,'CROP-OPS-TEST']
    );
  }
  if(submit)await db.query('select * from public.submit_weighing_batch($1)',[batch.id]);
  return one('select * from public.weighing_batches where id=$1',[batch.id]);
}
async function allocate(batch,{sale=5000,moisture=1000,waste=2000,tare=2000}={}){
  return one(`select * from public.allocate_weighing_intake(
    $1,'WH-001',$2,$3,$4,$5,null,$6
  )`,[batch.id,moisture,waste,tare,sale,randomUUID()]);
}
async function settleBean(batch,{request=randomUUID(),lot=null,principal=null,quantity=null}={}){
  return one(`select * from public.settle_crop_intake(
    p_request_id=>$1,p_batch_id=>$2,p_location_id=>'WH-001',
    p_market_price_kyat=>100000,p_labour_basis=>'SALE',
    p_labour_rate_kyat=>150,p_commission_rate=>2,p_freight_kyat=>0,
    p_payment_method=>'CASH',p_payment_reference=>null,
    p_debt_advance_lot_id=>$3,p_debt_principal_kyat=>$4,
    p_debt_quantity=>$5,p_chili_bag_prices=>null,p_notes=>null
  )`,[request,batch.id,lot,principal,quantity]);
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
    '202609270001_wholesale_sale_buyer_labour.sql'
  ])await db.exec(await migration(file));
  await asUser();
});

after(async()=>{await db?.close()});

test('bean split settles only sale-reserved weight and preserves farmer consignment',async()=>{
  await setDate('2026-09-15');
  const batch=await receipt(), allocation=await allocate(batch);
  assert.equal(Number(allocation.net_centi_pyitha),35000);
  assert.equal(Number(allocation.sale_reserved_centi_pyitha),5000);
  assert.equal(Number(allocation.consigned_centi_pyitha),30000);
  const saved=await settleBean(batch);
  assert.match(saved.settlement_ref,/^CS-20260915-\d{6,}$/);
  assert.equal(Number(saved.purchased_centi_pyitha),5000);
  assert.equal(Number(saved.gross_value_kyat),250000);
  assert.equal(Number(saved.total_expense_kyat),5250);
  assert.equal(Number(saved.payable_kyat),244750);
  assert.equal(Number(saved.stock_after_centi_pyitha)-Number(saved.stock_before_centi_pyitha),5000);
  assert.equal((await one('select sale_state from public.intake_allocations where id=$1',[allocation.id])).sale_state,'SETTLED');
  assert.equal((await one('select status from public.weighing_batches where id=$1',[batch.id])).status,'SETTLED');
  const custody=await one('select available_weight_centi_pyitha from public.consignment_lots where id=$1',[allocation.consignment_lot_id]);
  assert.equal(Number(custody.available_weight_centi_pyitha),30000);
  const cash=await one('select * from public.cash_ledger_entries where document_ref=$1',[saved.settlement_ref]);
  assert.equal(cash.direction,'OUT');
  assert.equal(cash.category,'FARMER_PAYOUT');
  assert.equal(Number(cash.amount_kyat),244750);
});

test('settlement is idempotent and debt offset uses exact half-month interest without fake cash-in',async()=>{
  await setDate('2026-10-01');
  const advance=await one(`select * from public.issue_advance(
    p_request_id=>$1,p_customer_id=>'F-001',p_advance_type=>'CASH',
    p_principal_kyat=>100000,p_monthly_interest_rate=>3,
    p_product_id=>null,p_quantity=>null,p_unit_price_kyat=>null,
    p_location_id=>null,p_notes=>null
  )`,[randomUUID()]);
  const lot=await one('select id from public.advance_lots where advance_ref=$1',[advance.advance_ref]);
  await setDate('2026-10-17');
  const batch=await receipt();await allocate(batch,{sale:35000,moisture:1000,waste:2000,tare:2000});
  const request=randomUUID(), first=await settleBean(batch,{request,lot:lot.id,principal:100000});
  assert.equal(Number(first.debt_principal_kyat),100000);
  assert.equal(Number(first.debt_interest_kyat),3000);
  assert.equal(Number(first.debt_total_kyat),103000);
  const retry=await settleBean(batch,{request,lot:lot.id,principal:100000});
  assert.equal(retry.settlement_id,first.settlement_id);
  assert.equal(retry.idempotent,true);
  await assert.rejects(settleBean(batch,{request,lot:lot.id,principal:99999}),/different settlement data/i);
  const repayment=await one('select * from public.advance_repayments where transaction_id=(select transaction_id from public.crop_settlements where id=$1)',[first.settlement_id]);
  assert.equal(repayment.payment_method,'OFFSET');
  assert.equal(Number(repayment.half_month_steps),2);
  assert.equal((await one('select status from public.advance_lots where id=$1',[lot.id])).status,'PAID');
  const entries=await db.query('select direction,category,amount_kyat from public.cash_ledger_entries where transaction_id=(select transaction_id from public.crop_settlements where id=$1)',[first.settlement_id]);
  assert.equal(entries.rows.length,1);
  assert.equal(entries.rows[0].direction,'OUT');
  assert.equal(Number(entries.rows[0].amount_kyat),Number(first.payable_kyat));
});

test('chili settlement requires one authoritative per-bag tare and price',async()=>{
  await setDate('2026-11-01');
  const batch=await receipt({crop:'C-004',bags:2,weight:3000});
  const prices=[
    {bag_no:1,tare_centi_pyitha:10,unit_price_kyat:5000},
    {bag_no:2,tare_centi_pyitha:20,unit_price_kyat:6000}
  ];
  const saved=await one(`select * from public.settle_crop_intake(
    $1,$2,'WH-001',null,'SALE',150,2,0,'CASH',null,
    null,null,null,$3::jsonb,null
  )`,[randomUUID(),batch.id,JSON.stringify(prices)]);
  assert.equal(saved.crop_category,'CHILI');
  assert.equal(Number(saved.purchased_centi_pyitha),5970);
  assert.equal(Number(saved.gross_value_kyat),328300);
  assert.equal((await one('select count(*)::int n from public.crop_settlement_bag_prices where settlement_id=$1',[saved.settlement_id])).n,2);
  const bad=await receipt({crop:'C-004',bags:2,weight:3000});
  await assert.rejects(db.query(`select * from public.settle_crop_intake(
    $1,$2,'WH-001',null,'SALE',150,2,0,'CASH',null,
    null,null,null,$3::jsonb,null
  )`,[randomUUID(),bad.id,JSON.stringify(prices.slice(0,1))]),/Every submitted chili bag/i);
  assert.equal((await one('select status from public.weighing_batches where id=$1',[bad.id])).status,'SUBMITTED');
});

test('wholesale sale atomically reduces owned stock and records either full payment or credit',async()=>{
  await setDate('2026-12-01');
  const batch=await receipt();await allocate(batch,{sale:35000,moisture:1000,waste:2000,tare:2000});
  await settleBean(batch);
  const paidRequest=randomUUID();
  const paid=await one(`select * from public.record_wholesale_crop_sale(
    $1,'Buyer A','C-001','WH-001',10000,3,20,120000,300,5000,595900,
    'CASH','5Q/1234',null
  )`,[paidRequest]);
  assert.equal(Number(paid.gross_value_kyat),600000);
  assert.equal(Number(paid.labour_rate_kyat),300);
  assert.equal(Number(paid.labour_total_kyat),900);
  assert.equal(Number(paid.net_value_kyat),595900);
  assert.equal(Number(paid.receivable_kyat),0);
  assert.equal(Number(paid.stock_before_centi_pyitha)-Number(paid.stock_after_centi_pyitha),10000);
  const cash=await one('select amount_kyat from public.cash_ledger_entries where document_ref=$1',[paid.sale_ref]);
  assert.equal(Number(cash.amount_kyat),595900);
  const retry=await one(`select * from public.record_wholesale_crop_sale(
    $1,'Buyer A','C-001','WH-001',10000,3,20,120000,300,5000,595900,
    'CASH','5Q/1234',null
  )`,[paidRequest]);
  assert.equal(retry.sale_id,paid.sale_id);
  assert.equal(retry.idempotent,true);
  await assert.rejects(db.query(`select * from public.record_wholesale_crop_sale(
    $1,'Buyer A','C-001','WH-001',10000,3,20,120000,301,5000,595903,
    'CASH','5Q/1234',null
  )`,[paidRequest]),/different crop-sale data/i);
  const credit=await one(`select * from public.record_wholesale_crop_sale(
    $1,'Buyer Credit','C-001','WH-001',5000,2,20,120000,300,0,0,
    'CREDIT',null,null
  )`,[randomUUID()]);
  assert.equal(Number(credit.labour_total_kyat),600);
  assert.equal(Number(credit.receivable_kyat),300600);
  const receivable=await one('select * from public.buyer_receivable_lots where sale_id=$1',[credit.sale_id]);
  assert.equal(Number(receivable.opening_kyat),300600);
  assert.equal(Number(receivable.remaining_kyat),300600);
  await assert.rejects(db.query(`select * from public.record_wholesale_crop_sale(
    $1,'Bad Buyer','C-001','WH-001',100,1,1,1000,300,0,1000,
    'CASH',null,null
  )`,[randomUUID()]),/must equal net value/i);
  await assert.rejects(db.query(`select * from public.record_wholesale_crop_sale(
    $1,'Bad Labour','C-001','WH-001',100,1,1,1000,-1,0,999,
    'CASH',null,null
  )`,[randomUUID()]),/Invalid wholesale crop-sale input/i);
  const legacy=await one(`select * from public.record_wholesale_crop_sale(
    $1,'Legacy Buyer','C-001','WH-001',100,1,1,1000,0,1000,
    'CASH',null,null
  )`,[randomUUID()]);
  const legacyRow=await one('select labour_rate_kyat,labour_total_kyat,net_value_kyat from public.wholesale_crop_sales where id=$1',[legacy.sale_id]);
  assert.equal(Number(legacyRow.labour_rate_kyat),0);
  assert.equal(Number(legacyRow.labour_total_kyat),0);
  assert.equal(Number(legacyRow.net_value_kyat),1000);
});

test('day close blocks pending work, carries opening cash, and rejects later postings',async()=>{
  await setDate('2027-01-01');
  const pending=await receipt();
  const preview=await one('select * from public.get_day_close_preview()');
  assert.ok(Number(preview.pending_unallocated_batches)>0);
  await assert.rejects(db.query(
    'select * from public.close_business_day($1,$2,$3)',
    [randomUUID(),100000,100000]
  ),/pending operations/i);
  await db.query('select * from public.void_weighing_batch($1,$2)',[pending.id,'cancel pending close test']);
  const ready=await one('select * from public.get_day_close_preview()');
  assert.equal(Number(ready.pending_total),0);
  const first=await one('select * from public.close_business_day($1,$2,$3)',[
    randomUUID(),100000,100000
  ]);
  assert.equal(iso(first.business_date),'2027-01-01');
  assert.match(first.day_close_ref,/^DC-20270101-\d{6,}$/);
  await assert.rejects(db.query(`select * from public.record_business_expense(
    $1,'late',1,'CASH',null,null
  )`,[randomUUID()]),/already closed/i);
  await assert.rejects(receipt({submit:false}),/already closed/i);

  await setDate('2027-01-02');
  const secondPreview=await one('select * from public.get_day_close_preview()');
  assert.equal(Number(secondPreview.opening_cash_kyat),100000);
  assert.equal(secondPreview.opening_cash_required,false);
  const second=await one('select * from public.close_business_day($1,$2,$3)',[
    randomUUID(),null,100000
  ]);
  assert.equal(Number(second.opening_cash_kyat),100000);
});

test('new ledgers are owner-readable but reject direct authenticated writes',async()=>{
  await asUser(viewer,'authenticated');
  assert.equal((await db.query('select * from public.crop_settlements')).rows.length,0);
  await assert.rejects(db.query('insert into public.business_day_closes default values'),/permission denied|row-level security/i);
  await assert.rejects(db.query('select * from public.get_crop_stock_balances()'),/role|required|permission/i);
  await asUser(owner);
});

test('read-only production verifier reports every crop-operation check PASS',async()=>{
  await asUser(owner);
  const verifier=await readFile(
    new URL('../supabase/ops/verify_crop_sales_day_close_schema.sql',import.meta.url),
    'utf8'
  );
  const executed=await db.exec(verifier);
  const rows=executed.at(-1)?.rows??[];
  assert.ok(rows.length>=18);
  const failed=rows.filter(row=>row.status!=='PASS');
  assert.deepEqual(failed,[]);
  assert.equal(rows.find(row=>row.check_name==='OVERALL')?.status,'PASS');
});

test('pre-existing owner-finance verifier stays accurate with crop documents and offsets',async()=>{
  await asUser(owner);
  const verifier=await readFile(
    new URL('../supabase/ops/verify_owner_finance_schema.sql',import.meta.url),
    'utf8'
  );
  const rows=(await db.exec(verifier)).at(-1)?.rows??[];
  assert.deepEqual(rows.filter(row=>row.status!=='PASS'),[]);
  assert.equal(rows.find(row=>row.check_name==='OVERALL')?.status,'PASS');
});
