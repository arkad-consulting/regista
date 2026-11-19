# Installation et moteurs

## Ce qu'il faut

- Un Mac avec puce Apple (M1 ou plus récent) et macOS 15 ou plus récent.
- Les outils en ligne de commande d'Apple. Si vous ne les avez pas, tapez `xcode-select --install` dans le Terminal et
  attendez la fin de l'installation d'Apple.
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

## Depuis une image disque

Quand une version est publiée sous la forme `Regista-<version>.dmg`, il ne faut ni le Terminal, ni les outils d'Apple,
ni Homebrew : ouvrez le fichier, faites glisser Regista sur Applications et ouvrez-le depuis là (ouvert depuis l'image
ou depuis Téléchargements, Regista propose de se déplacer tout seul). Puis, dans Regista › Réglages › Moteurs, installez
le modèle de transcription (1,6 Go) : ffmpeg, whisper.cpp et DeepFilterNet sont déjà dans l'app. Connectez Claude dans
Réglages › Claude.

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
