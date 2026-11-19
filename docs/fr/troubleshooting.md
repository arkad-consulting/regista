# Résolution des problèmes

## Un bouton ou un élément est grisé

Regista ne cache rien : une fonction qui ne peut pas démarrer pour l'instant reste visible, grisée, avec la raison à
côté ou dessous. Les cas les plus fréquents :

- *Un moteur manque.* Par exemple « Le moteur qui transcrit la parole manque : installez-le depuis Réglages ›
  Moteurs. » ou « Nécessite Blender : installez-le dans Réglages › Moteurs. ». Appuyez sur **Installer…** s'il est
  là, ou ouvrez **Réglages › Moteurs** et installez-le depuis cet écran (voir [Installation et moteurs](install.md)).
- *Le Mac n'a pas assez de mémoire pour cette fonction.* Par exemple « Nécessite le niveau Pro » ou « La voix clonée
  demande un Mac avec au moins 16 Go de RAM ». La voix clonée demande le niveau Moyen (16 Go) ; l'entraînement de la
  voix et la génération locale, le niveau Pro (32 Go).
- *Il manque une étape avant.* Par exemple « Il faut d'abord la transcription. » ou « Mettez d'abord la vidéo dans la
  timeline : coupez les pauses. ». Faites d'abord l'étape indiquée : dans Simple, chaque étape dit aussi laquelle vient
  ensuite.
- *Aucun projet n'est ouvert.* Beaucoup de boutons ont besoin d'une vidéo dans le projet : dans **Accueil**, ouvrez un
  projet ou importez une vidéo.
- *La génération n'a pas de générateur prêt.* Dans **Générer**, chaque générateur grisé dit pourquoi : ComfyUI non
  installé ou pas prêt (fichiers de modèle ou nœuds manquants), Higgsfield sans compte connecté. Le générateur local se
  prépare à la main : **Réglages › Moteurs**, **Comment l'installer**.

## Un moteur manque ou ne fonctionne pas

1. Ouvrez **Réglages › Moteurs** et regardez l'état du moteur. S'il y a **Installer**, appuyez dessus et suivez
   l'avancement dans **Tâches**.
2. Si l'installation échoue, la tâche affiche « Échec de l'installation » et la raison. Vérifiez l'espace libre et la
   connexion, puis réessayez.
3. Dans le Terminal, `~/code/regista/scripts/doctor.sh` vérifie toute l'installation et dit comment corriger chaque
   problème.
4. Si cela ne suffit pas, relancez l'installation : `~/code/regista/scripts/install.sh`. Ce qui est déjà installé et
   vérifié reste tel quel.

## ComfyUI ne démarre pas ou une génération échoue

- *« ComfyUI does not answer … and Regista does not know where it is ».* Choisissez le dossier de ComfyUI dans
  **Réglages › Moteurs › ComfyUI**, ou lancez ComfyUI vous-même et indiquez-y son **Adresse**.
- *« … has no Python environment of its own ».* Créez-le dans le dossier de ComfyUI comme l'indiquent les instructions de
  ComfyUI (`.venv` ou `venv`), installez-y les dépendances de ComfyUI, puis **Vérifier à nouveau**.
- *ComfyUI s'arrête avant de répondre, ou ne répond pas en cinq minutes.* Regista arrête ce qu'il a lancé et affiche les
  dernières lignes du journal de ComfyUI : souvent un paquet Python manquant ou un pack de nœuds qui ne se charge pas.
  Lancez ComfyUI une fois à la main depuis son dossier pour voir le message entier.
- *« node … is not in ComfyUI ».* Installez le pack de nœuds indiqué (ComfyUI-GGUF pour Wan 2.2) et redémarrez ComfyUI ;
  pour un nœud de ComfyUI lui-même, mettez ComfyUI à jour.
- *« model file … is missing: put it in ComfyUI's models/… folder ».* La ligne du modèle dans **Réglages › Moteurs**
  liste chaque fichier avec son dossier et la page où le télécharger. Redémarrez ComfyUI après avoir ajouté des fichiers.
- *« ComfyUI ran out of memory ».* Fermez d'autres apps lourdes, ou demandez une taille plus petite ou un clip plus court.
- *L'app de bureau de ComfyUI.* Elle écoute sur un autre port que 8188 : indiquez son **Adresse** (par exemple
  `http://127.0.0.1:8000`).

## Autorisations : caméra, micro, écran

macOS demande l'autorisation la première fois que Regista utilise la caméra, le micro ou l'écran. Si vous avez refusé,
ou si l'autorisation n'est pas encore active :

- Dans **Enregistrer**, la ligne de la source indique que l'autorisation macOS manque. Appuyez sur **Autoriser…** :
  Réglages Système › Confidentialité et sécurité s'ouvre, où vous autorisez Regista.
- **Caméra** et **Micro** : Confidentialité et sécurité › Caméra et Microphone, activez Regista.
- **Écran** (et **Audio du Mac**) : Confidentialité et sécurité › Enregistrement de l'écran et de l'audio du système,
  activez Regista. Puis quittez et rouvrez Regista : dans **Enregistrer**, il y a **Rouvrir Regista**. L'autorisation
  ne compte qu'à partir de ce moment ; tant que ce n'est pas le cas, Regista affiche
  **L'enregistrement de l'écran n'est pas encore actif**.
- **Touches pressées dans la vidéo** (dans les tutoriels) : il faut aussi Confidentialité et sécurité › Accessibilité.
  Les clics et le curseur n'en ont pas besoin.
- Le **Prompteur** qui suit votre voix utilise l'autorisation du micro ; sur macOS 15, il faut aussi la Reconnaissance
  vocale.

Une mise à jour de Regista ne devrait pas redemander les autorisations. Si c'est le cas, autorisez-les de nouveau et
rouvrez l'app.

## « Claude non connecté »

L'onglet **Claude** du panneau de droite, et la barre du haut, affichent **Claude non connecté** tant que Claude n'a pas
utilisé Regista. C'est normal tant que vous ne lui avez rien demandé. Si Claude ne trouve pas Regista :

1. Ouvrez **Réglages › Claude**. Sous **Claude Desktop** (ou **Claude Code**), il doit y avoir
   **Connecté à cette app**. S'il y a **Non connecté**, appuyez sur **Connecter Claude Desktop…** (ou
   **Connecter Claude Code…**). S'il y a **Connecté à une autre copie de Regista**, appuyez sur
   **Pointer vers cette app…**.
2. Quittez complètement Claude Desktop (⌘Q, pas seulement la fenêtre) et rouvrez-le. Pour Claude Code, ouvrez une
   nouvelle session.
3. Dans les réglages développeur de Claude Desktop, « regista » doit apparaître comme actif.
4. Ouvrez Regista, puis demandez à Claude, par exemple : « Avec Regista, liste mes vidéos ».

Claude travaille mais vous ne voyez rien dans la fenêtre ? Regista était fermé la première fois que Claude l'a utilisé :
Claude travaille alors sans fenêtre et enregistre le projet, que vous ouvrez ensuite depuis **Accueil**. Pour suivre en
direct, ouvrez Regista, puis quittez et rouvrez Claude Desktop (ou ouvrez une nouvelle session de Claude Code).

Si Claude répond « timed out » pendant une longue tâche (une transcription, un export), Regista travaille encore.
Demandez-lui d'attendre une minute et de regarder l'état du projet, sans tout recommencer.

## Une tâche échoue

Transcriptions, nettoyage de la voix, exports, installations et générations sont des tâches. Elles sont dans
**Tâches**, dans la barre d'état : chacune a son avancement et **Annuler**. Une tâche qui échoue laisse le projet tel
qu'il était et explique pourquoi en mots simples ; une tâche annulée affiche **Annulé : rien n'a été modifié.**. Lisez
la raison, corrigez la cause (un moteur, l'espace libre, un fichier déplacé) et relancez-la. **Retirer de la liste**
enlève la ligne.

Une commande qui échoue, la vôtre ou celle de Claude, ne change rien non plus : vous pouvez réessayer sans risque.

## Où sont les journaux

- Installation : `~/Library/Application Support/Regista/logs` (un fichier par étape qui peut échouer).
- La connexion avec Claude Desktop : `~/Library/Logs/Claude/mcp-server-regista.log`, écrit par Claude Desktop.
- Le contrôle complet, à joindre à un signalement : dans le Terminal,
  `~/code/regista/scripts/doctor.sh > ~/Desktop/regista-doctor.txt 2>&1` crée le fichier `regista-doctor.txt` sur le
  Bureau.

## Signaler un problème

Dans le menu **Aide**, **Signaler un problème…** ouvre la page publique des signalements :
https://github.com/arkad-consulting/regista/issues. Indiquez :

- ce que vous avez fait ou demandé (copiez votre demande à Claude, s'il y en a une) ;
- ce que vous attendiez et ce qui s'est passé ;
- une capture d'écran (⇧⌘4 ou ⇧⌘5) et la durée de la vidéo ;
- le fichier `regista-doctor.txt`, si le problème concerne l'installation ou un moteur.

La page est publique : ne joignez pas de vidéos, de voix ni de données que vous ne voulez pas montrer.
