# Risoluzione dei problemi

## Un pulsante o una voce è grigia

Regista non nasconde niente: una funzione che ora non può partire resta visibile, grigia, e accanto o sotto c'è il
motivo. I casi più comuni:

- *Manca un motore.* Per esempio «Manca il motore che trascrive il parlato: si installa da Impostazioni › Motori.» o
  «Serve Blender: si installa da Impostazioni › Motori.». Premi **Installa…** quando c'è, oppure apri
  **Impostazioni › Motori** e installalo da lì (vedi [Installazione e motori](install.md)).
- *Il Mac ha poca memoria per quella funzione.* Per esempio «Serve il livello Pro» o «La voce clonata richiede un Mac
  con almeno 16 GB di RAM». La voce clonata chiede il livello Medio (16 GB), l'allenamento della voce e la generazione
  locale il livello Pro (32 GB).
- *Manca un passo prima.* Per esempio «Prima serve la trascrizione.» o «Prima metti il video in timeline: taglia le
  pause.». Fai prima il passo indicato: in Semplice ogni passo dice anche qual è il prossimo.
- *Non c'è un progetto aperto.* Molti pulsanti chiedono un video nel progetto: in **Inizio** apri un progetto o
  importane uno.
- *La generazione non ha un generatore pronto.* In **Genera**, ogni generatore grigio dice perché: ComfyUI non
  installato o non pronto (mancano file del modello o nodi), Higgsfield senza un account collegato. Il generatore
  locale va preparato a mano: **Impostazioni › Motori**, **Come installarlo**.

## Un motore manca o non funziona

1. Apri **Impostazioni › Motori** e guarda lo stato del motore. Se c'è **Installa**, premilo e segui l'avanzamento in
   **Lavori**.
2. Se l'installazione non riesce, il lavoro dice «Installazione non riuscita» e il motivo. Controlla lo spazio
   libero e la connessione, poi riprova.
3. Nel Terminale, `~/code/regista/scripts/doctor.sh` controlla tutta l'installazione e dice come sistemare ogni
   problema.
4. Se non basta, rilancia l'installazione: `~/code/regista/scripts/install.sh`. Quello che è già installato e verificato
   resta com'è.

## Permessi: camera, microfono, schermo

macOS chiede il permesso la prima volta che Regista usa la camera, il microfono o lo schermo. Se hai rifiutato, o se il
permesso non vale ancora:

- In **Registra** la riga della sorgente dice che manca il permesso di macOS. Premi **Consenti…**: si apre
  Impostazioni di Sistema › Privacy e sicurezza, dove consenti Regista.
- **Camera** e **Microfono**: Privacy e sicurezza › Videocamera e Microfono, attiva Regista.
- **Schermo** (e **Audio del Mac**): Privacy e sicurezza › Registrazione schermo e audio di sistema, attiva Regista.
  Poi chiudi e riapri Regista: in **Registra** c'è **Riapri Regista**. Il permesso vale solo da quel momento; finché
  non vale, Regista dice **Registrazione dello schermo non ancora attiva**.
- **Tasti premuti nel video** (nei tutorial): serve anche Privacy e sicurezza › Accessibilità. Clic e cursore non ne
  hanno bisogno.
- **Gobbo** che segue la voce: usa il permesso del microfono; su macOS 15 serve anche il Riconoscimento vocale.

Un aggiornamento di Regista non dovrebbe chiedere di nuovo i permessi. Se succede, consentili di nuovo e riapri l'app.

## «Claude non collegato»

La scheda **Claude** del pannello destro, e la barra in alto, dicono **Claude non collegato** finché Claude non usa
Regista. Questo è normale finché non gli chiedi qualcosa. Se Claude non trova Regista:

1. Apri **Impostazioni › Claude**. Sotto **Claude Desktop** (o **Claude Code**) deve esserci
   **Collegato a questa app**. Se c'è **Non collegato**, premi **Collega Claude Desktop…** (o
   **Collega Claude Code…**). Se c'è **Collegato a un'altra copia di Regista**, premi **Ricollega a questa app…**.
2. Chiudi Claude Desktop del tutto (⌘Q, non solo la finestra) e riaprilo. Per Claude Code, apri una nuova sessione.
3. In Claude Desktop, nelle impostazioni dello sviluppatore, la voce «regista» deve risultare attiva.
4. Apri Regista, poi chiedi a Claude, per esempio: «Con Regista, elenca i miei video».

Claude lavora ma non vedi niente nella finestra? Regista era chiuso quando Claude l'ha usato la prima volta: in quel
caso Claude lavora senza finestra e salva il progetto, che poi apri da **Inizio**. Per vederlo in diretta, apri Regista
e poi chiudi e riapri Claude Desktop (o apri una nuova sessione di Claude Code).

Se Claude dice «timed out» durante un lavoro lungo (una trascrizione, un export), Regista sta ancora lavorando. Chiedigli
di aspettare un minuto e di guardare lo stato del progetto, senza ricominciare da capo.

## Un lavoro non riesce

Trascrizioni, pulizia della voce, export, installazioni e generazioni sono lavori. Li trovi in **Lavori**, nella barra di
stato: ognuno ha l'avanzamento e **Annulla**. Un lavoro che non riesce lascia il progetto com'era e dice il motivo in
parole semplici; un lavoro annullato dice **Annullato: niente è stato modificato.**. Leggi il motivo, sistema la causa
(un motore, lo spazio libero, un file spostato) e rilancialo. **Togli dalla lista** toglie la riga.

Anche un comando che non riesce, tuo o di Claude, non cambia niente: puoi riprovare senza danni.

## Dove sono i log

- Installazione: `~/Library/Application Support/Regista/logs` (un file per passo che può fallire).
- Il collegamento con Claude Desktop: `~/Library/Logs/Claude/mcp-server-regista.log`, scritto da Claude Desktop.
- Il controllo completo, da allegare a una segnalazione: nel Terminale,
  `~/code/regista/scripts/doctor.sh > ~/Desktop/regista-doctor.txt 2>&1` crea il file `regista-doctor.txt` sulla
  Scrivania.

## Segnalare un problema

Dal menu **Aiuto**, **Segnala un problema…** apre la pagina pubblica delle segnalazioni:
https://github.com/arkad-consulting/regista/issues. Scrivi:

- cosa hai fatto o chiesto (copia la richiesta a Claude, se c'è);
- cosa ti aspettavi e cosa è successo;
- un'immagine dello schermo (⇧⌘4 o ⇧⌘5) e la durata del video;
- il file `regista-doctor.txt`, se il problema riguarda l'installazione o un motore.

La pagina è pubblica: non allegare video, voci o dati che non vuoi mostrare.
