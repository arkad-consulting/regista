# Glossary — the app's product terms in four languages

Keep these the same everywhere in `*.lproj/Localizable.strings` (scheme and checks: `Sources/Regista/App/Words.swift`,
`scripts/l10n.py`). Write as macOS does in each language: short, sentence case, no word-for-word copies of the Italian.

- **Italian** (source): informal *tu* ("Importa il tuo video").
- **English**: imperative, plain ("Import your video").
- **French**: *vous*, as macOS ("Importez votre vidéo"); a space before `: ; ? !` and inside « guillemets », as macOS.
- **Portuguese**: Brazilian wording kept as neutral as possible, as macOS pt-BR ("Importe seu vídeo"); avoid
  forms that read only as European Portuguese (*ecrã*, *ficheiro*, *utilizador*) and only as slang.
- **Quotes** around a name or a typed text: « » in Italian and French, “ ” in English and Portuguese.
- **Numbers** are written as the words' language writes them, whatever the Mac's region: a decimal point in English, a
  decimal comma in the other three (`Words.locale`); a percent as the language writes it ("50%", French "50 %"). Times
  on the timeline's grid (`0:03.5`, `00:00:01:00`) keep their notation in every language.

| Italian (key) | English | Français | Português |
|---|---|---|---|
| Inizio | Home | Accueil | Início |
| Registra | Record | Enregistrer | Gravar |
| Monta / montaggio | Edit / edit | Montage | Editar / edição |
| Esporta | Export | Exporter | Exportar |
| Impostazioni | Settings | Réglages | Ajustes |
| Motori | Engines | Moteurs | Motores |
| Media | Media | Médias | Mídia |
| Testi e sottotitoli | Text & captions | Textes et sous-titres | Textos e legendas |
| Reel parlato (the kind of video, Inizio's first card) | Talking-head reel | Reel face caméra | Reel falado |
| sottotitoli | captions | sous-titres | legendas |
| gobbo | teleprompter | prompteur | teleprompter |
| copione | script | script | roteiro |
| ripresa (one take) | take | prise | tomada |
| Riprese (the V1 footage lane, `track.footage`) | Footage | Rushes | Filmagens |
| Audio della ripresa (the footage's own sound beside a generated voice, `track.footageSound`) | Footage sound | Son des rushes | Áudio das filmagens |
| trascrizione / trascrivi | transcript / transcribe | transcription / transcrire | transcrição / transcrever |
| Ispettore | Inspector | Inspecteur | Inspetor |
| Claude | Claude | Claude | Claude |
| clip | clip | clip | clipe |
| traccia / pista | track | piste | faixa |
| timeline | timeline | timeline | linha do tempo |
| testina | playhead | tête de lecture | indicador de reprodução |
| Sorgente / Programma (monitors) | Source / Program | Source / Programme | Origem / Programa |
| Semplice / Pro | Simple / Pro | Simple / Pro | Simples / Pro |
| taglio / taglia | cut | coupe / couper | corte / cortar |
| intercalari (ehm, allora, cioè… left in the edit) | filler words | mots de remplissage | palavras de preenchimento |
| parola chiave | keyword | mot clé | palavra-chave |
| Voce | Voice | Voix | Voz |
| voce fuori campo | voice-over | voix off | narração |
| tono (of a voice) | tone | ton | tom |
| Musica | Music | Musique | Música |
| effetti sonori (Effetti lane, `track.sfx`) | sound effects (SFX) | effets sonores | efeitos sonoros |
| Grafica | Graphics | Graphismes | Gráficos |
| Genera | Generate | Générer | Gerar |
| Marca / brand kit | Brand / brand kit | Marque / kit de marque | Marca / kit de marca |
| Il tuo brand (the brand kit preview's sample caption, when the kit's name does not fit) | Your brand | Votre marque | Sua marca |
| look / stile / filtro | look / style / filter | look / style / filtre | look / estilo / filtro |
| movimento del logo (Grafica › Logo: Sting finale, Giro…, `logo.animate`) | logo motion | mouvement du logo | movimento do logo |
| Lavori (jobs) | Jobs | Tâches | Tarefas |
| livello (RAM tier) | tier | niveau | nível |
| progetto | project | projet | projeto |
| profilo | profile | profil | perfil |
| Annulla l'ultima modifica (`menu.undo`) | Undo | Annuler | Desfazer |
| Annulla (a dialog, a job) | Cancel | Annuler | Cancelar |
| Ripeti (`menu.redo`) | Redo | Rétablir | Refazer |
| Fine (a sheet, `button.done`) | Done | Terminé | OK |
| loudness, LUFS, dBTP | loudness | loudness | loudness |
| tipo di video (the rule sheet a project follows) | kind of video | type de vidéo | tipo de vídeo |
| Segui il formato del progetto (no kind of its own: the kind comes from the format) | Follow the project's format | Suivre le format du projet | Seguir o formato do projeto |
| Per cominciare (Inizio's block while something is missing, #112) | Getting started | Pour commencer | Para começar |
| modello di trascrizione (the whisper model file) | transcription model | modèle de transcription | modelo de transcrição |
| immagine disco (the published `.dmg`) | disk image | image disque | imagem de disco |
| Applicazioni (the folder) | Applications | Applications | Aplicativos |
| collegare Claude / Collega… | connect Claude / Connect… | connecter Claude / Connecter… | conectar o Claude / Conectar… |
| codice sorgente (the repository a developer clones) | source code | code source | código-fonte |
| copertina (a reel's cover image, `cover.*`) | cover | couverture | capa |
| scaricare / Scarica (a file from the network) | download / Download | télécharger / Télécharger | baixar / Baixar |
| file del modello (a ComfyUI model file) | model file | fichier de modèle | arquivo de modelo |
| citazione (words someone said, with their source: the `quote-card` template) | quote | citation | citação |
| svolta (the moment of a video that changes what the viewer thinks: the rule sheets) | turn | tournant | virada |
| verdetto (what a check says in the report: passed, fixed, known issue, not checked) | verdict | verdict | veredito |
| scelta / Scelte (what a rule sheet leaves to the person: caption style, pace, framing…, Impostazioni › Regole) | choice / Choices | choix / Choix | escolha / Escolhas |
| ritmo (a choice: how long the pauses between sentences last) | pace | rythme | ritmo |
| inquadratura (a choice: one framing, or punch-ins that hide the cuts) | framing | cadrage | enquadramento |

Names never translated: Regista, Claude, Claude Code, Claude Desktop, MCP, ComfyUI, Higgsfield, WhisperX, VoxCPM2,
HyperFrames, Blender, Shotcut, FFmpeg, macOS, Arkad, WeSites, the shortcut glyphs (⌘ ⌥ ⇧ ⌃).
