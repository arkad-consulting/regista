# Guida di Regista

Regista è un programma per montare video sul Mac: reel in cui parli alla camera, tutorial dello schermo, video senza
volto con la tua voce. Puoi montare da solo con i pulsanti, oppure chiedere a Claude di farlo per te: vedi ogni passo
nella finestra e puoi annullarlo.

Si installa con un solo comando nel Terminale: trovi tutto in [Installazione e motori](install.md).

## La finestra

- *La barra a sinistra* ha un'icona per ogni attività: **Inizio**, **Registra**, **Media**, **Testi e sottotitoli**,
  **Audio**, **Voce**, **Grafica**, **Genera**, **Esporta**. In basso ci sono **Motori** e **Impostazioni**. Da ⌘1 a ⌘9
  apri le attività nello stesso ordine. Se tieni il puntatore su un'icona, compare il suo nome.
- *Il pannello laterale* mostra il contenuto dell'attività scelta. Lo nascondi e lo riapri con ⌃⌘S; per allargarlo,
  trascina il bordo.
- *Le schede dei progetti* stanno in alto, al centro. Ogni progetto aperto ha la sua scheda; il pallino dice se è
  salvato. Il + apre una **Nuova scheda**.
- *L'area centrale* cambia con l'attività: in **Inizio** scegli da dove partire, in **Registra** vedi l'anteprima,
  nelle attività di montaggio vedi il montaggio, in **Esporta** il risultato.
- *Il pannello destro* ha le schede **Claude** (ogni passo di Claude, in parole semplici) e **Ispettore** (le
  regolazioni della clip selezionata); in **Registra** c'è anche **Gobbo** (il testo da leggere mentre registri). Lo nascondi con
  ⌥⌘I.
- *La barra di stato*, in fondo, dice la memoria e il livello del Mac, il volume del montaggio e se il progetto è
  salvato. Quando Regista lavora (una trascrizione, un export) compare **Lavori**: un clic mostra l'avanzamento,
  **Annulla** e gli eventuali errori.

Ogni pulsante fa un passo che puoi annullare con ⌘Z e ripetere con ⇧⌘Z, anche i passi fatti da Claude.

## Il primo reel, passo per passo

Questo è il percorso più semplice: registri, Regista monta da solo, tu controlli ed esporti.

1. In **Inizio** scegli **Reel parlato** e poi **Apri Registra**. Se hai già un video girato, scegli invece
   **o importa un video** e salta al punto 6.
2. In **Registra**, sotto **Cosa registri**, scegli **Solo volto**. **Camera** e **Microfono** devono essere accesi.
   La prima volta macOS chiede il permesso per la camera e il microfono: consentilo.
3. Nel pannello destro, scheda **Gobbo**, incolla il testo: una frase per riga. Con **Gobbo** acceso in **Sorgenti**,
   il gobbo si apre e parte insieme alla registrazione.
4. Premi **Registra** (⇧⌘R) e leggi. Se sbagli una frase, ricominciala: il gobbo torna all'inizio della frase e segna
   una nuova ripresa. Per finire premi di nuovo ⇧⌘R.
5. A fine registrazione resti in **Registra**: la ripresa va nel progetto della scheda e puoi registrarne un'altra,
   che si aggiunge allo stesso progetto. L'avviso in alto dice dove è andata e quante riprese ha il progetto; **Vai al
   montaggio** apre il montaggio con la ripresa. Se accendi **Montaggio automatico a fine registrazione** (è spento di
   base), Regista apre il montaggio e fa da solo il montaggio di base. Lo vedi in **Lavori**, nella barra di stato.
6. Nella barra sopra il montaggio scegli **Semplice** (⌥⌘1). A sinistra trovi sei passi: **Taglio e riprese**,
   **Sottotitoli**, **Aspetto**, **Musica e suoni**, **Voce**, **Grafica**. Ognuno dice se è fatto, da fare o
   facoltativo.
7. Se il montaggio non è ancora fatto, premi **Fai tutto**: taglia le pause, sceglie le riprese, pulisce la voce, mette
   i sottotitoli e una luce più viva. Puoi fermarlo quando vuoi; se lo rilanci, non aggiunge niente due volte.
8. Apri i passi uno per uno e guarda il risultato nel monitor:
   - **Taglio e riprese**: quanto stretto è il taglio (le pause lunghe spariscono) e, per le frasi lette più volte, quale
     ripresa tenere. Regista sceglie la migliore; puoi provarne un'altra.
   - **Sottotitoli**: **Sottotitoli nel video** acceso o spento e lo stile: **Talking head** (lo stile dei reel
     approvati), **Serif elegante**, **Bold + parola chiave**, **Karaoke fantasma**.
   - **Aspetto**: **Luce leggera** e, se vuoi, un colore per tutto il video.
   - **Musica e suoni**: **Scegli una musica…** (si abbassa da sola quando parli) e **Un whoosh sui tagli**. Sono
     facoltativi: su Instagram la musica di tendenza si aggiunge di solito nell'app.
   - **Voce**: **Pulisci la voce** toglie il rumore e porta la voce a −15 LUFS, il volume giusto per i social.
   - **Grafica**: un titolo, il **Logo nel video**, una scheda animata. Le schede si aggiungono alla testina: spostala
     prima sulla frase giusta.
9. Premi **Esporta il reel**. Si apre **Esporta** con il formato **Reel 9:16**. Guarda i **Controlli** (durata, volume,
   picco, sottotitoli aggiornati), poi premi **Esporta video…**, scegli il nome e la cartella. Alla fine
   **Mostra nel Finder** apre la cartella.

Regista toglie le pause lunghe e tiene la ripresa migliore di ogni frase. Non toglie ancora gli intercalari come «ehm»
dentro una frase: se ne trovi uno, toglilo a mano dalla trascrizione (vedi più sotto).

Con Claude: chiedigli di togliere gli intercalari. Ti dice quante esitazioni («ehm») ha trovato e quanti secondi
toglierebbe, le toglie se sei d'accordo, e parole come «allora» o «cioè» solo quelle che gli indichi. Spesso la
trascrizione non scrive le esitazioni: restano una pausa, e il taglio delle pause lunghe di solito le toglie.

## Cosa aggiunge Pro

Scegli **Pro** (⌥⌘2) nella barra sopra il montaggio. Vedi due monitor, **Sorgente** e **Programma**, e sotto la
timeline con le piste: sottotitoli, grafica, riprese, voce, musica ed effetti sonori. A sinistra della timeline ci sono
gli strumenti selezione (V), lama (C), testo (T) e mano (H); a destra il misuratore del volume. Semplice e Pro mostrano
lo stesso progetto: quello che cambi in uno lo vedi nell'altro.

- **Media**: i file del progetto. **Importa…** aggiunge video, audio e immagini. Doppio clic su un file per vederlo
  nel monitor **Sorgente**.
- **Testi e sottotitoli** ha quattro schede. **Passi** fa il percorso dal video ai sottotitoli un passo alla volta
  (**Trascrivi**, **Copione**, **Scegli le riprese**, **Taglia le pause**, **Pulisci la voce**, **Sottotitoli**), oppure
  tutto insieme con **Fai tutto**. **Sottotitoli** cambia stile e parole chiave. **Trascrizione** segue la testina: un
  clic su una parola ti porta lì; selezioni delle parole (⌥clic, ⇧clic) e le togli dal montaggio con ⌫. **Riprese**
  mostra le letture di ogni frase: approvi quella scelta o ne scegli un'altra, poi rifai il taglio.
- **Audio** ha due schede. **Mix**: il volume del montaggio, la pulizia della voce, la musica (**Aggiungi musica…**, il
  volume e quanto si abbassa sotto la voce). **Effetti sonori**: cerchi un suono, lo ascolti con un clic e lo metti alla
  testina.
- **Grafica**: **Filtri**, **Regola**, **Effetti**, **Stili**, **Motion** e **Logo**. Ogni voce dice cosa fa e, dove
  si può, mostra un'anteprima sul tuo fotogramma. Un clic la applica alla clip selezionata o alla testina. Una voce che
  ora non può funzionare resta visibile, grigia, con il motivo (per esempio un titolo 3D senza Blender).
- **Genera**: un'**Immagine** da una descrizione, una **Clip** da un fotogramma, una **Musica**, oppure **Ingrandisci**
  una clip generata. Il generatore locale (ComfyUI, gratis) chiede un Mac del livello Pro (32 GB) e va preparato a parte (vedi
  [Installazione e motori](install.md)). Il generatore nel cloud (Higgsfield) è a pagamento: prima vedi il costo, poi
  approvi la spesa (il pulsante mostra la cifra) oppure **Rifiuta**. L'approvazione vale solo per quella generazione. Quello che generi
  finisce in **Media**.
- **Esporta**: il formato (**Reel 9:16**, **Feed 4:5**, **Quadrato**, **Orizzontale**), **Sottotitoli impressi**, il
  **Bit rate**, i **Controlli** e i file: **Esporta video…**, **Sottotitoli .srt…** e **Progetto Shotcut…** (per finire
  il montaggio in Shotcut).
- **Copertina**, in **Esporta** (solo per i video verticali 9:16): porta la testina sul fotogramma giusto e premi
  **Usa questo fotogramma**, scrivi il titolo (3–5 parole) e scegli dove sta: **In alto**, **Al centro** o **In basso**.
  Le due cornici tratteggiate sono i ritagli della griglia di Instagram (3:4) e dello scaffale degli Shorts (2:3): se il
  titolo ne esce, sotto c'è scritto di quanti pixel e cosa scegliere. **Salva copertina…** scrive il PNG da caricare
  come copertina. La copertina non ha sottotitoli; carattere e colori del titolo vengono dal kit della **Marca**.
- **Ispettore**, nel pannello destro: le regolazioni della clip selezionata (tempi, posizione, colore, volume,
  velocità).

### Spostare sottotitoli e grafica

Nel monitor **Programma** (o nel monitor di Semplice) clicchi un sottotitolo, un titolo, uno sticker o il logo: compare
una cornice. Trascinalo dove vuoi. Mentre trascini compaiono le guide e, in rosso, le zone coperte dall'interfaccia di
Instagram. Per la misura trascina un angolo o usa il cursore che compare sotto. Doppio clic rimette l'elemento al suo
posto. Le frecce lo spostano di un pixel, con ⇧ di dieci; Esc lo lascia. Ogni spostamento è un solo passo di ⌘Z, e
l'export lo mette esattamente dove lo vedi.

## Il gobbo

Il gobbo è una finestra che vedi solo tu: sta sopra le altre, vicino alla webcam, e non compare mai in una registrazione
dello schermo né in una condivisione. Il testo lo scrivi nella scheda **Gobbo** del pannello destro: ogni riga numerata
è una frase, cioè una ripresa.

- **Scorrimento**: **Voce** (il gobbo ti ascolta e avanza mentre leggi), **Velocità** (scorre da solo) o **Manuale**.
- **Segue la voce**: la lingua in cui leggi. Il riconoscimento avviene sul Mac: nessun audio esce dal computer.
- **Specchiato** capovolge il testo per il vetro di un teleprompter.
- **Rifaccio** e **Stop**: le parole che, dette ad alta voce, ricominciano la frase o fermano la registrazione.
- **Mostra il gobbo**, **Ascolta e segui** e **Ricomincia** lo provano senza registrare.

Spazio avvia e ferma lo scorrimento; ↓ passa alla frase dopo, ↑ ricomincia la frase. Un pedale Bluetooth o un
telecomando da presentazione funzionano senza configurarli.

## Un tutorial dello schermo

1. In **Inizio** scegli **Tutorial dello schermo**, oppure in **Registra** scegli **Solo schermo** o
   **Schermo + volto**.
2. Nella riga **Schermo** scegli cosa registrare: uno schermo intero, una finestra o **Scegli un'area…**. Accendi
   **Audio del Mac** se serve il suono del computer.
3. Con il volto acceso, in **Volto nel video** scegli dove va: **Bolla**, **Affiancati**, **Verticale**, **Volto**,
   **Ritaglio** o **Solo schermo**. Puoi cambiarlo anche mentre registri.
4. Premi **Registra** (⇧⌘R); ⇧⌘P mette in pausa. Le finestre di Regista e il gobbo non finiscono nel video.
5. Alla fine si apre un progetto 16:9 con lo schermo, la camera e il microfono già sincronizzati. Da lì monti come
   sempre, oppure chiedi a Claude, per esempio: «fai lo zoom sui clic».

La prima volta macOS chiede il permesso di registrare lo schermo: vedi [Risoluzione dei problemi](troubleshooting.md).

## Marca: colori, caratteri e logo

Un brand kit raccoglie i colori, i caratteri e il logo di un marchio. Nella barra sopra il montaggio, il pulsante
**Marca** mostra il kit del progetto: un clic apre l'elenco e un altro clic sceglie il kit. Sottotitoli, titoli e logo
prendono i suoi colori in un colpo solo.

I kit si creano e si modificano in **Impostazioni › Brand kit**: nome, colori, caratteri, logo e la sua posizione. Ogni
modifica si annulla con ⌘Z. Per passare un kit a un'altra persona, **Esporta…** crea un solo file `.registakit`
(colori, caratteri e logo dentro); chi lo riceve usa **Importa…** nella stessa schermata. Il logo nel video si mette da **Grafica › Logo** oppure, in Semplice, dal passo **Grafica**.

## Lavorare con Claude

Claude può fare tutto quello che fanno i pulsanti, e anche le cose che nell'interfaccia sono ancora scomode. Per
collegarlo vedi [Installazione e motori](install.md). Tieni Regista aperto: così vedi ogni passo in diretta.

Cosa puoi chiedere, per esempio:

> Con Regista, elenca i miei video e dimmi cosa puoi farci.

> Monta il video «prova.mov» come reel: le riprese migliori, senza pause, voce pulita, sottotitoli in italiano, con il
> mio brand kit. Fammi vedere qualche fotogramma prima di esportare.

> Sposta i sottotitoli più in alto. Togli la seconda frase. Il nome del mio marchio è scritto male a 0:12.

- Nella scheda **Claude** del pannello destro leggi ogni passo che Claude fa, in parole semplici.
- Ogni passo di Claude si annulla con ⌘Z, come i tuoi.
- Claude non spende niente da solo: una generazione a pagamento parte solo dopo la tua approvazione nell'app.
- Claude lavora sui file di Filmati › Regista e non cancella né modifica i tuoi originali.

## Dove finiscono i file

Tutto va nella cartella Filmati › Regista (la cambi in **Impostazioni › Generale**, **Cartella di Regista**):

- `Registrazioni`: i video che registri;
- `Progetti`: i progetti (`.regista`);
- `Export`: i video esportati, i sottotitoli `.srt` e i progetti Shotcut.

Con **Salvataggio automatico** acceso, Regista salva ogni minuto i progetti che hanno già una cartella. Un progetto mai
salvato lo salvi tu con ⌘S.

Tutte le scorciatoie da tastiera sono in **Impostazioni › Scorciatoie**. Se qualcosa non va, leggi
[Risoluzione dei problemi](troubleshooting.md); per la tua voce clonata, [Registrare la tua voce](voice.md).
