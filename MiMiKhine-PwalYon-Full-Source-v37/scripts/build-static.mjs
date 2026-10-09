import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourcePath = resolve(projectRoot, "public", "pwal-yon-dashboard.html");
const standaloneOutputPath = resolve(projectRoot, "outputs", "pwal-yon-dashboard.html");
const ogImagePath = resolve(projectRoot, "public", "og.png");
const outputPath = resolve(projectRoot, "dist", "server", "index.js");
const dashboardHtml = await readFile(sourcePath, "utf8");
const ogImageBase64 = (await readFile(ogImagePath)).toString("base64");

if (
  !dashboardHtml.includes("မီမီခိုင် ပွဲရုံ") ||
  !dashboardHtml.includes("MI MI KHINE PWAL YON") ||
  !dashboardHtml.includes('id="saveInputSale"') ||
  !dashboardHtml.includes('id="marketPriceForm"') ||
  !dashboardHtml.includes("upsert_market_price") ||
  !dashboardHtml.includes("weighing_batches") ||
  !dashboardHtml.includes("create_weighing_batch") ||
  !dashboardHtml.includes("submit_weighing_batch") ||
  !dashboardHtml.includes("register_weighing_business_date") ||
  !dashboardHtml.includes("add_bag_weight") ||
  !dashboardHtml.includes("mimi-khine-weighing-offline-v1") ||
  !dashboardHtml.includes("WEIGHING_HISTORY_PAGE_SIZE") ||
  !dashboardHtml.includes('id="intakeSaleWeight"') ||
  !dashboardHtml.includes("intake_allocations") ||
  !dashboardHtml.includes("allocate_weighing_intake") ||
  !dashboardHtml.includes("consignment_lots") ||
  !dashboardHtml.includes("issue_advance") ||
  !dashboardHtml.includes("repay_advance") ||
  !dashboardHtml.includes("record_product_sale") ||
  !dashboardHtml.includes("record_stock_receipt") ||
  !dashboardHtml.includes("record_business_expense") ||
  !dashboardHtml.includes('id="stockReceiptForm"') ||
  !dashboardHtml.includes("get_product_stock_balances") ||
  !dashboardHtml.includes("get_farmer_debt_balances") ||
  !dashboardHtml.includes("settle_crop_intake") ||
  !dashboardHtml.includes("record_wholesale_crop_sale") ||
  !dashboardHtml.includes("get_crop_stock_balances") ||
  !dashboardHtml.includes("get_day_close_preview") ||
  !dashboardHtml.includes("close_business_day") ||
  !dashboardHtml.includes("pwalYonCropOperationsReadCopy.v1") ||
  !dashboardHtml.includes("const PILOT_LOCKED_WRITE_IDS=[]") ||
  dashboardHtml.includes("AD-DEMO-001") ||
  dashboardHtml.includes("ရွှေဝါ ပွဲရုံ") ||
  !dashboardHtml.includes("Live System Readiness") ||
  !dashboardHtml.includes("__SITE_ORIGIN__/og.png") ||
  ogImageBase64.length < 1000
) {
  throw new Error("Dashboard source validation failed");
}

const workerSource = `const DASHBOARD_HTML = ${JSON.stringify(dashboardHtml)};
const OG_IMAGE_BASE64 = ${JSON.stringify(ogImageBase64)};

const htmlHeaders = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  "referrer-policy": "same-origin",
  "x-frame-options": "SAMEORIGIN",
};

const imageHeaders = {
  "content-type": "image/png",
  "cache-control": "public, max-age=86400, stale-while-revalidate=604800",
  "x-content-type-options": "nosniff",
};

function decodeBase64(value) {
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/" || url.pathname === "/pwal-yon-dashboard.html") {
      const html = DASHBOARD_HTML.replaceAll("__SITE_ORIGIN__", url.origin);
      return new Response(request.method === "HEAD" ? null : html, { status: 200, headers: htmlHeaders });
    }
    if (url.pathname === "/og.png") {
      return new Response(request.method === "HEAD" ? null : decodeBase64(OG_IMAGE_BASE64), {
        status: 200,
        headers: imageHeaders,
      });
    }
    return new Response("Not found", {
      status: 404,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  },
};
`;

await mkdir(dirname(outputPath), { recursive: true });
await mkdir(dirname(standaloneOutputPath), { recursive: true });
await writeFile(standaloneOutputPath, dashboardHtml, "utf8");
await writeFile(outputPath, workerSource, "utf8");
console.log("Static Sites build created: dist/server/index.js");
