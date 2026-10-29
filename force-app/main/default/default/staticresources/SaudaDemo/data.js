/* =====================================================================
   Sauda (Agreement) Demo — Shared data & helpers
   ---------------------------------------------------------------------
   DEMO ONLY. Nothing is sent to a backend. Records live in the browser's
   localStorage so the Create -> List -> Detail flow feels real across
   pages. Clearing browser storage resets the demo.
   ===================================================================== */

const STORE_KEY = "gem_sauda_demo_v1";

/* ----------------------------- Master data ------------------------- */
// Product categories (Gem Edible style)
const CATEGORIES = [
  "Groundnut Oils",
  "Sunflower Oils",
  "Mustard Oils",
  "Sesame Oils",
  "Refined Oils",
  "Lamp & Divine Oils",
  "Bulk / Crude",
];

// Edible-oil products inspired by Gem Edible (gemedible.com)
const PRODUCTS = [
  { code: "GG-GN-1L",  name: "Gem's Gold Groundnut Oil 1L",        category: "Groundnut Oils", uom: "CASE", rate: 2380 },
  { code: "GG-GN-5L",  name: "Gem's Gold Groundnut Oil 5L Tin",    category: "Groundnut Oils", uom: "TIN",  rate: 1180 },
  { code: "GG-SF-1L",  name: "Gem's Gold Sunflower Oil 1L Pouch",  category: "Sunflower Oils", uom: "CASE", rate: 1640 },
  { code: "GG-SF-5L",  name: "Gem's Gold Sunflower Oil 5L Jar",    category: "Sunflower Oils", uom: "JAR",  rate: 820  },
  { code: "GG-MU-1L",  name: "Gem's Gold Mustard Oil 1L",          category: "Mustard Oils",   uom: "CASE", rate: 1720 },
  { code: "GG-SE-1L",  name: "Gem's Gold Sesame (Gingelly) Oil 1L",category: "Sesame Oils",    uom: "CASE", rate: 2960 },
  { code: "GG-RB-15K", name: "Gem Refined Rice Bran Oil 15Kg Tin", category: "Refined Oils",   uom: "TIN",  rate: 2240 },
  { code: "GG-PALM-15",name: "Gem Refined Palm Oil 15Kg Tin",      category: "Refined Oils",   uom: "TIN",  rate: 1560 },
  { code: "GG-LAMP-1L",name: "Nithyam Lamp Oil 1L",                category: "Lamp & Divine Oils", uom: "CASE", rate: 1240 },
  { code: "GG-BULK-MT",name: "Crude Groundnut Oil (Bulk)",         category: "Bulk / Crude",   uom: "MT",   rate: 142000 },
];

// Customers / parties
const PARTIES = [
  "Sri Annapurna Distributors, Chennai",
  "Lakshmi Traders, Coimbatore",
  "Balaji Wholesale Mart, Madurai",
  "Vijay Super Bazaar, Salem",
  "Anand Provision Stores, Trichy",
  "Metro Cash & Carry, Bengaluru",
];

const BROKERS = ["— None —", "R. Kumar & Co.", "Sterling Brokers", "Coastal Commodity Agents"];

// Source locations (Plant / Depot) for FOR/Ex movement
const LOCATIONS = [
  { id: "PLANT-VIRUDHUNAGAR", name: "Virudhunagar Plant", type: "Plant" },
  { id: "PLANT-NAMAKKAL",     name: "Namakkal Plant",     type: "Plant" },
  { id: "DEPOT-CHENNAI",      name: "Chennai Depot",      type: "Depot" },
  { id: "DEPOT-COIMBATORE",   name: "Coimbatore Depot",   type: "Depot" },
  { id: "DEPOT-BENGALURU",    name: "Bengaluru Depot",    type: "Depot" },
];

const UOMS = ["CASE", "TIN", "JAR", "BOX", "KG", "MT", "KL"];
const PAYMENT_TERMS = ["Advance", "Net 7 Days", "Net 15 Days", "Net 30 Days", "Against Delivery"];
// FOR = Freight On Road (delivered to buyer) | Ex = Ex-works (buyer lifts goods)
const DELIVERY_TYPES = ["FOR", "Ex"];

/* ----------------------------- Seed records ------------------------ */
function seedSaudas() {
  return [
    {
      id: "SAU-1001",
      party: "Sri Annapurna Distributors, Chennai",
      broker: "R. Kumar & Co.",
      saudaDate: "2026-05-20",
      effectiveFrom: "2026-06-01",
      effectiveTo: "2026-07-31",
      deliveryType: "FOR",
      location: "PLANT-VIRUDHUNAGAR",
      paymentTerms: "Net 15 Days",
      remarks: "Monsoon stock commitment. Rate locked against Q2 crush.",
      status: "Active",
      lines: [
        { product: "GG-GN-5L",  qty: 400, uom: "TIN",  buyPrice: 1080, sellPrice: 1180, effFrom: "2026-06-01", effTo: "2026-07-31" },
        { product: "GG-SF-5L",  qty: 600, uom: "JAR",  buyPrice: 740,  sellPrice: 820,  effFrom: "2026-06-01", effTo: "2026-07-31" },
        { product: "GG-GN-1L",  qty: 250, uom: "CASE", buyPrice: 2180, sellPrice: 2380, effFrom: "2026-06-01", effTo: "2026-07-31" },
      ],
      history: [
        { ts: "2026-05-20 10:14", action: "Created", by: "Demo User", note: "Sauda drafted with 3 line items." },
        { ts: "2026-05-20 10:16", action: "Activated", by: "Demo User", note: "Status moved Draft → Active." },
      ],
      indent: { stage: 1 }, // 0=none,1=indent,2=confirmed,3=invoiced,4=delivered
    },
    {
      id: "SAU-1002",
      party: "Metro Cash & Carry, Bengaluru",
      broker: "— None —",
      saudaDate: "2026-05-25",
      effectiveFrom: "2026-06-05",
      effectiveTo: "2026-06-30",
      deliveryType: "Ex",
      location: "DEPOT-BENGALURU",
      paymentTerms: "Advance",
      remarks: "Bulk crude lifting, buyer arranges tanker.",
      status: "Draft",
      lines: [
        { product: "GG-BULK-MT", qty: 30, uom: "MT", buyPrice: 134000, sellPrice: 142000, effFrom: "2026-06-05", effTo: "2026-06-30" },
      ],
      history: [
        { ts: "2026-05-25 16:40", action: "Created", by: "Demo User", note: "Draft sauda for bulk crude." },
      ],
      indent: { stage: 0 },
    },
  ];
}

/* ----------------------------- Store API --------------------------- */
function loadSaudas() {
  try {
    const raw = localStorage.getItem(STORE_KEY);
    if (!raw) {
      const seed = seedSaudas();
      localStorage.setItem(STORE_KEY, JSON.stringify(seed));
      return seed;
    }
    return JSON.parse(raw);
  } catch (e) {
    return seedSaudas();
  }
}
function saveSaudas(list) { localStorage.setItem(STORE_KEY, JSON.stringify(list)); }
function getSauda(id) { return loadSaudas().find(s => s.id === id) || null; }
function upsertSauda(sauda) {
  const list = loadSaudas();
  const i = list.findIndex(s => s.id === sauda.id);
  if (i >= 0) list[i] = sauda; else list.unshift(sauda);
  saveSaudas(list);
}
function nextSaudaId() {
  const list = loadSaudas();
  let max = 1000;
  list.forEach(s => {
    const n = parseInt(String(s.id).replace(/\D/g, ""), 10);
    if (!isNaN(n) && n > max) max = n;
  });
  return "SAU-" + (max + 1);
}
function resetDemo() {
  localStorage.removeItem(STORE_KEY);
  loadSaudas();
}

/* ----------------------------- Lookups ----------------------------- */
function productByCode(code) { return PRODUCTS.find(p => p.code === code) || null; }
function productName(code) { const p = productByCode(code); return p ? p.name : code; }
function locationName(id) { const l = LOCATIONS.find(x => x.id === id); return l ? l.name : id; }
function locationType(id) { const l = LOCATIONS.find(x => x.id === id); return l ? l.type : ""; }

/* ----------------------------- Formatting -------------------------- */
function inr(n) {
  if (n === "" || n === null || n === undefined || isNaN(n)) return "—";
  return "₹" + Number(n).toLocaleString("en-IN", { maximumFractionDigits: 2 });
}
function num(n) {
  if (n === "" || n === null || n === undefined || isNaN(n)) return "0";
  return Number(n).toLocaleString("en-IN");
}
function fmtDate(d) {
  if (!d) return "—";
  const dt = new Date(d + "T00:00:00");
  if (isNaN(dt)) return d;
  return dt.toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" });
}
function todayISO() { return new Date().toISOString().slice(0, 10); }
function nowStamp() {
  const d = new Date();
  return d.toISOString().slice(0, 10) + " " +
    d.toTimeString().slice(0, 5);
}
function daysBetween(a, b) {
  const d1 = new Date(a + "T00:00:00"), d2 = new Date(b + "T00:00:00");
  return Math.round((d2 - d1) / 86400000);
}

/* ----------------------------- Status badge ------------------------ */
function statusBadge(status) {
  const map = {
    Draft:     "badge-draft",
    Active:    "badge-active",
    Extended:  "badge-extended",
    Cancelled: "badge-cancelled",
    Buyback:   "badge-buyback",
    Converted: "badge-converted",
    Closed:    "badge-closed",
  };
  const cls = map[status] || "badge-draft";
  return `<span class="badge ${cls}"><span class="dot"></span>${status}</span>`;
}
function deliveryPill(type) {
  const cls = type === "Ex" ? "ex" : "for";
  const title = type === "Ex" ? "Ex-works — buyer lifts goods" : "FOR — delivered to buyer";
  return `<span class="pill ${cls}" title="${title}">${type}</span>`;
}

/* ----------------------------- Line totals ------------------------- */
// Sauda is valued at the agreed SELL price; margin = (sell - buy) * qty
function lineSellTotal(l) { return (Number(l.qty) || 0) * (Number(l.sellPrice) || 0); }
function lineBuyTotal(l)  { return (Number(l.qty) || 0) * (Number(l.buyPrice)  || 0); }
function lineMargin(l)    { return lineSellTotal(l) - lineBuyTotal(l); }
function saudaSellValue(s){ return (s.lines || []).reduce((t, l) => t + lineSellTotal(l), 0); }
function saudaMargin(s)   { return (s.lines || []).reduce((t, l) => t + lineMargin(l), 0); }
function saudaQty(s)      { return (s.lines || []).reduce((t, l) => t + (Number(l.qty) || 0), 0); }

/* ----------------------------- Toast ------------------------------- */
function toast(msg, type = "success") {
  let wrap = document.querySelector(".toast-wrap");
  if (!wrap) { wrap = document.createElement("div"); wrap.className = "toast-wrap"; document.body.appendChild(wrap); }
  const icons = { success: "✓", warn: "⚠", danger: "✕", info: "ℹ" };
  const el = document.createElement("div");
  el.className = "toast " + type;
  el.innerHTML = `<span>${icons[type] || "✓"}</span><span>${msg}</span>`;
  wrap.appendChild(el);
  setTimeout(() => { el.style.opacity = "0"; el.style.transition = "opacity .3s"; setTimeout(() => el.remove(), 300); }, 3200);
}

/* ----------------------------- Shared chrome ----------------------- */
function topbar(active) {
  const link = (href, label, key) =>
    `<a href="${href}" class="${active === key ? "active" : ""}">${label}</a>`;
  return `
  <header class="topbar">
    <a class="brand" href="index.html" style="color:inherit;text-decoration:none">
      <span class="logo">G</span>
      <span>Gem Edible CRM <small>Sauda / Agreement Module</small></span>
    </a>
    <nav>
      ${link("index.html", "Home", "home")}
      ${link("sauda-list.html", "Saudas", "list")}
      ${link("sauda-create.html", "+ New Sauda", "create")}
      ${link("rate-config.html", "Rate Configuration", "rate")}
      ${link("rate-rollout.html", "Rate Rollout", "rollout")}
    </nav>
  </header>`;
}
function mountTopbar(active) {
  const host = document.getElementById("topbar");
  if (host) host.outerHTML = topbar(active);
}
function qs(name) { return new URLSearchParams(location.search).get(name); }

/* =====================================================================
   Rate Rollout (rate creation -> approval chain -> sales team)
   SRM -> NSM -> Zonal Head -> Sales Team, ending in a Sauda.
   ===================================================================== */
const ROLLOUT_KEY = "gem_rate_rollout_demo_v1";

// Approval hierarchy (top -> bottom)
const HIERARCHY = ["SRM", "NSM", "Zonal Head", "Sales Team"];

// Dimensions a premium/discount rule can target (from the process diagram)
const DIMENSIONS = ["State", "Persona", "Customer", "Product Category", "Product Type", "Particular Product"];
const STATES = ["Tamil Nadu", "Karnataka", "Kerala", "Andhra Pradesh", "Maharashtra"];
const PERSONAS = ["Distributor", "Wholesaler", "Modern Trade", "Retailer", "HoReCa"];
const PRODUCT_TYPES = ["Pouch", "Tin", "Jar", "Bottle", "Bulk"];

/* ---- Rollout status helpers ----
   stageIndex: how far down the chain it has rolled out
     0 = created by SRM, awaiting NSM
     1 = NSM rolled out, awaiting Zonal Head
     2 = Zonal Head rolled out -> received by Sales Team (complete)
   status: Draft | Pending NSM | Pending Zonal Head | Rolled Out | Rejected
*/
// Which role must act next for a given status
function rolloutApprover(r) {
  if (r.status === "Pending NSM") return "NSM";
  if (r.status === "Pending Zonal Head") return "Zonal Head";
  return null;
}
function rolloutBadge(status) {
  const map = {
    "Draft": "badge-draft",
    "Pending NSM": "badge-buyback",
    "Pending Zonal Head": "badge-buyback",
    "Rolled Out": "badge-active",
    "Rejected": "badge-cancelled",
  };
  return `<span class="badge ${map[status] || "badge-draft"}"><span class="dot"></span>${status}</span>`;
}

function seedRollouts() {
  return [
    {
      id: "RR-1001",
      title: "Daily Oil Rate — South Zone",
      effectiveDate: todayISO(),
      region: "South Zone",
      status: "Pending Zonal Head",
      lines: [
        { product: "GG-SF-5L",  baseRate: 820,  revisedRate: 835 },
        { product: "GG-GN-5L",  baseRate: 1180, revisedRate: 1205 },
        { product: "GG-MU-1L",  baseRate: 1720, revisedRate: 1720 },
      ],
      adjustments: [
        { dimension: "Product Category", target: "Sunflower Oils", kind: "Discount", amountType: "%", value: 2, favourite: true, addedBy: "NSM" },
        { dimension: "State", target: "Karnataka", kind: "Premium", amountType: "₹", value: 15, favourite: false, addedBy: "NSM" },
      ],
      approvals: [
        { role: "SRM", action: "Created", ts: "2026-06-03 09:10", note: "Base rates set against today's crush." },
        { role: "NSM", action: "Approved & Rolled Out", ts: "2026-06-03 09:40", note: "Added category discount + Karnataka premium." },
      ],
    },
    {
      id: "RR-1002",
      title: "Festive Forward Rate — West Zone",
      effectiveDate: todayISO(),
      region: "West Zone",
      status: "Pending NSM",
      lines: [
        { product: "GG-GN-1L", baseRate: 2380, revisedRate: 2410 },
        { product: "GG-SE-1L", baseRate: 2960, revisedRate: 2990 },
      ],
      adjustments: [],
      approvals: [
        { role: "SRM", action: "Created", ts: "2026-06-03 08:05", note: "Festive season forward rate." },
      ],
    },
    {
      id: "RR-1000",
      title: "Daily Oil Rate — South Zone (prev.)",
      effectiveDate: "2026-06-02",
      region: "South Zone",
      status: "Rolled Out",
      lines: [
        { product: "GG-SF-1L", baseRate: 1640, revisedRate: 1660 },
      ],
      adjustments: [
        { dimension: "Persona", target: "Modern Trade", kind: "Discount", amountType: "%", value: 1.5, favourite: true, addedBy: "Zonal Head" },
      ],
      approvals: [
        { role: "SRM", action: "Created", ts: "2026-06-02 09:00", note: "" },
        { role: "NSM", action: "Approved & Rolled Out", ts: "2026-06-02 09:30", note: "" },
        { role: "Zonal Head", action: "Approved & Rolled Out", ts: "2026-06-02 10:15", note: "Released to sales team." },
      ],
    },
  ];
}

function loadRollouts() {
  try {
    const raw = localStorage.getItem(ROLLOUT_KEY);
    if (!raw) { const s = seedRollouts(); localStorage.setItem(ROLLOUT_KEY, JSON.stringify(s)); return s; }
    return JSON.parse(raw);
  } catch (e) { return seedRollouts(); }
}
function saveRollouts(list) { localStorage.setItem(ROLLOUT_KEY, JSON.stringify(list)); }
function getRollout(id) { return loadRollouts().find(r => r.id === id) || null; }
function upsertRollout(r) {
  const list = loadRollouts();
  const i = list.findIndex(x => x.id === r.id);
  if (i >= 0) list[i] = r; else list.unshift(r);
  saveRollouts(list);
}
function nextRolloutId() {
  let max = 1000;
  loadRollouts().forEach(r => { const n = parseInt(String(r.id).replace(/\D/g, ""), 10); if (!isNaN(n) && n > max) max = n; });
  return "RR-" + (max + 1);
}
function resetRolloutDemo() { localStorage.removeItem(ROLLOUT_KEY); loadRollouts(); }

// Acting role (simulated logged-in role) persisted for the demo
function getActingRole() { return localStorage.getItem("gem_acting_role") || "SRM"; }
function setActingRole(role) { localStorage.setItem("gem_acting_role", role); }
