// Real PostgreSQL (PGlite), isolated in memory. Never touches production.
// Supabase Auth is represented by auth.users and the auth.uid() claim helper.
// PGlite uses one connection, so these tests do not prove cross-connection races.
import {after, before, test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

let db;
const owner=randomUUID(),viewer=randomUUID(),inactive=randomUUID();
const migration=async name=>(await readFile(new URL('../supabase/migrations/'+name,import.meta.url),'utf8')).replaceAll('create extension if not exists pgcrypto;','');
const one=async(sql,params=[])=>(await db.query(sql,params)).rows[0];
const isoDate=value=>value instanceof Date?value.toISOString().slice(0,10):String(value);

async function asUser(userId,role='authenticated'){
  await db.exec('reset role');
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[userId]);
  if(role)await db.exec('set role '+role);
}
async function asOwner({role=true}={}){await asUser(owner,role?'authenticated':null)}
async function setBusinessDate(value){
  await db.exec('reset role');
  await db.query('update public.business_settings set business_date_override=$1',[value]);
  await asOwner();
}
async function issueCash({principal=10000,rate=3,request=randomUUID()}={}){
  return one(`select * from public.issue_advance(
    p_request_id=>$1,p_customer_id=>$2,p_advance_type=>'CASH',
    p_principal_kyat=>$3,p_monthly_interest_rate=>$4,
    p_product_id=>null,p_quantity=>null,p_unit_price_kyat=>null,
    p_location_id=>null,p_notes=>null
  )`,[request,'F-001',principal,rate]);
}
async function issueGoods({product='P-002',quantity=8,price=72000,rate=3,request=randomUUID()}={}){
  return one(`select * from public.issue_advance(
    p_request_id=>$1,p_customer_id=>$2,p_advance_type=>'GOODS',
    p_principal_kyat=>null,p_monthly_interest_rate=>$3,
    p_product_id=>$4,p_quantity=>$5,p_unit_price_kyat=>$6,
    p_location_id=>'WH-001',p_notes=>'test goods'
  )`,[request,'F-001',rate,product,quantity,price]);
}
async function repay({lot,principal=null,quantity=null,method='CASH',reference=null,request=randomUUID(),notes=null}={}){
  return one(`select * from public.repay_advance(
    p_request_id=>$1,p_advance_lot_id=>$2,p_principal_kyat=>$3,
    p_quantity=>$4,p_payment_method=>$5,p_payment_reference=>$6,p_notes=>$7
  )`,[request,lot,principal,quantity,method,reference,notes]);
}
async function receiveStock({supplier='Test Supplier',product='P-002',location='WH-001',quantity=3,cost=70000,method='CASH',reference=null,request=randomUUID(),notes=null}={}){
  return one(`select * from public.record_stock_receipt(
    p_request_id=>$1,p_supplier_name=>$2,p_product_id=>$3,p_location_id=>$4,
    p_quantity=>$5,p_unit_cost_kyat=>$6,p_payment_method=>$7,
    p_payment_reference=>$8,p_notes=>$9
  )`,[request,supplier,product,location,quantity,cost,method,reference,notes]);
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
  await db.query("insert into auth.users(id,email) values($1,'owner@test.invalid'),($2,'viewer@test.invalid'),($3,'inactive@test.invalid')",[owner,viewer,inactive]);
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
    '202609080001_master_data_stage2.sql'
  ])await db.exec(await migration(file));
  await setBusinessDate('2026-07-01');
  await one('select * from public.commit_opening_balance_import($1,$2,$3,$4::jsonb,$5)',[
    randomUUID(),'FARMER_DEBT','pre-finance-debt.csv',
    JSON.stringify([{customer_id:'F-001',opening_date:'2026-06-01',principal_kyat:'120000',monthly_rate:'3',notes:'legacy debt'}]),null
  ]);
  await one('select * from public.commit_opening_balance_import($1,$2,$3,$4::jsonb,$5)',[
    randomUUID(),'PRODUCT_STOCK','pre-finance-stock.csv',
    JSON.stringify([
      {product_id:'P-001',location_id:'WH-001',quantity:'20',notes:null},
      {product_id:'P-002',location_id:'WH-001',quantity:'20',notes:null}
    ]),null
  ]);
  const finance=await migration('202609100001_owner_finance_ledger.sql');
  await db.exec('reset role');
  await db.exec(finance);
  await db.exec(finance);
  const historical=await migration('202610180001_historical_farmer_advances.sql');
  await db.exec(historical);
  await db.exec(historical);
  await asOwner();
});

after(async()=>{await db?.close()});

test('opening farmer debt is backfilled once and future imports create repayable lots',async()=>{
  await asOwner();
  let backfilled=await one("select count(*)::int n from public.advance_lots where opening_balance_entry_id is not null and customer_id='F-001'");
  assert.equal(backfilled.n,1);
  const old=await one("select * from public.advance_lots where opening_balance_entry_id is not null and customer_id='F-001'");
  assert.equal(old.advance_type,'CASH');
  assert.equal(isoDate(old.issued_date),'2026-06-01');
  assert.equal(Number(old.remaining_principal_kyat),120000);
  assert.equal(Number(old.monthly_interest_rate),3);

  const request=randomUUID();
  await one('select * from public.commit_opening_balance_import($1,$2,$3,$4::jsonb,$5)',[
    request,'FARMER_DEBT','post-finance-debt.csv',
    JSON.stringify([{customer_id:'F-014',opening_date:'2026-06-15',principal_kyat:'90000',monthly_rate:'2.5',notes:null}]),null
  ]);
  const retry=await one('select * from public.commit_opening_balance_import($1,$2,$3,$4::jsonb,$5)',[request,'FARMER_DEBT','changed.csv','[]',null]);
  assert.equal(retry.idempotent,true);
  assert.equal((await one("select count(*)::int n from public.advance_lots where opening_balance_entry_id is not null and customer_id='F-014'")).n,1);
  const balances=(await db.query('select * from public.get_farmer_debt_balances()')).rows;
  assert.equal(Number(balances.find(row=>row.customer_id==='F-014').remaining_principal_kyat),90000);
});

test('historical cash and goods advances preserve old dates without current cash or stock movement',async()=>{
  await setBusinessDate('2026-07-01');
  const before=await one(`select
    (select count(*) from public.cash_ledger_entries)::int cash,
    (select count(*) from public.product_stock_movements)::int stock,
    (select quantity from public.get_product_stock_balances()
      where product_id='P-002' and location_id='WH-001') quantity`);
  const request=randomUUID();
  const rows=[
    {customer_id:'F-001',opening_date:'2026-06-12',advance_type:'CASH',principal_kyat:'100000',monthly_rate:'3',notes:'old cash'},
    {customer_id:'F-001',opening_date:'2026-06-06',advance_type:'GOODS',product_id:'P-002',location_id:'WH-001',quantity:'2',unit_price_kyat:'72000',monthly_rate:'3',notes:'old fertilizer'}
  ];
  const first=await one('select * from public.commit_historical_advance_import($1,$2,$3::jsonb,$4)',[request,'legacy-ledger.csv',JSON.stringify(rows),'verified']);
  assert.equal(first.import_type,'FARMER_ADVANCE');
  assert.equal(first.row_count,2);
  assert.equal(Number(first.total_quantity),2);
  assert.equal(Number(first.total_principal_kyat),244000);
  assert.equal(first.idempotent,false);
  const retry=await one('select * from public.commit_historical_advance_import($1,$2,$3::jsonb,$4)',[request,'changed.csv','[]',null]);
  assert.equal(retry.import_id,first.import_id);
  assert.equal(retry.idempotent,true);

  const lots=(await db.query("select * from public.advance_lots where notes like 'Historical Advance%' order by issued_date,advance_type")).rows;
  assert.equal(lots.length,2);
  const goods=lots.find(row=>row.advance_type==='GOODS'),cash=lots.find(row=>row.advance_type==='CASH');
  assert.equal(isoDate(cash.issued_date),'2026-06-12');
  assert.equal(Number(cash.original_principal_kyat),100000);
  assert.equal(isoDate(goods.issued_date),'2026-06-06');
  assert.equal(goods.product_id,'P-002');
  assert.equal(goods.location_id,'WH-001');
  assert.equal(Number(goods.original_quantity),2);
  assert.equal(Number(goods.unit_price_kyat),72000);
  assert.equal(Number(goods.original_principal_kyat),144000);

  const after=await one(`select
    (select count(*) from public.cash_ledger_entries)::int cash,
    (select count(*) from public.product_stock_movements)::int stock,
    (select quantity from public.get_product_stock_balances()
      where product_id='P-002' and location_id='WH-001') quantity`);
  assert.deepEqual(after,before);

  await setBusinessDate('2026-07-23');
  const payment=await repay({lot:goods.id,quantity:1});
  assert.equal(Number(payment.elapsed_days),47);
  assert.equal(Number(payment.half_month_steps),4);
  assert.equal(Number(payment.principal_kyat),72000);
  assert.equal(Number(payment.interest_kyat),4320);
});

test('historical advance import rejects future dates, malformed rows and direct writes atomically',async()=>{
  await setBusinessDate('2026-07-01');
  const count=await one("select count(*)::int n from public.opening_balance_imports where import_type='FARMER_ADVANCE'");
  await assert.rejects(one('select * from public.commit_historical_advance_import($1,$2,$3::jsonb,$4)',[
    randomUUID(),'bad.csv',JSON.stringify([
      {customer_id:'F-001',opening_date:'2026-06-01',advance_type:'CASH',principal_kyat:'10000',monthly_rate:'3'},
      {customer_id:'F-001',opening_date:'2026-07-02',advance_type:'GOODS',product_id:'P-002',location_id:'WH-001',quantity:'1',unit_price_kyat:'72000',monthly_rate:'3'}
    ]),null
  ]),/cannot be after/i);
  assert.deepEqual(await one("select count(*)::int n from public.opening_balance_imports where import_type='FARMER_ADVANCE'"),count);
  await db.exec('set role authenticated');
  await assert.rejects(db.query("insert into public.opening_balance_entries(import_id,line_no,entry_type) values(gen_random_uuid(),1,'FARMER_ADVANCE')"),/permission denied/i);
  await asOwner();
});

test('cash advance uses server date and number, is idempotent, and rejects a changed retry',async()=>{
  await setBusinessDate('2026-07-01');
  const request=randomUUID(),first=await issueCash({principal:100000,request});
  assert.match(first.advance_ref,/^AD-20260701-\d{6,}$/);
  assert.equal(isoDate(first.business_date),'2026-07-01');
  assert.equal(Number(first.original_principal_kyat),100000);
  assert.equal(first.original_quantity,null);
  assert.equal(first.idempotent,false);
  await db.exec('reset role');
  const before=await one("select (select count(*) from public.finance_transactions)::int tx,(select count(*) from public.advance_lots where transaction_id is not null)::int lots,(select count(*) from public.cash_ledger_entries)::int cash,(select sum(last_value)::bigint from public.finance_document_counters)::bigint counter");
  await asOwner();
  const retry=await issueCash({principal:100000,request});
  assert.equal(retry.advance_id,first.advance_id);
  assert.equal(retry.advance_ref,first.advance_ref);
  assert.equal(retry.idempotent,true);
  await db.exec('reset role');
  assert.deepEqual(await one("select (select count(*) from public.finance_transactions)::int tx,(select count(*) from public.advance_lots where transaction_id is not null)::int lots,(select count(*) from public.cash_ledger_entries)::int cash,(select sum(last_value)::bigint from public.finance_document_counters)::bigint counter"),before);
  await asOwner();
  await assert.rejects(issueCash({principal:100001,request}),/different advance data/i);
  await db.exec('reset role');
  assert.deepEqual(await one("select (select count(*) from public.finance_transactions)::int tx,(select count(*) from public.advance_lots where transaction_id is not null)::int lots,(select count(*) from public.cash_ledger_entries)::int cash,(select sum(last_value)::bigint from public.finance_document_counters)::bigint counter"),before);
  await asOwner();
  const cash=await one('select * from public.cash_ledger_entries where document_ref=$1',[first.advance_ref]);
  assert.equal(cash.direction,'OUT');assert.equal(cash.category,'ADVANCE');assert.equal(Number(cash.amount_kyat),100000);
});

test('server half-month interest boundaries are exact and non-compounding',async()=>{
  const cases=[
    [0,0,0],[1,1,150],[15,1,150],[16,2,300],
    [30,2,300],[31,3,450],[45,3,450],[46,4,600],[47,4,600]
  ];
  for(const [days,steps,interest] of cases){
    await setBusinessDate('2026-07-01');
    const issued=await issueCash({principal:10000});
    const lot=await one('select id from public.advance_lots where advance_ref=$1',[issued.advance_ref]);
    const date=new Date(Date.UTC(2026,6,1+days)).toISOString().slice(0,10);
    await setBusinessDate(date);
    const paid=await repay({lot:lot.id,principal:10000});
    assert.equal(Number(paid.elapsed_days),days,'elapsed day '+days);
    assert.equal(Number(paid.half_month_steps),steps,'step day '+days);
    assert.equal(Number(paid.interest_kyat),interest,'interest day '+days);
    assert.equal(Number(paid.total_received_kyat),10000+interest,'total day '+days);
    const updated=await one('select status,remaining_principal_kyat from public.advance_lots where id=$1',[lot.id]);
    assert.equal(updated.status,'PAID');assert.equal(Number(updated.remaining_principal_kyat),0);
  }
});

test('goods advance and repayment use issue-time price, whole units and atomic stock',async()=>{
  await setBusinessDate('2026-06-06');
  const before=await one("select quantity from public.get_product_stock_balances() where product_id='P-002' and location_id='WH-001'");
  const issued=await issueGoods();
  assert.equal(Number(issued.original_principal_kyat),576000);
  assert.equal(Number(issued.stock_before),Number(before.quantity));
  assert.equal(Number(issued.stock_after),Number(before.quantity)-8);
  const lot=await one('select * from public.advance_lots where advance_ref=$1',[issued.advance_ref]);
  const movement=await one('select * from public.product_stock_movements where transaction_id=$1',[lot.transaction_id]);
  assert.equal(movement.movement_type,'OUT_ADVANCE');assert.equal(Number(movement.quantity_delta),-8);
  assert.equal((await one('select count(*)::int n from public.cash_ledger_entries where transaction_id=$1',[lot.transaction_id])).n,0);
  await db.exec('reset role');await db.query("update public.products set default_unit_price_kyat=99000 where product_id='P-002'");await asOwner();
  await setBusinessDate('2026-08-06');
  const paid=await repay({lot:lot.id,quantity:2});
  assert.equal(Number(paid.elapsed_days),61);assert.equal(Number(paid.half_month_steps),5);
  assert.equal(Number(paid.principal_kyat),144000);assert.equal(Number(paid.interest_kyat),10800);
  assert.equal(Number(paid.remaining_quantity),6);assert.equal(Number(paid.remaining_principal_kyat),432000);
  await assert.rejects(issueGoods({quantity:1.5}),/whole-unit/i);
  await db.exec('reset role');
  const snapshot=await one("select (select count(*) from public.finance_transactions)::int tx,(select count(*) from public.product_stock_movements)::int moves,(select sum(last_value)::bigint from public.finance_document_counters)::bigint counter");
  await asOwner();
  await assert.rejects(issueGoods({quantity:999}),/insufficient product stock/i);
  await db.exec('reset role');
  assert.deepEqual(await one("select (select count(*) from public.finance_transactions)::int tx,(select count(*) from public.product_stock_movements)::int moves,(select sum(last_value)::bigint from public.finance_document_counters)::bigint counter"),snapshot);
  await asOwner();
});

test('fractional goods repayments cannot exhaust principal before quantity',async()=>{
  await setBusinessDate('2026-08-06');
  await db.exec('reset role');
  await db.query("update public.products set whole_units_only=false where product_id='P-003'");
  await asOwner();
  await receiveStock({product:'P-003',quantity:10,cost:1});

  const issued=await issueGoods({product:'P-003',quantity:1.001,price:1});
  const lot=await one('select * from public.advance_lots where advance_ref=$1',[issued.advance_ref]);
  assert.equal(Number(lot.original_principal_kyat),1);
  await db.exec('reset role');
  const before=await one("select (select status from public.advance_lots where id=$1) status,(select remaining_quantity from public.advance_lots where id=$1) quantity,(select remaining_principal_kyat from public.advance_lots where id=$1) principal,(select count(*) from public.finance_transactions)::int tx,(select count(*) from public.advance_repayments)::int repayments,(select count(*) from public.cash_ledger_entries)::int cash,(select coalesce(sum(last_value),0)::bigint from public.finance_document_counters) counter",[lot.id]);
  await asOwner();
  await assert.rejects(repay({lot:lot.id,quantity:.501}),/exhaust principal before quantity/i);
  await db.exec('reset role');
  assert.deepEqual(await one("select (select status from public.advance_lots where id=$1) status,(select remaining_quantity from public.advance_lots where id=$1) quantity,(select remaining_principal_kyat from public.advance_lots where id=$1) principal,(select count(*) from public.finance_transactions)::int tx,(select count(*) from public.advance_repayments)::int repayments,(select count(*) from public.cash_ledger_entries)::int cash,(select coalesce(sum(last_value),0)::bigint from public.finance_document_counters) counter",[lot.id]),before);
  await asOwner();
  const closed=await repay({lot:lot.id,quantity:1.001});
  assert.equal(Number(closed.principal_kyat),1);
  assert.equal(Number(closed.remaining_quantity),0);
  assert.equal(Number(closed.remaining_principal_kyat),0);
  const closedLot=await one('select status,remaining_quantity,remaining_principal_kyat from public.advance_lots where id=$1',[lot.id]);
  assert.equal(closedLot.status,'PAID');
  assert.equal(Number(closedLot.remaining_quantity),0);
  assert.equal(Number(closedLot.remaining_principal_kyat),0);

  const roundingIssued=await issueGoods({product:'P-003',quantity:.003,price:500});
  const roundingLot=await one('select * from public.advance_lots where advance_ref=$1',[roundingIssued.advance_ref]);
  const first=await repay({lot:roundingLot.id,quantity:.001});
  assert.equal(Number(first.principal_kyat),1);
  assert.equal(Number(first.remaining_quantity),.002);
  assert.equal(Number(first.remaining_principal_kyat),1);
  await assert.rejects(repay({lot:roundingLot.id,quantity:.001}),/exhaust principal before quantity/i);
  const final=await repay({lot:roundingLot.id,quantity:.002});
  assert.equal(Number(final.principal_kyat),1);
  assert.equal(Number(final.remaining_quantity),0);
  assert.equal(Number(final.remaining_principal_kyat),0);
  const totals=await one('select sum(selected_quantity) quantity,sum(principal_kyat)::bigint principal from public.advance_repayments where advance_lot_id=$1',[roundingLot.id]);
  assert.equal(Number(totals.quantity),.003);
  assert.equal(Number(totals.principal),2);
});

test('immediate product sale posts stock and cash atomically',async()=>{
  await setBusinessDate('2026-08-07');
  const request=randomUUID();
  const sale=await one(`select * from public.record_product_sale(
    p_request_id=>$1,p_customer_type=>'WALK_IN',p_customer_id=>null,
    p_buyer_name=>'လမ်းကြုံဝယ်သူ',p_product_id=>'P-001',p_location_id=>'WH-001',
    p_quantity=>2,p_unit_price_kyat=>75000,p_payment_method=>'CASH',
    p_payment_reference=>null,p_notes=>null
  )`,[request]);
  assert.match(sale.sale_ref,/^GS-20260807-\d{6,}$/);assert.equal(Number(sale.total_kyat),150000);
  assert.equal(Number(sale.stock_after),Number(sale.stock_before)-2);
  const cash=await one('select * from public.cash_ledger_entries where document_ref=$1',[sale.sale_ref]);
  assert.equal(cash.direction,'IN');assert.equal(cash.category,'PRODUCT_SALE');assert.equal(Number(cash.amount_kyat),150000);
  const retry=await one(`select * from public.record_product_sale(
    p_request_id=>$1,p_customer_type=>'WALK_IN',p_customer_id=>null,
    p_buyer_name=>'လမ်းကြုံဝယ်သူ',p_product_id=>'P-001',p_location_id=>'WH-001',
    p_quantity=>2,p_unit_price_kyat=>75000,p_payment_method=>'CASH',
    p_payment_reference=>null,p_notes=>null
  )`,[request]);
  assert.equal(retry.sale_id,sale.sale_id);assert.equal(retry.idempotent,true);
  await assert.rejects(db.query(`select * from public.record_product_sale(
    p_request_id=>$1,p_customer_type=>'WALK_IN',p_customer_id=>null,
    p_buyer_name=>'Buyer',p_product_id=>'P-001',p_location_id=>'WH-001',
    p_quantity=>1,p_unit_price_kyat=>1,p_payment_method=>'BANK',
    p_payment_reference=>null,p_notes=>null
  )`,[randomUUID()]),/reference is required/i);
});

test('farmer product sales require an active farmer and store the canonical master name',async()=>{
  await setBusinessDate('2026-08-07');
  await assert.rejects(db.query(`select * from public.record_product_sale(
    p_request_id=>$1,p_customer_type=>'FARMER',p_customer_id=>null,
    p_buyer_name=>'Spoof Name',p_product_id=>'P-001',p_location_id=>'WH-001',
    p_quantity=>1,p_unit_price_kyat=>75000,p_payment_method=>'CASH',
    p_payment_reference=>null,p_notes=>null
  )`,[randomUUID()]),/customer ID is required/i);
  await assert.rejects(db.query(`select * from public.record_product_sale(
    p_request_id=>$1,p_customer_type=>'FARMER',p_customer_id=>'F-NOT-FOUND',
    p_buyer_name=>'Spoof Name',p_product_id=>'P-001',p_location_id=>'WH-001',
    p_quantity=>1,p_unit_price_kyat=>75000,p_payment_method=>'CASH',
    p_payment_reference=>null,p_notes=>null
  )`,[randomUUID()]),/active farmer not found/i);
  const saved=await one(`select * from public.record_product_sale(
    p_request_id=>$1,p_customer_type=>'FARMER',p_customer_id=>'F-001',
    p_buyer_name=>'Spoof Name',p_product_id=>'P-001',p_location_id=>'WH-001',
    p_quantity=>1,p_unit_price_kyat=>75000,p_payment_method=>'CASH',
    p_payment_reference=>null,p_notes=>null
  )`,[randomUUID()]);
  const sale=await one('select customer_id,buyer_name from public.finance_product_sales where id=$1',[saved.sale_id]);
  const farmer=await one("select full_name from public.farmers where customer_id='F-001'");
  assert.equal(sale.customer_id,'F-001');
  assert.equal(sale.buyer_name,farmer.full_name);
  assert.notEqual(sale.buyer_name,'Spoof Name');
});

test('paid stock receipt increases stock and posts one cash out atomically and idempotently',async()=>{
  await setBusinessDate('2026-08-09');
  const request=randomUUID();
  const before=await one("select quantity from public.get_product_stock_balances() where product_id='P-002' and location_id='WH-001'");
  const saved=await receiveStock({supplier:'အောင်မြေဆီဆိုင်',quantity:3,cost:70000,request});
  assert.match(saved.receipt_ref,/^ST-20260809-\d{6,}$/);
  assert.equal(isoDate(saved.business_date),'2026-08-09');
  assert.equal(Number(saved.total_kyat),210000);
  assert.equal(Number(saved.stock_before),Number(before.quantity));
  assert.equal(Number(saved.stock_after),Number(before.quantity)+3);
  const receipt=await one('select * from public.finance_stock_receipts where id=$1',[saved.receipt_id]);
  assert.equal(receipt.supplier_name,'အောင်မြေဆီဆိုင်');
  assert.equal(Number(receipt.quantity),3);
  const movement=await one('select * from public.product_stock_movements where transaction_id=$1',[receipt.transaction_id]);
  assert.equal(movement.movement_type,'IN_PURCHASE');
  assert.equal(Number(movement.quantity_delta),3);
  const cash=await one('select * from public.cash_ledger_entries where transaction_id=$1',[receipt.transaction_id]);
  assert.equal(cash.direction,'OUT');
  assert.equal(cash.category,'STOCK_PURCHASE');
  assert.equal(Number(cash.amount_kyat),210000);
  await db.exec('reset role');
  const counts=await one("select (select count(*) from public.finance_transactions)::int tx,(select count(*) from public.finance_stock_receipts)::int receipts,(select count(*) from public.product_stock_movements)::int movements,(select count(*) from public.cash_ledger_entries)::int cash");
  await asOwner();
  const retry=await receiveStock({supplier:'အောင်မြေဆီဆိုင်',quantity:3,cost:70000,request});
  assert.equal(retry.receipt_id,saved.receipt_id);
  assert.equal(retry.idempotent,true);
  await db.exec('reset role');
  assert.deepEqual(await one("select (select count(*) from public.finance_transactions)::int tx,(select count(*) from public.finance_stock_receipts)::int receipts,(select count(*) from public.product_stock_movements)::int movements,(select count(*) from public.cash_ledger_entries)::int cash"),counts);
  await asOwner();
  await assert.rejects(receiveStock({quantity:1.5}),/whole-unit/i);
  await db.exec('reset role');
  await db.query("update public.products set whole_units_only=false where product_id='P-001'");
  await asOwner();
  await assert.rejects(receiveStock({product:'P-001',quantity:1.2345}),/up to three decimals/i);
  await db.exec('reset role');
  await db.query("update public.products set whole_units_only=true where product_id='P-001'");
  await asOwner();
});

test('expense accepts arbitrary positive whole kyat without a user voucher number',async()=>{
  await setBusinessDate('2026-08-08');
  for(const amount of [5000,6000,6001,12350]){
    const saved=await one(`select * from public.record_business_expense(
      p_request_id=>$1,p_category=>'စက်သုံးဆီ',p_amount_kyat=>$2,
      p_payment_method=>'CASH',p_payment_reference=>null,p_notes=>'နေ့စဉ်သုံးငွေ'
    )`,[randomUUID(),amount]);
    assert.match(saved.expense_ref,/^EX-20260808-\d{6,}$/);
    assert.equal(Number(saved.amount_kyat),amount);
    const cash=await one('select * from public.cash_ledger_entries where document_ref=$1',[saved.expense_ref]);
    assert.equal(cash.direction,'OUT');assert.equal(cash.category,'EXPENSE');assert.equal(Number(cash.amount_kyat),amount);
  }
  await assert.rejects(db.query(`select * from public.record_business_expense(
    p_request_id=>$1,p_category=>'စက်သုံးဆီ',p_amount_kyat=>0,
    p_payment_method=>'CASH',p_payment_reference=>null,p_notes=>null
  )`,[randomUUID()]),/positive whole kyat/i);
});

test('seven-day cash flow is aggregated server-side beyond the row-list limit',async()=>{
  await setBusinessDate('2026-09-01');
  await db.exec('begin');
  try{
    await db.exec('reset role');
    await db.query(`with source as (
      select n,gen_random_uuid() id,gen_random_uuid() request_id,
        'EX-20260901-'||lpad((800000+n)::text,6,'0') document_ref
      from generate_series(1,1005) as rows(n)
    )
    insert into public.finance_transactions(
      id,request_id,request_payload,document_ref,document_type,
      business_date,created_by
    )
    select id,request_id,'{}'::jsonb,document_ref,'EXPENSE','2026-09-01',$1
    from source`,[owner]);
    await db.query(`insert into public.cash_ledger_entries(
      transaction_id,document_ref,business_date,direction,amount_kyat,
      payment_method,category,label,principal_kyat,interest_kyat,created_by
    )
    select id,document_ref,business_date,'OUT',1,'CASH','EXPENSE',
      'cash-flow stress row',0,0,$1
    from public.finance_transactions
    where document_ref like 'EX-20260901-8%'`,[owner]);
    await asOwner();
    const rows=(await db.query('select * from public.get_daily_cash_flow()')).rows;
    assert.equal(rows.length,7);
    const last=rows.at(-1);
    assert.equal(isoDate(last.business_date),'2026-09-01');
    assert.equal(Number(last.cash_in_kyat),0);
    assert.equal(Number(last.cash_out_kyat),1005);
    assert.equal(Number(last.net_kyat),-1005);
    assert.equal(Number(last.physical_cash_in_kyat),0);
    assert.equal(Number(last.physical_cash_out_kyat),1005);
    assert.equal(Number(last.advance_cash_kyat),0);
    assert.equal(Number(last.expense_cash_kyat),1005);
    assert.equal(Number(last.expense_total_kyat),1005);
    assert.equal(Number(last.product_sales_total_kyat),0);
    assert.equal(Number(last.product_sales_cash_kyat),0);
    assert.equal(Number(last.product_sales_non_cash_kyat),0);
    assert.equal(Number(last.non_cash_in_kyat),0);
    assert.equal(Number(last.non_cash_out_kyat),0);
    assert.equal(Number(last.entry_count),1005);
  }finally{
    await db.exec('reset role');
    await db.exec('rollback');
    await asOwner();
  }
});

test('owner-only policies, RPC gates and append-only guards reject bypasses',async()=>{
  await asUser(viewer);
  await assert.rejects(issueCash(),/role|required|permission/i);
  await assert.rejects(db.query('select * from public.get_product_stock_balances()'),/role|required|permission/i);
  await assert.rejects(db.query('select * from public.get_daily_cash_flow()'),/role|required|permission/i);
  assert.equal((await db.query('select * from public.advance_lots')).rows.length,0);
  await asUser(inactive);
  assert.equal((await db.query('select * from public.cash_ledger_entries')).rows.length,0);
  await db.exec('reset role;set role anon');
  await assert.rejects(db.query('select * from public.advance_lots'),/permission denied/i);
  await asOwner();
  await assert.rejects(db.query("insert into public.business_expenses(transaction_id,expense_ref,business_date,category,amount_kyat,payment_method,created_by) values(gen_random_uuid(),'EX-20260101-999999','2026-01-01','x',1,'CASH',$1)",[owner]),/permission denied|row-level security/i);
  await db.exec('reset role');
  const transaction=await one('select id from public.finance_transactions limit 1');
  await assert.rejects(db.query("update public.finance_transactions set status='POSTED' where id=$1",[transaction.id]),/append-only/i);
  const lot=await one('select id from public.advance_lots limit 1');
  await assert.rejects(db.query('delete from public.advance_lots where id=$1',[lot.id]),/repayment workflow/i);
  await asOwner();
});

test('read-only production verifier reports every finance invariant as PASS',async()=>{
  await db.exec('reset role');
  const verifier=await readFile(
    new URL('../supabase/ops/verify_owner_finance_schema.sql',import.meta.url),
    'utf8'
  );
  const result=await db.query(verifier);
  const failures=result.rows.filter(row=>row.status!=='PASS');
  assert.deepEqual(failures,[]);
  assert.equal(result.rows.at(-1).check_name,'OVERALL');
  assert.equal(result.rows.at(-1).status,'PASS');
  await asOwner();
});
