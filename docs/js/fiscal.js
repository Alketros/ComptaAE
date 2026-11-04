// Règles micro-entreprise, périodes de déclaration, formatage.

export const CATEGORIES = {
  vente: { label: 'Vente de marchandises (BIC)', short: 'Vente', service: false, allowance: 0.71, box: ['5KO', '5TA'], vl: 0.01 },
  bic: { label: 'Prestation de services (BIC)', short: 'Services BIC', service: true, allowance: 0.50, box: ['5KP', '5TB'], vl: 0.017 },
  bnc: { label: 'Prestation libérale (BNC)', short: 'Libéral BNC', service: true, allowance: 0.34, box: ['5HQ', '5TE'], vl: 0.022 },
  cipav: { label: 'Libéral réglementé (CIPAV)', short: 'CIPAV', service: true, allowance: 0.34, box: ['5HQ', '5TE'], vl: 0.022 },
};
export const CATEGORY_KEYS = Object.keys(CATEGORIES);

export const METHODS = {
  virement: 'Virement', carte: 'Carte bancaire', especes: 'Espèces', cheque: 'Chèque',
  paypal: 'PayPal / Stripe…', prelevement: 'Prélèvement', autre: 'Autre',
};

export const PURCHASE_CATEGORIES = {
  marchandises: 'Marchandises / matières premières',
  materiel: 'Matériel / équipement',
  logiciel: 'Logiciel / abonnement',
  fournitures: 'Fournitures de bureau',
  deplacement: 'Déplacements / transport',
  telecom: 'Téléphone / internet',
  formation: 'Formation',
  sousTraitance: 'Sous-traitance',
  publicite: 'Publicité / communication',
  banqueAssurance: 'Banque / assurance',
  autre: 'Autre',
};

export const PURCHASE_ICONS = {
  marchandises: '📦', materiel: '💻', logiciel: '🧩', fournitures: '📎', deplacement: '🚗', telecom: '📶',
  formation: '🎓', sousTraitance: '🤝', publicite: '📣', banqueAssurance: '🏦', autre: '🧾',
};

export const CFP = {
  commercant: { label: 'Commerçant (0,1 %)', rate: 0.001 },
  artisan: { label: 'Artisan (0,3 %)', rate: 0.003 },
  liberal: { label: 'Libéral (0,2 %)', rate: 0.002 },
};

export const DEFAULT_SETTINGS = {
  businessName: '', ownerName: '', siret: '', address: '',
  mainCategory: 'bnc',
  frequency: 'monthly',          // 'monthly' | 'quarterly'
  cfp: 'liberal',
  versementLiberatoire: false,
  acreEnabled: false,
  acreEndDate: '',
  acreReduction: 50,
  rates: { vente: 12.3, bic: 21.2, bnc: 25.6, cipav: 23.2 },   // % — valeurs 2026
  plafondVente: 203100, plafondServices: 83600,
  seuilTVAVente: 85000, seuilTVAServices: 37500,
  declaredPeriods: [],
  lastBackup: null,
};

export function withDefaults(s) {
  const d = structuredClone(DEFAULT_SETTINGS);
  if (!s) return d;
  return { ...d, ...s, rates: { ...d.rates, ...(s.rates || {}) } };
}

// ---------- Dates (chaînes AAAA-MM-JJ, heure locale) ----------

const pad = (n) => String(n).padStart(2, '0');
export const ymd = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
export const today = () => ymd(new Date());
export const toDate = (s) => { const [y, m, d] = s.split('-').map(Number); return new Date(y, m - 1, d, 12); };
export const first = (y, m) => `${y}-${pad(m)}-01`;            // m : 1..12, peut déborder
export function monthStart(y, m) { const d = new Date(y, m - 1, 1, 12); return ymd(d); }
export const yearOf = (s) => Number(s.slice(0, 4));
export const monthOf = (s) => Number(s.slice(5, 7));
export function addDays(s, n) { const d = toDate(s); d.setDate(d.getDate() + n); return ymd(d); }
export function daysUntil(s) { return Math.round((toDate(s) - toDate(today())) / 86400000); }

export const range = {
  month: (y, m) => [monthStart(y, m), monthStart(y, m + 1)],
  quarter: (y, q) => [monthStart(y, (q - 1) * 3 + 1), monthStart(y, (q - 1) * 3 + 4)],
  year: (y) => [monthStart(y, 1), monthStart(y + 1, 1)],
};
export const inRange = (d, [a, b]) => !!d && d >= a && d < b;

const MONTHS = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
const MONTHS_SHORT = ['janv', 'févr', 'mars', 'avr', 'mai', 'juin', 'juil', 'août', 'sept', 'oct', 'nov', 'déc'];
export const monthName = (m) => MONTHS[m - 1];
export const monthShort = (m) => MONTHS_SHORT[m - 1];
export const cap = (s) => s ? s[0].toUpperCase() + s.slice(1) : s;

export function period(dateStr, frequency) {
  const y = yearOf(dateStr), m = monthOf(dateStr);
  let start, end, key, label;
  if (frequency === 'quarterly') {
    const q = Math.floor((m - 1) / 3) + 1;
    [start, end] = range.quarter(y, q);
    key = `${y}-T${q}`;
    label = `${q === 1 ? '1er' : q + 'e'} trimestre ${y}`;
  } else {
    [start, end] = range.month(y, m);
    key = `${y}-${pad(m)}`;
    label = `${monthName(m)} ${y}`;
  }
  // Échéance : dernier jour du mois qui suit la période
  const deadline = addDays(monthStart(yearOf(end), monthOf(end) + 1), -1);
  return { start, end, key, label, deadline };
}
export const prevPeriod = (p, f) => period(addDays(p.start, -1), f);
export const nextPeriod = (p, f) => period(p.end, f);

/** Période à déclarer en priorité : la période close si son échéance n'est pas passée et qu'elle n'est pas déclarée. */
export function nextDeclaration(settings, now = today()) {
  const cur = period(now, settings.frequency);
  const prev = prevPeriod(cur, settings.frequency);
  if (now <= prev.deadline && !settings.declaredPeriods.includes(prev.key)) return prev;
  return cur;
}

// ---------- Formatage ----------

const eurFmt = new Intl.NumberFormat('fr-FR', { style: 'currency', currency: 'EUR' });
export const eur = (v) => eurFmt.format(v || 0);
export const eurPlain = (v) => eur(v).replace(/[  ]/g, ' ');
export const frDate = (s) => s ? `${s.slice(8, 10)}/${s.slice(5, 7)}/${s.slice(0, 4)}` : '';
export const round2 = (v) => Math.round((v + Number.EPSILON) * 100) / 100;
export const amountInput = (v) => v == null ? '' : round2(v).toFixed(2).replace('.', ',').replace(/,00$/, '');
export function parseAmount(s) {
  if (s == null) return null;
  const c = String(s).replace(/[€\s  ]/g, '').replace(',', '.');
  if (!c) return null;
  const v = Number(c);
  return Number.isFinite(v) ? v : null;
}

// ---------- Calculs ----------

export const socialRate = (s, cat) => (s.rates[cat] ?? 0) / 100;
export const vlRate = (s, cat) => s.versementLiberatoire ? CATEGORIES[cat].vl : 0;
export const acreFactor = (s, date) =>
  s.acreEnabled && s.acreEndDate && date <= s.acreEndDate ? Math.max(0, 1 - s.acreReduction / 100) : 1;

export function summary(sales, purchases, r, settings) {
  const out = {
    caByCat: {}, purchases: 0, cotisations: 0, cfp: 0, impotVL: 0,
    pendingCount: 0, pendingAmount: 0, salesCount: 0, purchasesCount: 0,
  };
  for (const s of sales) {
    if (s.paymentDate) {
      if (!inRange(s.paymentDate, r)) continue;
      out.caByCat[s.category] = (out.caByCat[s.category] || 0) + s.amount;
      out.cotisations += s.amount * socialRate(settings, s.category) * acreFactor(settings, s.paymentDate);
      out.cfp += s.amount * (CFP[settings.cfp]?.rate ?? 0);
      out.impotVL += s.amount * vlRate(settings, s.category);
      out.salesCount++;
    } else if (inRange(s.invoiceDate, r)) {
      out.pendingCount++;
      out.pendingAmount += s.amount;
    }
  }
  for (const p of purchases) {
    if (inRange(p.date, r)) { out.purchases += p.amount; out.purchasesCount++; }
  }
  out.cotisations = round2(out.cotisations);
  out.cfp = round2(out.cfp);
  out.impotVL = round2(out.impotVL);
  out.ca = round2(Object.values(out.caByCat).reduce((a, b) => a + b, 0));
  out.caServices = round2(Object.entries(out.caByCat).filter(([k]) => CATEGORIES[k]?.service).reduce((a, [, v]) => a + v, 0));
  out.caVente = round2(out.caByCat.vente || 0);
  out.urssaf = round2(out.cotisations + out.cfp + out.impotVL);
  out.profit = round2(out.ca - out.purchases - out.urssaf);
  out.taxable = round2(Object.entries(out.caByCat).reduce((a, [k, v]) => a + v * (1 - (CATEGORIES[k]?.allowance ?? 0)), 0));
  return out;
}

export const uid = () => (crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36) + Math.random().toString(36).slice(2));
