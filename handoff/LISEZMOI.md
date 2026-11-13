# Regista — installer et utiliser

**Regista** est un éditeur vidéo pour Mac que **Claude pilote pour toi**. Tu mets une vidéo brute dans un dossier,
tu écris à Claude ce que tu veux (« monte-moi un reel avec sous-titres »), et Claude fait le montage dans l'app
Regista : il choisit les meilleures prises, enlève les pauses, nettoie la voix, ajoute les sous-titres et la marque,
regarde le résultat et exporte la vidéo. Tu vois chaque étape en direct dans l'app et tu peux retoucher à la main.
Tout tourne sur ton Mac (pas d'abonnement en plus, sauf ton compte Claude).

## 1. Avant de commencer

- Un Mac avec puce Apple (M1 ou plus récent) et **macOS 15** ou plus récent (menu  → À propos de ce Mac).
- Environ **16 Go libres** sur le disque, une bonne connexion internet, 20 à 40 minutes la première fois.
- **Claude Desktop** (https://claude.ai/download) **ou** Claude Code, connecté avec **ton** compte Claude.
  Installe-le **avant** Regista : l'installation le connecte automatiquement (sinon, relance `INSTALLA.command` après).
- Le mot de passe de ton Mac (compte administrateur) : il peut être demandé pour installer les outils Apple ou Homebrew.

Tu n'as rien d'autre à installer à la main : le script vérifie tout et, s'il manque quelque chose
(outils de développement d'Apple, Homebrew), il te dit exactement quoi faire.

## 2. Installer

**Avec une seule commande (conseillé).** Si les outils de développement d'Apple ne sont pas encore là, tape
d'abord `xcode-select --install` dans le Terminal et attends la fin de l'installation d'Apple. Ensuite, quitte Claude
Desktop (⌘Q), colle cette ligne dans le Terminal et appuie sur Entrée :

```
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

Le script pose les mêmes questions que ci-dessous (étapes 4 et 5) ; à la fin, passe à la section 3.

**Avec le zip (sans Git)**, si quelqu'un t'a envoyé un paquet `regista-….zip` :

1. **Quitte Claude Desktop** s'il est ouvert (⌘Q).
2. Double-clique sur le **zip** : un dossier `regista-…` apparaît (dans Téléchargements).
3. Dans ce dossier, double-clique sur **`INSTALLA.command`**. Une fenêtre Terminal s'ouvre et l'installation démarre.
   - Si macOS dit qu'il ne peut pas ouvrir le fichier : **clic droit** (ou ctrl-clic) sur `INSTALLA.command` →
     **Ouvrir** → **Ouvrir**. S'il n'y a pas de bouton « Ouvrir » : **Réglages Système → Confidentialité et
     sécurité**, en bas : **« Ouvrir quand même »**, puis double-clique de nouveau.
   - Si ça ne marche toujours pas : ouvre l'app **Terminal**, tape `bash` suivi d'un espace, **glisse
     `INSTALLA.command` dans la fenêtre**, puis appuie sur Entrée. C'est exactement la même chose.
   - Si macOS demande que Terminal accède au dossier Téléchargements : **Autoriser**.
4. Le script pose quelques questions, en français. **Appuie simplement sur Entrée** pour la réponse par défaut :
   - *Installer Blender… / Installer Shotcut… ?* (logiciels facultatifs) → Entrée = non ;
   - *Connecter Regista à Claude Desktop ?* → Entrée = oui.
5. **S'il s'arrête** avec un message en rouge, c'est presque toujours une étape à faire puis à relancer :
   - *Command Line Tools are missing* : une fenêtre Apple s'est ouverte → **Installer**, attends la fin,
     puis double-clique de nouveau sur `INSTALLA.command` ;
   - Homebrew absent : accepte son installation proposée dans le Terminal. Le programme officiel peut demander
     le mot de passe administrateur (rien ne s’affiche pendant la saisie). Regista reprend ensuite automatiquement.
     Si tu refuses ou si l’installation échoue, suis le message puis relance `INSTALLA.command`.
6. À la fin tu vois **« Regista est installé »** et **« Terminé »**. L'app Regista est dans **Applications**.

Relancer l'installation (la commande ou `INSTALLA.command`) ne casse rien : ce qui est déjà installé et vérifié est gardé.

## 3. Vérifier que tout marche

Dans le Terminal, colle cette ligne et appuie sur Entrée :

```
~/code/regista/scripts/doctor.sh
```

La dernière ligne doit être **« Tout est en ordre »**. Sinon, chaque problème est suivi d'une ligne qui dit
comment le corriger.

## 4. Connecter Claude

**Claude Desktop**
1. Quitte-le **complètement** (⌘Q, pas seulement fermer la fenêtre) puis rouvre-le.
2. Vérifie : menu **Claude → Réglages… → Développeur** : « regista » doit être là, avec l'état *running*.
3. Dans une nouvelle conversation, le bouton **＋** (ou l'icône des outils) sous la zone de saisie montre
   **regista** et ses outils, activés.
4. La première fois que Claude utilise un outil regista, il demande la permission : choisis **« Toujours autoriser »**
   (sinon il le redemande à chaque étape).
5. Conseil : crée un **Projet** « Regista » dans Claude Desktop et colle le contenu de **`START-PROMPT.md`** dans
   ses instructions. Toutes les conversations de ce projet sauront comment travailler.

**Claude Code** (si tu l'utilises) : dans le Terminal, `claude mcp list` doit montrer `regista … ✓ Connected`.
L'installation y ajoute aussi le skill **regista** (`~/.claude/skills/regista`) : Claude sait quand utiliser Regista
et quelles règles suivre, sans rien coller. Demande simplement « monte cette vidéo ».

## 5. Où mettre tes vidéos

Dans le dossier **Films › Regista** (`~/Movies/Regista`, créé par l'installation). Claude ne voit que ce dossier :
mets-y la vidéo (et le script en `.txt` ou `.md`, si tu en as un). Les vidéos finies (`.mp4`) et les sous-titres
(`.srt`) vont dans le sous-dossier **Export**, les projets dans **Progetti**, tes enregistrements faits dans l'app
dans **Registrazioni** ; Claude te dit où.

**Ouvre l'app Regista avant de parler à Claude** : en haut à droite elle affiche « Claude Desktop connecté » (ou Claude Code) et tu vois le
montage se faire en direct. App fermée, Claude travaille quand même, sans fenêtre.

## 6. Premiers prompts à essayer

Commence simple :

> Avec Regista, liste mes vidéos et dis-moi ce que tu peux en faire.

Un reel face caméra :

> Avec Regista, monte la vidéo X.mov en reel talking-head : choisis les meilleures prises, enlève les pauses,
> voix propre, sous-titres en français dans le style approuvé, avec mon kit de marque. Montre-moi le résultat.

Un tutoriel écran (enregistré dans l'app : **Enregistrer** → « Écran seul » ou « Écran + visage ») :

> Avec Regista, monte le tutoriel Y : l'écran en grand, mon visage dans une bulle en bas à droite, zoom automatique
> sur les clics, coupe les silences et les hésitations, voix propre, sous-titres en français, export 16:9.
> Montre-moi quelques images avant d'exporter.

Une vidéo sans personne à l'image, avec ta voix clonée (voir 7 bis) :

> Avec Regista, fais une vidéo voix off de 30 secondes avec ce texte : « … ». Ma voix en français, mes captures
> d'écran du dossier comme images, sous-titres, pas de musique. Montre-moi le résultat avant d'exporter.

Ensuite, corrige en parlant normalement : « enlève la deuxième phrase », « sous-titres plus gros »,
« le nom de ma marque est mal écrit à 0:12 ». Un montage prend plusieurs minutes ; pour tester, des vidéos de 1 à 3 minutes
suffisent.

## 7. Premiers essais

1. L'installation va jusqu'au bout et `doctor.sh` dit « Tout est en ordre ».
2. Claude Desktop (ou Claude Code) voit les outils regista.
3. « Liste mes vidéos » fonctionne.
4. Un reel face caméra **en français** : bonnes prises choisies ? pauses bien coupées ? son propre ?
   sous-titres justes et lisibles (noms propres, découpage) ? cadrage (la tête n'est pas coupée) ?
5. Un tutoriel : enregistre 1–2 minutes d'écran + caméra dans l'app, puis fais-le monter.
6. Des corrections demandées à Claude, et des retouches à la main dans l'app (niveaux **Simple** et **Pro**), puis un export.
7. Note le temps que prend chaque étape, les plantages et les messages incompréhensibles.

## 7 bis. Ta propre voix (optionnel)

Regista peut faire une voix off **avec ta voix clonée**, en local et gratuitement, sur un Mac avec 16 Go ou plus. Ton Regista arrive **sans profil
et sans aucune voix** : aucune voix d'une autre personne n'est fournie avec Regista.

1. Crée ton profil : **Réglages → Profil et voix** → ton prénom (ou demande à Claude « crée mon profil, je suis Léa »).
2. Dans l'app, panneau **Voix** → bouton d'enregistrement : la lecture guidée s'affiche sur le prompteur. Ou
   demande à Claude « enregistre ma voix en français » (ou en portugais) : il te donne le texte à lire (~30 min,
   une phrase d'accord avec ton prénom, puis 7 blocs de ton). Le mieux : ton téléphone avec un micro externe, dans
   une pièce calme ; un fichier par bloc.
3. Donne les fichiers à Claude, un par un. Après le bloc neutre, ta voix marche déjà.
4. Pour le meilleur résultat (Mac avec 32 Go ou plus) : « entraîne ma voix en français » — environ 2 h.

Ta voix reste sur ton Mac, dans ton profil. Tu peux la supprimer à tout moment dans Réglages → Profil et voix.

## 8. Limites connues

- **Interface** : l'app suit la langue du Mac, en français, italien ou anglais (le portugais arrive : en attendant
  l'app s'affiche en anglais). Elle n'est pas finie partout : le niveau **Simple** et les panneaux Graphismes et
  Générer sont encore provisoires. Ce que tu ne trouves pas à la main, demande-le à Claude.
- **Moteurs** : Réglages → Moteurs montre ce qui est installé sur ton Mac selon sa mémoire, et installe le reste.
- **Générations payantes** (images/vidéos Higgsfield) : pas installées par défaut ; même configurées, chaque
  génération doit être **approuvée par toi dans l'app Regista** et le total est **plafonné**. La génération locale
  gratuite (ComfyUI) se configure à la main et demande un Mac de 32 Go.
- **Enregistrer** l'écran, la caméra ou le micro : la première fois macOS demande les autorisations (Réglages
  Système → Confidentialité et sécurité → Caméra, Micro, Enregistrement de l'écran) ; accepte, puis quitte et rouvre
  Regista.
- **Claude Desktop** et les opérations longues (transcription d'une longue vidéo, export) : Claude peut afficher
  « timed out » alors que Regista continue de travailler. Dis-lui : « attends une minute et regarde l'état du projet ».
- Un montage complet, c'est des dizaines d'échanges avec Claude : il utilise une bonne partie de la limite d'usage
  de ton abonnement.

## 9. Mettre à jour

Installé avec la commande : relance `~/code/regista/scripts/install.sh` (il récupère la dernière version et
recompile). Installé avec le zip : décompresse un zip plus récent et double-clique sur son `INSTALLA.command`. Tes
vidéos, ce qui est déjà téléchargé et les réglages sont gardés ; la mise à jour prend quelques minutes. Ensuite quitte et rouvre Claude Desktop
et l'app Regista.

## 10. Signaler un problème

Ouvre une issue sur https://github.com/arkad-consulting/regista/issues.

Pour chaque problème : **ce que tu as demandé** (copie le prompt), **ce que tu attendais**, **ce qui s'est passé**,
des **captures d'écran** (⌘⇧4 ou ⌘⇧5), le nom et la durée de la vidéo. Joins le rapport de vérification :

```
~/code/regista/scripts/doctor.sh > ~/Desktop/regista-doctor.txt 2>&1
```

(le fichier `regista-doctor.txt` arrive sur ton Bureau). Si c'est l'installation qui a échoué, envoie une capture de la
fenêtre Terminal et le dossier `~/Library/Application Support/Regista/logs`.
