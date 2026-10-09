import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext, Script } from 'node:vm';
import test from 'node:test';

const source = await readFile(new URL('../outputs/pwal-yon-dashboard.html', import.meta.url), 'utf8');
const builder = source.match(/function buildCropSettlementPrintData\(number\)\{[\s\S]*?\n\}\nasync function saveCropSettlement/)?.[0]
  .replace(/\nasync function saveCropSettlement$/, '');
const financeBuilders = source.match(/function buildCashAdvancePrintData\([\s\S]*?\n\}\ndocument\.getElementById\('previewVoucherSample'\)/)?.[0]
  .replace(/\ndocument\.getElementById\('previewVoucherSample'\)$/, '');

function renderLayout(posted, { allocation = null, preview = { entries: [] } } = {}) {
  assert.ok(builder, 'crop voucher builder is present');
  const context = {
    cropOpsState: { settlements: [posted] },
    chiliCalculation: () => preview,
    settlementCalculation: () => preview,
    intakeAllocationByBatch: new Map(allocation ? [[posted.batch_id, allocation]] : []),
    cropOpsNumber: value => Number.isFinite(Number(value)) ? Number(value) : 0,
    viss: centi => (Number(centi) / 100).toFixed(2),
    signedMoney: value => `ကျပ် ${Number(value).toLocaleString('en-US')}`,
    mm: value => String(value),
    conditionLabel: condition => condition === 'WET' ? 'အစို' : 'အခြောက်',
    methodLabels: { CASH: 'ငွေသား' },
    currentTransaction: 'WB-001',
  };
  return runInNewContext(`${builder}\nbuildCropSettlementPrintData('CS-001')`, context);
}

function renderFinanceLayout(builderName, payload) {
  assert.ok(financeBuilders, 'advance and repayment voucher builders are present');
  const context = {
    signedMoney: value => `ကျပ် ${Number(value).toLocaleString('en-US')}`,
    mm: value => String(value),
    viss: centi => (Number(centi) / 100).toFixed(2),
    advanceInterestPeriodLabel: days => {
      const dayValue = Math.max(0, Math.floor(Number(days) || 0));
      const steps = dayValue === 0 ? 0 : Math.ceil(dayValue / 15);
      if (!steps) return 'အတိုးမရှိ';
      if (steps === 1) return 'လဝက်စာတိုး';
      const fullMonths = Math.floor(steps / 2);
      return steps % 2 ? `${fullMonths} လခွဲစာတိုး` : `${fullMonths} လစာတိုး`;
    },
  };
  return runInNewContext(`${financeBuilders}\n${builderName}(${JSON.stringify(payload)})`, context);
}

test('crop receipt is A5, monochrome and has the sample print action without posting data', () => {
  assert.match(source, /<style id="voucher-print-styles">[\s\S]*?@page\{size:A5 portrait;margin:7mm\}/);
  assert.match(source, /id="voucherItemFrame"/);
  assert.match(source, /id="voucherAdjustmentsWrap"/);
  assert.match(source, /id="voucherSummaryRows"/);
  assert.match(source, /id="previewVoucherSample"/);
  assert.match(source, /voucherNumber:'နမူနာ',register:false/);
  assert.match(source, /ဆန်နှင့် ပဲမျိုးစုံ ရောင်းဝယ်ရေး/);
  assert.match(source, /ဖုန်း — 09 422 464 572၊ 09 795 012 580၊ 09 882 288 208၊ 09 455 338 854/);
  assert.match(source, /လိပ်စာ — ဓမ္မာရုံကျောင်းလမ်း၊ ဟင်္သာတမြို့။/);
  assert.match(source, /\.voucher\{display:flex!important;flex-direction:column;min-height:196mm!important/);
  assert.match(source, /\.voucher-bottom\{[^}]*margin-top:4mm/);
  assert.doesNotMatch(source, /\.voucher-bottom\{[^}]*margin-top:auto/);
  assert.match(source, /\.voucher \.signatures\{[^}]*margin:auto 0 0!important;[^}]*padding-top:10mm/);
  assert.match(source, /\.voucher \.footer\{margin:4mm 0 0!important/);
  assert.doesNotMatch(source, /\.voucher \.footer\{margin:auto/);
  assert.doesNotMatch(source, /id="voucherDetailHeading"/);
  assert.doesNotMatch(source, /detailHeading:/);
  assert.match(source, /<th>အိတ်<\/th><th>ပိဿာ<\/th>/);
  assert.match(source, /id="voucherItemTable" data-columns="6"/);
  assert.match(source, /id="voucherItemColumns"/);
  assert.match(source, /id="voucherItemHead"/);
  assert.match(source, /layout\?\.columns\|\|\['စဉ်'/);
  assert.match(source, /voucherItemTable\.dataset\.columns=String\(columns\.length\)/);
  assert.match(source, /id="voucherAdjustmentsWrap" hidden><h4>ကုန်ကျစရိတ်<\/h4>/);
  assert.match(source, /items\.map\(row=>`<tr>\$\{row\.map\(value=>`<td>\$\{safeText\(value\)\}/);
});

test('all inline dashboard scripts remain valid JavaScript', () => {
  for (const match of source.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) {
    if (match[1].trim()) assert.doesNotThrow(() => new Script(match[1]));
  }
});

test('bean voucher shows sale weight apart from consigned weight and server costs', () => {
  const posted = {
    settlement_ref: 'CS-001', batch_id: 'B1', crop_category: 'BEAN',
    crop_name_snapshot: 'မတ်ပဲ', source_gross_centi_pyitha: 36000,
    purchased_centi_pyitha: 5000, actual_bags: 12,
    pricing_divisor_pyitha: 20, market_price_kyat: 120000,
    gross_value_kyat: 300000, labour_total_kyat: 500,
    commission_total_kyat: 3000, freight_kyat: 1500,
    total_expense_kyat: 5000, debt_principal_kyat: 10000,
    debt_interest_kyat: 500, debt_total_kyat: 10500,
    location_id: 'WH', payment_method: 'CASH', payment_reference: null,
  };
  const allocation = {
    moisture_centi_pyitha: 300, waste_centi_pyitha: 200,
    tare_centi_pyitha: 500, consigned_centi_pyitha: 30000,
  };
  const layout = renderLayout(posted, { allocation });
  const adjustments = Object.fromEntries(layout.adjustments);
  assert.equal(layout.items.length, 1);
  assert.equal(layout.items[0][2], '12 အိတ်');
  assert.equal(layout.items[0][3], '50.00');
  assert.equal(layout.items[0][4], 'ကျပ် 120,000');
  assert.doesNotMatch(layout.items[0][4], /ပိဿာ|\/\s*20/);
  assert.equal(layout.detailRows.length, 0);
  for (const removed of ['မူရင်း Gross', 'အစိုအလျော့', 'အမှိုက်အလျော့', 'အိတ်ခွံ', 'အပ်ထား', 'ယခုရောင်း Net']) {
    assert.equal(adjustments[removed], undefined);
  }
  assert.equal(adjustments['လုပ်သားခ'], '− ကျပ် 500');
  assert.equal(adjustments['အတိုး'], '− ကျပ် 500');
  assert.match(layout.note, /မပါဝင်ပါ/);
});

test('consignment voucher is a four-column receipt for only the consigned weight', () => {
  const layout = renderFinanceLayout('buildConsignmentPrintData', {
    cropName: 'မတ်ပဲ', bags: '—', weightCentiPyitha: 30000,
  });
  assert.deepEqual([...layout.columns], ['စဉ်', 'သီးနှံ အမျိုးအစား', 'အိတ်', 'ပိဿာ']);
  assert.equal(layout.items.length, 1);
  assert.deepEqual([...layout.items[0]], ['1', 'မတ်ပဲ', '—', '300.00']);
  assert.equal(layout.detailRows.length, 0);
  assert.equal(layout.adjustments.length, 0);
  assert.equal(layout.summaryRows.length, 0);
  assert.equal(layout.note, '');
  assert.match(source, /title:isConsignment\?'အပ်ပဲ ဘောင်ချာ'/);
  assert.match(source, /total:viss\(weight\)\+' ပိဿာ'/);
  assert.doesNotMatch(source.match(/function printIntakeAllocation\(a\)\{[\s\S]*?\n\}/)?.[0] || '', /မူရင်းအိတ်ချိန်ရက်|အစိုအလျော့|ငွေ \/ အကြွေး|ငွေရှင်းဘောင်ချာမဟုတ်/);
});

test('wholesale voucher shows only the crop name and adds buyer-paid labour per sold bag', () => {
  const layout = renderFinanceLayout('buildWholesaleSalePrintData', {
    cropName: 'မတ်ပဲ', bags: 6, weightCentiPyitha: 4960,
    rate: 120000, gross: 297600,
    labourRate: 300, labourTotal: 1800,
    freight: 0, net: 299400,
  });
  const adjustments = Object.fromEntries(layout.adjustments);
  const summary = Object.fromEntries(layout.summaryRows);

  assert.equal(layout.items[0][1], 'မတ်ပဲ');
  assert.doesNotMatch(layout.items[0][1], /ပိဿာ/);
  assert.equal(layout.items[0][2], '6 အိတ်');
  assert.equal(layout.items[0][3], '49.60');
  assert.equal(adjustments['လုပ်သားခ (6 အိတ် × ကျပ် 300)'], '+ ကျပ် 1,800');
  assert.equal(summary['သီးနှံတန်ဖိုး'], 'ကျပ် 297,600');
  assert.equal(summary['ဝယ်သူပေးရန် စုစုပေါင်း'], 'ကျပ် 299,400');
});

test('all customer voucher previews are available without posting data', () => {
  for (const id of ['previewConsignmentVoucher', 'previewInputSaleVoucher', 'previewAdvanceRepaymentVoucher', 'previewWholesaleSaleVoucher']) {
    assert.match(source, new RegExp(`id="${id}"`));
    const marker = `document.getElementById('${id}').onclick=`;
    const start = source.indexOf(marker);
    assert.notEqual(start, -1, `${id} handler exists`);
    const end = source.indexOf('\n};', start + marker.length);
    assert.notEqual(end, -1, `${id} handler closes`);
    const handler = source.slice(start, end + 3);
    assert.match(handler, /voucherNumber:'နမူနာ'/);
    assert.match(handler, /register:false/);
    assert.doesNotMatch(handler, /financeRpc|supabaseClient\.rpc|confirm\(|financeRequestId|postProductStockOut|recordCashEntry|financeReloadAfterWrite/);
  }
  assert.match(source, /actionGroup=before\?\.closest\('\.form-actions'\)/);
  assert.match(source, /panel\.insertBefore\(effects,anchor\)/);
});

test('chili voucher prints each bag with its own condition and price', () => {
  const posted = {
    settlement_ref: 'CS-001', batch_id: 'B2', crop_category: 'CHILI',
    crop_name_snapshot: 'ငရုတ်', source_gross_centi_pyitha: 7000,
    purchased_centi_pyitha: 6700, actual_bags: 2,
    gross_value_kyat: 101000, labour_total_kyat: 335,
    commission_total_kyat: 1010, freight_kyat: 1000,
    total_expense_kyat: 2345, debt_principal_kyat: 0,
    debt_interest_kyat: 0, debt_total_kyat: 0,
    location_id: 'WH', payment_method: 'CASH', payment_reference: null,
  };
  const preview = { entries: [
    { bagNo: 1, net: 33, rate: 1000, amount: 33000, meta: { condition: 'WET', qualityGrade: 'A' } },
    { bagNo: 2, net: 34, rate: 2000, amount: 68000, meta: { condition: 'DRY', qualityGrade: 'B' } },
  ] };
  const layout = renderLayout(posted, { preview });
  assert.equal(layout.items.length, 2);
  assert.match(layout.items[0][1], /အစို/);
  assert.match(layout.items[1][1], /အခြောက်/);
  assert.equal(layout.items[0][2], '1 အိတ်');
  assert.notEqual(layout.items[0][4], layout.items[1][4]);
  assert.equal(layout.detailRows.length, 0);
  assert.equal(Object.fromEntries(layout.adjustments)['အိတ်ခွံ'], undefined);
});

test('cash advance prints as its own borrowing voucher', () => {
  const layout = renderFinanceLayout('buildCashAdvancePrintData', {
    reference: 'AD-001', date: '2026-09-21', farmerId: 'F-001',
    principal: 100000, rate: 3, note: 'စိုက်ပျိုးစရိတ်',
  });
  assert.equal(layout.type, 'ငွေသားချေးယူ');
  assert.equal(layout.detailRows.length, 0);
  assert.equal(layout.note, '');
});

test('goods advance prints product, quantity and issue-time unit value', () => {
  const layout = renderFinanceLayout('buildGoodsAdvancePrintData', {
    reference: 'AD-002', date: '2026-09-21', farmerId: 'F-014',
    productName: 'မြေဆီ', productCode: 'P-002', locationId: 'WH-001',
    quantity: 2, unit: 'အိတ်', unitPrice: 72000, rate: 3, note: '',
  });
  const details = Object.fromEntries(layout.detailRows);
  assert.equal(layout.type, 'စိုက်ထုတ်ပစ္စည်း အကြွေးယူ');
  assert.equal(details['ကုန်ပစ္စည်း'], 'မြေဆီ');
  assert.equal(details['အရေအတွက်'], '2 အိတ်');
  assert.equal(details['တစ်ယူနစ်တန်ဖိုး'], 'ကျပ် 72,000');
  assert.equal(details['Stock Location'], undefined);
  assert.equal(layout.note, '');
});

test('repayment identifies the debt lot and shows the full simple-interest calculation', () => {
  const layout = renderFinanceLayout('buildRepaymentPrintData', {
    advanceRef: 'AD-001',
    description: 'ငွေသား အရင်း ကျပ် 100,000',
    originalDescription: 'ငွေသား', originalPrincipal: 100000,
    issuedDate: '၁၂.၆.၂၀၂၆', paymentDate: '၂၉.၇.၂၀၂၆', days: 47, steps: 4,
    rate: 3, principal: 100000, interest: 6000, remainingDescription: 'ကျပ် 0',
  });
  const details = Object.fromEntries(layout.detailRows);
  const summary = Object.fromEntries(layout.summaryRows);

  assert.equal(layout.type, 'အကြွေးဆပ်ငွေ လက်ခံ');
  assert.equal(details['အကြွေးစာရင်းအမှတ်'], 'AD-001');
  assert.equal(details['အကြွေးယူသည့်ရက်'], '၁၂.၆.၂၀၂၆');
  assert.equal(details['မူလယူထားမှု'], 'ငွေသား');
  assert.equal(details['မူလအကြွေးအရင်း'], 'ကျပ် 100,000');
  assert.equal(details['ဆပ်သည့်ရက်'], '၂၉.၇.၂၀၂၆');
  assert.equal(details['ယခုရှင်းသည့်အပိုဒ်'], 'ငွေသား အရင်း ကျပ် 100,000');
  assert.equal(details['ကြာရက် / အတိုးကာလ'], '47 ရက် · 2 လစာတိုး');
  assert.equal(details['လစဉ် ရိုးရိုးအတိုးနှုန်း'], '3%');
  assert.equal(details['အတိုးတွက်ချက်မှု'], 'ကျပ် 100,000 × 3% × 2 လ = ကျပ် 6,000');
  assert.equal(summary['ယခုဆပ်သည့်အရင်း'], 'ကျပ် 100,000');
  assert.equal(summary['ယခုအတိုး'], 'ကျပ် 6,000');
  assert.equal(summary['ဆပ်ပြီး အကြွေးအရင်းလက်ကျန်'], 'ကျပ် 0');
  assert.equal(layout.note, '');
});
