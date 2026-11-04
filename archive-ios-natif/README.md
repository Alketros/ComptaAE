# Compta AE — comptabilité d'auto-entrepreneur pour iPhone

Application iOS personnelle (SwiftUI, iOS 17+), 100 % locale : aucune donnée ne quitte l'iPhone.

## Fonctionnalités

| Onglet | Contenu |
|---|---|
| **Accueil** | Prochaine déclaration URSSAF (CA à déclarer, cotisations, échéance, bouton « Copier le CA », « Marquer déclarée »), résumé du mois et de l'année (CA, achats, URSSAF, bénéfice), graphique mensuel, jauges des plafonds micro / franchise TVA, factures en attente, cases de la 2042-C-PRO pour la déclaration de revenus |
| **Ventes** (livre des recettes) | Saisie manuelle rapide ou import PDF / scan / photo avec extraction automatique. Suggestions de clients (et pré-remplissage depuis la dernière vente du client), n° de facture incrémenté automatiquement, statut encaissé / en attente (balayer → « Encaissée »), duplication |
| **Achats** (registre des achats) | Import PDF / scan / photo avec extraction (fournisseur, date, TTC, TVA, n°, catégorie devinée), suggestions de fournisseurs, alerte « achats sans justificatif » |
| **Export** | Par année, trimestre ou mois : **dossier complet .zip** (PDF + Excel + tous les justificatifs renommés `2026-03-12_Client_F2026-004.pdf`), registre PDF, tableur Excel. Sauvegarde / restauration |
| **Réglages** | Entreprise, activité (vente / BIC / BNC / CIPAV), fréquence mensuelle ou trimestrielle, CFP, versement libératoire, ACRE, taux et plafonds modifiables, Face ID, rappels de déclaration |

**Lecture des factures** : texte du PDF, ou reconnaissance de texte (Vision) pour les scans et photos. Sur un iPhone compatible Apple Intelligence (iOS 26+), le modèle local affine le résultat. Les montants et dates proposés par l'IA ne sont gardés que s'ils figurent réellement dans le document.

## Installation sur votre iPhone (gratuit)

Il vous faut un **Mac avec Xcode 16 ou plus récent** (gratuit sur le Mac App Store) et un identifiant Apple.

1. Ouvrez `ComptaAE.xcodeproj` dans Xcode.
2. Cliquez sur le projet **ComptaAE** (barre de gauche) → cible **ComptaAE** → onglet **Signing & Capabilities** :
   - **Team** : ajoutez votre identifiant Apple (« Add an Account… ») et choisissez « *Votre nom* (Personal Team) ».
   - **Bundle Identifier** : remplacez `com.perso.comptaae` par un identifiant unique, par ex. `com.votrenom.comptaae`.
3. Branchez l'iPhone en USB. Sur l'iPhone, activez **Réglages → Confidentialité et sécurité → Mode développeur** (l'iPhone redémarre).
4. Dans Xcode, choisissez votre iPhone en haut de la fenêtre, puis ▶︎ (**Cmd + R**).
5. Au premier lancement, sur l'iPhone : **Réglages → Général → VPN et gestion de l'appareil** → faites confiance à votre profil développeur.

### Bon à savoir

- **Compte gratuit** : l'app doit être réinstallée depuis Xcode **tous les 7 jours** (refaites simplement ▶︎). Vos données sont **conservées** tant que vous ne supprimez pas l'app. Avec le compte développeur payant (99 €/an), la signature dure 1 an.
- **Sauvegardes** : faites régulièrement *Export → Créer une sauvegarde → Enregistrer dans Fichiers → iCloud Drive*. Si vous supprimez l'app, vous perdez tout ce qui n'est pas sauvegardé.
- Les justificatifs sont aussi visibles dans l'app **Fichiers** → *Sur mon iPhone → Compta AE → Justificatifs*.

## Règles appliquées (à vérifier sur urssaf.fr)

- Le CA déclaré à l'URSSAF est le **CA encaissé** (date d'encaissement), pas le CA facturé.
- Taux 2026 pré-remplis : vente 12,3 %, services BIC 21,2 %, libéral BNC 25,6 %, CIPAV 23,2 % + CFP (0,1 / 0,2 / 0,3 %). Versement libératoire : 1 % / 1,7 % / 2,2 %.
- Plafonds 2026 : 203 100 € (ventes), 83 600 € (services). Franchise TVA : 85 000 € / 37 500 €.
- Échéances : fin du mois suivant la période (mensuel), ou 30 avril / 31 juillet / 31 octobre / 31 janvier (trimestriel).

Tous les taux et plafonds sont modifiables dans les Réglages : ils changent souvent. Les montants affichés sont des **estimations** et ne remplacent pas votre espace URSSAF.

## Structure du code

```
ComptaAE/
├── ComptaAEApp.swift          Point d'entrée, onglets, verrouillage Face ID
├── Models/
│   ├── Models.swift           Vente, Achat (SwiftData), catégories, modes de paiement
│   └── Settings.swift         Réglages et taux
├── Services/
│   ├── Fiscal.swift           Périodes, échéances, calcul des cotisations, formatage
│   ├── DocumentExtractor.swift  Lecture PDF / OCR / Apple Intelligence
│   ├── Exporter.swift         PDF, Excel, dossier ZIP, sauvegarde / restauration
│   ├── PDFReport.swift        Mise en page PDF paginée
│   ├── XLSXWriter.swift       Génération .xlsx sans dépendance
│   ├── ZipArchive.swift       ZIP minimal
│   ├── AttachmentStore.swift  Stockage des justificatifs
│   └── Notifications.swift    Rappels d'échéance
└── Views/                     Écrans SwiftUI
```

### Si Xcode n'ouvre pas le projet

Créez un nouveau projet *iOS → App* (nom « ComptaAE », interface SwiftUI, stockage SwiftData), supprimez les fichiers générés (`ContentView.swift`, `Item.swift`, `ComptaAEApp.swift`), puis glissez le contenu du dossier `ComptaAE/` dans le projet. Ajoutez dans l'onglet *Info* de la cible : `Privacy - Camera Usage Description` et `Privacy - Face ID Usage Description`.
