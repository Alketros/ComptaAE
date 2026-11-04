// Lecture des factures : texte du PDF (pdf.js) ou reconnaissance de texte (Tesseract) pour
// les photos / scans, puis analyse par règles. Tout se fait dans le téléphone.

const VENDOR = new URL('../vendor/', import.meta.url).href;

let pdfjsPromise;
function pdfjs() {
  if (!pdfjsPromise) {
    pdfjsPromise = import(VENDOR + 'pdfjs/pdf.min.mjs').then((lib) => {
      lib.GlobalWorkerOptions.workerSrc = VENDOR + 'pdfjs/pdf.worker.min.mjs';
      return lib;
    });
  }
  return pdfjsPromise;
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.onload = resolve;
    s.onerror = () => reject(new Error('Chargement impossible : ' + src));
    document.head.appendChild(s);
  });
}

let workerPromise;
async function ocrWorker(onProgress) {
  if (!workerPromise) {
    workerPromise = (async () => {
      if (!window.Tesseract) await loadScript(VENDOR + 'tesseract/tesseract.min.js');
      return window.Tesseract.createWorker('fra', 1, {
        workerPath: VENDOR + 'tesseract/worker.min.js',
        corePath: VENDOR + 'tesseract/',
        langPath: VENDOR + 'tesseract/lang',
        gzip: true,
        logger: (m) => { if (m.status === 'recognizing text') ocrProgress?.(m.progress); },
      });
    })().catch((e) => { workerPromise = null; throw e; });
  }
  ocrProgress = onProgress;
  return workerPromise;
}
let ocrProgress = null;

async function ocr(canvas, onProgress) {
  const worker = await ocrWorker(onProgress);
  const { data } = await worker.recognize(canvas);
  return data.text || '';
}

// ---------- Fichiers ----------

function loadImage(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => { URL.revokeObjectURL(url); resolve(img); };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('Image illisible')); };
    img.src = url;
  });
}

function toCanvas(img, maxSide) {
  const scale = Math.min(1, maxSide / Math.max(img.width, img.height));
  const c = document.createElement('canvas');
  c.width = Math.round(img.width * scale);
  c.height = Math.round(img.height * scale);
  const ctx = c.getContext('2d');
  ctx.fillStyle = '#fff';
  ctx.fillRect(0, 0, c.width, c.height);
  ctx.drawImage(img, 0, 0, c.width, c.height);
  return c;
}

const canvasToBuffer = (c, type = 'image/jpeg', q = 0.82) =>
  new Promise((resolve) => c.toBlob((b) => b.arrayBuffer().then(resolve), type, q));

/** Texte d'un PDF, en reconstituant les lignes à partir des positions. */
async function pdfText(buffer, onProgress) {
  const lib = await pdfjs();
  const doc = await lib.getDocument({ data: new Uint8Array(buffer.slice(0)), isEvalSupported: false }).promise;
  const pages = Math.min(doc.numPages, 4);
  let text = '';
  for (let i = 1; i <= pages; i++) {
    const page = await doc.getPage(i);
    const content = await page.getTextContent();
    const items = content.items.filter((it) => it.str && it.str.trim())
      .map((it) => ({ x: it.transform[4], y: it.transform[5], h: Math.abs(it.transform[3]) || 10, s: it.str }));
    items.sort((a, b) => b.y - a.y || a.x - b.x);
    const lines = [];
    for (const it of items) {
      const line = lines[lines.length - 1];
      if (line && Math.abs(line.y - it.y) < Math.max(line.h, it.h) * 0.5) line.items.push(it);
      else lines.push({ y: it.y, h: it.h, items: [it] });
    }
    text += lines.map((l) => l.items.sort((a, b) => a.x - b.x).map((i) => i.s).join('  ')).join('\n') + '\n';
  }
  if (text.replace(/\s/g, '').length >= 30) return text;

  // PDF scanné : rendu en image puis OCR
  let ocrText = '';
  for (let i = 1; i <= Math.min(doc.numPages, 2); i++) {
    const page = await doc.getPage(i);
    const vp1 = page.getViewport({ scale: 1 });
    const viewport = page.getViewport({ scale: Math.min(3, 2000 / Math.max(vp1.width, vp1.height)) });
    const c = document.createElement('canvas');
    c.width = viewport.width; c.height = viewport.height;
    await page.render({ canvasContext: c.getContext('2d'), viewport }).promise;
    ocrText += await ocr(c, onProgress) + '\n';
  }
  return ocrText;
}

/**
 * Lit un fichier (PDF ou image) et renvoie le justificatif à stocker et les infos détectées.
 * @returns {Promise<{attachment:{data:ArrayBuffer,type:string,name:string}, info:object}>}
 */
export async function readDocument(file, kind, onProgress) {
  const isPdf = file.type === 'application/pdf' || /\.pdf$/i.test(file.name);
  let attachment, text = '';
  if (isPdf) {
    const data = await file.arrayBuffer();
    attachment = { data, type: 'application/pdf', name: file.name || 'document.pdf' };
    try { text = await pdfText(data, onProgress); } catch (e) { console.warn(e); }
  } else {
    const img = await loadImage(file);
    const stored = toCanvas(img, 1800);
    attachment = { data: await canvasToBuffer(stored), type: 'image/jpeg', name: (file.name || 'photo').replace(/\.\w+$/, '') + '.jpg' };
    try { text = await ocr(toCanvas(img, 2200), onProgress); } catch (e) { console.warn(e); }
  }
  return { attachment, info: parse(text, kind), text };
}

/** Rendu des pages d'un PDF en images (pour l'affichage du justificatif). */
export async function pdfPages(buffer, maxPages = 10) {
  const lib = await pdfjs();
  const doc = await lib.getDocument({ data: new Uint8Array(buffer.slice(0)), isEvalSupported: false }).promise;
  const out = [];
  for (let i = 1; i <= Math.min(doc.numPages, maxPages); i++) {
    const page = await doc.getPage(i);
    const vp1 = page.getViewport({ scale: 1 });
    const viewport = page.getViewport({ scale: Math.min(2.5, 1600 / vp1.width) });
    const c = document.createElement('canvas');
    c.width = viewport.width; c.height = viewport.height;
    await page.render({ canvasContext: c.getContext('2d'), viewport }).promise;
    out.push(c);
  }
  return out;
}

// ---------- Analyse par règles ----------

export const normalize = (s) => s.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();

const AMOUNT_RE = /(^|[^\d.,])(\d{1,3}(?:[ \u00A0\u202F]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{3})*(?:[.,]\d{1,2})?)(?![.,]?\d)(\s*%)?/g;
const NUM_DATE_RE = /(^|\D)(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4}|\d{2})(?!\d)/g;
const ISO_DATE_RE = /(^|\D)(\d{4})-(\d{2})-(\d{2})(?!\d)/g;
const TEXT_DATE_RE = /(^|\D)(\d{1,2})(?:er)?\s+(janv(?:ier)?|fevr?(?:ier)?|mars|avr(?:il)?|mai|juin|juil(?:let)?|aout|sept(?:embre)?|oct(?:obre)?|nov(?:embre)?|dec(?:embre)?|january|february|march|april|may|june|july|august|september|october|november|december)\.?\s+(\d{4})/g;

export function toNumber(raw) {
  let s = raw.replace(/[ \u00A0\u202F]/g, '');
  const c = s.lastIndexOf(','), d = s.lastIndexOf('.');
  if (c >= 0 && d >= 0) {
    const dec = c > d ? ',' : '.';
    s = s.split(dec === ',' ? '.' : ',').join('').replace(dec, '.');
  } else if (c >= 0 || d >= 0) {
    const sep = c >= 0 ? ',' : '.';
    const parts = s.split(sep);
    if (parts.length > 2 || (parts.length === 2 && parts[1].length === 3)) s = parts.join('');
    else s = s.replace(sep, '.');
  }
  const v = Number(s);
  return Number.isFinite(v) ? v : null;
}

const stripDates = (line) => line.replace(NUM_DATE_RE, '$1 ').replace(ISO_DATE_RE, '$1 ').replace(TEXT_DATE_RE, '$1 ');

export function amounts(line) {
  const out = [];
  for (const m of stripDates(line).matchAll(AMOUNT_RE)) {
    if (m[3]) continue; // pourcentage
    const v = toNumber(m[2]);
    if (v && v > 0 && v < 1e7) out.push(v);
  }
  return out;
}

const TOTAL_KEYS = ['net a payer', 'total ttc', 'montant ttc', 'total a payer', 'montant a payer', 'reste a payer',
  'montant total', 'total general', 'grand total', 'amount due', 'total due', 'total paid', 'montant regle', 'total'];

function findTotal(lines) {
  for (const key of TOTAL_KEYS) {
    const found = [];
    lines.forEach((line, i) => {
      if (!line.includes(key)) return;
      if (key === 'total' && (['sous-total', 'sous total', 'subtotal', ' ht', 'hors tax', 'tva', 'vat', 'remise'].some((x) => line.includes(x)) || line.endsWith('ht'))) return;
      let a = amounts(line);
      if (!a.length && i + 1 < lines.length) a = amounts(lines[i + 1]);
      if (a.length) found.push(Math.max(...a));
    });
    if (found.length) return Math.max(...found);
  }
  const euro = lines.filter((l) => l.includes('€') || l.includes('eur')).flatMap(amounts);
  return euro.length ? Math.max(...euro) : null;
}

function findVAT(lines, total) {
  const cand = lines.filter((l) => (l.includes('tva') || l.includes('vat')) &&
    !['intracom', '293', 'non applicable', 'numero', 'n°'].some((x) => l.includes(x)));
  const preferred = cand.filter((l) => l.includes('total') || l.includes('montant'));
  for (const group of [preferred, cand]) {
    const v = group.flatMap(amounts).filter((x) => total == null || x < total * 0.5);
    if (v.length) return Math.max(...v);
  }
  return null;
}

function monthNumber(m) {
  if (m.startsWith('juil') || m.startsWith('jul')) return 7;
  if (m.startsWith('juin') || m.startsWith('jun')) return 6;
  return { jan: 1, fev: 2, feb: 2, mar: 3, avr: 4, apr: 4, mai: 5, may: 5, aou: 8, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 }[m.slice(0, 3)];
}

export function dates(line) {
  const out = [];
  const maxYear = new Date().getFullYear() + 1;
  const make = (y, m, d) => {
    y = Number(y); m = Number(m); d = Number(d);
    if (y < 100) y += 2000;
    if (y < 2000 || y > maxYear || m < 1 || m > 12 || d < 1 || d > 31) return;
    out.push(`${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`);
  };
  for (const m of line.matchAll(ISO_DATE_RE)) make(m[2], m[3], m[4]);
  for (const m of line.matchAll(NUM_DATE_RE)) make(m[4], m[3], m[2]);
  for (const m of line.matchAll(TEXT_DATE_RE)) { const mo = monthNumber(m[3]); if (mo) make(m[4], mo, m[2]); }
  return out;
}

function findDate(lines) {
  const keys = ['date de facture', 'date facture', "date d'emission", 'date d emission', 'facture du', 'emise le',
    'invoice date', 'date de la facture', 'date :', 'date:', 'date'];
  const excluded = ['echeance', 'due', 'livraison', 'naissance', 'expiration', 'validite', 'limite'];
  const ok = (l) => !excluded.some((x) => l.includes(x));
  for (const key of keys) {
    for (let i = 0; i < lines.length; i++) {
      if (!lines[i].includes(key) || !ok(lines[i])) continue;
      const d = dates(lines[i])[0] || (i + 1 < lines.length ? dates(lines[i + 1])[0] : null);
      if (d) return d;
    }
  }
  for (const l of lines) { if (ok(l)) { const d = dates(l)[0]; if (d) return d; } }
  return null;
}

const INVOICE_RES = [
  /(?:n[°o]\s*(?:de\s*)?facture|num[ée]ro\s*(?:de\s*)?facture|invoice\s*(?:number|no\.?|#|n[°o]))\s*[:.]?\s*([A-Z0-9][A-Z0-9\-_/.]*\d[A-Z0-9\-_/.]*)/gi,
  /(?:facture|invoice|re[çc]u|receipt|avoir|commande)\s*(?:n[°o]\.?|num[ée]ro|number|no\.?|#)?\s*[:.]?\s*([A-Z0-9][A-Z0-9\-_/.]*\d[A-Z0-9\-_/.]*)/gi,
];

function findInvoiceNumber(raw) {
  for (const re of INVOICE_RES) {
    for (const line of raw) {
      for (const m of line.matchAll(re)) {
        const v = m[1].replace(/[.\-/_]+$/, '');
        if (v.length >= 2 && !dates(v).length) return v;
      }
    }
  }
  return null;
}

const clean = (s) => s.replace(/^[\s:\-–|]+|[\s:\-–|]+$/g, '');
const LEGAL = /\b(sas|sasu|sarl|eurl|sa|sci|snc|inc|ltd|llc|gmbh|limited|corp)\b/;

function findSupplier(raw, norm) {
  const banned = ['facture', 'invoice', 'date', 'page', 'client', 'devis', 'recu', 'ticket', 'tel', 'siret', 'siren',
    'capital', 'rcs', '@', 'http', 'adresse', 'commande', 'total', 'tva', 'bon de'];
  const top = norm.slice(0, 15);
  const acceptable = (i) => {
    const n = norm[i];
    return (n.match(/\p{L}/gu) || []).length >= 3 && n.length <= 60 && !banned.some((b) => n.includes(b)) && !amounts(n).length;
  };
  for (let i = 0; i < top.length; i++) {
    if (LEGAL.test(norm[i]) && norm[i].length <= 60 && !norm[i].includes('capital') && !norm[i].includes('rcs')) return clean(raw[i]);
  }
  const dom = norm.join(' ').match(/www\.([a-z0-9-]+)\./);
  if (dom) {
    for (let i = 0; i < top.length; i++) if (acceptable(i) && norm[i].includes(dom[1])) return clean(raw[i]);
    return cap(dom[1]);
  }
  for (let i = 0; i < top.length; i++) if (acceptable(i)) return clean(raw[i]);
  return null;
}
const cap = (s) => s[0].toUpperCase() + s.slice(1);

function findClient(raw, norm) {
  const keys = ['facture a', 'facturer a', 'adresse de facturation', 'destinataire', 'bill to', 'billed to', 'client'];
  const refs = ['n° client', 'no client', 'numero client', 'code client', 'ref client', 'reference client', 'client n'];
  for (const key of keys) {
    for (let i = 0; i < norm.length; i++) {
      if (!norm[i].includes(key) || refs.some((r) => norm[i].includes(r))) continue;
      const colon = raw[i].indexOf(':');
      if (colon >= 0) {
        const after = clean(raw[i].slice(colon + 1));
        if ((after.match(/\p{L}/gu) || []).length >= 2) return after;
      }
      if (i + 1 < raw.length && (raw[i + 1].match(/\p{L}/gu) || []).length >= 2) return clean(raw[i + 1]);
    }
  }
  return null;
}

const CATEGORY_WORDS = [
  ['telecom', ['orange', 'sfr', 'bouygues', 'free mobile', 'freebox', 'sosh', 'red by sfr', 'forfait mobile', 'box internet']],
  ['deplacement', ['sncf', 'ouigo', 'uber', 'bolt', 'totalenergies', 'carburant', 'gazole', 'sans plomb', 'peage', 'parking', 'vinci autoroutes', 'air france', 'blablacar', 'billet de train', 'taxi']],
  ['logiciel', ['abonnement', 'subscription', 'adobe', 'microsoft', 'google workspace', 'icloud', 'notion', 'github', 'licence', 'ovh', 'o2switch', 'hebergement', 'nom de domaine', 'figma', 'canva', 'openai', 'anthropic', 'dropbox', 'spotify']],
  ['formation', ['formation', 'udemy', 'coursera', 'openclassrooms']],
  ['publicite', ['publicite', 'facebook ads', 'google ads', 'vistaprint', 'cartes de visite', 'impression']],
  ['banqueAssurance', ['frais bancaires', 'qonto', 'shine', 'assurance', 'rc pro']],
  ['materiel', ['ordinateur', 'macbook', 'ecran', 'clavier', 'souris', 'imprimante', 'ldlc', 'darty', 'boulanger', 'materiel']],
  ['fournitures', ['fournitures', 'papeterie', 'bureau vallee', 'cartouche', 'ramette']],
];

function guessCategory(text) {
  for (const [cat, words] of CATEGORY_WORDS) {
    for (const w of words) {
      if (new RegExp(`(^|[^a-z0-9])${w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}($|[^a-z0-9])`).test(text)) return cat;
    }
  }
  return null;
}

export function parse(text, kind) {
  const raw = (text || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const norm = raw.map(normalize);
  const info = {};
  const total = findTotal(norm);
  if (total != null) info.amount = Math.round(total * 100) / 100;
  const vat = findVAT(norm, total);
  if (vat != null) info.vat = Math.round(vat * 100) / 100;
  info.date = findDate(norm);
  info.invoiceNumber = findInvoiceNumber(raw);
  if (kind === 'purchase') {
    info.party = findSupplier(raw, norm);
    info.purchaseCategory = guessCategory(normalize(text || ''));
  } else {
    info.party = findClient(raw, norm);
  }
  for (const k of Object.keys(info)) if (info[k] == null) delete info[k];
  return info;
}
