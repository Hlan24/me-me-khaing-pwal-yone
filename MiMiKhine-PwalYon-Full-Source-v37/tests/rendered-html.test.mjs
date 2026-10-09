import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render(pathname = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(new Request(`https://example.test${pathname}`));
}

test("serves the full Pwal Yon dashboard", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);
  const html = await response.text();
  assert.match(html, /မီမီခိုင် ပွဲရုံ/);
  assert.doesNotMatch(html, /ရွှေဝါ ပွဲရုံ/);
  assert.match(html, /MI MI KHINE PWAL YON/);
  assert.doesNotMatch(html, /SHWE WAR PWAL YON/i);
  assert.match(html, /Mobile Weighing & Live Sync/);
  assert.match(html, /ကုန်ပစ္စည်း လက်ငင်းအရောင်း/);
  assert.match(html, /Live System Readiness/);
  assert.match(html, /LIVE · အိတ်ချိန် \+ Master \+ Finance/);
  assert.match(html, /Supabase · Login လိုသည်/);
  assert.match(html, /Supabase Live Data/);
  assert.match(html, /bag_weights/);
  assert.doesNotMatch(html, /codex-preview/);
});

test("keeps the sidebar menu separate from the user profile", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  const sideCss = source.match(/\.side\{([^}]*)\}/)?.[1] ?? "";
  const navCss = source.match(/\.nav\{([^}]*)\}/)?.[1] ?? "";
  const profileCss = source.match(/\.profile\{([^}]*)\}/)?.[1] ?? "";

  assert.match(sideCss, /display:flex/);
  assert.match(sideCss, /flex-direction:column/);
  assert.match(sideCss, /height:100dvh/);
  assert.match(sideCss, /overflow:hidden/);
  assert.match(navCss, /flex:1 1 auto/);
  assert.match(navCss, /min-height:0/);
  assert.match(navCss, /overflow-y:auto/);
  assert.match(profileCss, /position:static/);
  assert.doesNotMatch(profileCss, /position:absolute/);

  assert.match(
    source,
    /id="menu"[^>]*aria-controls="side"[^>]*aria-expanded="false"/,
  );
  assert.match(source, /id="sidebarOverlay"[^>]*hidden/);
  assert.match(source, /side\.inert=mobile&&!isOpen/);
  assert.match(source, /event\.key==='Escape'/);
});

test("keeps an accessible local-session logout beside the sidebar profile", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  const logoutTag =
    source.match(/<button\b[^>]*\bid="sidebarSignOut"[^>]*>/)?.[0] ?? "";
  assert.match(logoutTag, /\btype="button"/);
  assert.match(logoutTag, /\bhidden\b/);
  assert.match(logoutTag, /\bdisabled\b/);
  assert.match(logoutTag, /aria-label="ဤစက်မှ Logout"/);
  assert.match(source, /\.profile-copy\{[^}]*min-width:0;flex:1/);
  assert.match(source, /\.profile-logout\{[^}]*min-height:44px/);
  assert.match(source, /\.profile-logout:focus-visible\{[^}]*outline:/);
  assert.match(source, /\.profile-logout\[hidden\]\{display:none!important\}/);
  assert.match(
    source,
    /let hasSession=Boolean\(supabaseSessionUser\);sidebarSignOut\.hidden=!hasSession;sidebarSignOut\.disabled=!hasSession;supabaseSignOut\.disabled=!hasSession/,
  );
  assert.match(source, /signOut\(\{scope:'local'\}\)/);
  assert.match(source, /let\{error\}=await supabaseClient\.auth\.signOut\(\{scope:'local'\}\);if\(error\)throw error/);
  assert.match(source, /await stopSupabaseRealtime\(\);supabaseSessionUser=null;supabaseStaffMember=null/);
  assert.match(source, /setSupabaseState\('LOGIN_REQUIRED'/);
  assert.match(source, /supabaseSignOut\.onclick=logoutCurrentDevice;sidebarSignOut\.onclick=logoutCurrentDevice/);
  assert.match(source, /closeSidebar\(true\);openSupabaseSettings\(\)/);
  assert.equal((source.match(/signOut\(\{scope:'local'\}\)/g) ?? []).length, 1);
});

test("persists each mobile bag locally before idempotent Supabase sync", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(
    source,
    /cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2\.112\.3/,
  );
  assert.doesNotMatch(source, /@supabase\/supabase-js@2["/]/);
  assert.match(source, /globalThis\.supabase\.createClient/);
  assert.match(source, /async function saveBagWeightToSupabase/);
  assert.match(source, /\.rpc\('create_weighing_batch'/);
  assert.match(source, /\.rpc\('add_bag_weight'/);
  assert.match(source, /\.rpc\('submit_weighing_batch'/);
  assert.match(source, /\.rpc\('void_bag_weight'/);
  assert.match(source, /\.rpc\('void_weighing_batch'/);
  assert.match(source, /async function addBag\(\)/);
  assert.match(source, /await putOfflineWeighingEntry\([\s\S]{0,2500}?syncBagOutbox\(/);
  assert.match(source, /weight_centi_pyitha:centi/);
  assert.match(source, /activeSupabaseBatchId=createUuid\(\)/);
  assert.match(source, /pendingBagAttempt/);
  assert.match(source, /bagSaveInFlight/);
  assert.doesNotMatch(source, /\.from\('bag_weights'\)\.insert\(/);
  assert.doesNotMatch(source, /\.from\('bag_weights'\)\.update\(/);

  assert.match(source, /\.channel\('pwal-yon-live-'/);
  assert.match(
    source,
    /\.on\('postgres_changes',\{event:'\*',schema:'public',table:'weighing_batches'/,
  );
  assert.match(
    source,
    /\.on\('postgres_changes',\{event:'\*',schema:'public',table:'bag_weights'/,
  );
  assert.match(source, /handleBagWeightChange/);
  assert.match(source, /async function loadTodayBagWeights/);
  assert.match(source, /renderLiveBatchTable/);

  assert.match(source, /let bags=\[\],bagMeta=\[\],bagIdentity=\[\],nextBagNumber=1/);
  assert.doesNotMatch(source, /bags=\[3020,2980,3050\]/);
  assert.doesNotMatch(source, /bagIdentity=\[\{id:'DEMO-001'/);
});

test("requires Supabase Auth and never embeds a privileged key", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /signInWithPassword/);
  assert.doesNotMatch(source, /\.auth\.signUp\s*\(/);
  assert.match(source, /persistSession:true/);
  assert.match(source, /autoRefreshToken:true/);
  assert.match(source, /if\(!supabaseClient\|\|!supabaseSessionUser\)throw/);
  assert.match(source, /Publishable Key/);

  assert.match(
    source,
    /url:'https:\/\/usufheovofmqchjlzlsz\.supabase\.co'/,
  );
  assert.match(
    source,
    /publishableKey:'sb_publishable_6jRi6u2_EuB9O9ipP_YuRg_T5eSyK2D'/,
  );
  assert.doesNotMatch(source, /\bid="supabaseUrl"/);
  assert.doesNotMatch(source, /\bid="supabasePublishableKey"/);
  assert.doesNotMatch(source, /\bid="saveSupabaseConfig"/);
  assert.doesNotMatch(source, /\bid="clearSupabaseConfig"/);
  assert.match(
    source,
    /if\(pinned\.url&&pinned\.publishableKey\)return pinned/,
  );
  assert.match(source, /signOut\(\{scope:'local'\}\)/);

  assert.doesNotMatch(source, /sb_secret_[A-Za-z0-9_-]{20,}/);
  assert.doesNotMatch(source, /service_role\s*[:=]\s*['"][^'"]+/i);
});

test("supports secure invited-user password setup and password recovery", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /id="supabasePasswordSetupForm" hidden/);
  assert.match(source, /id="supabaseNewPassword"[^>]*autocomplete="new-password"[^>]*minlength="10"/);
  assert.match(source, /id="supabaseConfirmPassword"[^>]*autocomplete="new-password"[^>]*minlength="10"/);
  assert.match(source, /event==='PASSWORD_RECOVERY'/);
  assert.match(source, /action==='recovery'\|\|\['invite','recovery'\]\.includes\(type\)/);
  assert.match(source, /accessToken=hash\.get\('access_token'\)\|\|query\.get\('access_token'\)/);
  assert.match(source, /refreshToken=hash\.get\('refresh_token'\)\|\|query\.get\('refresh_token'\)/);
  assert.match(source, /supabaseClient\.auth\.updateUser\(\{password\}\)/);
  assert.match(source, /password\.length<10/);
  assert.match(source, /password!==confirmPassword/);
  assert.match(source, /cleanSupabaseAuthCallbackUrl\(\)/);
  assert.match(source, /history\.replaceState/);

  assert.match(source, /id="supabaseResetPassword"/);
  assert.match(source, /supabaseClient\.auth\.resetPasswordForEmail\(email,\{redirectTo\}\)/);
  assert.match(source, /new URL\('\/pwal-yon-dashboard\.html\?auth_action=recovery',location\.origin\)\.href/);
  assert.match(source, /supabaseClient\.auth\.exchangeCodeForSession\(supabaseAuthCallbackIntent\.code\)/);
  assert.match(source, /supabaseClient\.auth\.verifyOtp\(\{token_hash:supabaseAuthCallbackIntent\.tokenHash,type:supabaseAuthCallbackIntent\.type\}\)/);
  assert.match(source, /supabaseClient\.auth\.setSession\(\{access_token:supabaseAuthCallbackIntent\.accessToken,refresh_token:supabaseAuthCallbackIntent\.refreshToken\}\)/);
  assert.match(source, /supabasePasswordSetupAuthorized=Boolean\(session\?\.user\)/);
  assert.match(source, /if\(callbackVerified&&data\.session\)/);
  assert.match(source, /else if\(!\(supabaseAuthCallbackIntent\.hasTokens\|\|supabaseAuthCallbackIntent\.code\|\|supabaseAuthCallbackIntent\.tokenHash\)\)/);
  assert.match(source, /if\(!supabasePasswordSetupAuthorized\)/);
  assert.match(source, /Password reset link သက်တမ်းကုန်သွားသည် သို့မဟုတ် Session မရပါ/);
  assert.match(source, /callbackKeys=\['auth_action'/);
  const openSettingsBody = source.match(/function openSupabaseSettings\(\)\{([^}]*)\}/)?.[1] ?? "";
  assert.doesNotMatch(openSettingsBody, /setSupabaseError\(''\)/);
  assert.match(source, /openSupabaseSettings\(\);setSupabaseError\(message\)/);
  assert.doesNotMatch(source, /localStorage\.setItem\([^\n]*(?:password|supabaseNewPassword|supabaseConfirmPassword)/i);
  assert.doesNotMatch(source, /\.auth\.signUp\s*\(/);
});

test("bridges root auth callbacks into the full-page dashboard route", async () => {
  const page = await readFile(
    new URL("../app/page.tsx", import.meta.url),
    "utf8",
  );

  assert.match(page, /keys=\['auth_action','code','token','token_hash','type','error','error_code','error_description','access_token','refresh_token'\]/);
  assert.match(page, /location\.replace\('\/pwal-yon-dashboard\.html'\+location\.search\+location\.hash\)/);
  assert.match(page, /src="\/pwal-yon-dashboard\.html"/);
  assert.doesNotMatch(page, /console\.(?:log|error|warn)\([^\n]*(?:location|hash|search|token)/i);
});

test("ships a constrained RLS-enabled bag_weights migration", async () => {
  const migration = await readFile(
    new URL(
      "../supabase/migrations/202608120001_bag_weights_realtime.sql",
      import.meta.url,
    ),
    "utf8",
  );

  assert.match(migration, /create table if not exists public\.bag_weights/i);
  assert.match(migration, /weight_centi_pyitha integer not null/i);
  assert.match(migration, /weight_centi_pyitha between 1 and 20000/i);
  assert.match(migration, /bag_no integer not null/i);
  assert.match(migration, /unique \(batch_id, bag_no\)/i);
  assert.match(migration, /enable row level security/i);
  assert.match(migration, /to authenticated/i);
  assert.match(migration, /auth\.uid\(\)/i);
  assert.match(migration, /alter publication supabase_realtime/i);
  assert.match(migration, /create table if not exists public\.staff_members/i);
  assert.match(migration, /active boolean not null default false/i);
  assert.match(migration, /role in \('owner', 'admin', 'weigher', 'accountant', 'viewer'\)/i);
  assert.match(migration, /create_inactive_staff_member/i);
  assert.match(migration, /after insert on auth\.users/i);
  assert.match(migration, /current_staff_is_active\(\)/i);
  assert.match(migration, /current_staff_has_role\(required_roles text\[\]\)/i);
  assert.match(migration, /Active staff can read bag weights/i);
  assert.match(migration, /Active weighing staff can insert own bag weights/i);
  assert.doesNotMatch(
    migration,
    /create policy "Active staff can read bag weights"[\s\S]*?using\s*\(\s*true\s*\)/i,
  );
  assert.doesNotMatch(
    migration,
    /create policy[\s\S]*?to anon[\s\S]*?with check\s*\(\s*true\s*\)/i,
  );
});

test("ships canonical weighing headers, offline date integrity, and RPC-only hardening", async () => {
  const masterMigration = await readFile(
    new URL(
      "../supabase/migrations/202608130001_weighing_batches_master_data.sql",
      import.meta.url,
    ),
    "utf8",
  );
  const offlineMigration = await readFile(
    new URL(
      "../supabase/migrations/202608260001_offline_queue_integrity.sql",
      import.meta.url,
    ),
    "utf8",
  );
  const hardeningMigration = await readFile(
    new URL(
      "../supabase/migrations/202609010001_weighing_batches_offline_history.sql",
      import.meta.url,
    ),
    "utf8",
  );

  assert.match(masterMigration, /create table if not exists public\.weighing_batches/i);
  assert.match(masterMigration, /batch_ref text not null/i);
  assert.match(masterMigration, /voucher_ref text/i);
  assert.match(masterMigration, /total_gross_weight_centi_pyitha bigint not null/i);
  assert.match(masterMigration, /status in \('DRAFT', 'SUBMITTED', 'SETTLED', 'VOID'\)/i);
  assert.match(masterMigration, /foreign key \(batch_id\)[\s\S]*?references public\.weighing_batches \(id\)/i);
  assert.match(masterMigration, /validate constraint bag_weights_batch_fk/i);
  assert.match(masterMigration, /create index if not exists weighing_batches_history_idx/i);
  assert.match(masterMigration, /create or replace function public\.add_bag_weight/i);
  assert.match(masterMigration, /public\.next_document_ref\('WR', business_date\)/i);
  assert.match(masterMigration, /insert into public\.weighing_audit_events/i);

  assert.match(offlineMigration, /create or replace function public\.register_weighing_business_date/i);
  assert.match(offlineMigration, /valid_until timestamptz/i);
  assert.match(offlineMigration, /interval '72 hours'/i);
  assert.match(
    offlineMigration,
    /create or replace function public\.create_weighing_batch\([\s\S]*?p_business_date date/i,
  );
  assert.match(offlineMigration, /Existing batch identity does not match this request/i);

  assert.match(hardeningMigration, /validate constraint bag_weights_batch_fk/i);
  assert.match(hardeningMigration, /weighing_batches_status_history_page_idx/i);
  assert.match(hardeningMigration, /alter table public\.weighing_batches force row level security/i);
  assert.match(hardeningMigration, /alter table public\.bag_weights force row level security/i);
  assert.match(hardeningMigration, /using \(public\.current_staff_is_active\(\)\)/i);
  assert.match(hardeningMigration, /revoke all privileges[\s\S]*?on table public\.bag_weights[\s\S]*?from anon, authenticated/i);
  assert.match(hardeningMigration, /revoke update \(status, batch_ref\)[\s\S]*?from anon, authenticated/i);
  assert.match(hardeningMigration, /alter publication supabase_realtime[\s\S]*?add table public\.weighing_batches/i);
  assert.doesNotMatch(hardeningMigration, /create table if not exists public\.weighing_batches/i);
  assert.doesNotMatch(hardeningMigration, /create or replace function public\.submit_weighing_batch/i);
});

test("keeps a durable IndexedDB weighing outbox across refreshes", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /WEIGHING_OFFLINE_DB='mimi-khine-weighing-offline-v1'/);
  assert.match(source, /indexedDB\.open\(WEIGHING_OFFLINE_DB,WEIGHING_OFFLINE_DB_VERSION\)/);
  assert.match(source, /createObjectStore\(WEIGHING_BATCH_STORE,\{keyPath:'id'\}\)/);
  assert.match(source, /createObjectStore\(WEIGHING_BAG_STORE,\{keyPath:'id'\}\)/);
  assert.match(source, /createObjectStore\(WEIGHING_META_STORE,\{keyPath:'key'\}\)/);
  assert.match(source, /async function putOfflineWeighingBatch\(/);
  assert.match(source, /async function putOfflineBagWeight\(/);
  assert.match(source, /async function readOfflineWeighingBatches\(/);
  assert.match(source, /async function readOfflineBagWeights\(/);
  assert.match(source, /function syncBagOutbox\(/);
  assert.match(source, /async function restoreOfflineDraftBatch\(/);
  assert.match(source, /async function mutateOfflineWeighingBatch\(/);
  assert.match(source, /async function mutateOfflineBagWeight\(/);
  assert.match(source, /bagOutboxRequestVersion\+\+/);
  assert.match(
    source,
    /record\.desired_status==='VOID'\|\|record\.sync_state!=='SYNCED'\|\|!record\.server_synced[\s\S]{0,500}?saveBagWeightToSupabase\(record\)[\s\S]{0,800}?voidBagWeightInSupabase\(record\.id\)/,
  );
  assert.match(source, /result\.errors\.push\(\{batchId:snapshot\.id,error\}\)/);
  assert.match(source, /sync_state:'PENDING'/);
  assert.match(source, /retryBagOutbox\.onclick=/);
  assert.match(source, /window\.addEventListener\('online',[\s\S]{0,1000}?syncBagOutbox\(/);
  assert.doesNotMatch(
    source,
    /localStorage\.(?:setItem|getItem)\([^\n]*(?:bag.?outbox|bag.?queue|weighing-offline)/i,
  );
});

test("allows a new batch after submit without waiting for settlement", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.doesNotMatch(source, /ဤ Batch ကို ငွေရှင်းပြီးမှ Batch အသစ်ဖွင့်နိုင်ပါသည်/);
  assert.doesNotMatch(
    source,
    /\(isChiliCrop\(\)\?'CHW-':'WB-'\)\+new Date\(\)\.toISOString\(\)[\s\S]{0,400}?Date\.now\(\)/,
  );
  assert.match(source, /submit_requested:true,[^\n]{0,120}?status:'SUBMIT_PENDING'/);
  assert.match(source, /void_requested:true,[^\n]{0,120}?status:'VOID_PENDING'/);
  assert.match(source, /resetBatch\.onclick=[\s\S]{0,4000}?resetLocalBatchState\(\)/);
  assert.match(source, /function resetLocalBatchState\(\)[\s\S]{0,1000}?activeSupabaseBatchId=createUuid\(\)/);
  assert.match(source, /currentTransaction=header\.batch_number\|\|currentTransaction/);
});

test("preserves the server-confirmed offline business-date window across reloads", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  const applyDateFunction = source.match(
    /function applyServerBusinessDate\([\s\S]*?(?=async function fetchServerBusinessDate\()/,
  )?.[0] ?? "";

  assert.ok(applyDateFunction, "applyServerBusinessDate must exist");
  assert.doesNotMatch(applyDateFunction, /putOfflineMeta\(/);
  assert.match(
    source,
    /async function fetchServerBusinessDate\(\)[\s\S]{0,1600}?putOfflineMeta\(\{key:'server_business_date',value:date,user_id:supabaseSessionUser\.id,device_id:deviceId,confirmed_at:confirmedAt,valid_until:validUntil/,
  );
  assert.doesNotMatch(source, /confirmed_at:row\?\.confirmed_at\|\|new Date/);
  assert.match(source, /validUntilMs<=confirmedMs/);
  assert.match(
    source,
    /let cachedDate=await getOfflineMeta\('server_business_date'\);if\(cachedDate\?\.value\)applyServerBusinessDate\(cachedDate\.value,\{forceHistory:true\}\)/,
  );
  assert.match(
    source,
    /context\?\.user_id!==supabaseSessionUser\?\.id/,
  );
  assert.match(source, /context\?\.device_id!==deviceId/);
  assert.match(source, /Date\.parse\(context\?\.valid_until\|\|''\)/);
});

test("loads weighing history with server filters and pagination", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /WEIGHING_HISTORY_PAGE_SIZE=20/);
  assert.match(source, /async function loadWeighingHistoryPage\(/);
  assert.match(source, /\.from\('weighing_batches'\)\.select\(WEIGHING_BATCH_COLUMNS,\{count:'exact'\}\)/);
  assert.match(source, /\.gte\('business_date',from\)\.lte\('business_date',to\)/);
  assert.match(source, /query=query\.eq\('status',historyStatus\.value\)/);
  assert.match(source, /\.range\(offset,offset\+WEIGHING_HISTORY_PAGE_SIZE-1\)/);
  assert.match(source, /weighingHistoryForm\.onsubmit=/);
  assert.match(source, /historyPrevious\.onclick=/);
  assert.match(source, /historyNext\.onclick=/);
  assert.match(source, /\.from\('bag_weights'\)\.select\(BAG_WEIGHT_COLUMNS\)\.eq\('batch_id',batchId\)\.order\('bag_no'/);
  assert.match(source, /\.rpc\('register_weighing_business_date'/);
  assert.match(source, /p_business_date:businessDate/);
});

test("checks active staff membership before reading or writing bags", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /\.from\('staff_members'\)/);
  assert.match(source, /function requireActiveStaff\(\)/);
  assert.match(source, /supabaseStaffMember\?\.active/);
  assert.match(source, /requireActiveStaff\(\);let\{data,error\}=await supabaseClient\.rpc\('add_bag_weight'/);
  assert.match(source, /code==='PGRST205'/);
  assert.match(source, /invalid login credentials/i);
  assert.match(source, /email not confirmed/i);
  assert.match(source, /code==='STAFF_INACTIVE'/);
  assert.match(source, /id="profileName"/);
  assert.match(source, /id="profileRole"/);
});

test("keeps a subscribed same-user realtime session visibly LIVE", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(
    source,
    /let reuseRealtime=priorId===nextId&&Boolean\(supabaseChannel\);setSupabaseState\('CONNECTING','Staff အသုံးပြုခွင့်နှင့် Server Business Date စစ်နေသည်'\)/,
  );
  assert.match(
    source,
    /if\(!reuseRealtime&&navigator\.onLine\)await startSupabaseRealtime\(\);else if\(reuseRealtime&&supabaseRealtimeReady\)restoreSupabaseConnectionState\('Active Staff session အတည်ပြုပြီး · Realtime ဆက်ချိတ်ထားသည်'\)/,
  );
  assert.match(
    source,
    /function restoreSupabaseConnectionState\(detail\)\{setSupabaseState\(supabaseRealtimeReady\?'LIVE':'CONNECTING',detail\)\}/,
  );
  assert.match(
    source,
    /if\(status==='SUBSCRIBED'\)\{supabaseRealtimeReady=true;setSupabaseState\('LIVE'/,
  );
  assert.match(source, /syncBagOutbox\(\{quiet:true\}\)\.catch/);
});

test("labels every production ledger accurately and removes the old write locks", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /LIVE · အိတ်ချိန် \+ Master \+ Finance \+ Stock/);
  assert.match(source, /အိတ်ချိန်မှ Day Close အထိ Supabase Server Ledger/);
  assert.match(source, /const PILOT_LOCKED_WRITE_IDS=\[\]/);
  for (const id of ["saveSale", "finalizeDay", "finalizeSettlement", "finalizeChiliSettlement"]) {
    assert.doesNotMatch(source, new RegExp(`PILOT_LOCKED_WRITE_IDS[^;]*['"]${id}['"]`));
  }
  assert.match(source, /data-pilot-write="locked"/);
  for (const id of ["farmerForm", "productForm", "cropForm"]) {
    assert.doesNotMatch(source, new RegExp(`PILOT_LOCKED_WRITE_IDS[^;]*['"]${id}['"]`));
  }
  for (const id of [
    "advancePrint",
    "saveAdvanceRepayment",
    "saveInputSale",
    "saveExpense",
  ]) {
    assert.doesNotMatch(source, new RegExp(`PILOT_LOCKED_WRITE_IDS[^;]*['"]${id}['"]`));
  }
  assert.match(source, /const financeWriteReady=/);
  assert.match(source, /Owner Login.*Server Finance Ledger/);
  assert.match(source, /settle_crop_intake/);
  assert.match(source, /record_wholesale_crop_sale/);
  assert.match(source, /close_business_day/);
  assert.doesNotMatch(source, /သီးနှံငွေရှင်း၊ လက်ကားအရောင်းနှင့် Day Close သည် နောက်အဆင့် Server Ledger မပြီးသေး/);
});

test("connects settlement, owned crop stock, wholesale sale and day close to server RPCs", async () => {
  const source = await readFile(new URL("../outputs/pwal-yon-dashboard.html", import.meta.url), "utf8");
  for (const id of [
    "settlementPaymentReference",
    "chiliPaymentReference",
    "finalizeSettlement",
    "finalizeChiliSettlement",
    "saveSale",
    "saleLabourRate",
    "saleLabourOutput",
    "finalizeDay",
  ]) assert.match(source,new RegExp(`id=["']${id}["']`));
  assert.match(source,/saleLocation\.id='saleLocation'/);
  assert.match(source,/chiliSettlementLocation\.id='chiliSettlementLocation'/);
  assert.match(source,/p_chili_bag_prices:chili\?result\.entries\.map/);
  assert.match(source,/p_debt_advance_lot_id/);
  assert.match(source,/financeRequestId\('cropSettlement\.'/);
  assert.match(source,/financeRequestId\('wholesaleSale'/);
  assert.match(source,/p_labour_rate_kyat:sale\.labourRate/);
  assert.match(source,/labour=actualBags\*labourRate/);
  assert.match(source,/gross\+labour-freight/);
  assert.match(source,/financeRequestId\('dayClose\.'/);
  assert.match(source,/businessDate=String\(day\?\.business_date\|\|todayIso\(\)\)/);
  assert.match(source,/!countedText\|\|!Number\.isSafeInteger\(countedRaw\)/);
  assert.match(source,/cropOpsSetReadiness\(source==='SERVER'\)/);
  assert.match(source,/get_crop_stock_balances/);
  assert.match(source,/get_day_close_preview/);
  assert.match(source,/pwalYonCropOperationsReadCopy\.v1/);
  assert.match(source,/cropOpsWriteReady/);
  assert.match(source,/Offline Read Copy · ငွေ\/Stock မတင်ပါ/);
  assert.match(source,/အပ်ပဲကို ပွဲရုံပိုင် Stock ထဲ မရောပါ/);
});

test("ships all six stage 2 master-data workflows with online authority and a device cache", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );
  for (const id of [
    "farmerForm",
    "cropForm",
    "productForm",
    "stockLocationMasterPanel",
    "staffRoleMasterPanel",
    "openingBalanceMasterPanel",
    "openingCsvFile",
    "openingImportPreview",
    "openingImportHistoryBody",
  ]) {
    assert.match(source, new RegExp(`id=["']${id}["']`));
  }
  assert.match(source, /mimi-khine-master-cache-v1/);
  assert.match(source, /masterFetchAll\('farmers',MASTER_TABLE_COLUMNS\.farmers,'customer_id'\)/);
  assert.match(source, /masterFetchAll\('crop_types',MASTER_TABLE_COLUMNS\.crops,'crop_type_id'\)/);
  assert.match(source, /masterFetchAll\('products',MASTER_TABLE_COLUMNS\.products,'product_id'\)/);
  assert.match(source, /masterFetchAll\('stock_locations',MASTER_TABLE_COLUMNS\.locations,'location_id'\)/);
  assert.match(source, /masterFetchAll\('opening_balance_entries',MASTER_TABLE_COLUMNS\.entries,'id'\)/);
  assert.match(source, /query=query\.gt\(orderColumn,cursor\)/);
  assert.match(source, /\.from\('staff_members'\)\.select\(MASTER_TABLE_COLUMNS\.staff\)/);
  assert.match(source, /\.rpc\('commit_opening_balance_import'/);
  assert.match(source, /CSV Header မမှန်ပါ/);
  assert.match(source, /whole_units_only/);
  assert.match(source, /Opening Balance Import မှသာ တင်ပါ/);
});

test("ships the owner-only finance ledger with server RPC writes and an offline read copy", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  for (const id of [
    "financeLedgerStatus",
    "advanceLocation",
    "inputSaleLocation",
    "stockReceiptForm",
    "stockReceiptProduct",
    "stockReceiptLocation",
    "saveStockReceipt",
    "expenseReference",
    "financeAdvanceKpi",
    "financeInterestKpi",
    "financeProductStockKpi",
    "financeTodayExpenseKpi",
  ]) {
    assert.match(source, new RegExp(`\\bid=["']${id}["']`), `missing #${id}`);
  }

  for (const rpc of [
    "issue_advance",
    "repay_advance",
    "record_product_sale",
    "record_stock_receipt",
    "record_business_expense",
    "get_product_stock_balances",
    "get_farmer_debt_balances",
  ]) {
    assert.match(source, new RegExp(`['"]${rpc}['"]`), `missing ${rpc} RPC`);
  }

  for (const table of [
    "advance_lots",
    "advance_repayments",
    "finance_product_sales",
    "finance_stock_receipts",
    "product_stock_movements",
    "cash_ledger_entries",
    "business_expenses",
  ]) {
    assert.match(source, new RegExp(`['"]${table}['"]`), `missing ${table} read/realtime source`);
  }

  assert.match(source, /pwalYonFinanceReadCopy\.v1/);
  assert.match(source, /function financeStorageIdentity\(/);
  assert.match(source, /financeScopedKey\(FINANCE_CACHE_KEY\)/);
  assert.match(source, /value\.projectHost===identity\.projectHost/);
  assert.match(source, /value\.userId===identity\.userId/);
  assert.match(source, /function financeRestoreCache\(/);
  assert.match(source, /navigator\.onLine!==false/);
  assert.match(source, /financeOwnerReady\(\)/);
  assert.match(source, /role==='owner'/);
  assert.match(source, /p_request_id:requestId/);
  assert.match(source, /financeRequestId\(/);
  assert.match(source, /postgres_changes/);
  assert.doesNotMatch(source, /AD-DEMO-001|AD-OPEN-027/);
});

test("ships a role-gated immutable opening-balance migration", async () => {
  const migration = await readFile(
    new URL(
      "../supabase/migrations/202609080001_master_data_stage2.sql",
      import.meta.url,
    ),
    "utf8",
  );
  assert.match(migration, /create table if not exists public\.opening_balance_imports/i);
  assert.match(migration, /create table if not exists public\.opening_balance_entries/i);
  assert.match(migration, /create or replace function public\.commit_opening_balance_import/i);
  assert.match(migration, /require_staff_roles\(array\['owner', 'admin', 'accountant'\]\)/i);
  assert.match(migration, /Opening-balance imports are immutable/i);
  assert.match(migration, /p_request_id uuid/i);
  assert.match(migration, /jsonb_array_length\(p_rows\) > 1000/i);
  assert.match(migration, /whole_units_only/i);
  assert.match(migration, /grant execute on function public\.commit_opening_balance_import[\s\S]*to authenticated/i);
  assert.doesNotMatch(
    migration,
    /grant\s+(?:insert|update|delete)\s*(?:\([^;]*\))?\s+on\s+table\s+public\.opening_balance_entries\s+to\s+authenticated/i,
  );
});

test("keeps the standalone output and deployed worker in sync", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );
  const publicSource = await readFile(
    new URL("../public/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );
  assert.equal(publicSource, source);
  const response = await render("/pwal-yon-dashboard.html");
  const html = await response.text();
  assert.equal(
    html,
    source.replaceAll("__SITE_ORIGIN__", "https://example.test"),
  );
  assert.doesNotMatch(html, /__SITE_ORIGIN__/);
  assert.match(html, /https:\/\/example\.test\/og\.png/);
});

test("separates immediate product sales from farmer advances", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  const requiredIds = [
    "inputSaleForm",
    "inputSaleCustomerType",
    "inputSaleCustomer",
    "inputSaleProduct",
    "inputSaleQty",
    "inputSaleUnit",
    "inputSaleUnitPrice",
    "inputSalePaymentMethod",
    "inputSaleReference",
    "inputSaleValidation",
    "inputSaleStockOutput",
    "inputSaleSubtotalOutput",
    "inputSaleTotalOutput",
    "saveInputSale",
    "inputSaleHistoryBody",
    "productStockMovementBody",
  ];

  for (const id of requiredIds) {
    assert.match(source, new RegExp(`\\bid="${id}"`), `missing #${id}`);
  }

  const handler = source.match(
    /saveInputSale\.onclick=async\(\)=>\{([\s\S]*?)\nfunction financeSyncStockReceiptReference/,
  )?.[1];
  assert.ok(handler, "missing server-backed immediate-sale handler");
  assert.match(handler, /financeRpc\('record_product_sale'/);
  assert.match(handler, /p_location_id:sale\.locationId/);
  assert.match(handler, /p_customer_id:sale\.customerId/);
  assert.match(handler, /p_quantity:sale\.qty/);
  assert.match(handler, /await financeReloadAfterWrite\(\)/);
  assert.match(handler, /voucherNumber:ref/);
  assert.doesNotMatch(
    handler,
    /receiptNo\(|postDebtIncrease|postDebtRepayment|advanceLots\.push|farmerDebt\[|recordCashEntry\(|postProductStockOut\(/,
  );
  assert.match(source, /method!=='CASH'&&!reference/);
  assert.match(source, /\['CASH','BANK','MOBILE'\]/);
  assert.match(source, /\[saveSale,finalizeSettlement,finalizeChiliSettlement\]/);
});

test("uses one server-authoritative stock path for sales and advances", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /financeRpc\('issue_advance'/);
  assert.match(source, /financeRpc\('record_product_sale'/);
  assert.match(source, /financeRpc\('record_stock_receipt'/);
  assert.match(source, /supabaseClient\.rpc\('get_product_stock_balances'/);
  assert.match(source, /financeStock\(option\?\.dataset\.code,locationId\)/);
  assert.match(source, /await financeReloadAfterWrite\(\)/);

  const advanceHandler = source.match(
    /advancePrint\.onclick=async\(\)=>\{([\s\S]*?)\nsaveAdvanceRepayment\.onclick=async/,
  )?.[1] ?? "";
  const saleHandler = source.match(
    /saveInputSale\.onclick=async\(\)=>\{([\s\S]*?)\nfunction financeSyncStockReceiptReference/,
  )?.[1] ?? "";
  assert.doesNotMatch(advanceHandler, /postProductStockOut\(|productStockMovements\.unshift/);
  assert.doesNotMatch(saleHandler, /postProductStockOut\(|productStockMovements\.unshift/);

  const quantity = 2;
  const unitPrice = 75_000;
  const stockBefore = 86;
  assert.equal(Math.round(quantity * unitPrice), 150_000);
  assert.equal(Math.round((stockBefore - quantity) * 100) / 100, 84);
});

test("records paid stock receipts atomically instead of reusing opening balances", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  for (const id of [
    "stockReceiptSupplier",
    "stockReceiptProduct",
    "stockReceiptLocation",
    "stockReceiptQty",
    "stockReceiptUnitCost",
    "stockReceiptPaymentMethod",
    "stockReceiptReference",
    "stockReceiptBeforeOutput",
    "stockReceiptAfterOutput",
    "stockReceiptTotalOutput",
    "stockReceiptHistoryBody",
    "saveStockReceipt",
  ]) {
    assert.match(source, new RegExp(`\\bid="${id}"`), `missing #${id}`);
  }

  const handler = source.match(
    /saveStockReceipt\.onclick=async\(\)=>\{([\s\S]*?)\nfunction financeSyncExpenseReference/,
  )?.[1];
  assert.ok(handler, "missing server-backed stock-receipt handler");
  assert.match(handler, /financeRpc\('record_stock_receipt'/);
  assert.match(handler, /p_supplier_name:check\.supplier/);
  assert.match(handler, /p_product_id:check\.product\.product_id/);
  assert.match(handler, /p_location_id:check\.locationId/);
  assert.match(handler, /p_quantity:check\.qty/);
  assert.match(handler, /p_unit_cost_kyat:check\.unitCost/);
  assert.match(handler, /await financeReloadAfterWrite\(\)/);
  assert.doesNotMatch(handler, /commit_opening_balance_import|opening_balance_entries|postProductStockOut/);
  assert.match(source, /movement_type==='IN_PURCHASE'\?'PURCHASE'/);
});

test("renders the seven-day cash-flow chart only from server cash rows", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /id="financeCashFlow"/);
  assert.match(source, /function financeRenderCashFlow\(/);
  assert.match(source, /financeState\.raw\.cashFlow\.map/);
  assert.match(source, /supabaseClient\.rpc\('get_daily_cash_flow'\)/);
  assert.match(source, /cashFlow:financeState\.raw\.cashFlow\.slice\(0,7\)/);
  assert.match(source, /dailyCashSummary=safe\.cashFlow\.find/);
  assert.match(source, /dailyCashSummary\.physical_cash_in_kyat/);
  assert.match(source, /dailyCashSummary\.expense_total_kyat/);
  assert.match(source, /version:4/);
  assert.match(source, /value\?\.version===4/);
  assert.match(source, /from\('cash_ledger_entries'\)[\s\S]*?\.eq\('business_date',date\)/);
  assert.doesNotMatch(source, /financeState\.raw\.cash\.forEach/);
  assert.doesNotMatch(source, /\.gte\('business_date',cashStart\)/);
  assert.doesNotMatch(source, /ဇူ ၂၉|height:65%|height:88%/);
});

test("keeps the weighing page usable while crop master data is still loading", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  const customerInfo = source.match(
    /function customerInfo\(\)\{([\s\S]*?)\nfunction isChiliCrop/,
  )?.[1];
  assert.ok(customerInfo, "missing customerInfo helper");
  assert.match(customerInfo, /if\(!option\)return\{/);
  assert.match(customerInfo, /cropCode:''/);
});

test("rejects silent rounding in cash and goods repayments", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /cashRaw!==Math\.round\(cashRaw\)/);
  assert.match(source, /Math\.round\(goodsRaw\*1000\)\/1000/);
  assert.match(source, /ကျပ်ပြည့်ဖြင့်သာ ထည့်ပါ/);
  assert.match(source, /ဒဿမ ၃ လုံးအထိသာ ထည့်ပါ/);
});

test("posts immediate sales correctly to cash and day-close summaries", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /productSalesCash/);
  assert.match(source, /productSalesNonCash/);
  assert.match(source, /ကုန်ပစ္စည်းလက်ငင်းအရောင်း · Cash/);
  assert.match(source, /ကုန်ပစ္စည်းလက်ငင်းအရောင်း · Bank\/Mobile/);
  assert.match(source, /inputSaleSaving=true/);
  assert.match(source, /if\(inputSaleSaving\)return/);
  assert.match(source, /'အကြွေး \/ အတိုး','မတင်ပါ'/);
});

test("accepts any whole-kyat daily expense without a voucher reference", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(
    source,
    /id="expenseAmount"[^>]*min="1"[^>]*step="1"/,
  );
  assert.doesNotMatch(source, /\bid="expenseRef"/);
  assert.match(source, /id="expenseReference"/);

  const handler = source.match(
    /saveExpense\.onclick=async\(\)=>\{([\s\S]*?)\nadvanceLocation\.onchange=/,
  )?.[1];
  assert.ok(handler, "missing server-backed daily-expense handler");
  assert.match(handler, /financeRpc\('record_business_expense'/);
  assert.match(handler, /p_amount_kyat:check\.amount/);
  assert.match(handler, /await financeReloadAfterWrite\(\)/);
  assert.doesNotMatch(handler, /receiptNo\(|setVoucher\(|window\.print\(/);
  assert.match(source, /amountRaw!==Math\.round\(amountRaw\)/);
  assert.match(source, /method!=='CASH'&&!reference/);

  for (const amount of [5_000, 6_000, 6_001, 12_350]) {
    assert.equal(Number.isInteger(amount) && amount >= 1, true);
  }
});

test("accepts whole-kyat wholesale prices and related repayment amounts", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  for (const [id, minimum] of [
    ["saleRate", "1"],
    ["saleLabourRate", "0"],
    ["saleFreight", "0"],
    ["salePaid", "0"],
    ["consignmentSettlementPrice", "1"],
    ["consignmentDebtRepayment", "1"],
    ["debtRepayment", "1"],
    ["chiliDebtRepayment", "1"],
  ]) {
    assert.match(
      source,
      new RegExp(`id="${id}"[^>]*min="${minimum}"[^>]*step="1"`),
      `${id} must accept every whole-kyat value`,
    );
  }

  assert.match(
    source,
    /min="1" max="10000000000" step="1"[^>]*data-market-crop-id/,
  );
  assert.doesNotMatch(source, /id="saleRate"[^>]*step="100"/);

  for (const amount of [600, 100_000, 247_400]) {
    assert.equal(Number.isSafeInteger(amount) && amount >= 0, true);
  }
});

test("charges wholesale labour per actual sold bag and keeps voucher crop names clean", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(
    source,
    /id="saleActualBags"[^>]*required[^>]*min="1"[^>]*step="1"/,
  );
  assert.match(source, /labour=actualBags\*labourRate/);
  assert.match(source, /net=Math\.max\(0,gross\+labour-freight\)/);
  assert.match(source, /p_labour_rate_kyat:sale\.labourRate/);
  assert.match(source, /labour_rate_kyat,labour_total_kyat/);

  const marker = "document.getElementById('previewWholesaleSaleVoucher').onclick=()=>";
  const start = source.indexOf(marker);
  assert.notEqual(start, -1, "wholesale voucher preview handler exists");
  const end = source.indexOf("\n};", start + marker.length);
  assert.notEqual(end, -1, "wholesale voucher preview handler closes");
  const handler = source.slice(start, end + 3);
  assert.match(handler, /cropName=warehouseStock\[saleCrop\.value\]\?\.name\|\|'မတ်ပဲ'/);
  assert.doesNotMatch(handler, /selectedOptions|textContent/);
  assert.match(handler, /labourTotal=bags\*labourRate/);
  assert.match(handler, /net=gross\+labourTotal-freight/);
});

test("keeps advances open-ended and exposes partial repayment controls", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.doesNotMatch(source, /\bid=["'](?:months|mode)["']/i);
  assert.doesNotMatch(source, /\bfor=["'](?:months|mode)["']/i);

  const requiredIds = [
    "repayAdvanceFarmer",
    "repayDate",
    "repayAdvanceLot",
    "repayGoodsField",
    "repayQty",
    "repayCashField",
    "repayPrincipal",
    "repayPaymentMethod",
    "repayReference",
    "repayValidation",
    "repayIssueOutput",
    "repayDaysOutput",
    "repayPrincipalOutput",
    "repayInterestOutput",
    "repayTotalOutput",
    "repayRemainingOutput",
    "saveAdvanceRepayment",
    "advanceLedgerCount",
    "advanceLedgerBody",
    "advanceRepaymentBody",
  ];

  for (const id of requiredIds) {
    assert.match(source, new RegExp(`\\bid="${id}"`), `missing #${id}`);
  }
});

test("wires repayment receipts with the original debt and voucher-formatted dates", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /function formatAdvanceVoucherDate\(value\)\{/);
  assert.match(
    source,
    /return\[date\.getUTCDate\(\),date\.getUTCMonth\(\)\+1,date\.getUTCFullYear\(\)\]\.map\(mm\)\.join\('\.'\)/,
  );
  assert.match(
    source,
    /function buildRepaymentPrintData\(\{[^}]*originalPrincipal[^}]*\}\)/,
  );
  assert.match(
    source,
    /\['မူလအကြွေးအရင်း',signedMoney\(originalPrincipal\)\]/,
  );
  assert.match(source, /originalPrincipal:lot\.originalPrincipal/);
  assert.match(
    source,
    /issuedDate:formatAdvanceVoucherDate\(lot\.issuedDate\)/,
  );
  assert.match(
    source,
    /paymentDate:formatAdvanceVoucherDate\((?:payment\.paymentDate|date)\)/,
  );
});

test("calculates advance interest in started half-month steps", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.doesNotMatch(source, /AD-DEMO|AD-OPEN-027/);
  assert.match(source, /id="repayQty"[^>]*value="2"/);
  assert.match(
    source,
    /return Math\.round\(principalValue\*rateValue\/100\*halfMonthSteps\/2\)/,
  );
  assert.match(source, /Math\.ceil\(dayValue\/15\)/);
  assert.match(source, /function advanceInterestPeriodLabel\(/);
  assert.match(source, /if\(steps===1\)return'လဝက်စာတိုး'/);
  assert.match(source, /steps%2\?mm\(fullMonths\)\+' လခွဲစာတိုး':mm\(fullMonths\)\+' လစာတိုး'/);
  assert.doesNotMatch(source, /လဝက်ဆင့်/);
  assert.match(source, /၁–၁၅ ရက် = လဝက်တိုး/);
  assert.doesNotMatch(source, /dayValue\/30/);
  assert.doesNotMatch(source, /ကြာရက် ÷ ၃၀/);
  assert.doesNotMatch(source, /ရက်အလိုက် ရိုးရိုးအတိုး/);

  const labelSource = source.match(
    /function advanceInterestPeriodLabel\(days\)\{[^\n]+\}/,
  )?.[0];
  assert.ok(labelSource, "missing interest-period label formatter");
  const periodLabel = Function(
    "advanceInterestHalfMonthSteps",
    "mm",
    `${labelSource}; return advanceInterestPeriodLabel;`,
  )(
    days => Number(days) === 0 ? 0 : Math.ceil(Number(days) / 15),
    value => new Intl.NumberFormat("my-MM").format(value),
  );
  assert.equal(periodLabel(0), "အတိုးမရှိ");
  assert.equal(periodLabel(15), "လဝက်စာတိုး");
  assert.equal(periodLabel(16), "၁ လစာတိုး");
  assert.equal(periodLabel(30), "၁ လစာတိုး");
  assert.equal(periodLabel(31), "၁ လခွဲစာတိုး");
  assert.equal(periodLabel(40), "၁ လခွဲစာတိုး");
  assert.equal(periodLabel(45), "၁ လခွဲစာတိုး");
  assert.equal(periodLabel(46), "၂ လစာတိုး");
  assert.equal(periodLabel(47), "၂ လစာတိုး");
  assert.equal(periodLabel(60), "၂ လစာတိုး");
  assert.equal(periodLabel(61), "၂ လခွဲစာတိုး");

  const selectedPrincipal = 2 * 72_000;
  const monthlyRate = 3;
  const halfMonthSteps = (days) => days === 0 ? 0 : Math.ceil(days / 15);
  const accruedInterest = (days) => Math.round(
    selectedPrincipal * (monthlyRate / 100) * halfMonthSteps(days) / 2,
  );
  const cases = [
    { days: 0, steps: 0, interest: 0 },
    { days: 1, steps: 1, interest: 2_160 },
    { days: 15, steps: 1, interest: 2_160 },
    { days: 16, steps: 2, interest: 4_320 },
    { days: 30, steps: 2, interest: 4_320 },
    { days: 31, steps: 3, interest: 6_480 },
    { days: 45, steps: 3, interest: 6_480 },
    { days: 46, steps: 4, interest: 8_640 },
    { days: 47, steps: 4, interest: 8_640 },
    { days: 60, steps: 4, interest: 8_640 },
  ];

  assert.equal(selectedPrincipal, 144_000);
  for (const entry of cases) {
    assert.equal(halfMonthSteps(entry.days), entry.steps, `${entry.days} days`);
    assert.equal(accruedInterest(entry.days), entry.interest, `${entry.days} days`);
  }
  assert.equal(Math.round(100_000 * 0.03 * halfMonthSteps(40) / 2), 4_500);
  assert.equal(Math.round(100_000 * 0.03 * halfMonthSteps(47) / 2), 6_000);
  assert.equal(selectedPrincipal + accruedInterest(60), 152_640);
});

test("allocates crop-settlement debt by lot with accrued interest", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /function quoteAdvancePrincipalFIFO\(/);
  assert.match(source, /simpleAdvanceInterest\(principal,lot\.monthlyRate,days\)/);
  assert.match(source, /halfMonthSteps=advanceInterestHalfMonthSteps\(days\)/);
  assert.match(source, /halfMonthSteps,monthUnits,monthlyRate/);
  assert.match(source, /commitAdvanceQuote\(s\.advanceQuote,\{id:currentTransaction/);
  assert.match(source, /debtDeduction:quote\.total/);
  assert.match(source, /အကြွေးအရင်း \+ အတိုး/);
  assert.match(source, /source:'BEAN_OFFSET'/);
  assert.match(source, /source:'CHILI_OFFSET'/);
  assert.match(source, /committedAdvanceSources=new Set\(\)/);
  assert.match(source, /committedAdvanceSources\.has\(sourceKey\)/);
  assert.match(source, /committedAdvanceSources\.add\(sourceKey\)/);
  assert.match(source, /function todayIso\(\)\{return openBusinessDate\}/);
});

test("shows each debt lot and an explicit repayment choice in crop settlements", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  const requiredIds = [
    "beanDebtPreview",
    "beanDebtLotCount",
    "beanDebtLotBody",
    "beanDebtOpenPrincipal",
    "beanDebtFullInterest",
    "beanDebtSelectedPrincipal",
    "beanDebtSelectedInterest",
    "beanDebtSelectedTotal",
    "beanDebtAfterPrincipal",
    "beanDebtMismatch",
    "beanDebtLotSelect",
    "beanDebtCashField",
    "beanDebtGoodsField",
    "beanDebtQuantity",
    "beanDebtUnitPrice",
    "beanDebtGoodsPrincipal",
    "chiliDebtPreview",
    "chiliDebtLotCount",
    "chiliDebtLotBody",
    "chiliDebtOpenPrincipal",
    "chiliDebtFullInterest",
    "chiliDebtSelectedPrincipal",
    "chiliDebtSelectedInterest",
    "chiliDebtSelectedTotal",
    "chiliDebtAfterPrincipal",
    "chiliDebtMismatch",
    "chiliDebtLotSelect",
    "chiliDebtCashField",
    "chiliDebtGoodsField",
    "chiliDebtQuantity",
    "chiliDebtUnitPrice",
    "chiliDebtGoodsPrincipal",
  ];

  for (const id of requiredIds) {
    assert.match(source, new RegExp(`\\bid="${id}"`), `missing #${id}`);
  }

  assert.match(source, /function renderDebtAllocationPreview\(/);
  assert.match(source, /function quoteAdvanceLotSelection\(/);
  assert.match(source, /function syncSettlementDebtLots\(/);
  assert.match(source, /function readSettlementDebtSelection\(/);
  assert.match(source, /openAdvanceLots\(customerId\)/);
  assert.match(
    source,
    /simpleAdvanceInterest\(lot\.remainingPrincipal,lot\.monthlyRate,days\)/,
  );
  assert.match(
    source,
    /renderDebtAllocationPreview\('bean',c\.id,quote,todayIso\(\),result\.debt\)/,
  );
  assert.match(
    source,
    /renderDebtAllocationPreview\('chili',c\.id,quote,todayIso\(\),result\.debt\)/,
  );
  assert.match(source, /selection=readSettlementDebtSelection\('bean'/);
  assert.match(source, /selection=readSettlementDebtSelection\('chili'/);
  assert.match(source, /allocation\.unitPrice!==lot\.unitPrice/);
  assert.match(source, /mm\(entry\.quantity\).*signedMoney\(entry\.unitPrice\)/);
  assert.match(source, /function advanceAllocationReceiptDescription\(/);
  assert.match(
    source,
    /mobileCustomer\.onchange=\(\)=>\{renderBags\(\);settlementCalculation\(\);chiliCalculation\(\)\}/,
  );

  const principal = 100_000;
  const monthlyRate = 3;
  const days = 60;
  const halfMonthSteps = Math.ceil(days / 15);
  const interest = Math.round(
    principal * (monthlyRate / 100) * halfMonthSteps / 2,
  );

  assert.equal(halfMonthSteps, 4);
  assert.equal(interest, 6_000);
  assert.equal(principal + interest, 106_000);
});

test("quotes only the selected cash or goods debt lot", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  const emptySource = source.match(/function emptyAdvanceQuote[^\n]*/)?.[0];
  const quoteSource = source.match(/function quoteAdvanceLotSelection[^\n]*/)?.[0];
  assert.ok(emptySource, "missing empty quote helper");
  assert.ok(quoteSource, "missing selected-lot quote helper");

  const lots = [
    {
      id: "AD-DEMO-001",
      customerId: "F-001",
      issuedDate: "2026-06-06",
      type: "GOODS",
      itemName: "Fertilizer",
      unit: "bag",
      unitPrice: 72_000,
      remainingQty: 8,
      remainingPrincipal: 576_000,
      monthlyRate: 3,
    },
    {
      id: "AD-OPEN-001",
      customerId: "F-001",
      issuedDate: "2026-07-01",
      type: "CASH",
      itemName: "Cash",
      unit: "MMK",
      unitPrice: 1,
      remainingQty: null,
      remainingPrincipal: 4_880_000,
      monthlyRate: 3,
    },
  ];
  const serial = (date) => Date.parse(`${date}T00:00:00Z`);
  const elapsedDays = (from, to) => Math.floor(
    (serial(to) - serial(from)) / 86_400_000,
  );
  const advanceInterestHalfMonthSteps = (days) => days === 0
    ? 0
    : Math.ceil(days / 15);
  const simpleAdvanceInterest = (principal, rate, days) => Math.round(
    principal * rate / 100 * advanceInterestHalfMonthSteps(days) / 2,
  );
  const quoteSelected = new Function(
    "openAdvanceLots",
    "elapsedDays",
    "advanceInterestHalfMonthSteps",
    "simpleAdvanceInterest",
    "todayIso",
    `${emptySource}\n${quoteSource}\nreturn quoteAdvanceLotSelection;`,
  )(
    (customerId) => lots.filter((lot) => lot.customerId === customerId),
    elapsedDays,
    advanceInterestHalfMonthSteps,
    simpleAdvanceInterest,
    () => "2026-08-06",
  );

  const cash = quoteSelected(
    "F-001",
    "AD-OPEN-001",
    { principal: 100_000 },
    "2026-08-06",
  );
  assert.deepEqual(cash.errors, []);
  assert.equal(cash.quote.allocations.length, 1);
  assert.equal(cash.quote.allocations[0].lotId, "AD-OPEN-001");
  assert.equal(cash.quote.principal, 100_000);
  assert.equal(cash.quote.interest, 4_500);
  assert.equal(cash.quote.total, 104_500);

  const goods = quoteSelected(
    "F-001",
    "AD-DEMO-001",
    { quantity: 2 },
    "2026-08-06",
  );
  assert.deepEqual(goods.errors, []);
  assert.equal(goods.quote.allocations.length, 1);
  assert.equal(goods.quote.allocations[0].lotId, "AD-DEMO-001");
  assert.equal(goods.quote.allocations[0].quantity, 2);
  assert.equal(goods.quote.allocations[0].unitPrice, 72_000);
  assert.equal(goods.quote.principal, 144_000);
  assert.equal(goods.quote.interest, 10_800);
  assert.equal(goods.quote.total, 154_800);

  const beanWrapper = source.match(
    /settlementCalculation=\(\)=>\{let c=customerInfo\(\),selection=[^\n]*/,
  )?.[0];
  const chiliWrapper = source.match(
    /chiliCalculation=\(\)=>\{let c=customerInfo\(\),selection=[^\n]*/,
  )?.[0];
  assert.ok(beanWrapper);
  assert.ok(chiliWrapper);
  assert.doesNotMatch(beanWrapper, /quoteAdvancePrincipalFIFO/);
  assert.doesNotMatch(chiliWrapper, /quoteAdvancePrincipalFIFO/);
});

test("allows debt collection from blacklisted farmers while blocking new advances", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.doesNotMatch(source, /AD-DEMO|AD-OPEN-027/);
  assert.match(source, /function syncRepaymentFarmers\(\)[^\n]*advanceLots\.filter/);
  assert.match(source, /farmer\?\.risk_level==='BLACKLISTED'/);
  assert.match(source, /row\.risk_level==='BLACKLISTED'\?'disabled':''/);
});

test("separates each major workflow into keyboard-accessible task tabs", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /\bdata-view=["']goods-sales["']/);
  assert.match(source, /\bid=["']goods-sales["']/);

  assert.match(source, /function createTaskWorkspace\s*\(/);
  assert.match(source, /function activateTaskTab\s*\(/);
  assert.match(source, /function showView\s*\(/);

  for (const role of ["tablist", "tab", "tabpanel"]) {
    assert.match(
      source,
      new RegExp(`["']${role}["']`),
      `missing accessible ${role} role`,
    );
  }

  for (const key of ["ArrowRight", "ArrowLeft", "Home", "End"]) {
    assert.match(source, new RegExp(`["']${key}["']`), `missing ${key} support`);
  }

  assert.match(source, /\.task-workflow-panel\[hidden\]\s*\{/);
  assert.match(
    source,
    /showView\('weighing',consignment\?'consignment':'settlement'\)/,
  );
  assert.match(
    source,
    /showView\(\s*["']goods-sales["']\s*,\s*["']sale["']\s*\)/,
  );
  assert.match(
    source,
    /showView\(\s*["']farmers["']\s*,\s*["']new["']\s*\)/,
  );
  assert.match(source, /previousKey:defaultKey/);
  assert.match(source, /let productCatalogReturn=null/);
  assert.match(source, /productCatalogReturn=null;showView/);
  assert.match(source, /function closeCropEntry\(\)[^\n]*previousKey/);
});

test("records daily bean and chili prices in one responsive workflow", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /data-view="market-prices"/);
  assert.match(source, /id="market-prices"/);
  assert.match(source, /id="marketPriceForm"/);
  assert.match(source, /id="marketPriceEntryRows"/);
  assert.match(source, /id="saveMarketPrices"/);
  assert.match(source, /id="fillPreviousMarketPrices"/);
  assert.match(source, /နေ့စဉ်ပေါက်ဈေး တစ်ခါတည်းထည့်ရန်/);
  assert.match(source, /category==='chili'\?\['WET','DRY'\]:\['STANDARD'\]/);
  assert.match(source, /price_unit_pyitha:unit/);
  assert.match(source, /တစ်ပိဿာလျှင်/);
  assert.match(source, /၂၀ ပိဿာဈေး/);
  assert.match(source, /function saveMarketPriceSheet\(/);
  assert.match(source, /Number\.isInteger\(price\)/);
  assert.match(source, /marketPriceSourceNote/);
});

test("keeps a durable PC-local market-price mirror and retries Supabase", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /indexedDB\.open\(MARKET_PRICE_DB,1\)/);
  assert.match(source, /createObjectStore\(MARKET_PRICE_STORE,\{keyPath:'key'\}\)/);
  assert.match(source, /function marketNaturalKey\(/);
  assert.match(source, /sync_state:'PENDING'/);
  assert.match(source, /async function putLocalMarketPrice\(/);
  assert.match(source, /async function readLocalMarketPrices\(/);
  assert.match(source, /async function syncPendingMarketPrices\(/);
  assert.match(source, /\.rpc\('upsert_market_price',params\)/);
  assert.match(source, /\.from\('market_prices'\)\.select\(MARKET_PRICE_COLUMNS\)/);
  assert.match(
    source,
    /\.on\('postgres_changes',\{event:'\*',schema:'public',table:'market_prices'\},handleMarketPriceChange\)/,
  );
  assert.match(source, /Online \+ PC/);
  assert.match(source, /Supabase Server မရောက်နိုင်ပါ/);
  assert.doesNotMatch(source, /localStorage\.setItem\([^\n]*market.?price/i);
});

test("builds monthly, year-over-year, seasonal and forecast market reports", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  for (const id of [
    "marketHistoryPanel",
    "marketHistoryCrop",
    "marketHistoryCondition",
    "marketHistoryFrom",
    "marketHistoryTo",
    "marketReportPanel",
    "marketReportCrop",
    "marketReportCondition",
    "marketReportYear",
    "marketTrendChart",
    "marketMonthlyReportBody",
    "marketForecastBody",
  ]) {
    assert.match(source, new RegExp(`\\bid="${id}"`), `missing #${id}`);
  }

  assert.match(source, /function monthlyMarketSeries\(/);
  assert.match(source, /function renderMarketTrendChart\(/);
  assert.match(source, /function renderMarketForecast\(/);
  assert.match(source, /function marketChangePercent\(/);
  assert.match(source, /priorSeries=monthlyMarketSeries\(dimensionRows,year-1\)/);
  assert.match(source, /observedMonths<3/);
  assert.match(source, /annual\.length>1/);
  assert.match(source, /nextAnnual=Math\.max\(1,annual\.at\(-1\)\.avg\+slope\)/);
  assert.match(source, /ရာသီပုံစံ/);
  assert.match(source, /ခန့်မှန်းသာ/);
  assert.doesNotMatch(source, /Math\.random\(\)[^\n]*(?:forecast|price|ဈေး)/i);
});

test("ships a constrained RLS market-price migration and idempotent RPC", async () => {
  const migration = await readFile(
    new URL(
      "../supabase/migrations/202608310001_daily_market_prices.sql",
      import.meta.url,
    ),
    "utf8",
  );

  assert.match(migration, /create table if not exists public\.market_prices/i);
  assert.match(migration, /business_date date not null/i);
  assert.match(migration, /category in \('bean', 'chili'\)/i);
  assert.match(migration, /condition in \('STANDARD', 'WET', 'DRY', 'MIXED'\)/i);
  assert.match(migration, /price_mmk bigint not null/i);
  assert.match(migration, /market_prices_daily_natural_key unique/i);
  assert.match(migration, /enable row level security/i);
  assert.match(migration, /public\.current_staff_is_active\(\)/i);
  assert.match(migration, /array\['owner', 'admin', 'accountant'\]/i);
  assert.match(migration, /create or replace function public\.upsert_market_price/i);
  assert.match(migration, /on conflict \([\s\S]*business_date,[\s\S]*crop_type_id,[\s\S]*condition,[\s\S]*price_unit_pyitha[\s\S]*\) do update/i);
  assert.match(migration, /alter publication supabase_realtime add table public\.market_prices/i);
  assert.doesNotMatch(migration, /grant\s+(?:all|select|insert|update)[^;]*\s+to\s+anon/i);
  assert.doesNotMatch(migration, /create policy[\s\S]*?to anon/i);
});

test("keeps farmer-owned bean consignment separate from settlement and owned stock", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );
  const migration = await readFile(
    new URL(
      "../supabase/migrations/202609030001_farmer_bean_consignment.sql",
      import.meta.url,
    ),
    "utf8",
  );

  assert.doesNotMatch(source, /name="mobileIntakeMode"/);
  assert.match(source, /id="intakeSaleWeight"/);
  assert.match(source, /id="consignmentPanel"/);
  assert.match(source, /id="acceptConsignment"/);
  assert.doesNotMatch(source, /\.rpc\('set_weighing_intake_mode'/);
  assert.match(source, /\.rpc\('allocate_weighing_intake'/);
  assert.match(
    source,
    /\.on\('postgres_changes',\{event:'\*',schema:'public',table:'consignment_lots'\},handleConsignmentLotChange\)/,
  );
  assert.match(source, /Number\(allocation.sale_reserved_centi_pyitha\)\/100/);
  assert.match(source, /အပ်ပဲသည် ပွဲရုံပိုင် Stock နှင့် ငွေစာရင်းထဲ မဝင်ပါ/);

  const acceptFlow =
    source.match(
      /async function acceptSelectedConsignment\(\)\{([\s\S]*?)\nfunction initializeConsignmentUi/,
    )?.[1] ?? "";
  assert.match(acceptFlow, /allocate_weighing_intake/);
  assert.match(acceptFlow, /ငွေမရှင်းရသေး/);
  assert.doesNotMatch(
    acceptFlow,
    /postInventory|recordCashEntry|postDebtRepayment|warehouseStock/,
  );
  assert.doesNotMatch(
    source.match(/const PILOT_LOCKED_WRITE_IDS=\[([^\]]*)\]/)?.[1] ?? "",
    /acceptConsignment/,
  );

  assert.match(migration, /add column if not exists intake_mode text not null default 'DIRECT_SALE'/i);
  assert.match(migration, /intake_mode in \('DIRECT_SALE', 'FARMER_CONSIGNMENT'\)/i);
  assert.match(migration, /create table if not exists public\.consignment_lots/i);
  assert.match(migration, /batch_id uuid not null unique/i);
  assert.match(migration, /original_net_weight_centi_pyitha[\s\S]*?gross_weight_centi_pyitha[\s\S]*?moisture_deduction_centi_pyitha[\s\S]*?waste_deduction_centi_pyitha[\s\S]*?tare_deduction_centi_pyitha/i);
  assert.match(migration, /create table if not exists public\.consignment_movements/i);
  assert.match(migration, /movement_type in \([\s\S]*?'DEPOSIT'[\s\S]*?'WITHDRAWAL'[\s\S]*?'SALE_TRANSFER'/i);
  assert.match(migration, /Consignment movements are append-only/i);
  assert.match(migration, /create or replace function public\.set_weighing_intake_mode/i);
  assert.match(migration, /create or replace function public\.accept_farmer_consignment/i);
  assert.match(migration, /v_batch\.status <> 'SUBMITTED'/i);
  assert.match(migration, /crop\.category = 'BEAN'/i);
  assert.match(migration, /array\['owner', 'admin', 'accountant'\]/i);
  assert.match(migration, /acceptance_request_id uuid not null unique/i);
  assert.match(migration, /force row level security/i);
  assert.match(migration, /revoke all privileges on table public\.consignment_lots[\s\S]*?from anon, authenticated/i);
  assert.match(migration, /alter publication supabase_realtime[\s\S]*?add table public\.consignment_lots/i);
  assert.doesNotMatch(
    migration,
    /grant\s+(?:all|insert|update|delete)[^;]*on table public\.consignment_(?:lots|movements)[^;]*to authenticated/i,
  );
});

test("guides a locked direct-sale settlement to a selected allocation and a safe sample preview", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /id="settlementPrerequisite"/);
  assert.match(source, /ခွဲထားသောစာရင်း[^<]*မှ <b>ငွေရှင်းတွက်ကြည့်ရန်<\/b>/);
  assert.match(source, /id="settlementGoWeighing"/);
  assert.match(source, /id="settlementGoAllocation"/);
  assert.match(source, /id="settlementChooseAllocation"/);
  assert.match(source, /id="previewSettlementSample"/);
  assert.ok(
    source.includes(
      "document.getElementById('settlementGoAllocation').onclick=()=>showView('weighing','consignment')",
    ),
  );
  assert.ok(
    source.includes(
      "document.getElementById('settlementChooseAllocation').onclick=()=>showView('weighing','intake-history')",
    ),
  );
  assert.ok(
    source.includes(
      "document.getElementById('previewSettlementSample').onclick=()=>document.getElementById('previewVoucherSample').click()",
    ),
  );
  assert.match(
    source,
    /function unlockSettlement\(\)\{[^\n]*settlementPrerequisite'\)\.hidden=true[^\n]*settlement-controls'\)\.inert=false/,
  );
  assert.match(
    source,
    /function lockSettlement\(\)\{[^\n]*settlementPrerequisite'\)\.hidden=false[^\n]*settlement-controls'\)\.inert=true/,
  );
  assert.match(source, /register\?'✓ စာရင်းသိမ်းပြီး[^\n]*Server စာရင်းမသိမ်းပါ'/);
  assert.match(source, /\['consignment','intake-history','consignment-settlement'\]\.includes\(taskKey\)/);
});

test("shows the implemented server-backed day-close workflow as ready for pilot testing", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );

  assert.match(source, /id="financeTodayExpenseTrend">Server တွင် တင်ပြီးသော ယနေ့အသုံးစရိတ်/);
  assert.match(source, /id="dayCloseState">Server စောင့်နေသည်/);
  assert.match(source, /id="dayCloseHint">Owner Login ဝင်ပြီး Server Day Close ကိုဖတ်ပါ/);
  assert.match(source, /<label for="openingCashInput">မနက်ဖွင့် ငွေသား<\/label>/);
  assert.match(source, /Day Close \/ သီးနှံငွေရှင်း[\s\S]*?<span class="state ready">Server Ledger ပြီး<\/span>/);
  assert.match(source, /const PILOT_LOCKED_WRITE_IDS=\[\]/);
});

test("contains unique element identifiers", async () => {
  const source = await readFile(
    new URL("../outputs/pwal-yon-dashboard.html", import.meta.url),
    "utf8",
  );
  const ids = [...source.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
  assert.equal(new Set(ids).size, ids.length);
});

test("serves the embedded social preview PNG", async () => {
  const expected = await readFile(
    new URL("../public/og.png", import.meta.url),
  );
  const response = await render("/og.png");
  const actual = Buffer.from(await response.arrayBuffer());

  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^image\/png\b/i);
  assert.deepEqual(actual.subarray(0, 8), Buffer.from([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
  ]));
  assert.deepEqual(actual, expected);
});

test("returns a plain 404 for unknown paths", async () => {
  const response = await render("/missing");
  assert.equal(response.status, 404);
});
