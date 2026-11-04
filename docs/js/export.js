// Exports : Excel (.xlsx), PDF, dossier ZIP complet, sauvegarde / restauration.
import {
  CATEGORIES, CATEGORY_KEYS, METHODS, PURCHASE_CATEGORIES, summary, inRange, range, eurPlain, frDate,
  monthName, cap, yearOf, monthOf, monthStart, today, withDefaults,
} from './fiscal.js';

const enc = new TextEncoder();

// ---------- ZIP (stocké, sans compression) ----------

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(bytes) {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

export function zip(files) {   // files: [{name, data: Uint8Array|ArrayBuffer|string}]
  const now = new Date();
  const time = (now.getHours() << 11) | (now.getMinutes() << 5) | (now.getSeconds() >> 1);
  const date = ((now.getFullYear() - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate();
  const chunks = [], central = [];
  let offset = 0;
  for (const f of files) {
    const name = enc.encode(f.name);
    const data = typeof f.data === 'string' ? enc.encode(f.data) : new Uint8Array(f.data);
    const crc = crc32(data);
    const h = new DataView(new ArrayBuffer(30));
    h.setUint32(0, 0x04034b50, true); h.setUint16(4, 20, true); h.setUint16(6, 0x0800, true); h.setUint16(8, 0, true);
    h.setUint16(10, time, true); h.setUint16(12, date, true); h.setUint32(14, crc, true);
    h.setUint32(18, data.length, true); h.setUint32(22, data.length, true); h.setUint16(26, name.length, true); h.setUint16(28, 0, true);
    chunks.push(new Uint8Array(h.buffer), name, data);
    const c = new DataView(new ArrayBuffer(46));
    c.setUint32(0, 0x02014b50, true); c.setUint16(4, 20, true); c.setUint16(6, 20, true); c.setUint16(8, 0x0800, true);
    c.setUint16(10, 0, true); c.setUint16(12, time, true); c.setUint16(14, date, true); c.setUint32(16, crc, true);
    c.setUint32(20, data.length, true); c.setUint32(24, data.length, true); c.setUint16(28, name.length, true);
    c.setUint32(42, offset, true);
    central.push(new Uint8Array(c.buffer), name);
    offset += 30 + name.length + data.length;
  }
  const cdSize = central.reduce((a, b) => a + b.length, 0);
  const e = new DataView(new ArrayBuffer(22));
  e.setUint32(0, 0x06054b50, true); e.setUint16(8, files.length, true); e.setUint16(10, files.length, true);
  e.setUint32(12, cdSize, true); e.setUint32(16, offset, true);
  return new Blob([...chunks, ...central, new Uint8Array(e.buffer)], { type: 'application/zip' });
}

export function unzip(buffer) {   // lit les ZIP « stockés » produits par zip()
  const b = new Uint8Array(buffer), v = new DataView(buffer);
  const out = {};
  let i = 0;
  while (i + 30 <= b.length && v.getUint32(i, true) === 0x04034b50) {
    const method = v.getUint16(i + 8, true), size = v.getUint32(i + 18, true);
    const nl = v.getUint16(i + 26, true), xl = v.getUint16(i + 28, true);
    const name = new TextDecoder().decode(b.subarray(i + 30, i + 30 + nl));
    const start = i + 30 + nl + xl;
    if (method === 0) out[name] = b.slice(start, start + size).buffer;
    i = start + size;
  }
  return out;
}

// ---------- Excel ----------

const esc = (s) => String(s ?? '').replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const col = (i) => { let s = '', n = i + 1; while (n > 0) { const r = (n - 1) % 26; s = String.fromCharCode(65 + r) + s; n = Math.floor((n - 1) / 26); } return s; };
const serial = (d) => Math.round((Date.UTC(+d.slice(0, 4), +d.slice(5, 7) - 1, +d.slice(8, 10)) - Date.UTC(1899, 11, 30)) / 86400000);

// Cellules : 'texte' | {t:'h'|'b', v} | {m: nombre} | {bm: nombre} | {d:'AAAA-MM-JJ'} | {sum:[col,de,à], v} | null
function cellXML(c, ref) {
  if (c == null || c === '') return '';
  if (typeof c === 'string') return `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${esc(c)}</t></is></c>`;
  if (c.t) return `<c r="${ref}" s="${c.t === 'h' ? 1 : 4}" t="inlineStr"><is><t xml:space="preserve">${esc(c.v)}</t></is></c>`;
  if ('m' in c) return `<c r="${ref}" s="3"><v>${(+c.m || 0).toFixed(2)}</v></c>`;
  if ('bm' in c) return `<c r="${ref}" s="5"><v>${(+c.bm || 0).toFixed(2)}</v></c>`;
  if ('d' in c) return c.d ? `<c r="${ref}" s="2"><v>${serial(c.d)}</v></c>` : '';
  if ('sum' in c) {
    const [k, a, b] = c.sum, L = col(k);
    return `<c r="${ref}" s="5"><f>${b >= a ? `SUM(${L}${a}:${L}${b})` : '0'}</f><v>${(+c.v || 0).toFixed(2)}</v></c>`;
  }
  return '';
}

function sheetXML({ rows, widths, freeze = true }) {
  let x = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">';
  if (freeze) x += '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>';
  x += '<cols>' + widths.map((w, i) => `<col min="${i + 1}" max="${i + 1}" width="${w}" customWidth="1"/>`).join('') + '</cols><sheetData>';
  rows.forEach((row, r) => {
    x += `<row r="${r + 1}">` + row.map((c, i) => cellXML(c, col(i) + (r + 1))).join('') + '</row>';
  });
  return x + '</sheetData></worksheet>';
}

const STYLES = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="2"><numFmt numFmtId="164" formatCode="#,##0.00\\ &quot;€&quot;"/><numFmt numFmtId="165" formatCode="dd/mm/yyyy"/></numFmts>
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCE6F1"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/><xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/></cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>`;

function workbook(sheets) {
  const n = sheets.length;
  const files = [
    { name: '[Content_Types].xml', data: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' + sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('') + '</Types>' },
    { name: '_rels/.rels', data: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>' },
    { name: 'xl/workbook.xml', data: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>' + sheets.map((s, i) => `<sheet name="${esc(s.name.replace(/[[\]:*?/\\]/g, '').slice(0, 31))}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join('') + '</sheets></workbook>' },
    { name: 'xl/_rels/workbook.xml.rels', data: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' + sheets.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('') + `<Relationship Id="rId${n + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>` },
    { name: 'xl/styles.xml', data: STYLES },
    ...sheets.map((s, i) => ({ name: `xl/worksheets/sheet${i + 1}.xml`, data: sheetXML(s) })),
  ];
  return new Blob([zip(files)], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
}

// ---------- Préparation des données ----------

export function scopeOf(kind, year, sub) {
  if (kind === 'quarter') return { range: range.quarter(year, sub), title: `${sub === 1 ? '1er' : sub + 'e'} trimestre ${year}`, stem: `${year}-T${sub}` };
  if (kind === 'month') return { range: range.month(year, sub), title: `${cap(monthName(sub))} ${year}`, stem: `${year}-${String(sub).padStart(2, '0')}` };
  return { range: range.year(year), title: `Année ${year}`, stem: `${year}` };
}

export const sanitize = (s) => (s || '').normalize('NFD').replace(/[̀-ͯ]/g, '')
  .replace(/[^A-Za-z0-9-]+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '').slice(0, 40) || 'document';

const extOf = (att) => att?.type === 'application/pdf' ? 'pdf' : att?.type === 'image/png' ? 'png' : 'jpg';

function dataset(state, scope) {
  const { sales, purchases, settings, attachmentMeta } = state;
  const r = scope.range;
  const receipts = sales.filter((s) => inRange(s.paymentDate, r)).sort((a, b) => a.paymentDate.localeCompare(b.paymentDate));
  const pending = sales.filter((s) => !s.paymentDate && inRange(s.invoiceDate, r)).sort((a, b) => a.invoiceDate.localeCompare(b.invoiceDate));
  const buys = purchases.filter((p) => inRange(p.date, r)).sort((a, b) => a.date.localeCompare(b.date));
  const sum = summary(sales, purchases, r, settings);
  const paths = {}, used = new Set();
  const reg = (id, folder, date, party, ref) => {
    if (!id || !attachmentMeta[id]) return;
    let base = `${folder}/${date}_${sanitize(party)}${ref ? '_' + sanitize(ref) : ''}`;
    const ext = extOf(attachmentMeta[id]);
    let p = `${base}.${ext}`, n = 2;
    while (used.has(p)) p = `${base}_${n++}.${ext}`;
    used.add(p); paths[id] = p;
  };
  for (const s of [...receipts, ...pending]) reg(s.attachmentId, 'Ventes', s.invoiceDate, s.client, s.invoiceNumber);
  for (const p of buys) reg(p.attachmentId, 'Achats', p.date, p.supplier, p.invoiceNumber);

  const months = [];
  for (let d = r[0]; d < r[1]; d = monthStart(yearOf(d), monthOf(d) + 1)) {
    months.push({ label: `${cap(monthName(monthOf(d)))} ${yearOf(d)}`, s: summary(sales, purchases, range.month(yearOf(d), monthOf(d)), settings) });
  }
  return { receipts, pending, buys, sum, paths, months };
}

const fileStem = (settings) => settings.businessName ? `Compta_${sanitize(settings.businessName)}` : 'Compta';

// ---------- Excel ----------

export function buildXLSX(state, scope) {
  const { settings } = state;
  const ds = dataset(state, scope);
  const H = (v) => ({ t: 'h', v }), B = (v) => ({ t: 'b', v });

  const recap = [
    [B(`Registre comptable — ${scope.title}`)],
    ['Entreprise', settings.businessName], ['Exploitant', settings.ownerName], ['SIRET', settings.siret],
    ['Adresse', settings.address], ['Régime', 'Micro-entreprise — franchise en base de TVA'], ['Généré le', { d: today() }], [],
    [H('Mois'), H('Ventes marchandises'), H('Services BIC'), H('Libéral BNC'), H('Libéral CIPAV'), H('Total CA encaissé'), H('Achats'), H('URSSAF estimé')],
  ];
  const first = recap.length + 1;
  for (const m of ds.months) {
    recap.push([m.label, ...CATEGORY_KEYS.map((k) => ({ m: m.s.caByCat[k] || 0 })), { m: m.s.ca }, { m: m.s.purchases }, { m: m.s.urssaf }]);
  }
  const last = recap.length;
  const t = ds.sum;
  recap.push([B('TOTAL'), ...CATEGORY_KEYS.map((k, i) => ({ sum: [1 + i, first, last], v: t.caByCat[k] || 0 })),
    { sum: [5, first, last], v: t.ca }, { sum: [6, first, last], v: t.purchases }, { sum: [7, first, last], v: t.urssaf }]);
  recap.push([], ["Les montants URSSAF sont des estimations calculées avec les taux paramétrés dans l'application."]);

  const rec = [[H("Date d'encaissement"), H('N° facture'), H('Date facture'), H('Client'), H('Nature'), H('Catégorie'), H('Mode de règlement'), H('Montant encaissé'), H('Justificatif')]];
  for (const s of ds.receipts) {
    rec.push([{ d: s.paymentDate }, s.invoiceNumber, { d: s.invoiceDate }, s.client, s.label, CATEGORIES[s.category]?.short, METHODS[s.method], { m: s.amount }, ds.paths[s.attachmentId] || '']);
  }
  rec.push([B('TOTAL'), null, null, null, null, null, null, { sum: [7, 2, rec.length], v: t.ca }]);

  const sheets = [
    { name: 'Récapitulatif', widths: [22, 18, 16, 16, 16, 18, 14, 16], rows: recap, freeze: false },
    { name: 'Livre des recettes', widths: [16, 14, 13, 26, 36, 14, 18, 16, 40], rows: rec },
  ];
  if (ds.pending.length) {
    const pen = [[H('Date facture'), H('N° facture'), H('Client'), H('Nature'), H('Montant'), H('Justificatif')]];
    for (const s of ds.pending) pen.push([{ d: s.invoiceDate }, s.invoiceNumber, s.client, s.label, { m: s.amount }, ds.paths[s.attachmentId] || '']);
    pen.push([B('TOTAL'), null, null, null, { sum: [4, 2, pen.length], v: t.pendingAmount }]);
    sheets.push({ name: 'Factures non encaissées', widths: [13, 14, 26, 36, 14, 40], rows: pen });
  }
  const buy = [[H('Date'), H('N° pièce'), H('Fournisseur'), H('Nature'), H('Catégorie'), H('Mode de règlement'), H('Montant TTC'), H('Dont TVA'), H('Justificatif')]];
  for (const p of ds.buys) {
    buy.push([{ d: p.date }, p.invoiceNumber, p.supplier, p.label, PURCHASE_CATEGORIES[p.category], METHODS[p.method], { m: p.amount }, { m: p.vat || 0 }, ds.paths[p.attachmentId] || '']);
  }
  const lb = buy.length;
  buy.push([B('TOTAL'), null, null, null, null, null, { sum: [6, 2, lb], v: t.purchases }, { sum: [7, 2, lb], v: ds.buys.reduce((a, p) => a + (p.vat || 0), 0) }]);
  sheets.push({ name: 'Registre des achats', widths: [12, 14, 26, 36, 26, 18, 14, 12, 40], rows: buy });

  return { blob: workbook(sheets), name: `${fileStem(settings)}_${scope.stem}.xlsx` };
}

// ---------- PDF ----------

let pdfLibPromise;
function loadPdfLib() {
  if (!pdfLibPromise) {
    const base = new URL('../vendor/', import.meta.url).href;
    const load = (src) => new Promise((res, rej) => { const s = document.createElement('script'); s.src = src; s.onload = res; s.onerror = rej; document.head.appendChild(s); });
    pdfLibPromise = (window.jspdf ? Promise.resolve() : load(base + 'jspdf.umd.min.js'))
      .then(() => load(base + 'jspdf.plugin.autotable.min.js'))
      .catch((e) => { pdfLibPromise = null; throw e; });
  }
  return pdfLibPromise;
}

// Les polices PDF standard ne connaissent pas les espaces fines insécables
const P = (s) => String(s ?? '').replace(/[  ]/g, ' ');

export async function buildPDF(state, scope) {
  await loadPdfLib();
  const { jsPDF } = window.jspdf;
  const { settings } = state;
  const ds = dataset(state, scope);
  const doc = new jsPDF({ orientation: 'landscape', unit: 'pt', format: 'a4' });
  const M = 32;
  let y = M + 8;
  const footer = `${settings.businessName || 'Registre comptable'} — ${scope.title} — édité le ${frDate(today())}`;

  doc.setFont('helvetica', 'bold'); doc.setFontSize(18);
  doc.text(P(`Registre comptable — ${scope.title}`), M, y); y += 20;
  doc.setFont('helvetica', 'normal'); doc.setFontSize(9.5); doc.setTextColor(80);
  const ident = [settings.businessName, settings.ownerName, settings.siret && `SIRET : ${settings.siret}`, settings.address,
    'Micro-entreprise — TVA non applicable, art. 293 B du CGI (franchise en base)'].filter(Boolean);
  for (const l of ident) { for (const part of l.split('\n')) { doc.text(P(part), M, y); y += 12; } }
  doc.setTextColor(0);
  y += 6;

  const section = (title) => {
    if (y > 520) { doc.addPage(); y = M + 8; }
    doc.setFont('helvetica', 'bold'); doc.setFontSize(13); doc.text(P(title), M, y); y += 6;
  };
  const table = (head, body, foot, columnStyles = {}) => {
    doc.autoTable({
      startY: y, head: [head.map(P)], body: body.map((r) => r.map(P)), foot: foot ? [foot.map(P)] : undefined,
      margin: { left: M, right: M, bottom: 36 }, styles: { fontSize: 8, cellPadding: 3, overflow: 'ellipsize' },
      headStyles: { fillColor: [220, 230, 241], textColor: 20, fontStyle: 'bold' },
      footStyles: { fillColor: [245, 245, 245], textColor: 20, fontStyle: 'bold' },
      alternateRowStyles: { fillColor: [248, 248, 248] }, columnStyles, showFoot: 'lastPage',
    });
    y = doc.lastAutoTable.finalY + 18;
  };
  const right = (...idx) => Object.fromEntries(idx.map((i) => [i, { halign: 'right' }]));

  section('Synthèse');
  const pairs = [];
  for (const k of CATEGORY_KEYS) if (ds.sum.caByCat[k]) pairs.push([`CA encaissé — ${CATEGORIES[k].label}`, eurPlain(ds.sum.caByCat[k])]);
  pairs.push(["Chiffre d'affaires encaissé total", eurPlain(ds.sum.ca)], ['Achats', eurPlain(ds.sum.purchases)],
    ['Cotisations et contributions URSSAF estimées', eurPlain(ds.sum.urssaf)]);
  if (ds.sum.pendingCount) pairs.push([`Factures non encaissées (${ds.sum.pendingCount})`, eurPlain(ds.sum.pendingAmount)]);
  doc.autoTable({ startY: y, body: pairs.map((r) => r.map(P)), theme: 'plain', margin: { left: M }, tableWidth: 420,
    styles: { fontSize: 9.5, cellPadding: 2.5 }, columnStyles: { 1: { halign: 'right', fontStyle: 'bold' } } });
  y = doc.lastAutoTable.finalY + 20;

  section('Livre des recettes');
  table(['Encaissement', 'N° facture', 'Client', 'Nature', 'Catégorie', 'Règlement', 'Montant', 'Justif.'],
    ds.receipts.map((s) => [frDate(s.paymentDate), s.invoiceNumber, s.client, s.label, CATEGORIES[s.category]?.short, METHODS[s.method], eurPlain(s.amount), s.attachmentId ? 'oui' : '—']),
    ['TOTAL', '', '', '', '', '', eurPlain(ds.sum.ca), ''], { ...right(6), 3: { cellWidth: 200 } });

  if (ds.pending.length) {
    section('Factures émises non encaissées (pour information)');
    table(['Date facture', 'N° facture', 'Client', 'Nature', 'Montant'],
      ds.pending.map((s) => [frDate(s.invoiceDate), s.invoiceNumber, s.client, s.label, eurPlain(s.amount)]),
      ['TOTAL', '', '', '', eurPlain(ds.sum.pendingAmount)], right(4));
  }

  section('Registre des achats');
  table(['Date', 'N° pièce', 'Fournisseur', 'Nature', 'Catégorie', 'Règlement', 'TTC', 'TVA', 'Justif.'],
    ds.buys.map((p) => [frDate(p.date), p.invoiceNumber, p.supplier, p.label, PURCHASE_CATEGORIES[p.category], METHODS[p.method], eurPlain(p.amount), p.vat ? eurPlain(p.vat) : '', p.attachmentId ? 'oui' : '—']),
    ['TOTAL', '', '', '', '', '', eurPlain(ds.sum.purchases), eurPlain(ds.buys.reduce((a, p) => a + (p.vat || 0), 0)), ''], right(6, 7));

  if (ds.months.length > 1) {
    section('Récapitulatif mensuel');
    table(['Mois', 'CA encaissé', 'Achats', 'URSSAF estimé', 'Bénéfice estimé'],
      ds.months.map((m) => [m.label, eurPlain(m.s.ca), eurPlain(m.s.purchases), eurPlain(m.s.urssaf), eurPlain(m.s.profit)]),
      ['TOTAL', eurPlain(ds.sum.ca), eurPlain(ds.sum.purchases), eurPlain(ds.sum.urssaf), eurPlain(ds.sum.profit)], right(1, 2, 3, 4));
  }
  doc.setFont('helvetica', 'normal'); doc.setFontSize(7.5); doc.setTextColor(120);
  doc.text(P("Recettes enregistrées à la date d'encaissement. Montants en euros. Les montants URSSAF sont des estimations."), M, Math.min(y, 560));

  const pages = doc.getNumberOfPages();
  for (let i = 1; i <= pages; i++) {
    doc.setPage(i); doc.setFontSize(7.5); doc.setTextColor(130);
    doc.text(P(`${footer} — page ${i}/${pages}`), M, doc.internal.pageSize.getHeight() - 16);
  }
  return { blob: doc.output('blob'), name: `${fileStem(settings)}_${scope.stem}.pdf` };
}

// ---------- Dossier complet ----------

export async function buildDossier(state, scope, getAttachment) {
  const ds = dataset(state, scope);
  const pdf = await buildPDF(state, scope);
  const xlsx = buildXLSX(state, scope);
  const files = [
    { name: pdf.name, data: await pdf.blob.arrayBuffer() },
    { name: xlsx.name, data: await xlsx.blob.arrayBuffer() },
  ];
  for (const [id, path] of Object.entries(ds.paths).sort((a, b) => a[1].localeCompare(b[1]))) {
    const att = await getAttachment(id);
    if (att) files.push({ name: `Justificatifs/${path}`, data: att.data });
  }
  return { blob: zip(files), name: `Dossier_${fileStem(state.settings)}_${scope.stem}.zip` };
}

// ---------- Sauvegarde ----------

export async function buildBackup(state, getAttachment) {
  const ids = new Set([...state.sales, ...state.purchases].map((x) => x.attachmentId).filter(Boolean));
  const atts = [];
  const files = [];
  for (const id of ids) {
    const a = await getAttachment(id);
    if (!a) continue;
    atts.push({ id, type: a.type, name: a.name });
    files.push({ name: `attachments/${id}`, data: a.data });
  }
  const json = JSON.stringify({ app: 'compta-ae', version: 1, exportedAt: new Date().toISOString(), settings: state.settings, sales: state.sales, purchases: state.purchases, attachments: atts }, null, 1);
  const d = new Date();
  const stamp = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  return { blob: zip([{ name: 'backup.json', data: json }, ...files]), name: `Sauvegarde_ComptaAE_${stamp}.zip` };
}

export function readBackup(buffer) {
  const entries = unzip(buffer);
  if (!entries['backup.json']) throw new Error("Ce fichier n'est pas une sauvegarde Compta AE.");
  const b = JSON.parse(new TextDecoder().decode(entries['backup.json']));
  if (b.app !== 'compta-ae') throw new Error("Ce fichier n'est pas une sauvegarde Compta AE.");
  const attachments = (b.attachments || []).map((a) => ({ ...a, data: entries[`attachments/${a.id}`] })).filter((a) => a.data);
  return { settings: withDefaults(b.settings), sales: b.sales || [], purchases: b.purchases || [], attachments };
}
