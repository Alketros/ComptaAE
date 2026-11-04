import { html, render, useState, useEffect, useMemo, useRef } from '../vendor/preact-htm.mjs';
import * as F from './fiscal.js';
import { db, requestPersistence } from './db.js';
import { readDocument, pdfPages } from './extract.js';
import * as X from './export.js';

const { CATEGORIES, CATEGORY_KEYS, METHODS, PURCHASE_CATEGORIES, PURCHASE_ICONS, eur, frDate } = F;

// ======================================================================
// Données
// ======================================================================

const upsert = (list, item) => {
  const i = list.findIndex((x) => x.id === item.id);
  if (i < 0) return [...list, item];
  const copy = list.slice(); copy[i] = item; return copy;
};

function useStore() {
  const [state, setState] = useState({ loaded: false, sales: [], purchases: [], settings: F.withDefaults() });
  const ref = useRef(state);
  ref.current = state;

  useEffect(() => {
    (async () => {
      const [sales, purchases, settings] = await Promise.all([db.all('sales'), db.all('purchases'), db.getMeta('settings')]);
      setState({ loaded: true, sales: sales || [], purchases: purchases || [], settings: F.withDefaults(settings) });
      requestPersistence();
    })().catch((e) => setState((s) => ({ ...s, loaded: true, error: String(e?.message || e) })));
  }, []);

  const api = useMemo(() => ({
    async saveSale(s) { await db.put('sales', s); setState((st) => ({ ...st, sales: upsert(st.sales, s) })); },
    async deleteSale(s) {
      if (s.attachmentId) await db.del('attachments', s.attachmentId);
      await db.del('sales', s.id);
      setState((st) => ({ ...st, sales: st.sales.filter((x) => x.id !== s.id) }));
    },
    async savePurchase(p) { await db.put('purchases', p); setState((st) => ({ ...st, purchases: upsert(st.purchases, p) })); },
    async deletePurchase(p) {
      if (p.attachmentId) await db.del('attachments', p.attachmentId);
      await db.del('purchases', p.id);
      setState((st) => ({ ...st, purchases: st.purchases.filter((x) => x.id !== p.id) }));
    },
    async addAttachment(att) { const id = F.uid(); await db.put('attachments', { id, ...att }); return id; },
    delAttachment: (id) => id && db.del('attachments', id),
    getAttachment: (id) => db.get('attachments', id),
    updateSettings(patch) {
      const settings = { ...ref.current.settings, ...patch };
      db.setMeta('settings', settings);
      setState((st) => ({ ...st, settings }));
    },
    async restore(backup) {
      const st = ref.current;
      const sIds = new Set(st.sales.map((x) => x.id)), pIds = new Set(st.purchases.map((x) => x.id));
      const existing = new Set(await db.attachmentKeys());
      for (const a of backup.attachments) if (!existing.has(a.id)) await db.put('attachments', a);
      const newSales = backup.sales.filter((x) => !sIds.has(x.id));
      const newPurchases = backup.purchases.filter((x) => !pIds.has(x.id));
      for (const s of newSales) await db.put('sales', s);
      for (const p of newPurchases) await db.put('purchases', p);
      let settings = st.settings;
      if (!settings.businessName && !settings.siret) { settings = backup.settings; await db.setMeta('settings', settings); }
      setState((cur) => ({ ...cur, settings, sales: [...cur.sales, ...newSales], purchases: [...cur.purchases, ...newPurchases] }));
      return { sales: newSales.length, purchases: newPurchases.length };
    },
  }), []);

  return [state, api];
}

// ======================================================================
// Petits composants
// ======================================================================

let toastTimer;
function toast(msg) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add('hidden'), 3200);
}

const Line = ({ k, v, strong, cls = '' }) => html`
  <div class="line ${strong ? 'strong' : ''}"><span class="k">${k}</span><span class="v ${cls}">${eur(v)}</span></div>`;

const Card = ({ title, ico, children }) => html`
  <div class="card"><div class="card-title"><span class="ico">${ico}</span>${title}</div>${children}</div>`;

const Stat = ({ label, value, cls = '' }) => html`
  <div class="stat"><div class="label">${label}</div><div class="value ${cls}">${eur(value)}</div></div>`;

function Sheet({ title, onCancel, onDone, doneLabel = 'Enregistrer', doneDisabled, cancelLabel = 'Annuler', children }) {
  useEffect(() => {
    document.body.style.overflow = 'hidden';
    return () => { document.body.style.overflow = ''; };
  }, []);
  return html`
    <div class="sheet-backdrop" onClick=${onCancel}></div>
    <div class="sheet" role="dialog">
      <div class="sheet-head">
        <button onClick=${onCancel} style="text-align:left">${cancelLabel}</button>
        <div class="title">${title}</div>
        ${onDone ? html`<button class="primary" disabled=${doneDisabled} onClick=${onDone}>${doneLabel}</button>` : html`<span style="min-width:80px"></span>`}
      </div>
      <div class="sheet-body">${children}</div>
    </div>`;
}

const Section = ({ label, help, children }) => html`
  <div class="form-section">
    ${label && html`<div class="label">${label}</div>`}
    <div class="fields">${children}</div>
    ${help && html`<div class="help">${help}</div>`}
  </div>`;

const TextField = ({ label, value, onInput, placeholder, left, type = 'text', inputmode, autocap }) => html`
  <label class="field">
    ${label && html`<span>${label}</span>`}
    <input class=${left || !label ? 'left' : ''} type=${type} inputmode=${inputmode} placeholder=${placeholder}
      autocapitalize=${autocap || 'sentences'} value=${value} onInput=${(e) => onInput(e.target.value)} />
  </label>`;

const AmountInput = ({ label, value, onInput }) => html`
  <label class="field">
    <span>${label}</span>
    <input type="text" inputmode="decimal" placeholder="0,00" class="num" value=${value} onInput=${(e) => onInput(e.target.value)} />
    <span class="suffix">€</span>
  </label>`;

const DateField = ({ label, value, onInput }) => html`
  <label class="field"><span>${label}</span><input type="date" value=${value} onInput=${(e) => e.target.value && onInput(e.target.value)} /></label>`;

const SelectField = ({ label, value, onChange, options }) => html`
  <label class="field">
    <span>${label}</span>
    <select value=${value} onChange=${(e) => onChange(e.target.value)}>
      ${Object.entries(options).map(([k, v]) => html`<option value=${k}>${v}</option>`)}
    </select>
  </label>`;

const Toggle = ({ label, checked, onChange }) => html`
  <label class="field toggle">
    <span>${label}</span>
    <span class="switch"><input type="checkbox" checked=${checked} onChange=${(e) => onChange(e.target.checked)} /><span></span></span>
  </label>`;

const Chips = ({ items, onPick }) => items.length ? html`
  <div class="chips">${items.map((it) => html`<button type="button" class="chip" onClick=${() => onPick(it)}>${it}</button>`)}</div>` : null;

function NumberField({ label, value, onChange, suffix, decimals = 2 }) {
  const [text, setText] = useState(String(value).replace('.', ','));
  useEffect(() => { if (F.parseAmount(text) !== value) setText(String(value).replace('.', ',')); }, [value]);
  return html`
    <label class="field">
      <span>${label}</span>
      <input type="text" inputmode=${decimals ? 'decimal' : 'numeric'} class="num" value=${text}
        onInput=${(e) => { setText(e.target.value); const v = F.parseAmount(e.target.value); if (v != null) onChange(v); }} />
      <span class="suffix">${suffix}</span>
    </label>`;
}

function Overlay({ text, progress }) {
  return html`<div class="overlay"><div class="box"><div class="spinner"></div>
    <div>${text}</div>${progress != null && html`<div class="tiny muted" style="margin-top:4px">${Math.round(progress * 100)} %</div>`}</div></div>`;
}

function suggestionsFrom(values, query) {
  const seen = new Set(), list = [];
  for (const v of values) { const k = v.toLowerCase(); if (v && !seen.has(k)) { seen.add(k); list.push(v); } }
  const q = query.trim().toLowerCase();
  if (!q) return list.slice(0, 8);
  if (list.some((x) => x.toLowerCase() === q)) return [];
  return list.filter((x) => x.toLowerCase().includes(q)).slice(0, 8);
}

/** Bouton invisible de sélection de fichier (PDF, photo, appareil photo). */
function useFilePicker(onFile, accept = 'application/pdf,image/*') {
  const ref = useRef();
  const input = html`<input ref=${ref} type="file" accept=${accept} class="hidden"
    onChange=${(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) onFile(f); }} />`;
  return [input, () => ref.current?.click()];
}

// ======================================================================
// Visualisation d'un justificatif
// ======================================================================

function AttachmentViewer({ id, api, onClose }) {
  const box = useRef();
  const [error, setError] = useState(null);
  useEffect(() => {
    let url;
    (async () => {
      const att = await api.getAttachment(id);
      if (!att) { setError('Document introuvable.'); return; }
      if (att.type === 'application/pdf') {
        const pages = await pdfPages(att.data);
        pages.forEach((c) => box.current?.appendChild(c));
      } else {
        url = URL.createObjectURL(new Blob([att.data], { type: att.type }));
        const img = new Image(); img.src = url; box.current?.appendChild(img);
      }
    })().catch((e) => setError(String(e?.message || e)));
    return () => url && URL.revokeObjectURL(url);
  }, [id]);
  return html`<${Sheet} title="Justificatif" cancelLabel="Fermer" onCancel=${onClose}>
    ${error && html`<p class="muted">${error}</p>`}
    <div class="viewer" ref=${box}></div>
  <//>`;
}

// ======================================================================
// Pièce jointe dans un formulaire
// ======================================================================

function AttachmentSection({ attachment, setAttachment, api, kind, onExtracted, created }) {
  const [busy, setBusy] = useState(null);
  const [viewing, setViewing] = useState(false);
  const [input, pick] = useFilePicker(async (file) => {
    setBusy(0);
    try {
      const { attachment: att, info } = await readDocument(file, kind, (p) => setBusy(p));
      const id = await api.addAttachment(att);
      created.current.push(id);
      setAttachment({ id, type: att.type });
      onExtracted?.(info);
    } catch (e) { toast('Import impossible : ' + (e?.message || e)); }
    setBusy(null);
  });
  return html`
    <${Section} label="Justificatif">
      ${attachment ? html`
        <button type="button" class="field link" style="width:100%" onClick=${() => setViewing(true)}>📄 Voir le document</button>
        <button type="button" class="field link red" style="width:100%;color:var(--red)" onClick=${() => setAttachment(null)}>Détacher le document</button>`
      : html`<button type="button" class="field link" style="width:100%" onClick=${pick}>📎 Joindre un PDF ou une photo</button>`}
    <//>
    ${input}
    ${busy != null && html`<${Overlay} text="Lecture du document…" progress=${busy || null} />`}
    ${viewing && html`<${AttachmentViewer} id=${attachment.id} api=${api} onClose=${() => setViewing(false)} />`}`;
}

/** Nettoyage des fichiers importés pendant l'édition mais non conservés. */
function useAttachmentCleanup(api, initialCreated) {
  const created = useRef(initialCreated);
  const finish = (keepId, previousId) => {
    for (const id of created.current) if (id !== keepId) api.delAttachment(id);
    if (previousId && previousId !== keepId && !created.current.includes(previousId)) api.delAttachment(previousId);
  };
  const cancel = (originalId) => { for (const id of created.current) if (id !== originalId) api.delAttachment(id); };
  return { created, finish, cancel };
}

// ======================================================================
// Formulaire de vente
// ======================================================================

function nextInvoiceNumber(sales) {
  const last = sales.slice().sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || '')).map((s) => s.invoiceNumber).find(Boolean);
  if (!last) return `F${new Date().getFullYear()}-001`;
  const m = last.match(/^(.*?)(\d+)$/);
  if (!m) return '';
  const n = String(Number(m[2]) + 1);
  return m[1] + n.padStart(m[2].length, '0');
}

function SaleForm({ entry, draft, state, api, onClose }) {
  const { sales, settings } = state;
  const lastMethod = sales.slice().sort((a, b) => (b.createdAt || '').localeCompare(a.createdAt || ''))[0]?.method;
  const d = draft || {};
  const [f, setF] = useState(() => entry ? {
    client: entry.client, label: entry.label, amount: F.amountInput(entry.amount), invoiceDate: entry.invoiceDate,
    paid: !!entry.paymentDate, paymentDate: entry.paymentDate || F.today(), method: entry.method, category: entry.category,
    invoiceNumber: entry.invoiceNumber, notes: entry.notes || '',
  } : {
    client: d.party || '', label: d.label || '', amount: d.amount != null ? F.amountInput(d.amount) : '',
    invoiceDate: d.date || F.today(), paid: !d.fromDocument, paymentDate: F.today(),
    method: d.method || lastMethod || 'virement', category: d.category || settings.mainCategory,
    invoiceNumber: d.invoiceNumber || (d.fromDocument ? '' : nextInvoiceNumber(sales)), notes: '',
  });
  const [attachment, setAttachment] = useState(() => {
    const id = entry?.attachmentId || d.attachmentId;
    return id ? { id, type: entry?.attachmentType || d.attachmentType } : null;
  });
  const cleanup = useAttachmentCleanup(api, d.attachmentId ? [d.attachmentId] : []);
  const set = (patch) => setF((x) => ({ ...x, ...patch }));
  const amount = F.parseAmount(f.amount);
  const canSave = amount > 0 && f.client.trim();

  const byRecent = sales.slice().sort((a, b) => (b.invoiceDate || '').localeCompare(a.invoiceDate || ''));
  const clientSugg = suggestionsFrom(byRecent.map((s) => s.client), f.client);
  const labelSugg = (() => {
    const src = f.client ? byRecent.filter((s) => s.client.toLowerCase() === f.client.toLowerCase()) : byRecent;
    const counts = {};
    for (const s of src) if (s.label) counts[s.label] = (counts[s.label] || 0) + 1;
    return Object.entries(counts).sort((a, b) => b[1] - a[1]).map(([k]) => k).filter((k) => k !== f.label).slice(0, 6);
  })();

  const pickClient = (name) => {
    const last = byRecent.find((s) => s.client === name && s.id !== entry?.id);
    set({ client: name, ...(last ? {
      label: f.label || last.label, amount: f.amount || F.amountInput(last.amount), category: last.category, method: last.method,
    } : {}) });
  };

  const onExtracted = (info) => set({
    client: f.client || info.party || '', amount: f.amount || (info.amount != null ? F.amountInput(info.amount) : ''),
    invoiceNumber: f.invoiceNumber || info.invoiceNumber || '', invoiceDate: info.date && !entry ? info.date : f.invoiceDate,
  });

  const save = async () => {
    const now = new Date().toISOString();
    const s = {
      id: entry?.id || F.uid(), createdAt: entry?.createdAt || now, updatedAt: now,
      client: f.client.trim(), label: f.label.trim(), amount: F.round2(amount), invoiceDate: f.invoiceDate,
      paymentDate: f.paid ? f.paymentDate : null, method: f.method, category: f.category,
      invoiceNumber: f.invoiceNumber.trim(), notes: f.notes, attachmentId: attachment?.id || null, attachmentType: attachment?.type || null,
    };
    await api.saveSale(s);
    cleanup.finish(s.attachmentId, entry?.attachmentId);
    onClose();
  };
  const cancel = () => { cleanup.cancel(entry?.attachmentId); onClose(); };

  return html`<${Sheet} title=${entry ? 'Modifier la vente' : 'Nouvelle vente'} onCancel=${cancel} onDone=${save} doneDisabled=${!canSave}>
    ${d.fromDocument && html`<div class="banner">✨ <span>Pré-rempli depuis le document : vérifiez les valeurs.</span></div>`}
    <${Section} label="Client">
      <${TextField} value=${f.client} placeholder="Nom du client" autocap="words" onInput=${(v) => set({ client: v })} />
      <${Chips} items=${clientSugg} onPick=${pickClient} />
    <//>
    <${Section} label="Prestation / vente">
      <${TextField} value=${f.label} placeholder="Nature (ex : Création site web)" onInput=${(v) => set({ label: v })} />
      <${Chips} items=${labelSugg} onPick=${(v) => set({ label: v })} />
      <${SelectField} label="Catégorie" value=${f.category} onChange=${(v) => set({ category: v })}
        options=${Object.fromEntries(CATEGORY_KEYS.map((k) => [k, CATEGORIES[k].short]))} />
    <//>
    <${Section} label="Montant" help="En franchise de TVA : montant facturé, sans TVA.">
      <${AmountInput} label="Montant" value=${f.amount} onInput=${(v) => set({ amount: v })} />
    <//>
    <${Section} label="Facture">
      <${TextField} label="N° de facture" value=${f.invoiceNumber} autocap="characters" onInput=${(v) => set({ invoiceNumber: v })} />
      <${DateField} label="Date de facture" value=${f.invoiceDate} onInput=${(v) => set({ invoiceDate: v })} />
    <//>
    <${Section} label="Encaissement" help="L'URSSAF se base sur le chiffre d'affaires encaissé : c'est la date d'encaissement qui compte.">
      <${Toggle} label="Paiement reçu" checked=${f.paid} onChange=${(v) => set({ paid: v })} />
      ${f.paid && html`<${DateField} label="Date d'encaissement" value=${f.paymentDate} onInput=${(v) => set({ paymentDate: v })} />`}
      <${SelectField} label="Mode de règlement" value=${f.method} onChange=${(v) => set({ method: v })} options=${METHODS} />
    <//>
    <${AttachmentSection} attachment=${attachment} setAttachment=${setAttachment} api=${api} kind="sale"
      onExtracted=${onExtracted} created=${cleanup.created} />
    <${Section} label="Notes">
      <${TextField} value=${f.notes} placeholder="Facultatif" onInput=${(v) => set({ notes: v })} />
    <//>
    ${entry && html`<div class="action-list">
      ${!entry.paymentDate && html`<button class="btn success block" onClick=${async () => { await api.saveSale({ ...entry, paymentDate: F.today() }); onClose(); }}>✓ Encaissée aujourd'hui</button>`}
      <button class="btn danger block" onClick=${async () => { if (confirm('Supprimer cette vente ?')) { await api.deleteSale(entry); onClose(); } }}>Supprimer la vente</button>
    </div>`}
  <//>`;
}

// ======================================================================
// Formulaire d'achat
// ======================================================================

function PurchaseForm({ entry, draft, state, api, onClose }) {
  const { purchases } = state;
  const byRecent = purchases.slice().sort((a, b) => (b.date || '').localeCompare(a.date || ''));
  const d = draft || {};
  const [f, setF] = useState(() => {
    if (entry) return {
      supplier: entry.supplier, label: entry.label, amount: F.amountInput(entry.amount), vat: entry.vat ? F.amountInput(entry.vat) : '',
      date: entry.date, method: entry.method, category: entry.category, invoiceNumber: entry.invoiceNumber, notes: entry.notes || '',
    };
    const known = d.party && byRecent.find((p) => p.supplier.toLowerCase() === d.party.toLowerCase());
    return {
      supplier: known ? known.supplier : (d.party || ''), label: d.label || known?.label || '',
      amount: d.amount != null ? F.amountInput(d.amount) : '', vat: d.vat != null ? F.amountInput(d.vat) : '',
      date: d.date || F.today(), method: d.method || byRecent[0]?.method || 'carte',
      category: known?.category || d.purchaseCategory || 'autre', invoiceNumber: d.invoiceNumber || '', notes: '',
    };
  });
  const [attachment, setAttachment] = useState(() => {
    const id = entry?.attachmentId || d.attachmentId;
    return id ? { id, type: entry?.attachmentType || d.attachmentType } : null;
  });
  const cleanup = useAttachmentCleanup(api, d.attachmentId ? [d.attachmentId] : []);
  const set = (patch) => setF((x) => ({ ...x, ...patch }));
  const amount = F.parseAmount(f.amount);
  const canSave = amount > 0 && f.supplier.trim();
  const sugg = suggestionsFrom(byRecent.map((p) => p.supplier), f.supplier);

  const pickSupplier = (name) => {
    const last = byRecent.find((p) => p.supplier === name && p.id !== entry?.id);
    set({ supplier: name, ...(last ? { label: f.label || last.label, amount: f.amount || F.amountInput(last.amount), category: last.category, method: last.method } : {}) });
  };
  const onExtracted = (info) => set({
    supplier: f.supplier || info.party || '', amount: f.amount || (info.amount != null ? F.amountInput(info.amount) : ''),
    vat: f.vat || (info.vat != null ? F.amountInput(info.vat) : ''), invoiceNumber: f.invoiceNumber || info.invoiceNumber || '',
    date: info.date && !entry ? info.date : f.date, category: f.category !== 'autre' ? f.category : (info.purchaseCategory || 'autre'),
  });

  const save = async () => {
    const now = new Date().toISOString();
    const p = {
      id: entry?.id || F.uid(), createdAt: entry?.createdAt || now, updatedAt: now,
      supplier: f.supplier.trim(), label: f.label.trim(), amount: F.round2(amount), vat: F.round2(F.parseAmount(f.vat) || 0),
      date: f.date, method: f.method, category: f.category, invoiceNumber: f.invoiceNumber.trim(), notes: f.notes,
      attachmentId: attachment?.id || null, attachmentType: attachment?.type || null,
    };
    await api.savePurchase(p);
    cleanup.finish(p.attachmentId, entry?.attachmentId);
    onClose();
  };
  const cancel = () => { cleanup.cancel(entry?.attachmentId); onClose(); };

  return html`<${Sheet} title=${entry ? "Modifier l'achat" : 'Nouvel achat'} onCancel=${cancel} onDone=${save} doneDisabled=${!canSave}>
    ${d.fromDocument && html`<div class="banner">✨ <span>Pré-rempli depuis le document : vérifiez les valeurs.</span></div>`}
    <${Section} label="Fournisseur">
      <${TextField} value=${f.supplier} placeholder="Nom du fournisseur" autocap="words" onInput=${(v) => set({ supplier: v })} />
      <${Chips} items=${sugg} onPick=${pickSupplier} />
    <//>
    <${Section} label="Achat">
      <${TextField} value=${f.label} placeholder="Nature (ex : Abonnement logiciel)" onInput=${(v) => set({ label: v })} />
      <${SelectField} label="Catégorie" value=${f.category} onChange=${(v) => set({ category: v })} options=${PURCHASE_CATEGORIES} />
      <${DateField} label="Date" value=${f.date} onInput=${(v) => set({ date: v })} />
    <//>
    <${Section} label="Montant" help="En franchise de TVA, la TVA payée n'est pas récupérable : c'est le montant TTC qui compte.">
      <${AmountInput} label="Montant TTC" value=${f.amount} onInput=${(v) => set({ amount: v })} />
      <${AmountInput} label="Dont TVA" value=${f.vat} onInput=${(v) => set({ vat: v })} />
    <//>
    <${Section} label="Paiement">
      <${SelectField} label="Mode de règlement" value=${f.method} onChange=${(v) => set({ method: v })} options=${METHODS} />
      <${TextField} label="N° facture / ticket" value=${f.invoiceNumber} onInput=${(v) => set({ invoiceNumber: v })} />
    <//>
    <${AttachmentSection} attachment=${attachment} setAttachment=${setAttachment} api=${api} kind="purchase"
      onExtracted=${onExtracted} created=${cleanup.created} />
    <${Section} label="Notes">
      <${TextField} value=${f.notes} placeholder="Facultatif" onInput=${(v) => set({ notes: v })} />
    <//>
    ${entry && html`<div class="action-list">
      <button class="btn danger block" onClick=${async () => { if (confirm('Supprimer cet achat ?')) { await api.deletePurchase(entry); onClose(); } }}>Supprimer l'achat</button>
    </div>`}
  <//>`;
}

// ======================================================================
// Ajout : saisie manuelle ou document
// ======================================================================

function AddMenu({ kind, api, onDraft }) {
  const [open, setOpen] = useState(false);
  const [busy, setBusy] = useState(null);
  const [input, pick] = useFilePicker(async (file) => {
    setBusy(0);
    try {
      const { attachment, info } = await readDocument(file, kind, (p) => setBusy(p));
      const id = await api.addAttachment(attachment);
      onDraft({ ...info, attachmentId: id, attachmentType: attachment.type, fromDocument: true });
    } catch (e) { toast('Import impossible : ' + (e?.message || e)); }
    setBusy(null);
  });
  return html`
    <button class="icon-btn" aria-label="Ajouter" onClick=${() => setOpen(true)}>+</button>
    ${input}
    ${open && html`<${Sheet} title="Ajouter" cancelLabel="Fermer" onCancel=${() => setOpen(false)}>
      <div class="action-list">
        <button class="btn block" onClick=${() => { setOpen(false); pick(); }}>📄 Depuis un document (PDF, photo, scan)</button>
        <button class="btn secondary block" onClick=${() => { setOpen(false); onDraft({}); }}>✏️ Saisie manuelle</button>
      </div>
      <p class="note">Avec « Depuis un document », vous pouvez choisir un PDF (Fichiers, mails enregistrés…), une photo, ou prendre directement une photo du ticket. Les informations sont lues automatiquement.</p>
    <//>`}
    ${busy != null && html`<${Overlay} text="Lecture du document…" progress=${busy || null} />`}`;
}

// ======================================================================
// Écran Ventes
// ======================================================================

const effectiveDate = (s) => s.paymentDate || s.invoiceDate;

function YearSelect({ year, setYear, years }) {
  return html`<select class="pill" value=${year} onChange=${(e) => setYear(Number(e.target.value))}>
    ${years.map((y) => html`<option value=${y}>${y}</option>`)}</select>`;
}

function SalesScreen({ state, api, openForm }) {
  const [year, setYear] = useState(new Date().getFullYear());
  const [filter, setFilter] = useState('all');
  const [q, setQ] = useState('');
  const years = [...new Set([new Date().getFullYear(), ...state.sales.map((s) => F.yearOf(effectiveDate(s)))])].sort((a, b) => b - a);

  const list = state.sales.filter((s) => {
    if (filter === 'pending') { if (s.paymentDate) return false; }
    else {
      if (F.yearOf(effectiveDate(s)) !== year) return false;
      if (filter === 'paid' && !s.paymentDate) return false;
    }
    const qq = q.trim().toLowerCase();
    return !qq || [s.client, s.label, s.invoiceNumber].some((x) => (x || '').toLowerCase().includes(qq));
  }).sort((a, b) => effectiveDate(b).localeCompare(effectiveDate(a)));

  const groups = {};
  for (const s of list) (groups[effectiveDate(s).slice(0, 7)] ||= []).push(s);
  const total = list.filter((s) => filter === 'pending' ? !s.paymentDate : s.paymentDate).reduce((a, s) => a + s.amount, 0);

  const markPaid = (e, s) => { e.stopPropagation(); api.saveSale({ ...s, paymentDate: F.today() }); toast('Vente marquée encaissée'); };

  return html`<div class="screen">
    <div class="header"><h1>Ventes</h1>
      ${filter !== 'pending' && html`<${YearSelect} year=${year} setYear=${setYear} years=${years} />`}
      <${AddMenu} kind="sale" api=${api} onDraft=${(d) => openForm({ type: 'sale', draft: d })} />
    </div>
    <div class="segmented">
      ${[['all', 'Toutes'], ['paid', 'Encaissées'], ['pending', 'En attente']].map(([k, l]) =>
        html`<button class=${filter === k ? 'on' : ''} onClick=${() => setFilter(k)}>${l}</button>`)}
    </div>
    <input class="search" type="search" placeholder="Rechercher (client, prestation, n°)" value=${q} onInput=${(e) => setQ(e.target.value)} />
    <div class="card" style="margin-top:10px;padding:12px 16px">
      <div class="line strong"><span class="k">${filter === 'pending' ? 'Total en attente' : `Total encaissé ${year}`}</span><span class="v">${eur(total)}</span></div>
    </div>
    ${!list.length && html`<div class="empty"><div class="ico">💶</div>Aucune vente.<br/>Touchez + pour saisir une vente ou importer une facture.</div>`}
    ${Object.keys(groups).sort().reverse().map((k) => html`
      <div class="group-title"><span>${F.cap(F.monthName(F.monthOf(k + '-01')))} ${k.slice(0, 4)}</span>
        <span>${eur(groups[k].filter((s) => s.paymentDate).reduce((a, s) => a + s.amount, 0))}</span></div>
      <div class="list">${groups[k].map((s) => html`
        <button class="item" onClick=${() => openForm({ type: 'sale', entry: s })}>
          <div class="main">
            <div class="t1">${s.client}${s.attachmentId ? ' 📎' : ''}</div>
            <div class="t2">${[s.label, s.invoiceNumber].filter(Boolean).join(' · ')}</div>
            ${s.paymentDate ? html`<div class="t3">Encaissée le ${frDate(s.paymentDate)}</div>`
              : html`<div class="t3 orange">En attente — facturée le ${frDate(s.invoiceDate)}</div>`}
          </div>
          <div class="amount">
            <div class=${s.paymentDate ? '' : 'orange'}>${eur(s.amount)}</div>
            ${!s.paymentDate && html`<span class="pay-btn" role="button" onClick=${(e) => markPaid(e, s)}>✓ Encaissée</span>`}
          </div>
        </button>`)}
      </div>`)}
  </div>`;
}

// ======================================================================
// Écran Achats
// ======================================================================

function PurchasesScreen({ state, api, openForm }) {
  const [year, setYear] = useState(new Date().getFullYear());
  const [cat, setCat] = useState('');
  const [q, setQ] = useState('');
  const years = [...new Set([new Date().getFullYear(), ...state.purchases.map((p) => F.yearOf(p.date))])].sort((a, b) => b - a);
  const list = state.purchases.filter((p) => {
    if (F.yearOf(p.date) !== year) return false;
    if (cat && p.category !== cat) return false;
    const qq = q.trim().toLowerCase();
    return !qq || [p.supplier, p.label, p.invoiceNumber].some((x) => (x || '').toLowerCase().includes(qq));
  }).sort((a, b) => b.date.localeCompare(a.date));
  const groups = {};
  for (const p of list) (groups[p.date.slice(0, 7)] ||= []).push(p);
  const missing = list.filter((p) => !p.attachmentId).length;

  return html`<div class="screen">
    <div class="header"><h1>Achats</h1>
      <${YearSelect} year=${year} setYear=${setYear} years=${years} />
      <${AddMenu} kind="purchase" api=${api} onDraft=${(d) => openForm({ type: 'purchase', draft: d })} />
    </div>
    <div class="toolbar">
      <select class="pill" value=${cat} onChange=${(e) => setCat(e.target.value)}>
        <option value="">Toutes catégories</option>
        ${Object.entries(PURCHASE_CATEGORIES).map(([k, v]) => html`<option value=${k}>${v}</option>`)}
      </select>
    </div>
    <input class="search" type="search" placeholder="Rechercher (fournisseur, nature, n°)" value=${q} onInput=${(e) => setQ(e.target.value)} />
    <div class="card" style="margin-top:10px;padding:12px 16px">
      <div class="line strong"><span class="k">Total achats ${year}</span><span class="v">${eur(list.reduce((a, p) => a + p.amount, 0))}</span></div>
      ${missing > 0 && html`<div class="small orange" style="margin-top:4px">⚠️ ${missing} achat${missing > 1 ? 's' : ''} sans justificatif</div>`}
    </div>
    ${!list.length && html`<div class="empty"><div class="ico">🧾</div>Aucun achat.<br/>Touchez + pour importer une facture ou un ticket.</div>`}
    ${Object.keys(groups).sort().reverse().map((k) => html`
      <div class="group-title"><span>${F.cap(F.monthName(F.monthOf(k + '-01')))} ${k.slice(0, 4)}</span>
        <span>${eur(groups[k].reduce((a, p) => a + p.amount, 0))}</span></div>
      <div class="list">${groups[k].map((p) => html`
        <button class="item" onClick=${() => openForm({ type: 'purchase', entry: p })}>
          <div class="emoji">${PURCHASE_ICONS[p.category] || '🧾'}</div>
          <div class="main">
            <div class="t1">${p.supplier}${p.attachmentId ? ' 📎' : ''}</div>
            <div class="t2">${p.label || PURCHASE_CATEGORIES[p.category]}</div>
            <div class="t3">${frDate(p.date)}</div>
          </div>
          <div class="amount">${eur(p.amount)}</div>
        </button>`)}
      </div>`)}
  </div>`;
}

// ======================================================================
// Accueil
// ======================================================================

function BarChart({ data }) {
  const W = 340, H = 150, pad = 18;
  const max = Math.max(1, ...data.flatMap((d) => [d.ca, d.achats]));
  const bw = (W - pad) / data.length;
  const fmt = (v) => v >= 1000 ? `${Math.round(v / 1000)} k` : `${Math.round(v)}`;
  return html`<svg class="chart" viewBox="0 0 ${W} ${H + 18}" preserveAspectRatio="none">
    ${[0.5, 1].map((r) => html`<line x1=${pad} x2=${W} y1=${H - (H - 10) * r} y2=${H - (H - 10) * r} stroke="var(--line)" stroke-width="0.5" />
      <text x="0" y=${H - (H - 10) * r + 3} font-size="8" fill="var(--muted)">${fmt(max * r)}</text>`)}
    ${data.map((d, i) => {
      const x = pad + i * bw, h1 = (H - 10) * d.ca / max, h2 = (H - 10) * d.achats / max, w = bw * 0.34;
      return html`<g>
        <rect x=${x + bw * 0.14} y=${H - h1} width=${w} height=${h1} rx="2" fill="var(--green)" />
        <rect x=${x + bw * 0.14 + w + 1} y=${H - h2} width=${w} height=${h2} rx="2" fill="var(--red)" opacity="0.7" />
        <text x=${x + bw / 2} y=${H + 13} font-size="8.5" text-anchor="middle" fill="var(--muted)">${d.label}</text></g>`;
    })}
  </svg>
  <div class="legend"><span><i style="background:var(--green)"></i>CA encaissé</span><span><i style="background:var(--red);opacity:.7"></i>Achats</span></div>`;
}

function Threshold({ title, value, limit }) {
  const r = limit > 0 ? value / limit : 0;
  const color = r >= 1 ? 'var(--red)' : r >= 0.8 ? 'var(--orange)' : 'var(--green)';
  return html`<div>
    <div class="row small"><span>${title}</span><span class="spacer"></span><span class="muted num">${eur(value)} / ${eur(limit)}</span></div>
    <div class="bar"><div style="width:${Math.min(100, r * 100)}%;background:${color}"></div></div>
  </div>`;
}

const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const isStandalone = () => window.navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;

function Dashboard({ state, api, setTab }) {
  const { sales, purchases, settings: s } = state;
  const now = F.today();
  const y = F.yearOf(now), m = F.monthOf(now);
  const [year, setYear] = useState(y);

  const month = F.summary(sales, purchases, F.range.month(y, m), s);
  const yearSum = F.summary(sales, purchases, F.range.year(year), s);
  const decl = F.nextDeclaration(s);
  const dSum = F.summary(sales, purchases, [decl.start, decl.end], s);
  const declared = s.declaredPeriods.includes(decl.key);
  const isCurrent = decl.start <= now && now < decl.end;
  const days = F.daysUntil(decl.deadline);
  const pending = sales.filter((x) => !x.paymentDate);
  const prev = F.summary(sales, purchases, F.range.year(year - 1), s);
  const chart = Array.from({ length: 12 }, (_, i) => {
    const r = F.summary(sales, purchases, F.range.month(year, i + 1), s);
    return { label: F.monthShort(i + 1), ca: r.ca, achats: r.purchases };
  });
  const hasServices = yearSum.caServices > 0 || CATEGORIES[s.mainCategory].service;
  const hasVente = yearSum.caVente > 0 || !CATEGORIES[s.mainCategory].service;
  const hasData = sales.length + purchases.length > 0;
  const backupAge = s.lastBackup ? F.daysUntil(s.lastBackup) * -1 : Infinity;

  const toggleDeclared = () => {
    const list = declared ? s.declaredPeriods.filter((k) => k !== decl.key) : [...s.declaredPeriods, decl.key];
    api.updateSettings({ declaredPeriods: list });
  };
  const copyCA = async () => {
    try { await navigator.clipboard.writeText(String(Math.round(dSum.ca))); toast('CA copié : ' + Math.round(dSum.ca) + ' €'); }
    catch { toast('Copie impossible'); }
  };

  return html`<div class="screen">
    <div class="header"><h1>Accueil</h1><${YearSelect} year=${year} setYear=${setYear} years=${Array.from({ length: 6 }, (_, i) => y - i)} /></div>

    ${isIOS && !isStandalone() && html`<div class="banner warn">📲 <span><b>Installez l'app :</b> touchez le bouton Partager <b>⎋</b> de Safari puis « <b>Sur l'écran d'accueil</b> ». Utilisez ensuite toujours l'icône de l'écran d'accueil (vos données y sont rangées).</span></div>`}
    ${!s.businessName && !hasData && html`<${Card} title="Bienvenue 👋" ico="">
      <p class="small muted" style="margin-top:0">Commencez par indiquer votre type d'activité et votre rythme de déclaration (mensuel ou trimestriel) : les calculs URSSAF en dépendent.</p>
      <button class="btn" onClick=${() => setTab('settings')}>Ouvrir les réglages</button>
    <//>`}
    ${hasData && backupAge > 30 && html`<div class="banner">💾 <span>${s.lastBackup ? `Dernière sauvegarde il y a ${backupAge} jours.` : 'Aucune sauvegarde pour l’instant.'} <button class="link" onClick=${() => setTab('export')}>Sauvegarder maintenant</button></span></div>`}

    <${Card} title="Déclaration URSSAF" ico="🏛️">
      <div class="big">${F.cap(decl.label)}</div>
      <div class="small" style="margin:2px 0 6px">
        ${declared ? html`<span class="green">✓ Déclarée</span>`
          : isCurrent ? html`<span class="muted">Période en cours — à déclarer entre le ${frDate(decl.end)} et le ${frDate(decl.deadline)}</span>`
          : html`<span class=${days <= 7 ? 'red' : 'orange'}>À déclarer avant le ${frDate(decl.deadline)} (${days} jour${days > 1 ? 's' : ''})</span>`}
      </div>
      <div class="divider"></div>
      ${Object.keys(dSum.caByCat).length ? CATEGORY_KEYS.filter((k) => dSum.caByCat[k]).map((k) =>
        html`<${Line} k=${'CA à déclarer — ' + CATEGORIES[k].short} v=${Math.round(dSum.caByCat[k])} strong />`)
        : html`<${Line} k="CA à déclarer" v=${0} strong />`}
      <${Line} k="Cotisations sociales" v=${dSum.cotisations} />
      <${Line} k="Formation professionnelle (CFP)" v=${dSum.cfp} />
      ${s.versementLiberatoire && html`<${Line} k="Versement libératoire (impôt)" v=${dSum.impotVL} />`}
      <${Line} k="Total à payer (estimé)" v=${dSum.urssaf} strong cls="indigo" />
      <div class="row" style="margin-top:12px">
        <button class="btn secondary sm" onClick=${copyCA}>Copier le CA</button>
        <span class="spacer"></span>
        ${(!isCurrent || declared) && html`<button class="btn sm ${declared ? 'secondary' : 'success'}" onClick=${toggleDeclared}>${declared ? 'Annuler' : '✓ Marquer déclarée'}</button>`}
      </div>
      <div style="margin-top:10px"><a class="link" href="https://www.autoentrepreneur.urssaf.fr" target="_blank" rel="noopener">Déclarer sur autoentrepreneur.urssaf.fr ↗</a></div>
    <//>

    <${Card} title=${F.cap(F.monthName(m)) + ' ' + y} ico="📅">
      <div class="grid2">
        <${Stat} label="CA encaissé" value=${month.ca} cls="green" />
        <${Stat} label="Achats" value=${month.purchases} cls="red" />
        <${Stat} label="URSSAF estimé" value=${month.urssaf} cls="indigo" />
        <${Stat} label="Bénéfice estimé" value=${month.profit} />
      </div>
      ${month.urssaf > 0 && html`<div class="note">💡 Mettez de côté ${eur(month.urssaf)} pour l'URSSAF.</div>`}
    <//>

    <${Card} title=${'Année ' + year} ico="📊">
      <${Line} k="Chiffre d'affaires encaissé" v=${yearSum.ca} strong cls="green" />
      ${Object.keys(yearSum.caByCat).length > 1 && CATEGORY_KEYS.filter((k) => yearSum.caByCat[k]).map((k) =>
        html`<${Line} k=${'   dont ' + CATEGORIES[k].short} v=${yearSum.caByCat[k]} />`)}
      <${Line} k="Achats" v=${yearSum.purchases} cls="red" />
      <${Line} k="Cotisations + CFP" v=${yearSum.cotisations + yearSum.cfp} />
      ${s.versementLiberatoire && html`<${Line} k="Impôt (versement libératoire)" v=${yearSum.impotVL} />`}
      <div class="divider"></div>
      <${Line} k="Bénéfice estimé" v=${yearSum.profit} strong />
      <div class="note">Bénéfice = CA encaissé − achats − sommes versées à l'URSSAF${s.versementLiberatoire ? '' : ' (avant impôt sur le revenu)'}.</div>
    <//>

    <${Card} title=${'Évolution ' + year} ico="📈"><${BarChart} data=${chart} /><//>

    <${Card} title=${'Plafonds ' + year} ico="🎯">
      ${hasServices && html`
        <${Threshold} title="Plafond micro (services)" value=${yearSum.caServices} limit=${s.plafondServices} />
        <${Threshold} title="Franchise TVA (services)" value=${yearSum.caServices} limit=${s.seuilTVAServices} />`}
      ${hasVente && html`
        <${Threshold} title="Plafond micro (ventes)" value=${hasServices ? yearSum.ca : yearSum.caVente} limit=${s.plafondVente} />
        <${Threshold} title="Franchise TVA (ventes)" value=${hasServices ? yearSum.ca : yearSum.caVente} limit=${s.seuilTVAVente} />`}
      <div class="note">Au-delà du seuil de franchise, vous devez facturer la TVA.</div>
    <//>

    ${pending.length > 0 && html`<${Card} title="Factures en attente de paiement" ico="⏳">
      <${Line} k=${pending.length + ' facture' + (pending.length > 1 ? 's' : '')} v=${pending.reduce((a, x) => a + x.amount, 0)} strong cls="orange" />
      ${(() => { const old = pending.map((x) => x.invoiceDate).sort()[0]; return F.daysUntil(old) < -30 && html`<div class="note">🔔 La plus ancienne date du ${frDate(old)} — pensez à relancer.</div>`; })()}
      <button class="link" style="margin-top:8px" onClick=${() => setTab('sales')}>Voir les ventes →</button>
    <//>`}

    <${Card} title=${`Déclaration de revenus ${year} (revenus ${year - 1})`} ico="🧾">
      ${prev.ca === 0 ? html`<div class="small muted">Aucun CA enregistré en ${year - 1}.</div>` : html`
        <div class="small muted" style="margin-bottom:6px">En plus de votre salaire, reportez votre CA brut sur la déclaration complémentaire 2042-C-PRO :</div>
        ${CATEGORY_KEYS.filter((k) => prev.caByCat[k]).map((k) =>
          html`<${Line} k=${`Case ${CATEGORIES[k].box[s.versementLiberatoire ? 1 : 0]} — ${CATEGORIES[k].short}`} v=${Math.round(prev.caByCat[k])} strong />`)}
        ${s.versementLiberatoire
          ? html`<div class="note">Avec le versement libératoire, l'impôt est déjà payé : ce CA sert au calcul du revenu fiscal de référence.</div>`
          : html`<${Line} k="Revenu imposable estimé (après abattement)" v=${prev.taxable} />
            <div class="note">Les impôts appliquent l'abattement automatiquement (71 % ventes, 50 % services BIC, 34 % BNC). Ce revenu s'ajoute à votre salaire.</div>`}`}
    <//>
  </div>`;
}

// ======================================================================
// Export
// ======================================================================

function ExportScreen({ state, api }) {
  const now = new Date();
  const [kind, setKind] = useState('year');
  const [year, setYear] = useState(now.getFullYear());
  const [quarter, setQuarter] = useState(Math.floor(now.getMonth() / 3) + 1);
  const [month, setMonth] = useState(now.getMonth() + 1);
  const [busy, setBusy] = useState(false);
  const [ready, setReady] = useState(null);   // {blob, name, backup}
  const [restoreInput, pickRestore] = useFilePicker(async (file) => {
    setBusy(true);
    try {
      const b = X.readBackup(await file.arrayBuffer());
      const r = await api.restore(b);
      toast(`Restauration terminée : ${r.sales} vente(s) et ${r.purchases} achat(s) ajoutés.`);
    } catch (e) { toast(e?.message || String(e)); }
    setBusy(false);
  }, '.zip,application/zip');

  const scope = X.scopeOf(kind, year, kind === 'quarter' ? quarter : month);
  const attachmentMeta = useMemo(() => {
    const m = {};
    for (const x of [...state.sales, ...state.purchases]) if (x.attachmentId) m[x.attachmentId] = { type: x.attachmentType };
    return m;
  }, [state.sales, state.purchases]);
  const full = { ...state, attachmentMeta };
  const preview = F.summary(state.sales, state.purchases, scope.range, state.settings);

  const run = async (fn, backup = false) => {
    setBusy(true);
    try { setReady({ ...(await fn()), backup }); }
    catch (e) { console.error(e); toast('Erreur : ' + (e?.message || e)); }
    setBusy(false);
  };

  const share = async () => {
    const { blob, name, backup } = ready;
    const file = new File([blob], name, { type: blob.type || 'application/octet-stream' });
    let done = false;
    if (navigator.canShare?.({ files: [file] })) {
      try { await navigator.share({ files: [file] }); done = true; }
      catch (e) { if (e.name === 'AbortError') return; }
    }
    if (!done) {
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a'); a.href = url; a.download = name; document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60000);
      done = true;
    }
    if (done && backup) api.updateSettings({ lastBackup: F.today() });
    setReady(null);
  };

  const years = Array.from({ length: 7 }, (_, i) => now.getFullYear() - i);
  return html`<div class="screen">
    <div class="header"><h1>Export</h1></div>
    <${Section} label="Période">
      <div style="padding:8px 10px">
        <div class="segmented">${[['year', 'Année'], ['quarter', 'Trimestre'], ['month', 'Mois']].map(([k, l]) =>
          html`<button class=${kind === k ? 'on' : ''} onClick=${() => setKind(k)}>${l}</button>`)}</div>
      </div>
      <${SelectField} label="Année" value=${String(year)} onChange=${(v) => setYear(Number(v))} options=${Object.fromEntries(years.map((y) => [y, String(y)]))} />
      ${kind === 'quarter' && html`<${SelectField} label="Trimestre" value=${String(quarter)} onChange=${(v) => setQuarter(Number(v))} options=${{ 1: 'T1 (janv.–mars)', 2: 'T2 (avr.–juin)', 3: 'T3 (juil.–sept.)', 4: 'T4 (oct.–déc.)' }} />`}
      ${kind === 'month' && html`<${SelectField} label="Mois" value=${String(month)} onChange=${(v) => setMonth(Number(v))} options=${Object.fromEntries(Array.from({ length: 12 }, (_, i) => [i + 1, F.cap(F.monthName(i + 1))]))} />`}
    <//>
    <div class="card small">
      <div class="line"><span class="k">Recettes encaissées</span><span class="v">${preview.salesCount} — ${eur(preview.ca)}</span></div>
      <div class="line"><span class="k">Achats</span><span class="v">${preview.purchasesCount} — ${eur(preview.purchases)}</span></div>
      ${preview.pendingCount > 0 && html`<div class="line"><span class="k">Factures non encaissées</span><span class="v">${preview.pendingCount}</span></div>`}
    </div>
    <div class="action-list">
      <button class="btn block" onClick=${() => run(() => X.buildDossier(full, scope, api.getAttachment))}>🗂️ Dossier complet (.zip)</button>
      <button class="btn secondary block" onClick=${() => run(() => X.buildPDF(full, scope))}>📄 Registre PDF</button>
      <button class="btn secondary block" onClick=${() => run(async () => X.buildXLSX(full, scope))}>📊 Tableur Excel (.xlsx)</button>
    </div>
    <p class="note">En cas de contrôle URSSAF, envoyez le <b>dossier complet</b> : livre des recettes et registre des achats en PDF (lisible) et en Excel (exploitable), plus tous les justificatifs renommés par date.</p>

    <div class="group-title" style="margin-top:26px"><span>Sauvegarde</span></div>
    <div class="action-list">
      <button class="btn secondary block" onClick=${() => run(() => X.buildBackup(state, api.getAttachment), true)}>💾 Créer une sauvegarde</button>
      <button class="btn secondary block" onClick=${pickRestore}>↩️ Restaurer une sauvegarde</button>
    </div>
    <p class="note">Vos données sont stockées dans l'iPhone. Une fois par mois, créez une sauvegarde et choisissez « Enregistrer dans Fichiers » → iCloud Drive. Si vous changez de téléphone, il suffira de la restaurer. La restauration ajoute ce qui manque sans rien effacer.
      ${state.settings.lastBackup && html`<br/>Dernière sauvegarde : ${frDate(state.settings.lastBackup)}.`}</p>
    ${restoreInput}
    ${busy && html`<${Overlay} text="Préparation…" />`}
    ${ready && html`<${Sheet} title="Fichier prêt" cancelLabel="Fermer" onCancel=${() => setReady(null)}>
      <div class="card" style="text-align:center">
        <div style="font-size:40px">${ready.name.endsWith('.zip') ? '🗂️' : ready.name.endsWith('.pdf') ? '📄' : '📊'}</div>
        <div class="bold" style="margin:6px 0 2px;word-break:break-all">${ready.name}</div>
        <div class="tiny muted">${(ready.blob.size / 1024 / 1024).toFixed(2)} Mo</div>
      </div>
      <button class="btn block" onClick=${share}>Partager / Enregistrer dans Fichiers</button>
      <p class="note">Choisissez « Enregistrer dans Fichiers », Mail, ou toute autre app.</p>
    <//>`}
  </div>`;
}

// ======================================================================
// Réglages
// ======================================================================

function SettingsScreen({ state, api }) {
  const s = state.settings;
  const up = (patch) => api.updateSettings(patch);
  const rate = (k) => (v) => up({ rates: { ...s.rates, [k]: v } });
  return html`<div class="screen">
    <div class="header"><h1>Réglages</h1></div>
    <${Section} label="Mon entreprise" help="Ces informations apparaissent en tête des exports.">
      <${TextField} label="Nom commercial" value=${s.businessName} onInput=${(v) => up({ businessName: v })} />
      <${TextField} label="Nom et prénom" value=${s.ownerName} autocap="words" onInput=${(v) => up({ ownerName: v })} />
      <${TextField} label="SIRET" value=${s.siret} inputmode="numeric" onInput=${(v) => up({ siret: v })} />
      <${TextField} label="Adresse" value=${s.address} onInput=${(v) => up({ address: v })} />
    <//>
    <${Section} label="Activité" help="La catégorie est proposée par défaut à chaque vente ; vous pouvez la changer vente par vente si vous avez une activité mixte.">
      <${SelectField} label="Activité principale" value=${s.mainCategory} onChange=${(v) => up({ mainCategory: v })}
        options=${Object.fromEntries(CATEGORY_KEYS.map((k) => [k, CATEGORIES[k].label]))} />
      <${SelectField} label="Déclaration URSSAF" value=${s.frequency} onChange=${(v) => up({ frequency: v })}
        options=${{ monthly: 'Mensuelle', quarterly: 'Trimestrielle' }} />
      <${SelectField} label="Formation pro. (CFP)" value=${s.cfp} onChange=${(v) => up({ cfp: v })}
        options=${Object.fromEntries(Object.entries(F.CFP).map(([k, v]) => [k, v.label]))} />
      <${Toggle} label="Versement libératoire de l'impôt" checked=${s.versementLiberatoire} onChange=${(v) => up({ versementLiberatoire: v })} />
    <//>
    <${Section} label="ACRE" help="L'ACRE réduit les cotisations jusqu'à la fin du 3e trimestre civil suivant le début d'activité (50 % pour une création avant le 1er juillet 2026, 25 % ensuite). Vérifiez sur votre espace URSSAF.">
      <${Toggle} label="Je bénéficie de l'ACRE" checked=${s.acreEnabled} onChange=${(v) => up({ acreEnabled: v })} />
      ${s.acreEnabled && html`
        <${DateField} label="Fin de l'ACRE" value=${s.acreEndDate || F.today()} onInput=${(v) => up({ acreEndDate: v })} />
        <${NumberField} label="Réduction" value=${s.acreReduction} suffix="%" onChange=${(v) => up({ acreReduction: v })} />`}
    <//>
    <${Section} label="Taux de cotisations sociales" help="Taux 2026 pré-remplis. Ils évoluent régulièrement : vérifiez-les sur urssaf.fr.">
      <${NumberField} label="Vente de marchandises" value=${s.rates.vente} suffix="%" onChange=${rate('vente')} />
      <${NumberField} label="Services BIC" value=${s.rates.bic} suffix="%" onChange=${rate('bic')} />
      <${NumberField} label="Libéral BNC" value=${s.rates.bnc} suffix="%" onChange=${rate('bnc')} />
      <${NumberField} label="Libéral CIPAV" value=${s.rates.cipav} suffix="%" onChange=${rate('cipav')} />
      <button class="field link" style="width:100%" onClick=${() => up({ rates: { ...F.DEFAULT_SETTINGS.rates } })}>Rétablir les taux 2026</button>
    <//>
    <${Section} label="Plafonds et seuils">
      <${NumberField} label="Plafond micro — ventes" value=${s.plafondVente} suffix="€" decimals=${0} onChange=${(v) => up({ plafondVente: v })} />
      <${NumberField} label="Plafond micro — services" value=${s.plafondServices} suffix="€" decimals=${0} onChange=${(v) => up({ plafondServices: v })} />
      <${NumberField} label="Franchise TVA — ventes" value=${s.seuilTVAVente} suffix="€" decimals=${0} onChange=${(v) => up({ seuilTVAVente: v })} />
      <${NumberField} label="Franchise TVA — services" value=${s.seuilTVAServices} suffix="€" decimals=${0} onChange=${(v) => up({ seuilTVAServices: v })} />
    <//>
    <div class="card">
      <div class="card-title"><span class="ico">💡</span>Aide-mémoire</div>
      <div class="help-item"><b>CA à déclarer</b><span>Le chiffre d'affaires encaissé sur la période (pas celui facturé), sans déduire les achats ni les frais.</span></div>
      <div class="help-item"><b>Achats</b><span>En micro-entreprise, les achats ne réduisent pas les cotisations. Le registre des achats est obligatoire pour la vente de marchandises, et utile à tous pour suivre la rentabilité réelle.</span></div>
      <div class="help-item"><b>Conservation</b><span>Gardez factures et justificatifs 10 ans. Faites une sauvegarde chaque mois (onglet Export).</span></div>
      <div class="help-item"><b>Salarié + micro</b><span>Vos cotisations micro s'ajoutent à celles de votre salaire. Côté impôts, le CA se déclare chaque printemps sur la 2042-C-PRO (voir l'accueil).</span></div>
      <div class="help-item"><b>Confidentialité</b><span>Tout reste dans votre iPhone : aucune donnée n'est envoyée sur internet, même la lecture des factures.</span></div>
    </div>
    <p class="note" style="text-align:center">Compta AE · version 1.0</p>
  </div>`;
}

// ======================================================================
// Application
// ======================================================================

const ICONS = {
  home: html`<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 3.2 2.8 11h2.7v9h5v-6h3v6h5v-9h2.7z"/></svg>`,
  sales: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="9"/><path d="M15.5 8.5a4 4 0 1 0 0 7M7 11h6M7 13.5h6" stroke-linecap="round"/></svg>`,
  purchases: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4h2.5l2.2 10.5h10l2-7.5H6.4"/><circle cx="9.5" cy="19" r="1.4"/><circle cx="16.5" cy="19" r="1.4"/></svg>`,
  export: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 15V3M7.5 7.5 12 3l4.5 4.5M5 12v7.5h14V12"/></svg>`,
  settings: html`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/></svg>`,
};
const TABS = [['home', 'Accueil'], ['sales', 'Ventes'], ['purchases', 'Achats'], ['export', 'Export'], ['settings', 'Réglages']];

function App() {
  const [state, api] = useStore();
  const [tab, setTabRaw] = useState(() => { try { return sessionStorage.getItem('tab') || 'home'; } catch { return 'home'; } });
  const [form, setForm] = useState(null);
  const setTab = (t) => { setTabRaw(t); try { sessionStorage.setItem('tab', t); } catch { } window.scrollTo(0, 0); };

  if (!state.loaded) return html`<div class="screen"><div class="empty"><div class="spinner"></div></div></div>`;
  if (state.error) return html`<div class="screen"><div class="card"><b>Impossible d'ouvrir les données.</b><p class="small muted">${state.error}</p>
    <p class="small muted">Si vous êtes en navigation privée, ouvrez l'app normalement.</p></div></div>`;

  const props = { state, api, openForm: setForm, setTab };
  return html`
    ${tab === 'home' && html`<${Dashboard} ...${props} />`}
    ${tab === 'sales' && html`<${SalesScreen} ...${props} />`}
    ${tab === 'purchases' && html`<${PurchasesScreen} ...${props} />`}
    ${tab === 'export' && html`<${ExportScreen} ...${props} />`}
    ${tab === 'settings' && html`<${SettingsScreen} ...${props} />`}
    <nav class="tabbar">${TABS.map(([k, l]) => html`
      <button class=${tab === k ? 'active' : ''} onClick=${() => setTab(k)}>${ICONS[k]}<span>${l}</span></button>`)}</nav>
    ${form?.type === 'sale' && html`<${SaleForm} key=${form.entry?.id || 'new'} entry=${form.entry} draft=${form.draft} state=${state} api=${api} onClose=${() => setForm(null)} />`}
    ${form?.type === 'purchase' && html`<${PurchaseForm} key=${form.entry?.id || 'new'} entry=${form.entry} draft=${form.draft} state=${state} api=${api} onClose=${() => setForm(null)} />`}`;
}

render(html`<${App} />`, document.getElementById('app'));
