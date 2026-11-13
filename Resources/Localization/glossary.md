# Glossary — the app's product terms in four languages

Keep these the same everywhere in `*.lproj/Localizable.strings` (scheme and checks: `Sources/Regista/App/Words.swift`,
`scripts/l10n.py`). Write as macOS does in each language: short, sentence case, no word-for-word copies of the Italian.

- **Italian** (source): informal *tu* ("Importa il tuo video").
- **English**: imperative, plain ("Import your video").
- **French**: *vous*, as macOS ("Importez votre vidéo"); a space before `: ; ? !` and inside « guillemets », as macOS.
- **Portuguese**: Brazilian wording kept as neutral as possible, as macOS pt-BR ("Importe seu vídeo"); avoid
  forms that read only as European Portuguese (*ecrã*, *ficheiro*, *utilizador*) and only as slang.

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
| sottotitoli | captions | sous-titres | legendas |
| gobbo | teleprompter | prompteur | teleprompter |
| copione | script | script | roteiro |
| ripresa (one take) | take | prise | tomada |
| Riprese (the V1 footage lane, `track.footage`) | Footage | Rushes | Filmagens |
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
| parola chiave | keyword | mot clé | palavra-chave |
| Voce | Voice | Voix | Voz |
| voce fuori campo | voice-over | voix off | narração |
| tono (of a voice) | tone | ton | tom |
| Musica | Music | Musique | Música |
| effetti sonori (Effetti lane, `track.sfx`) | sound effects (SFX) | effets sonores | efeitos sonoros |
| Grafica | Graphics | Graphismes | Gráficos |
| Genera | Generate | Générer | Gerar |
| Marca / brand kit | Brand / brand kit | Marque / kit de marque | Marca / kit de marca |
| look / stile / filtro | look / style / filter | look / style / filtre | look / estilo / filtro |
| Lavori (jobs) | Jobs | Tâches | Tarefas |
| livello (RAM tier) | tier | niveau | nível |
| progetto | project | projet | projeto |
| profilo | profile | profil | perfil |
| Annulla l'ultima modifica (`menu.undo`) | Undo | Annuler | Desfazer |
| Annulla (a dialog, a job) | Cancel | Annuler | Cancelar |
| Ripeti (`menu.redo`) | Redo | Rétablir | Refazer |
| Fine (a sheet, `button.done`) | Done | Terminé | OK |
| loudness, LUFS, dBTP | loudness | loudness | loudness |

Names never translated: Regista, Claude, Claude Code, Claude Desktop, MCP, ComfyUI, Higgsfield, WhisperX, VoxCPM2,
HyperFrames, Blender, Shotcut, FFmpeg, macOS, Arkad, WeSites, the shortcut glyphs (⌘ ⌥ ⇧ ⌃).
