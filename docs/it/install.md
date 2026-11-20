# Installazione e motori

## L'app scaricata

Serve un Mac con chip Apple (M1 o successivo) e macOS 15 o successivo. Non servono né il Terminale né gli strumenti di
Apple né Homebrew. Apri il file `Regista-<versione>.dmg`, trascina Regista su Applicazioni e aprilo da lì: aperto
dall'immagine disco o da Download, Regista propone di spostarsi da solo (**Sposta e riapri**).

Nell'app ci sono già ffmpeg, whisper.cpp e DeepFilterNet: registrare, tagliare, pulire la voce, la grafica e l'export
funzionano subito. Finché manca qualcosa, Inizio lo mostra in **Per cominciare**, una riga per ogni cosa:

- **Modello per trascrivere e fare i sottotitoli**: **Scarica** scarica il modello di trascrizione (1,6 GB; anche da
  **Impostazioni › Motori**). A download finito la riga sparisce da sola.
- **Collega Claude per montare parlando**: **Collega…** apre **Impostazioni › Claude**. **Non uso Claude** nasconde la riga
  per sempre: Regista funziona anche senza Claude, a mano.

Per installare dal codice sorgente (chi sviluppa Regista, o una versione non ancora pubblicata come immagine disco)
segui i passi qui sotto.

## Cosa serve

- Un Mac con chip Apple (M1 o successivo) e macOS 15 o successivo.
- Gli strumenti da riga di comando di Apple. Se non li hai, scrivi `xcode-select --install` nel Terminale e aspetta
  che l'installazione di Apple finisca.
- Spazio libero sul disco: circa 4 GB per il livello Base, 16 GB per Medio e Pro. La generazione locale del livello Pro,
  che si prepara a parte, ne chiede molti di più (circa 70 GB).
- Una buona connessione e da 20 a 40 minuti la prima volta.
- Per lavorare con Claude: Claude Desktop (https://claude.ai/download) o Claude Code, collegato al tuo account.
  Installalo prima di Regista, così l'installazione lo collega da sola. Regista funziona anche senza Claude, a mano.

## Un solo comando

Chiudi Claude Desktop (⌘Q), apri il Terminale, incolla questa riga e premi Invio:

```
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

L'installazione controlla il Mac, scarica i motori adatti alla sua memoria (ogni file ha una versione fissa e una firma
SHA-256 verificata), costruisce l'app sul tuo Mac, la mette in Applicazioni e collega Regista a Claude Desktop o a
Claude Code, quelli che trova. Fa qualche domanda: premi Invio per la risposta proposta. Se manca Homebrew, propone di
installarlo e può chiedere la password del Mac. Alla fine stampa un riepilogo: cosa ha trovato, cosa manca, come partire.

Se qualcuno ti ha mandato un file `regista-….zip`, aprilo e fai doppio clic su `INSTALLA.command`: fa la stessa cosa,
senza Git.

Per controllare l'installazione in qualsiasi momento:

```
~/code/regista/scripts/doctor.sh
```

L'ultima riga deve dire «Tutto a posto». Altrimenti, sotto ogni problema c'è una riga che dice come risolverlo.

## I livelli

Regista sceglie un livello dalla memoria del Mac. Ogni livello aggiunge qualcosa al precedente.

- **Base** (8 GB): registrare, tagliare, sottotitoli, voce pulita, grafica ed export. È il reel completo.
- **Medio** (16 GB): tempi delle parole più precisi, quindi tagli e sottotitoli più puliti; la tua voce clonata per la
  voce fuori campo (mentre lavora usa circa 8 GB); la grafica animata in HTML; i titoli 3D con Blender, se accetti di
  installarlo.
- **Pro** (32 GB e più): l'allenamento della tua voce (circa due ore) e la generazione locale e gratuita di immagini,
  clip e musica con ComfyUI. ComfyUI non si installa da solo: si prepara a mano, seguendo i passi che Regista mostra.
- **Nel cloud**, a ogni livello: la generazione a pagamento con Higgsfield. È facoltativa, serve un account, e ogni
  generazione mostra il costo e aspetta la tua approvazione.

Shotcut, per finire un montaggio fuori da Regista, viene proposto a ogni livello. Gli allineatori per l'italiano e il
francese hanno una licenza solo per uso non commerciale: l'installazione chiede prima di metterli. Senza di loro Regista
trascrive comunque, con whisper.cpp.

L'elenco completo, con dimensioni e licenze, è in [docs/reference/engines.md](https://github.com/arkad-consulting/regista/blob/main/docs/reference/engines.md).

## Installare un motore dopo

Apri **Impostazioni › Motori** (anche dall'icona **Motori** in basso nella barra a sinistra). In cima, **Questo Mac**
dice **Memoria**, **Livello** e **Spazio libero**. Sotto, i motori sono divisi per livello, ognuno con il suo stato:

- **Installato** o **Incluso in macOS**: è pronto.
- **Installa**: Regista lo scarica e lo installa. È un lavoro: l'avanzamento e **Annulla** sono in **Lavori**, nella
  barra di stato. Se il motore ha una licenza non commerciale, Regista te la mostra prima.
- **Come installarlo**: un motore che si prepara a mano (ComfyUI e i suoi modelli). Regista mostra i passi.
- **Rimuovi…**: cancella i file del motore, dopo averti detto cosa smette di funzionare.

**Forza livello** cambia il livello: **Automatico** lo sceglie dalla memoria. Un livello più alto mostra e installa
motori che possono rallentare il Mac o fermarsi per mancanza di memoria.

## Generazione in locale con ComfyUI

Sul livello Pro Regista crea immagini, clip, musica e upscale sul tuo Mac, gratis, con ComfyUI. Regista parla con
ComfyUI da sé, con i workflow che porta con sé; ComfyUI e i file dei suoi modelli si preparano a mano (circa 69 GB per i
quattro modelli). **Impostazioni › Motori › ComfyUI** mostra i passi; in breve:

1. Installa ComfyUI seguendo le sue istruzioni (https://docs.comfy.org/installation/manual_install), in una cartella con
   il suo ambiente Python (`.venv` o `venv` dentro quella cartella).
2. Di' a Regista dov'è: in **Impostazioni › Motori**, sulla riga **ComfyUI**, **Cartella di ComfyUI** › **Scegli…**.
   Regista avvia ComfyUI quando una generazione ne ha bisogno, lo dice nel lavoro mentre aspetta che risponda, e lo ferma
   dopo. Se avvii ComfyUI da te, o usi la sua app desktop (non ascolta sulla 8188), imposta lì invece il suo
   **Indirizzo**: un ComfyUI avviato da te resta acceso; dopo una generazione Regista gli chiede solo di liberare la
   memoria.
3. Installa il pacchetto di nodi ComfyUI-GGUF (https://github.com/city96/ComfyUI-GGUF) nella cartella `custom_nodes` di
   ComfyUI, poi riavvia ComfyUI: serve alle clip di Wan 2.2.
4. Procurati i file di ogni modello. La riga di ogni modello (Z-Image Turbo, Wan 2.2 image-to-video, ACE-Step 1.5,
   Real-ESRGAN + RIFE) elenca ogni file con la cartella, la dimensione, la licenza e la pagina dell'editore e, quando
   ComfyUI risponde, quali vede già. **Scarica** accanto a un file che manca (con la sua dimensione), o il pulsante sopra a più file che li
   scarica tutti, lo mette nella cartella `models` della cartella di ComfyUI che Regista conosce, con l'avanzamento e
   **Annulla** sulla stessa riga. Un download annullato o interrotto riprende da dove si era fermato; il file è
   controllato con il suo sha256 prima di essere messo al suo posto; prima Regista controlla lo spazio libero (i file
   più 2 GB). Un file che c'è già con la dimensione giusta non viene riscaricato, e uno di un'altra dimensione non viene
   mai sovrascritto. Regista scarica solo in una cartella di ComfyUI che conosce (quella che hai scelto, o una trovata
   nei posti consueti qui sotto): se ComfyUI lo avvia un programma, o c'è solo il suo indirizzo, scegli la sua cartella
   per avere i pulsanti, oppure scarica ogni file dalla pagina dell'editore nella cartella indicata. Claude può fare lo
   stesso con `generate.fetch`, dopo averti detto la dimensione. Poi riavvia ComfyUI perché veda i nuovi file.
5. Controlla: **Controlla di nuovo** sulla riga, oppure chiedi a Claude `generate.check`.

Senza una cartella impostata e senza nulla che risponda all'indirizzo, Regista cerca una cartella di ComfyUI (con il
suo ambiente Python) in questi posti, in quest'ordine: `~/ComfyUI`, `~/comfy/ComfyUI`, `~/Documents/ComfyUI`,
`~/Developer/ComfyUI`, `~/Projects/ComfyUI`, `~/src/ComfyUI`, `~/git/ComfyUI`, `/Applications/ComfyUI`. La riga dice
quale ha trovato; nelle tue impostazioni non viene scritto nulla finché non scegli una cartella.

## Collegare Claude

Apri **Impostazioni › Claude**.

- **Collegamento** dice se in questo momento c'è un Claude collegato all'app.
- Sotto **Claude Desktop**, premi **Collega Claude Desktop…**. Regista ti dice cosa aggiunge alla configurazione di
  Claude (tiene tutto il resto e fa prima una copia di sicurezza); conferma con **Collega**. Poi chiudi Claude Desktop
  del tutto (⌘Q) e riaprilo.
- Sotto **Claude Code**, premi **Collega Claude Code…**, conferma e apri una nuova sessione di Claude Code.
- Se una riga dice **Collegato a un'altra copia di Regista**, premi **Ricollega a questa app…**: Claude usava un'altra
  copia dell'app e potrebbe non conoscere i comandi nuovi.
- **Copia le istruzioni** copia un testo da incollare nelle istruzioni di un progetto di Claude Desktop: tutte le
  conversazioni di quel progetto sapranno come lavorare con Regista.

La prima volta che Claude usa Regista, Claude Desktop chiede il permesso: scegli di consentirlo sempre, altrimenti lo
chiede a ogni passo. Apri Regista prima di parlare con Claude, così vedi il lavoro in diretta.

## Aggiornare

Rilancia lo stesso comando dell'installazione, oppure:

```
~/code/regista/scripts/install.sh
```

Scarica l'ultima versione e ricostruisce l'app. I tuoi progetti, le impostazioni, i motori già scaricati e la tua voce
restano come sono. Se hai installato con il file zip, apri uno zip più recente e fai doppio clic sul suo
`INSTALLA.command`. Dopo l'aggiornamento chiudi e riapri Regista e Claude Desktop.

Se qualcosa non va durante l'installazione, vedi [Risoluzione dei problemi](troubleshooting.md).
