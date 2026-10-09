// Real PostgreSQL (PGlite), isolated in memory. Never touches production.
// Supabase Auth is represented by its users table and auth.uid() claim helper.
// pgcrypto extension registration is omitted; core gen_random_uuid is available.
// PGlite has one connection: these tests do not prove multi-connection races.
import {before,after,test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

let db,owner=randomUUID(),viewer=randomUUID(),inactive=randomUUID(),legacy,legacySnapshot;
const migration=async name=>(await readFile(new URL('../supabase/migrations/'+name,import.meta.url),'utf8')).replaceAll('create extension if not exists pgcrypto;','');
const one=async(sql,params=[])=>(await db.query(sql,params)).rows[0];
const asOwner=async()=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[owner]);};
async function receipt({crop='C-001',submit=true,mode}={}){
  const b=await one("select * from public.create_weighing_batch($1,$2,$3,$4::uuid)",['F-001',crop,'TEST-SPLIT',randomUUID()]);
  if(mode)await db.query('select * from public.set_weighing_intake_mode($1,$2)',[b.id,mode]);
  const bagIds=[];for(let i=1;i<=4;i++){const id=randomUUID();bagIds.push(id);await db.query('select * from public.add_bag_weight($1,$2,$3,$4,$5,$6,$7,$8)',[b.id,id,i,10000,crop==='C-004'?'DRY':null,crop==='C-004'?10:null,crop==='C-004'?'A':null,'TEST-SPLIT']);}
  if(submit)await db.query('select * from public.submit_weighing_batch($1)',[b.id]);
  return {...b,bagIds};
}
async function allocate(b,{sale=5000,moisture=1000,waste=2000,tare=2000,request=randomUUID(),notes=null,location='WH-001'}={}){
  return one('select * from public.allocate_weighing_intake($1,$2,$3,$4,$5,$6,$7,$8)',[b.id,location,moisture,waste,tare,sale,notes,request]);
}
before(async()=>{
  db=new PGlite();
  await db.exec("set max_stack_depth='100kB'");
  await db.exec(`create role anon;create role authenticated;create role service_role;
    create schema auth;create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}',created_at timestamptz default now());
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
    grant usage on schema auth to authenticated,anon,service_role;
    create publication supabase_realtime;`);
  for(const f of ['202608120001_bag_weights_realtime.sql','202608130001_weighing_batches_master_data.sql','202608260001_offline_queue_integrity.sql','202609010001_weighing_batches_offline_history.sql','202609030001_farmer_bean_consignment.sql'])await db.exec(await migration(f));
  await db.query("insert into auth.users(id,email) values($1,'owner@test.invalid'),($2,'viewer@test.invalid'),($3,'inactive@test.invalid')",[owner,viewer,inactive]);
  await db.query("update public.staff_members set role='owner',active=true where user_id=$1",[owner]);
  await db.query("update public.staff_members set role='viewer',active=true where user_id=$1",[viewer]);
  await db.exec(await migration('202609040000_business_date_ambiguity.sql'));
  await asOwner();legacy=await receipt({mode:'FARMER_CONSIGNMENT'});
  legacySnapshot=await one('select * from public.accept_farmer_consignment($1,$2,$3,$4,$5,$6,$7)',[legacy.id,'WH-001',1000,2000,2000,null,randomUUID()]);
  // Validate the exact one-file handoff, including its outer transaction.
  await import('../scripts/build-split-upgrade.mjs');
  const upgrade=await readFile(new URL('../outputs/split-intake-upgrade.sql',import.meta.url),'utf8');
  const applied=await db.exec(upgrade);
  assert.equal(applied.at(-1).rows[0].result,'SPLIT_READY');
  await db.exec(await migration('202609080001_master_data_stage2.sql'));
});
after(async()=>{await db?.close()});

test('new receipt is neutral and SQL splits net 350 into 50 plus 300',async()=>{
  await asOwner();const b=await receipt();assert.equal(b.intake_mode,'UNALLOCATED');const a=await allocate(b);
  assert.equal(a.net_centi_pyitha,35000);assert.equal(a.sale_reserved_centi_pyitha,5000);assert.equal(a.consigned_centi_pyitha,30000);assert.equal(a.sale_state,'PENDING_SETTLEMENT');
  const l=await one('select * from public.consignment_lots where id=$1',[a.consignment_lot_id]);assert.equal(l.original_net_weight_centi_pyitha,30000);assert.equal(l.available_weight_centi_pyitha,30000);
  const h=await one('select status,intake_mode from public.weighing_batches where id=$1',[b.id]);assert.equal(h.status,'SUBMITTED');assert.equal(h.intake_mode,'SPLIT');
  const m=await one('select count(*)::int n,sum(quantity_centi_pyitha)::bigint q from public.consignment_movements where lot_id=$1',[l.id]);assert.equal(m.n,1);assert.equal(m.q,30000);
});
test('retry returns same result without a second deposit, conflicting retry fails',async()=>{
  const b=await receipt(),request=randomUUID(),a=await allocate(b,{request,notes:'source'});
  assert.equal((await allocate(b,{request,notes:'source'})).id,a.id);
  assert.equal((await allocate(b,{notes:'source'})).id,a.id);
  await assert.rejects(allocate(b,{request,sale:6000,notes:'source'}),/already allocated/);
  await assert.rejects(allocate(b,{request,notes:'changed'}),/already allocated/);
  const other=await receipt();await assert.rejects(allocate(other,{request}),/another receipt/);
  assert.equal((await one('select count(*)::int n from public.intake_allocations where batch_id=$1',[other.id])).n,0);
});
test('all sale has no lot and all custody deposits full net',async()=>{
  const sale=await allocate(await receipt(),{sale:35000});assert.equal(sale.consignment_lot_id,null);assert.equal(sale.consigned_centi_pyitha,0);assert.equal(sale.sale_state,'PENDING_SETTLEMENT');
  const custody=await allocate(await receipt(),{sale:0});assert.equal(custody.sale_state,'NOT_APPLICABLE');assert.equal(custody.consigned_centi_pyitha,35000);
});
test('invalid amounts, draft and chili are rejected without allocation',async()=>{
  const b=await receipt();for(const change of [{sale:-1},{sale:35001},{sale:null},{moisture:40000},{tare:'9223372036854775807'}])await assert.rejects(allocate(b,change));
  assert.equal((await one('select count(*)::int n from public.intake_allocations where batch_id=$1',[b.id])).n,0);
  await assert.rejects(allocate(await receipt({submit:false})),/Submit all bags/);
  await assert.rejects(allocate(await receipt({crop:'C-004'})),/beans only/);
  await assert.rejects(allocate(b,{location:'MISSING'}),/Active stock location/);
});
test('legacy lots are preserved and old client cannot overwrite mixed allocation',async()=>{
  const old=await one('select * from public.consignment_lots where id=$1',[legacySnapshot.id]);
  for(const [key,value] of Object.entries(legacySnapshot))assert.deepEqual(old[key],value,key);
  assert.equal(old.sale_reserved_centi_pyitha,0);await assert.rejects(allocate(legacy),/Legacy consignment already accepted/);
  const b=await receipt();await allocate(b);
  await assert.rejects(db.query('select * from public.accept_farmer_consignment($1,$2,$3,$4,$5,$6,$7)',[b.id,'WH-001',1000,2000,2000,null,randomUUID()]),/already allocated/);
});
test('allocated source bags, totals and batch void are protected',async()=>{
  const b=await receipt();await allocate(b);
  await assert.rejects(db.query('select * from public.void_bag_weight($1,$2)',[b.bagIds[0],'test correction']),/immutable/);
  await assert.rejects(db.query('select * from public.void_weighing_batch($1,$2)',[b.id,'test correction']),/immutable/);
  const row=await one('select status,total_bags,total_gross_weight_centi_pyitha from public.weighing_batches where id=$1',[b.id]);
  assert.equal(row.status,'SUBMITTED');assert.equal(row.total_bags,4);assert.equal(row.total_gross_weight_centi_pyitha,40000);
});
test('allocation audit is immutable, anonymous and direct authenticated writes are denied',async()=>{
  const b=await receipt(),a=await allocate(b);
  await assert.rejects(db.query('update public.intake_allocations set notes=$1 where id=$2',['edit',a.id]),/append-only/);
  await assert.rejects(db.query('delete from public.intake_allocations where id=$1',[a.id]),/append-only/);
  await db.exec('set role authenticated');
  await assert.rejects(db.query('delete from public.intake_allocations where id=$1',[a.id]),/permission denied/);
  await db.exec('reset role;set role anon');await assert.rejects(db.query('select * from public.intake_allocations'),/permission denied/);await asOwner();
});
test('viewer cannot allocate and inactive staff cannot read',async()=>{
  const b=await receipt();await db.query("select set_config('request.jwt.claim.sub',$1,false)",[viewer]);await db.exec('set role authenticated');
  await assert.rejects(allocate(b),/permission|role|allowed|access/i);
  await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[inactive]);await db.exec('set role authenticated');
  assert.equal((await db.query('select * from public.intake_allocations')).rows.length,0);await asOwner();
});
test('pending selector excludes accepted legacy and split receipts',async()=>{
  const b=await receipt();await allocate(b);const pending=(await db.query('select * from public.list_unallocated_weighing_batches(100)')).rows;
  assert.equal(pending.some(r=>r.id===b.id||r.id===legacy.id),false);
  assert.ok(pending.every(r=>r.status==='SUBMITTED'&&r.crop_type_id!=='C-004'));
});

test('authenticated accountant path can split but cannot directly insert',async()=>{
  const b=await receipt();await db.exec('set role authenticated');
  const a=await allocate(b);assert.equal(a.consigned_centi_pyitha,30000);
  assert.equal((await db.query('select * from public.intake_allocations where id=$1',[a.id])).rows.length,1);
  await assert.rejects(db.query('insert into public.intake_allocations default values'),/permission denied/);
  await asOwner();
});
test('duplicate legacy operation id rolls back the new mode, lot and counters',async()=>{
  const b=await receipt(),before=await one('select sum(last_value)::int n from public.consignment_document_counters');
  await assert.rejects(allocate(b,{request:legacySnapshot.acceptance_request_id}),/duplicate key/);
  assert.equal((await one('select intake_mode from public.weighing_batches where id=$1',[b.id])).intake_mode,'UNALLOCATED');
  assert.equal((await one('select count(*)::int n from public.consignment_lots where batch_id=$1',[b.id])).n,0);
  assert.deepEqual(await one('select sum(last_value)::int n from public.consignment_document_counters'),before);
});
test('legacy statement trigger submits siblings and terminates on zero matches',async()=>{
  const b=await receipt({submit:false});
  await db.query("update public.bag_weights set status='SUBMITTED' where id=$1",[b.bagIds[0]]);
  const rows=(await db.query('select status from public.bag_weights where batch_id=$1',[b.id])).rows;
  assert.ok(rows.every(r=>r.status==='SUBMITTED'));
  await db.exec("update public.bag_weights set status='SUBMITTED' where false");
});

test('stage 2 opening balances commit atomically and retry idempotently',async()=>{
  await asOwner();await db.exec('set role authenticated');
  const request=randomUUID(),rows=[{customer_id:'F-001',opening_date:'2026-08-01',principal_kyat:'100000',monthly_rate:'3',notes:'opening cash'}];
  const first=await one('select * from public.commit_opening_balance_import($1,$2,$3,$4::jsonb,$5)',[request,'FARMER_DEBT','opening.csv',JSON.stringify(rows),'verified']);
  assert.match(first.import_ref,/^OB-\d{8}-\d{6,}$/);assert.equal(first.row_count,1);assert.equal(first.total_principal_kyat,100000);assert.equal(first.idempotent,false);
  const retry=await one('select * from public.commit_opening_balance_import($1,$2,$3,$4::jsonb,$5)',[request,'FARMER_DEBT','changed.csv','[]',null]);
  assert.equal(retry.import_id,first.import_id);assert.equal(retry.idempotent,true);
  assert.equal((await one('select opening_debt_kyat from public.farmers where customer_id=$1',['F-001'])).opening_debt_kyat,100000);
  await assert.rejects(db.query('update public.opening_balance_entries set principal_kyat=1 where import_id=$1',[first.import_id]),/permission denied|immutable/i);
  await db.exec('reset role');
});

test('stage 2 opening stock validates whole units and rolls back all bad rows',async()=>{
  await asOwner();await db.exec('set role authenticated');
  const good=await one('select * from public.commit_opening_balance_import($1,$2,$3,$4::jsonb,$5)',[randomUUID(),'PRODUCT_STOCK','products.csv',JSON.stringify([{product_id:'P-001',location_id:'WH-001',quantity:'12',notes:null}]),null]);
  assert.equal(Number(good.total_quantity),12);
  const before=(await one('select count(*)::int n from public.opening_balance_imports')).n;
  await assert.rejects(db.query('select * from public.commit_opening_balance_import($1,$2,$3,$4::jsonb,$5)',[randomUUID(),'PRODUCT_STOCK','bad.csv',JSON.stringify([{product_id:'P-001',location_id:'WH-001',quantity:'1.5'},{product_id:'P-002',location_id:'WH-001',quantity:'2'}]),null]),/whole-unit/i);
  assert.equal((await one('select count(*)::int n from public.opening_balance_imports')).n,before);
  await db.exec('reset role');
});

test('stage 2 master writes remain role-gated and anonymous reads are denied',async()=>{
  await asOwner();await db.exec('set role authenticated');
  const inserted=await one("insert into public.crop_types(name,category,settlement_method,default_tare_centi_pyitha,pricing_divisor_pyitha,notes) values('Stage Two Bean','BEAN','BATCH',20,20,'test') returning crop_type_id");
  assert.match(inserted.crop_type_id,/^C-\d{3,}$/);
  await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[viewer]);await db.exec('set role authenticated');
  await assert.rejects(db.query("insert into public.products(name,category,unit_name) values('Denied','OTHER','ခု')"),/row-level security|permission denied/i);
  await db.exec('reset role;set role anon');await assert.rejects(db.query('select * from public.opening_balance_imports'),/permission denied/i);await asOwner();
});
