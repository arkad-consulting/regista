# Guide de Regista

Regista est un logiciel de montage vidéo pour Mac : des reels où vous parlez face caméra, des tutoriels d'écran, des
vidéos sans visage avec votre propre voix. Vous pouvez monter vous-même avec les boutons, ou demander à Claude de le
faire pour vous : chaque étape s'affiche dans la fenêtre et peut être annulée.

L'installation tient en une seule commande dans le Terminal : tout est expliqué dans
[Installation et moteurs](install.md).

## La fenêtre

- *La barre de gauche* a une icône par activité : **Accueil**, **Enregistrer**, **Médias**, **Textes et sous-titres**,
  **Audio**, **Voix**, **Graphismes**, **Générer**, **Exporter**. En bas se trouvent **Moteurs** et **Réglages**. De ⌘1 à
  ⌘9, vous ouvrez les activités dans le même ordre. Laissez le pointeur sur une icône pour voir son nom.
- *Le panneau latéral* montre le contenu de l'activité choisie. ⌃⌘S le masque et le réaffiche ; faites glisser son bord
  pour l'élargir.
- *Les onglets de projet* sont en haut, au centre. Chaque projet ouvert a son onglet ; la pastille indique s'il est
  enregistré. Le + ouvre un **Nouvel onglet**.
- *La zone centrale* change avec l'activité : dans **Accueil** vous choisissez par où commencer, dans **Enregistrer**
  vous voyez l'aperçu, dans les activités de montage vous voyez le montage, dans **Exporter** le résultat.
- *Le panneau de droite* est le même partout et a trois onglets : **Prompteur** (le texte à lire pendant
  l'enregistrement), **Claude** (chaque étape de Claude, en mots simples) et **Inspecteur** (les réglages du clip
  sélectionné). ⌥⌘I le masque.
- *La barre d'état*, tout en bas, indique la mémoire et le niveau du Mac, le volume du montage et si le projet est
  enregistré. Quand Regista travaille (une transcription, un export), **Tâches** apparaît : un clic montre
  l'avancement, **Annuler** et les erreurs éventuelles.

Chaque bouton fait une étape que vous annulez avec ⌘Z et refaites avec ⇧⌘Z, y compris les étapes de Claude.

## Votre premier reel, étape par étape

C'est le chemin le plus simple : vous enregistrez, Regista monte tout seul, vous vérifiez et vous exportez.

1. Dans **Accueil**, choisissez **Reel face caméra** puis **Ouvrir Enregistrer**. Si vous avez déjà une vidéo, choisissez
   plutôt **ou importez une vidéo** et passez à l'étape 6.
2. Dans **Enregistrer**, sous **Ce que vous enregistrez**, choisissez **Visage seul**. **Caméra** et **Micro** doivent
   être allumés. La première fois, macOS demande l'autorisation pour la caméra et le micro : acceptez.
3. Dans le panneau de droite, onglet **Prompteur**, collez votre texte : une phrase par ligne. Avec **Prompteur**
   allumé dans **Sources**, le prompteur s'ouvre et démarre avec l'enregistrement.
4. Appuyez sur **Enregistrer** (⇧⌘R) et lisez. Si vous ratez une phrase, reprenez-la : le prompteur revient au début de
   la phrase et marque une nouvelle prise. Pour finir, appuyez de nouveau sur ⇧⌘R.
5. Si **Montage automatique en fin d'enregistrement** est allumé, Regista importe la vidéo, ouvre le montage et fait le
   montage de base tout seul. Vous le suivez dans **Tâches**, dans la barre d'état.
6. Dans la barre au-dessus du montage, choisissez **Simple** (⌥⌘1). À gauche, six étapes : **Coupe et prises**,
   **Sous-titres**, **Apparence**, **Musique et sons**, **Voix**, **Graphismes**. Chacune indique si elle est faite, à
   faire ou facultative.
7. Si le montage n'est pas encore fait, appuyez sur **Tout faire** : il coupe les pauses, choisit les prises, nettoie la
   voix, ajoute les sous-titres et une lumière plus vive. Vous pouvez l'arrêter à tout moment ; relancé, il n'ajoute
   rien deux fois.
8. Ouvrez les étapes une à une et regardez le résultat dans le moniteur :
   - **Coupe et prises** : à quel point la coupe est serrée (les longues pauses disparaissent) et, pour les phrases lues
     plusieurs fois, quelle prise garder. Regista choisit la meilleure ; vous pouvez en essayer une autre.
   - **Sous-titres** : **Sous-titres dans la vidéo** allumé ou éteint, et le style : **Face caméra** (le style des reels
     validés), **Serif élégant**, **Gras + mot clé**, **Karaoké fantôme**.
   - **Apparence** : **Lumière douce** et, si vous voulez, une couleur pour toute la vidéo.
   - **Musique et sons** : **Choisir une musique…** (elle baisse toute seule quand vous parlez) et
     **Un whoosh sur les coupes**. Les deux sont facultatifs : sur Instagram, la musique tendance s'ajoute en général
     dans l'app.
   - **Voix** : **Nettoyer la voix** enlève le bruit et met la voix à −15 LUFS, le bon volume pour les réseaux.
   - **Graphismes** : un titre, le **Logo dans la vidéo**, une carte animée. Les cartes s'ajoutent à la tête de lecture :
     placez-la d'abord sur la bonne phrase.
9. Appuyez sur **Exporter le reel**. **Exporter** s'ouvre au format **Reel 9:16**. Regardez les **Vérifications**
   (durée, volume, crête, sous-titres à jour), puis appuyez sur **Exporter la vidéo…** et choisissez le nom et le
   dossier. À la fin, **Afficher dans le Finder** ouvre le dossier.

Regista retire les longues pauses et garde la meilleure prise de chaque phrase. Il ne retire pas encore les mots de
remplissage comme « euh » à l'intérieur d'une phrase : si vous en trouvez un, enlevez-le à la main dans la transcription
(voir plus bas).

## Ce qu'ajoute Pro

Choisissez **Pro** (⌥⌘2) dans la barre au-dessus du montage. Vous avez deux moniteurs, **Source** et **Programme**, et
dessous la timeline avec ses pistes : sous-titres, graphismes, prises, voix, musique et effets sonores. À gauche de la
timeline, les outils sélection (V), lame (C), texte (T) et main (H) ; à droite, l'indicateur de volume. Simple et Pro
montrent le même projet : ce que vous changez dans l'un, vous le voyez dans l'autre.

- **Médias** : les fichiers du projet. **Importer…** ajoute des vidéos, des sons et des images. Un double-clic sur un
  fichier l'affiche dans le moniteur **Source**.
- **Textes et sous-titres** a quatre onglets. **Étapes** va de la vidéo aux sous-titres une étape à la fois
  (**Transcrire**, **Script**, **Choisir les prises**, **Couper les pauses**, **Nettoyer la voix**, **Sous-titres**), ou
  tout d'un coup avec **Tout faire**. **Sous-titres** change le style et les mots clés. **Transcription** suit la tête
  de lecture : un clic sur un mot vous y amène ; sélectionnez des mots (⌥clic, ⇧clic) et retirez-les du montage avec
  ⌫. **Prises** montre chaque lecture de chaque phrase : validez celle qui est choisie ou prenez-en une autre, puis
  refaites la coupe.
- **Audio** a deux onglets. **Mix** : le volume du montage, le nettoyage de la voix, la musique
  (**Ajouter de la musique…**, son volume et de combien elle baisse sous la voix). **Effets sonores** : cherchez un son,
  écoutez-le d'un clic et placez-le à la tête de lecture.
- **Graphismes** : **Filtres**, **Ajuster**, **Effets**, **Styles**, **Motion design** et **Logo**. Chaque élément dit
  ce qu'il fait et, quand c'est possible, montre un aperçu sur votre propre image. Un clic l'applique au clip
  sélectionné ou à la tête de lecture. Un élément qui ne peut pas fonctionner pour l'instant reste visible, grisé, avec
  la raison (un titre 3D sans Blender, par exemple).
- **Générer** : une **Image** à partir d'une description, des **Clips** à partir d'une image, une **Musique**, ou
  **Zoom avant** sur un clip généré. Le générateur local (ComfyUI, gratuit) demande un Mac du niveau Pro (32 Go) et se
  prépare à part (voir [Installation et moteurs](install.md)). Le générateur dans le cloud (Higgsfield) est payant :
  vous voyez d'abord le coût, puis vous approuvez la dépense (le bouton affiche le montant) ou vous cliquez sur
  **Refuser**. Une approbation ne vaut que pour cette génération. Ce que vous générez arrive dans **Médias**.
- **Exporter** : le format (**Reel 9:16**, **Feed 4:5**, **Carré**, **Paysage**), **Sous-titres incrustés**, le
  **Débit**, les **Vérifications** et les fichiers : **Exporter la vidéo…**, **Sous-titres .srt…** et
  **Projet Shotcut…** (pour finir le montage dans Shotcut).
- **Inspecteur**, dans le panneau de droite : les réglages du clip sélectionné (temps, position, couleur, volume,
  vitesse).

### Déplacer les sous-titres et les graphismes

Sur le moniteur **Programme** (ou celui de Simple), cliquez sur un sous-titre, un titre, un sticker ou le logo : un
cadre apparaît. Faites-le glisser où vous voulez. Pendant le déplacement apparaissent des repères et, en rouge, les
zones que couvre l'interface d'Instagram. Pour la taille, tirez un coin ou utilisez le curseur qui s'affiche dessous.
Un double-clic remet l'élément à sa place. Les flèches le déplacent d'un pixel, de dix avec ⇧ ; Échap le relâche.
Chaque déplacement compte pour une seule étape de ⌘Z, et l'export le place exactement là où vous le voyez.

## Le prompteur

Le prompteur est une fenêtre que vous seul voyez : elle reste au-dessus des autres, près de la webcam, et n'apparaît
jamais dans un enregistrement d'écran ni dans un partage d'écran. Le texte s'écrit dans l'onglet **Prompteur** du
panneau de droite : chaque ligne numérotée est une phrase, donc une prise.

- **Défilement** : **Voix** (le prompteur vous écoute et avance pendant que vous lisez), **Vitesse** (il défile tout
  seul) ou **Manuel**.
- **Suit votre voix** : la langue dans laquelle vous lisez. La reconnaissance se fait sur le Mac : aucun son ne sort de
  l'ordinateur.
- **Miroir** retourne le texte pour la vitre d'un téléprompteur.
- **Je reprends** et **Stop** : les mots qui, dits à voix haute, relancent la phrase ou arrêtent l'enregistrement.
- **Afficher le prompteur**, **Écouter et suivre** et **Recommencer** permettent de l'essayer sans enregistrer.

Espace lance et arrête le défilement ; ↓ passe à la phrase suivante, ↑ reprend la phrase. Une pédale Bluetooth ou une
télécommande de présentation fonctionne sans réglage.

## Un tutoriel d'écran

1. Dans **Accueil**, choisissez **Tutoriel d'écran**, ou dans **Enregistrer** choisissez **Écran seul** ou
   **Écran + visage**.
2. Dans la ligne **Écran**, choisissez quoi enregistrer : un écran entier, une fenêtre ou **Choisir une zone…**.
   Allumez **Audio du Mac** si vous voulez le son de l'ordinateur.
3. Avec le visage allumé, dans **Visage dans la vidéo**, choisissez sa place : **Bulle**, **Côte à côte**,
   **Superposé**, **Visage**, **Détourage** ou **Écran seul**. Vous pouvez le changer pendant l'enregistrement.
4. Appuyez sur **Enregistrer** (⇧⌘R) ; ⇧⌘P met en pause. Les fenêtres de Regista et le prompteur n'apparaissent jamais
   dans la vidéo.
5. À la fin, un projet 16:9 s'ouvre avec l'écran, la caméra et le micro déjà synchronisés. Vous montez comme d'habitude,
   ou vous demandez à Claude, par exemple : « fais un zoom sur les clics ».

La première fois, macOS demande l'autorisation d'enregistrer l'écran : voir [Résolution des problèmes](troubleshooting.md).

## Marque : couleurs, polices et logo

Un kit de marque réunit les couleurs, les polices et le logo d'une marque. Dans la barre au-dessus du montage, le
bouton **Marque** montre le kit du projet : un clic ouvre la liste, un autre clic choisit le kit. Sous-titres, titres
et logo prennent ses couleurs d'un seul coup.

Les kits se créent et se modifient dans **Réglages › Kit de marque** : nom, couleurs, polices, logo et sa position.
Chaque modification s'annule avec ⌘Z. Pour transmettre un kit à quelqu'un, **Exporter…** crée un seul fichier
`.registakit` (couleurs, polices et logo dedans) ; la personne qui le reçoit utilise **Importer…** dans le même écran. Le logo se met dans la vidéo depuis **Graphismes › Logo** ou, dans Simple, depuis
l'étape **Graphismes**.

## Travailler avec Claude

Claude peut faire tout ce que font les boutons, et aussi ce qui est encore malcommode dans l'interface. Pour le
connecter, voir [Installation et moteurs](install.md). Gardez Regista ouvert : vous suivez chaque étape en direct.

Ce que vous pouvez demander, par exemple :

> Avec Regista, liste mes vidéos et dis-moi ce que tu peux en faire.

> Monte « essai.mov » en reel : les meilleures prises, sans pauses, voix nettoyée, sous-titres en français, avec mon kit
> de marque. Montre-moi quelques images avant d'exporter.

> Remonte les sous-titres. Enlève la deuxième phrase. Le nom de ma marque est mal écrit à 0:12.

- Dans l'onglet **Claude** du panneau de droite, vous lisez chaque étape de Claude, en mots simples.
- Chaque étape de Claude s'annule avec ⌘Z, comme les vôtres.
- Claude ne dépense rien tout seul : une génération payante ne part qu'après votre approbation dans l'app.
- Claude travaille sur les fichiers de Films › Regista et ne supprime ni ne modifie jamais vos originaux.

## Où vont les fichiers

Tout va dans le dossier Films › Regista (vous le changez dans **Réglages › Général**, **Dossier de Regista**) :

- `Registrazioni` : les vidéos que vous enregistrez ;
- `Progetti` : les projets (`.regista`) ;
- `Export` : les vidéos exportées, les sous-titres `.srt` et les projets Shotcut.

Avec **Enregistrement automatique** allumé, Regista enregistre chaque minute les projets qui ont déjà un dossier. Un
projet jamais enregistré, c'est vous qui l'enregistrez avec ⌘S.

Tous les raccourcis clavier sont dans **Réglages › Raccourcis**. En cas de problème, lisez
[Résolution des problèmes](troubleshooting.md) ; pour votre voix clonée, [Enregistrer votre voix](voice.md).
