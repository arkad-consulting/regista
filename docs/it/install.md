# Installazione e motori

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

## Da un'immagine disco

Quando una versione è pubblicata come `Regista-<versione>.dmg`, non servono né il Terminale né gli strumenti di Apple
né Homebrew: apri il file, trascina Regista su Applicazioni e aprilo da lì (aperto dall'immagine o da Download, Regista
propone di spostarsi da solo). Poi, in Regista › Impostazioni › Motori, installa il modello di trascrizione (1,6 GB):
ffmpeg, whisper.cpp e DeepFilterNet sono già nell'app. Collega Claude in Impostazioni › Claude.

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
