// Stockage local (IndexedDB) : ventes, achats, justificatifs, réglages.
// Les fichiers sont stockés en ArrayBuffer (plus fiable que Blob sur Safari).

const DB_NAME = 'compta-ae';
const VERSION = 1;
let dbPromise;

function open() {
  if (!dbPromise) {
    dbPromise = new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, VERSION);
      req.onupgradeneeded = () => {
        const db = req.result;
        for (const name of ['sales', 'purchases', 'attachments']) {
          if (!db.objectStoreNames.contains(name)) db.createObjectStore(name, { keyPath: 'id' });
        }
        if (!db.objectStoreNames.contains('meta')) db.createObjectStore('meta');
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }
  return dbPromise;
}

async function run(store, mode, fn) {
  const db = await open();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, mode);
    const req = fn(tx.objectStore(store));
    tx.oncomplete = () => resolve(req?.result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error('Transaction annulée'));
  });
}

export const db = {
  all: (store) => run(store, 'readonly', (s) => s.getAll()),
  get: (store, id) => run(store, 'readonly', (s) => s.get(id)),
  put: (store, obj) => run(store, 'readwrite', (s) => s.put(obj)),
  del: (store, id) => run(store, 'readwrite', (s) => s.delete(id)),
  getMeta: (key) => run('meta', 'readonly', (s) => s.get(key)),
  setMeta: (key, value) => run('meta', 'readwrite', (s) => s.put(value, key)),
  attachmentKeys: () => run('attachments', 'readonly', (s) => s.getAllKeys()),
};

/** Demande au navigateur de ne pas effacer les données (Safari 17+). */
export async function requestPersistence() {
  try {
    if (navigator.storage?.persist) return await navigator.storage.persist();
  } catch { /* ignoré */ }
  return false;
}
