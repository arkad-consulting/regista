# Installation et moteurs

## L'app téléchargée

Il faut un Mac avec puce Apple (M1 ou plus récent) et macOS 15 ou plus récent. Il ne faut ni le Terminal, ni les outils
d'Apple, ni Homebrew. Ouvrez le fichier `Regista-<version>.dmg`, faites glisser Regista sur Applications et ouvrez-le
depuis là : ouvert depuis l'image disque ou depuis Téléchargements, Regista propose de se déplacer tout seul
(**Déplacer et rouvrir**).

ffmpeg, whisper.cpp et DeepFilterNet sont déjà dans l'app : enregistrer, couper, nettoyer la voix, les graphismes et
l'export fonctionnent tout de suite. Tant qu'il manque quelque chose, l'Accueil l'affiche dans **Pour commencer**, une
ligne pour chaque chose :

- **Modèle pour transcrire et créer les sous-titres** : **Télécharger** télécharge le modèle de transcription (1,6 Go ;
  aussi depuis **Réglages › Moteurs**). Une fois le téléchargement terminé, la ligne disparaît toute seule.
- **Connectez Claude pour monter en parlant** : **Connecter…** ouvre **Réglages › Claude**. **Je n'utilise pas Claude**
  masque la ligne pour de bon : Regista fonctionne aussi sans Claude, à la main.

Pour installer depuis le code source (si vous développez Regista, ou pour une version pas encore publiée en image
disque), suivez les étapes ci-dessous.

## Ce qu'il faut

- Un Mac avec puce Apple (M1 ou plus récent) et macOS 15 ou plus récent.
- Les outils en ligne de commande d'Apple. Si vous ne les avez pas, tapez `xcode-select --install` dans le Terminal et
  attendez la fin de l'installation d'Apple. Xcode n'est pas nécessaire : quand le SDK le plus récent de ces outils
  l'exige (macOS 27), l'installation utilise le SDK précédent qu'ils contiennent et le dit ; elle ne vous demande
  d'installer Xcode que si aucun ne fonctionne.
- De l'espace libre sur le disque : environ 4 Go pour le niveau Base, 16 Go pour Moyen et Pro. La génération locale du
  niveau Pro, qui se prépare à part, en demande beaucoup plus (environ 70 Go).
- Une bonne connexion et de 20 à 40 minutes la première fois.
- Pour travailler avec Claude : Claude Desktop (https://claude.ai/download) ou Claude Code, connecté à votre compte.
  Installez-le avant Regista : l'installation le connecte alors toute seule. Regista fonctionne aussi sans Claude, à la
  main.

## Une seule commande

Quittez Claude Desktop (⌘Q), ouvrez le Terminal, collez cette ligne et appuyez sur Entrée :

```
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

L'installation vérifie le Mac, télécharge les moteurs adaptés à sa mémoire (chaque fichier a une version fixe et une
empreinte SHA-256 vérifiée), construit l'app sur votre Mac, la place dans Applications et connecte Regista à Claude
Desktop ou à Claude Code, selon ce qu'elle trouve. Elle pose quelques questions : appuyez sur Entrée pour la réponse
proposée. Si Homebrew manque, elle propose de l'installer et peut demander le mot de passe du Mac. À la fin, elle
affiche un résumé : ce qu'elle a trouvé, ce qui manque, comment démarrer.

Si quelqu'un vous a envoyé un fichier `regista-….zip`, ouvrez-le et double-cliquez sur `INSTALLA.command` : il fait la
même chose, sans Git.

Pour vérifier l'installation à tout moment :

```
~/code/regista/scripts/doctor.sh
```

La dernière ligne doit dire « Tout est en ordre ». Sinon, sous chaque problème, une ligne explique comment le corriger.

## Les niveaux

Regista choisit un niveau selon la mémoire du Mac. Chaque niveau s'ajoute au précédent.

- **Base** (8 Go) : enregistrer, couper, sous-titres, voix nettoyée, graphismes et export. C'est le reel complet.
- **Moyen** (16 Go) : des temps de mots plus précis, donc des coupes et des sous-titres plus propres ; votre voix
  clonée pour la voix off (elle utilise environ 8 Go pendant qu'elle travaille) ; les graphismes animés en HTML ; les
  titres 3D avec Blender, si vous acceptez de l'installer.
- **Pro** (32 Go et plus) : l'entraînement de votre voix (environ deux heures) et la génération locale et gratuite
  d'images, de clips et de musique avec ComfyUI. ComfyUI ne s'installe pas tout seul : il se prépare à la main, en
  suivant les étapes que montre Regista.
- **Dans le cloud**, à tous les niveaux : la génération payante avec Higgsfield. Elle est facultative, demande un
  compte, et chaque génération affiche son coût et attend votre approbation.

Shotcut, pour finir un montage hors de Regista, est proposé à tous les niveaux. Les aligneurs pour l'italien et le
français ont une licence réservée à l'usage non commercial : l'installation demande avant de les ajouter. Sans eux,
Regista transcrit quand même, avec whisper.cpp.

La liste complète, avec tailles et licences, est dans [docs/reference/engines.md](https://github.com/arkad-consulting/regista/blob/main/docs/reference/engines.md)
(en anglais).

## Installer un moteur plus tard

Ouvrez **Réglages › Moteurs** (aussi depuis l'icône **Moteurs** en bas de la barre de gauche). En haut, **Ce Mac**
indique **Mémoire**, **Niveau** et **Espace libre**. Dessous, les moteurs sont rangés par niveau, chacun avec son état :

- **Installé** ou **Inclus dans macOS** : il est prêt.
- **Installer** : Regista le télécharge et l'installe. C'est une tâche : l'avancement et **Annuler** sont dans
  **Tâches**, dans la barre d'état. Si le moteur a une licence non commerciale, Regista vous la montre d'abord.
- **Comment l'installer** : un moteur qui se prépare à la main (ComfyUI et ses modèles). Regista montre les étapes.
- **Supprimer…** : efface les fichiers du moteur, après vous avoir dit ce qui ne fonctionnera plus.

**Forcer le niveau** change le niveau : **Automatique** le choisit selon la mémoire. Un niveau plus élevé montre et
installe des moteurs qui peuvent ralentir le Mac ou s'arrêter faute de mémoire.

## Génération locale avec ComfyUI

Au niveau Pro, Regista crée des images, des clips, de la musique et des upscales sur votre Mac, gratuitement, avec
ComfyUI. Regista parle lui-même à ComfyUI, avec les workflows qu'il embarque ; ComfyUI et les fichiers de ses modèles
s'installent à la main (environ 69 Go pour les quatre modèles). **Réglages › Moteurs › ComfyUI** affiche les étapes ;
en bref :

1. Installez ComfyUI en suivant ses propres instructions (https://docs.comfy.org/installation/manual_install), dans un
   dossier avec son propre environnement Python (`.venv` ou `venv` dans ce dossier).
2. Indiquez à Regista où il se trouve : dans **Réglages › Moteurs**, sur la ligne **ComfyUI**, **Dossier de ComfyUI** ›
   **Choisir…**. Regista lance ComfyUI quand une génération en a besoin, l'indique dans la tâche pendant qu'il attend
   sa réponse, et l'arrête ensuite. Si vous lancez ComfyUI vous-même, ou utilisez son app de bureau (elle n'écoute pas
   sur 8188), indiquez plutôt son **Adresse** à cet endroit : un ComfyUI lancé par vous reste allumé ; après une
   génération, Regista lui demande seulement de libérer sa mémoire.
3. Installez le pack de nœuds ComfyUI-GGUF (https://github.com/city96/ComfyUI-GGUF) dans le dossier `custom_nodes` de
   ComfyUI, puis redémarrez ComfyUI : les clips Wan 2.2 en ont besoin.
4. Obtenez les fichiers de chaque modèle. La ligne de chaque modèle (Z-Image Turbo, Wan 2.2 image vers vidéo,
   ACE-Step 1.5, Real-ESRGAN + RIFE) liste chaque fichier avec son dossier, sa taille, sa licence et la page de l'éditeur
   et, dès que ComfyUI répond, ceux qu'il voit déjà. **Télécharger** à côté d'un fichier manquant (avec sa taille), ou
   le bouton au-dessus de plusieurs fichiers qui les télécharge tous, le place dans le dossier `models` du dossier de ComfyUI que Regista
   connaît, avec la progression et **Annuler** sur la même ligne. Un téléchargement annulé ou interrompu reprend là où
   il s'était arrêté ; le fichier est vérifié avec son sha256 avant d'être mis en place ; l'espace libre est vérifié
   d'abord (les fichiers plus 2 Go). Un fichier déjà là avec la bonne taille n'est pas téléchargé à nouveau, et un
   fichier d'une autre taille n'est jamais écrasé. Regista télécharge seulement dans un dossier de ComfyUI qu'il connaît
   (celui que vous avez choisi, ou un dossier trouvé aux emplacements habituels ci-dessous) : si un programme démarre
   ComfyUI, ou si seule son adresse est indiquée, choisissez son dossier pour avoir les boutons, ou téléchargez chaque
   fichier depuis la page de l'éditeur dans le dossier indiqué. Claude peut faire de même avec `generate.fetch`, après
   vous avoir dit la taille. Redémarrez ensuite ComfyUI pour qu'il voie les nouveaux fichiers.
5. Vérifiez : **Vérifier à nouveau** sur la ligne, ou demandez à Claude `generate.check`.

Sans dossier indiqué et sans réponse à l'adresse, Regista cherche un dossier de ComfyUI (avec son environnement Python)
à ces endroits, dans cet ordre : `~/ComfyUI`, `~/comfy/ComfyUI`, `~/Documents/ComfyUI`, `~/Developer/ComfyUI`,
`~/Projects/ComfyUI`, `~/src/ComfyUI`, `~/git/ComfyUI`, `/Applications/ComfyUI`. La ligne indique celui qu'il a trouvé ;
rien n'est écrit dans vos réglages tant que vous ne choisissez pas un dossier.

## Connecter Claude

Ouvrez **Réglages › Claude**.

- **Connexion** indique si un Claude est connecté à l'app en ce moment.
- Sous **Claude Desktop**, appuyez sur **Connecter Claude Desktop…**. Regista vous dit ce qu'il ajoute à la
  configuration de Claude (il garde tout le reste et fait d'abord une copie de sauvegarde) ; confirmez avec
  **Connecter**. Ensuite, quittez complètement Claude Desktop (⌘Q) et rouvrez-le.
- Sous **Claude Code**, appuyez sur **Connecter Claude Code…**, confirmez et ouvrez une nouvelle session de Claude
  Code.
- Si une ligne indique **Connecté à une autre copie de Regista**, appuyez sur **Pointer vers cette app…** : Claude
  utilisait une autre copie de l'app et risque de ne pas connaître les nouvelles commandes.
- **Copier les instructions** copie un texte à coller dans les instructions d'un projet Claude Desktop : toutes les
  conversations de ce projet sauront travailler avec Regista.

La première fois que Claude utilise Regista, Claude Desktop demande l'autorisation : choisissez de toujours
l'autoriser, sinon il la redemande à chaque étape. Ouvrez Regista avant de parler à Claude, pour suivre le travail en
direct.

## Mettre à jour

Relancez la commande d'installation, ou :

```
~/code/regista/scripts/install.sh
```

Elle récupère la dernière version et reconstruit l'app. Vos projets, vos réglages, les moteurs déjà téléchargés et votre
voix restent tels quels. Si vous avez installé avec un fichier zip, ouvrez un zip plus récent et double-cliquez sur son
`INSTALLA.command`. Après la mise à jour, quittez et rouvrez Regista et Claude Desktop.

En cas de problème pendant l'installation, voir [Résolution des problèmes](troubleshooting.md).
