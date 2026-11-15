# ⚡ Velox Tweaks

Optimiseur Windows 10 / 11 pour les joueurs : une seule fenêtre, des réglages **réels et annulables**, et des outils qui changent vraiment quelque chose en jeu.

## Télécharger

👉 **[Dernière version](https://github.com/forpakK/velox-tweaks/releases/latest)** → télécharge `VeloxTweaks.zip`, puis clic droit → **Extraire tout**.

## Lancer

- **Recommandé :** double-clique une fois sur `Creer Velox Tweaks.exe.bat`, puis lance `Velox Tweaks.exe`.
- **Sinon :** clic droit sur `Lancer Velox Tweaks.bat` → **Exécuter en tant qu'administrateur**.

Velox vérifie tout seul les nouvelles versions au démarrage et propose de se mettre à jour.

## Ce que fait Velox

| Onglet | Contenu |
|---|---|
| **Dashboard** | Bouton **⚡ BOOSTER** (20 meilleurs réglages + plan performances en un clic), infos du PC |
| **Tweaks** | 34 réglages Windows (gaming, réseau, système, confidentialité, interface), chacun annulable |
| **Maintenance** | Nettoyage temp & shaders, TRIM, DNS, composants Windows |
| **Sauvegarde** | Point de restauration, export du registre, des pilotes et du plan d'alimentation |
| **Réparations** | Fichiers système (DISM/SFC), Internet, son, Windows Update, Store, explorateur |
| **Moniteur** | CPU, RAM, GPU, température, VRAM, consommation en direct (NVIDIA) |
| **Démarrage** | Activer / désactiver les programmes lancés avec Windows |
| **Outils gaming** | Convertisseur de sensibilité entre jeux, test de ping, check-up (Hz écran, XMP, Wi-Fi…) |
| **Velox Game Mode** | Plan d'alimentation ultime + **mode jeu automatique** quand un jeu se lance |

## Sécurité

- **Fais un point de restauration** avant (onglet Sauvegarde, ou case cochée par défaut dans Tweaks).
- Chaque tweak peut être annulé, et **Tout annuler** remet Windows par défaut.
- Tout le code est lisible dans `VeloxTweaks.ps1`. Rien n'est envoyé sur Internet, à part la vérification des mises à jour sur ce dépôt.
- Certains antivirus (Bitdefender…) bloquent le script parce qu'il modifie le registre et les services : c'est un faux positif. Ajoute une exception pour le dossier **avant** de dézipper.

## Honnêtement

Sur un PC récent, les tweaks Windows donnent peu de FPS en plus. Les vrais gains viennent de : **écran à sa bonne fréquence (144 Hz+)**, **XMP/EXPO activé dans le BIOS**, **câble Ethernet**, **pilote graphique à jour** et **DLSS / Reflex dans les jeux**. L'onglet **Outils gaming → Check-up** vérifie tout ça pour toi.
