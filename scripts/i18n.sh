# Installer and doctor messages in Italian, English, French and Portuguese (issue #60). Sourced by scripts/lib.sh (bash 3.2:
# no associative arrays, so one case per message).
#
# The language: $REGISTA_LANG (it, en, fr, pt) if set, else the first language of macOS (System Settings › General ›
# Language & Region), else English. Technical lines (paths, versions, checksums) stay as they are.
#
#   t <key> [args…]   prints the message (a printf format: %s are the args) in that language, English when it has none.

ui_lang() {
  local l="${REGISTA_LANG:-}"
  [ -n "$l" ] || l="$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ",()')"
  case "$l" in it*) echo it ;; fr*) echo fr ;; pt*) echo pt ;; *) echo en ;; esac
}
UI_LANG="$(ui_lang)"

t() {
  local k="$1" f; shift
  f="$(msg "$UI_LANG" "$k")"; [ -n "$f" ] || f="$(msg en "$k")"; [ -n "$f" ] || f="$k"
  # shellcheck disable=SC2059
  printf "$f" "$@"
}

msg() {
  case "$1.$2" in
    # ------------------------------------------------------------------ steps
    en.step_update) echo 'Update (git pull)' ;;
    it.step_update) echo 'Aggiornamento (git pull)' ;;
    fr.step_update) echo 'Mise à jour (git pull)' ;;
    pt.step_update) echo 'Atualização (git pull)' ;;
    en.step_preflight) echo 'Checks before installing' ;;
    it.step_preflight) echo "Controlli prima dell'installazione" ;;
    fr.step_preflight) echo "Vérifications avant l'installation" ;;
    pt.step_preflight) echo 'Verificações antes da instalação' ;;
    en.step_brew) echo 'Homebrew tools' ;;
    it.step_brew) echo 'Strumenti Homebrew' ;;
    fr.step_brew) echo 'Outils Homebrew' ;;
    pt.step_brew) echo 'Ferramentas Homebrew' ;;
    en.step_base) echo 'Engines — Base (transcription, voice cleaning, sound effects)' ;;
    it.step_base) echo 'Motori — Base (trascrizione, pulizia della voce, effetti sonori)' ;;
    fr.step_base) echo 'Moteurs — Base (transcription, nettoyage de la voix, effets sonores)' ;;
    pt.step_base) echo 'Motores — Base (transcrição, limpeza da voz, efeitos sonoros)' ;;
    en.step_wx) echo 'Engines — Medium (WhisperX: precise word timings)' ;;
    it.step_wx) echo 'Motori — Medium (WhisperX: tempi delle parole precisi)' ;;
    fr.step_wx) echo 'Moteurs — Medium (WhisperX : timing précis des mots)' ;;
    pt.step_wx) echo 'Motores — Medium (WhisperX: tempos precisos das palavras)' ;;
    en.step_vox) echo 'Engines — Medium (VoxCPM2: voice-over in your own voice)' ;;
    it.step_vox) echo 'Motori — Medium (VoxCPM2: voce fuori campo con la tua voce)' ;;
    fr.step_vox) echo 'Moteurs — Medium (VoxCPM2 : voix off avec ta propre voix)' ;;
    pt.step_vox) echo 'Motores — Medium (VoxCPM2: narração com a sua própria voz)' ;;
    en.step_node) echo 'Engines — Medium (Node.js and HyperFrames: HTML graphics)' ;;
    it.step_node) echo 'Motori — Medium (Node.js e HyperFrames: grafiche HTML)' ;;
    fr.step_node) echo 'Moteurs — Medium (Node.js et HyperFrames : graphismes HTML)' ;;
    pt.step_node) echo 'Motores — Medium (Node.js e HyperFrames: gráficos HTML)' ;;
    en.step_optional) echo 'Optional' ;;
    it.step_optional) echo 'Facoltativi' ;;
    fr.step_optional) echo 'Optionnels' ;;
    pt.step_optional) echo 'Opcionais' ;;
    en.step_app) echo 'Regista app and its MCP server' ;;
    it.step_app) echo "L'app Regista e il suo server MCP" ;;
    fr.step_app) echo "L'app Regista et son serveur MCP" ;;
    pt.step_app) echo 'O app Regista e o seu servidor MCP' ;;
    en.step_smoke) echo 'Check: Claude can talk to Regista (MCP)' ;;
    it.step_smoke) echo 'Verifica: Claude parla con Regista (MCP)' ;;
    fr.step_smoke) echo 'Vérification : Claude parle avec Regista (MCP)' ;;
    pt.step_smoke) echo 'Verificação: o Claude fala com o Regista (MCP)' ;;
    # ------------------------------------------------------------------ preflight
    en.need_macos) echo 'Regista runs on macOS only.' ;;
    it.need_macos) echo 'Regista funziona solo su macOS.' ;;
    fr.need_macos) echo 'Regista ne fonctionne que sur macOS.' ;;
    pt.need_macos) echo 'O Regista só funciona no macOS.' ;;
    en.need_arm) echo 'A Mac with Apple Silicon (M1 or later) is required, and the Terminal must not run under Rosetta.' ;;
    it.need_arm) echo 'Serve un Mac con Apple Silicon (M1 o successivo) e il Terminale non deve girare sotto Rosetta.' ;;
    fr.need_arm) echo 'Il faut un Mac Apple Silicon (M1 ou plus récent) et le Terminal ne doit pas tourner sous Rosetta.' ;;
    pt.need_arm) echo 'É preciso um Mac com Apple Silicon (M1 ou mais novo) e o Terminal não pode rodar sob o Rosetta.' ;;
    en.need_macos15) echo 'macOS 15 or later is required (this Mac: %s). Update macOS in System Settings › General › Software Update.' ;;
    it.need_macos15) echo 'Serve macOS 15 o successivo (questo Mac: %s). Aggiorna macOS in Impostazioni di Sistema › Generali › Aggiornamento Software.' ;;
    fr.need_macos15) echo 'macOS 15 ou plus récent est nécessaire (ce Mac : %s). Mets à jour macOS dans Réglages Système › Général › Mise à jour de logiciels.' ;;
    pt.need_macos15) echo 'É preciso o macOS 15 ou mais novo (este Mac: %s). Atualize o macOS em Ajustes do Sistema › Geral › Atualização de Software.' ;;
    en.clt_missing) echo "Apple's Command Line Tools are missing. A window has opened to install them (or run: xcode-select --install); when they are installed, run the installer again." ;;
    it.clt_missing) echo 'Mancano gli Strumenti da riga di comando di Apple. Si è aperta una finestra per installarli (oppure esegui: xcode-select --install); quando sono installati, rilancia il programma di installazione.' ;;
    fr.clt_missing) echo "Les outils de ligne de commande d'Apple manquent. Une fenêtre s'est ouverte pour les installer (ou exécute : xcode-select --install) ; une fois installés, relance l'installation." ;;
    pt.clt_missing) echo 'Faltam as Ferramentas de Linha de Comando da Apple. Uma janela foi aberta para instalá-las (ou execute: xcode-select --install); depois de instaladas, execute o instalador de novo.' ;;
    en.swift_old) echo 'Swift 6 or later is required (found: %s). Update the Command Line Tools in System Settings › General › Software Update.' ;;
    it.swift_old) echo 'Serve Swift 6 o successivo (trovato: %s). Aggiorna gli Strumenti da riga di comando in Impostazioni di Sistema › Generali › Aggiornamento Software.' ;;
    fr.swift_old) echo 'Swift 6 ou plus récent est nécessaire (trouvé : %s). Mets à jour les outils de ligne de commande dans Réglages Système › Général › Mise à jour de logiciels.' ;;
    pt.swift_old) echo 'É preciso o Swift 6 ou mais novo (encontrado: %s). Atualize as Ferramentas de Linha de Comando em Ajustes do Sistema › Geral › Atualização de Software.' ;;
    en.brew_missing) echo 'Homebrew is missing. Install it with the official command below (https://brew.sh), then run the installer again:' ;;
    it.brew_missing) echo 'Manca Homebrew. Installalo con il comando ufficiale qui sotto (https://brew.sh), poi rilancia il programma di installazione:' ;;
    fr.brew_missing) echo "Homebrew manque. Installe-le avec la commande officielle ci-dessous (https://brew.sh), puis relance l'installation :" ;;
    pt.brew_missing) echo 'Falta o Homebrew. Instale-o com o comando oficial abaixo (https://brew.sh) e execute o instalador de novo:' ;;
    en.brew_bootstrap) echo "Homebrew is missing. Regista can run its official installer; it may ask for your Mac administrator password." ;;
    it.brew_bootstrap) echo "Manca Homebrew. Regista può avviare il suo installer ufficiale; potrebbe chiedere la password di amministratore del Mac." ;;
    fr.brew_bootstrap) echo "Homebrew manque. Regista peut lancer son installateur officiel ; il peut demander le mot de passe administrateur du Mac." ;;
    pt.brew_bootstrap) echo "Falta o Homebrew. O Regista pode iniciar o instalador oficial; pode pedir a senha de administrador do Mac." ;;
    en.ask_brew) echo "Install Homebrew now?" ;;
    it.ask_brew) echo "Installare Homebrew adesso?" ;;
    fr.ask_brew) echo "Installer Homebrew maintenant ?" ;;
    pt.ask_brew) echo "Instalar o Homebrew agora?" ;;
    en.brew_terminal) echo "Homebrew is required. Open Terminal and run scripts/install.sh again without piping input; it will offer to install Homebrew. Or install Homebrew from https://brew.sh and rerun Regista's installer." ;;
    it.brew_terminal) echo "Serve Homebrew. Apri Terminale e rilancia scripts/install.sh senza input tramite pipe: ti proporrà di installare Homebrew. Oppure installalo da https://brew.sh e rilancia l'installer di Regista." ;;
    fr.brew_terminal) echo "Homebrew est nécessaire. Ouvre Terminal et relance scripts/install.sh sans entrée par un pipe : il proposera Homebrew. Ou installe Homebrew depuis https://brew.sh puis relance Regista." ;;
    pt.brew_terminal) echo "O Homebrew é necessário. Abra o Terminal e execute scripts/install.sh sem entrada por pipe: ele oferecerá a instalação do Homebrew. Ou instale pelo https://brew.sh e execute novamente o instalador do Regista." ;;
    en.brew_failed) echo "Homebrew installation did not finish. Check the message above, install Homebrew from https://brew.sh if needed, then run scripts/install.sh again." ;;
    it.brew_failed) echo "L'installazione di Homebrew non è terminata. Controlla il messaggio precedente, installa Homebrew da https://brew.sh se necessario e rilancia scripts/install.sh." ;;
    fr.brew_failed) echo "L'installation de Homebrew n'a pas abouti. Vérifie le message ci-dessus, installe Homebrew depuis https://brew.sh si nécessaire, puis relance scripts/install.sh." ;;
    pt.brew_failed) echo "A instalação do Homebrew não terminou. Verifique a mensagem acima, instale o Homebrew pelo https://brew.sh se necessário e execute scripts/install.sh novamente." ;;
    en.git_pull_failed) echo 'git pull failed (network, GitHub access or a diverged branch): installing the version already here. Check GitHub access (gh auth status) and run the installer again to update.' ;;
    it.git_pull_failed) echo "git pull non riuscito (rete, accesso a GitHub o ramo divergente): installo la versione già presente. Controlla l'accesso a GitHub (gh auth status) e rilancia per aggiornare." ;;
    fr.git_pull_failed) echo "git pull a échoué (réseau, accès GitHub ou branche divergente) : j'installe la version déjà présente. Vérifie l'accès à GitHub (gh auth status) et relance pour mettre à jour." ;;
    pt.git_pull_failed) echo 'git pull falhou (rede, acesso ao GitHub ou branch divergente): instalo a versão que já está aqui. Verifique o acesso ao GitHub (gh auth status) e execute de novo para atualizar.' ;;
    # ------------------------------------------------------------------ disk
    en.disk_short) echo 'Not enough free disk for the %s tier: %s GB free, it needs %s GB (%s GB of engines and models + %s GB of working space). Free some space and run the installer again (or force a smaller tier: --tier base).' ;;
    it.disk_short) echo 'Spazio libero insufficiente per il livello %s: %s GB liberi, ne servono %s GB (%s GB di motori e modelli + %s GB di spazio di lavoro). Libera spazio e rilancia (o forza un livello più piccolo: --tier base).' ;;
    fr.disk_short) echo "Pas assez d'espace libre pour le niveau %s : %s Go libres, il en faut %s Go (%s Go de moteurs et modèles + %s Go d'espace de travail). Libère de l'espace et relance (ou force un niveau plus petit : --tier base)." ;;
    pt.disk_short) echo 'Espaço livre insuficiente para o nível %s: %s GB livres, são necessários %s GB (%s GB de motores e modelos + %s GB de espaço de trabalho). Libere espaço e execute de novo (ou force um nível menor: --tier base).' ;;
    en.disk_ok) echo 'disk: %s GB free (the %s tier needs %s GB)' ;;
    it.disk_ok) echo 'disco: %s GB liberi (il livello %s ne chiede %s GB)' ;;
    fr.disk_ok) echo 'disque : %s Go libres (le niveau %s demande %s Go)' ;;
    pt.disk_ok) echo 'disco: %s GB livres (o nível %s pede %s GB)' ;;
    en.disk_short_one) echo 'Not enough free disk: %s GB free, %s needs about %s GB. Free some space and try again.' ;;
    it.disk_short_one) echo 'Spazio libero insufficiente: %s GB liberi, %s ne chiede circa %s GB. Libera spazio e riprova.' ;;
    fr.disk_short_one) echo "Pas assez d'espace libre : %s Go libres, %s demande environ %s Go. Libère de l'espace et réessaie." ;;
    pt.disk_short_one) echo 'Espaço livre insuficiente: %s GB livres, %s precisa de cerca de %s GB. Libere espaço e tente de novo.' ;;
    en.disk_comfy) echo 'ComfyUI and its models (Pro tier, set up by hand) take about %s more.' ;;
    it.disk_comfy) echo 'ComfyUI e i suoi modelli (livello Pro, da configurare a mano) occupano circa %s in più.' ;;
    fr.disk_comfy) echo "ComfyUI et ses modèles (niveau Pro, à installer à la main) prennent environ %s de plus." ;;
    pt.disk_comfy) echo 'O ComfyUI e seus modelos (nível Pro, configurados à mão) ocupam cerca de %s a mais.' ;;
    # ------------------------------------------------------------------ questions
    en.ask_model) echo 'Download the transcription model (%s, %s GB free)?' ;;
    it.ask_model) echo 'Scarico il modello di trascrizione (%s, %s GB liberi)?' ;;
    fr.ask_model) echo 'Télécharger le modèle de transcription (%s, %s Go libres) ?' ;;
    pt.ask_model) echo 'Baixar o modelo de transcrição (%s, %s GB livres)?' ;;
    en.ask_vox) echo 'Download the voice model VoxCPM2 (%s, %s GB free)?' ;;
    it.ask_vox) echo 'Scarico il modello di voce VoxCPM2 (%s, %s GB liberi)?' ;;
    fr.ask_vox) echo 'Télécharger le modèle de voix VoxCPM2 (%s, %s Go libres) ?' ;;
    pt.ask_vox) echo 'Baixar o modelo de voz VoxCPM2 (%s, %s GB livres)?' ;;
    en.skipped_rerun) echo 'skipped: run the installer again to add it' ;;
    it.skipped_rerun) echo 'saltato: rilancia il programma di installazione per aggiungerlo' ;;
    fr.skipped_rerun) echo "ignoré : relance l'installation pour l'ajouter" ;;
    pt.skipped_rerun) echo 'ignorado: execute o instalador de novo para adicioná-lo' ;;
    en.licence_notice) echo '%s is licensed %s (%s): NON-COMMERCIAL use only. Work for clients is commercial use. Without it, Regista transcribes this language with whisper.cpp (free for any use).' ;;
    it.licence_notice) echo '%s ha la licenza %s (%s): solo uso NON COMMERCIALE. Il lavoro per i clienti è uso commerciale. Senza, Regista trascrive questa lingua con whisper.cpp (libero per ogni uso).' ;;
    fr.licence_notice) echo "%s est sous licence %s (%s) : usage NON COMMERCIAL uniquement. Le travail pour des clients est un usage commercial. Sans lui, Regista transcrit cette langue avec whisper.cpp (libre pour tout usage)." ;;
    pt.licence_notice) echo '%s tem a licença %s (%s): só uso NÃO COMERCIAL. O trabalho para clientes é uso comercial. Sem ele, o Regista transcreve este idioma com o whisper.cpp (livre para qualquer uso).' ;;
    en.ask_licence) echo 'Install it and accept that licence?' ;;
    it.ask_licence) echo 'Lo installo e accetti quella licenza?' ;;
    fr.ask_licence) echo "L'installer en acceptant cette licence ?" ;;
    pt.ask_licence) echo 'Instalar e aceitar essa licença?' ;;
    en.optin_skipped) echo 'not installed (non-commercial licence, opt-in): add it with scripts/install.sh --with %s, or in Settings › Engines' ;;
    it.optin_skipped) echo 'non installato (licenza non commerciale, su richiesta): aggiungilo con scripts/install.sh --with %s, o in Impostazioni › Motori' ;;
    fr.optin_skipped) echo 'non installé (licence non commerciale, sur demande) : ajoute-le avec scripts/install.sh --with %s, ou dans Réglages › Moteurs' ;;
    pt.optin_skipped) echo 'não instalado (licença não comercial, sob demanda): adicione-o com scripts/install.sh --with %s ou em Ajustes › Motores' ;;
    en.ask_blender) echo 'Install Blender %s (%s download, 3D titles)?' ;;
    it.ask_blender) echo 'Installo Blender %s (%s da scaricare, titoli 3D)?' ;;
    fr.ask_blender) echo 'Installer Blender %s (%s à télécharger, titres 3D) ?' ;;
    pt.ask_blender) echo 'Instalar o Blender %s (%s para baixar, títulos 3D)?' ;;
    en.ask_shotcut) echo "Install Shotcut %s (%s download, opens Regista's MLT exports)?" ;;
    it.ask_shotcut) echo 'Installo Shotcut %s (%s da scaricare, apre gli export MLT di Regista)?' ;;
    fr.ask_shotcut) echo 'Installer Shotcut %s (%s à télécharger, ouvre les exports MLT de Regista) ?' ;;
    pt.ask_shotcut) echo 'Instalar o Shotcut %s (%s para baixar, abre as exportações MLT do Regista)?' ;;
    en.ask_comfy) echo 'Show the ComfyUI setup steps (Pro tier, %s with its models, set up by hand)?' ;;
    it.ask_comfy) echo 'Mostro i passi per configurare ComfyUI (livello Pro, %s con i modelli, a mano)?' ;;
    fr.ask_comfy) echo 'Afficher les étapes pour installer ComfyUI (niveau Pro, %s avec ses modèles, à la main) ?' ;;
    pt.ask_comfy) echo 'Mostrar os passos para configurar o ComfyUI (nível Pro, %s com os modelos, à mão)?' ;;
    en.comfy_steps) echo 'ComfyUI is set up by hand (%s with its models):' ;;
    it.comfy_steps) echo 'ComfyUI si configura a mano (%s con i modelli):' ;;
    fr.comfy_steps) echo "ComfyUI s'installe à la main (%s avec ses modèles) :" ;;
    pt.comfy_steps) echo 'O ComfyUI é configurado à mão (%s com os modelos):' ;;
    en.comfy_missing) echo 'Pro tier, set up by hand: scripts/install.sh --with comfyui prints the steps' ;;
    it.comfy_missing) echo 'livello Pro, da configurare a mano: scripts/install.sh --with comfyui mostra i passi' ;;
    fr.comfy_missing) echo 'niveau Pro, à installer à la main : scripts/install.sh --with comfyui affiche les étapes' ;;
    pt.comfy_missing) echo 'nível Pro, configurado à mão: scripts/install.sh --with comfyui mostra os passos' ;;
    # ------------------------------------------------------------------ app, Claude
    en.app_running) echo 'Regista is running: quit it (⌘Q) and open it again to use the new version' ;;
    it.app_running) echo 'Regista è aperto: chiudilo (⌘Q) e riaprilo per usare la nuova versione' ;;
    fr.app_running) echo 'Regista est ouvert : quitte-le (⌘Q) et rouvre-le pour utiliser la nouvelle version' ;;
    pt.app_running) echo 'O Regista está aberto: feche-o (⌘Q) e abra-o de novo para usar a nova versão' ;;
    en.no_claude) echo 'neither Claude Code nor Claude Desktop is connected: install one (https://claude.ai/download), sign in, run the installer again' ;;
    it.no_claude) echo 'né Claude Code né Claude Desktop sono collegati: installane uno (https://claude.ai/download), accedi, rilancia il programma di installazione' ;;
    fr.no_claude) echo "ni Claude Code ni Claude Desktop n'est connecté : installe l'un des deux (https://claude.ai/download), connecte-toi, relance l'installation" ;;
    pt.no_claude) echo 'nem o Claude Code nem o Claude Desktop estão conectados: instale um deles (https://claude.ai/download), entre na sua conta e execute o instalador de novo' ;;
    en.ask_desktop) echo 'Connect Regista to Claude Desktop (adds "regista" to its config, keeps everything else, backup first)?' ;;
    it.ask_desktop) echo 'Collego Regista a Claude Desktop (aggiunge "regista" alla sua configurazione, tiene tutto il resto, prima una copia di sicurezza)?' ;;
    fr.ask_desktop) echo 'Connecter Regista à Claude Desktop (ajoute "regista" à sa configuration, garde tout le reste, sauvegarde avant) ?' ;;
    pt.ask_desktop) echo 'Conectar o Regista ao Claude Desktop (adiciona "regista" à configuração, mantém o resto, faz um backup antes)?' ;;
    en.repoint) echo 'it points to another copy (%s): replaced with the server inside the app' ;;
    it.repoint) echo "puntava a un'altra copia (%s): sostituita con il server dentro l'app" ;;
    fr.repoint) echo "il pointait vers une autre copie (%s) : remplacée par le serveur dans l'app" ;;
    pt.repoint) echo 'apontava para outra cópia (%s): substituída pelo servidor dentro do app' ;;
    # ------------------------------------------------------------------ summary
    en.done_title) echo 'Regista is installed' ;;
    it.done_title) echo 'Regista è installato' ;;
    fr.done_title) echo 'Regista est installé' ;;
    pt.done_title) echo 'O Regista está instalado' ;;
    en.done_tier) echo 'Tier' ;;
    it.done_tier) echo 'Livello' ;;
    fr.done_tier) echo 'Niveau' ;;
    pt.done_tier) echo 'Nível' ;;
    en.done_found) echo 'Installed' ;;
    it.done_found) echo 'Installati' ;;
    fr.done_found) echo 'Installés' ;;
    pt.done_found) echo 'Instalados' ;;
    en.done_missing) echo 'Missing' ;;
    it.done_missing) echo 'Mancanti' ;;
    fr.done_missing) echo 'Manquants' ;;
    pt.done_missing) echo 'Faltando' ;;
    en.done_optional) echo 'Optional, not installed' ;;
    it.done_optional) echo 'Facoltativi non installati' ;;
    fr.done_optional) echo 'Optionnels non installés' ;;
    pt.done_optional) echo 'Opcionais não instalados' ;;
    en.done_next) echo 'Open Regista (in %s), then in Claude (Desktop or Code) write for example:\n      «edit this video: ~/Movies/Regista/Registrazioni/<file>.mov with the script <script>.md»\n      Claude works in the app and you see every step live. To update: scripts/install.sh · to check: scripts/doctor.sh' ;;
    it.done_next) echo 'Apri Regista (in %s), poi in Claude (Desktop o Code) scrivi per esempio:\n      «monta questo video: ~/Movies/Regista/Registrazioni/<file>.mov con il copione <copione>.md»\n      Claude lavora nell'"'"'app e vedi ogni passo dal vivo. Per aggiornare: scripts/install.sh · per controllare: scripts/doctor.sh' ;;
    fr.done_next) echo 'Ouvre Regista (dans %s), puis dans Claude (Desktop ou Code) écris par exemple :\n      « monte cette vidéo : ~/Movies/Regista/Registrazioni/<fichier>.mov avec le script <script>.md »\n      Claude travaille dans l'"'"'app et tu vois chaque étape en direct. Mise à jour : scripts/install.sh · vérification : scripts/doctor.sh' ;;
    pt.done_next) echo 'Abra o Regista (em %s) e, no Claude (Desktop ou Code), escreva por exemplo:\n      “edite este vídeo: ~/Movies/Regista/Registrazioni/<arquivo>.mov com o roteiro <roteiro>.md”\n      O Claude trabalha no app e você vê cada passo ao vivo. Para atualizar: scripts/install.sh · para verificar: scripts/doctor.sh' ;;
    en.done_code) echo 'Claude Code: start a new session to see the regista tools (claude mcp list)' ;;
    it.done_code) echo 'Claude Code: apri una nuova sessione per vedere gli strumenti regista (claude mcp list)' ;;
    fr.done_code) echo 'Claude Code : ouvre une nouvelle session pour voir les outils regista (claude mcp list)' ;;
    pt.done_code) echo 'Claude Code: abra uma nova sessão para ver as ferramentas regista (claude mcp list)' ;;
    en.done_desktop) echo 'Claude Desktop: quit it completely (⌘Q) and open it again' ;;
    it.done_desktop) echo 'Claude Desktop: chiudilo del tutto (⌘Q) e riaprilo' ;;
    fr.done_desktop) echo 'Claude Desktop : quitte-le complètement (⌘Q) et rouvre-le' ;;
    pt.done_desktop) echo 'Claude Desktop: feche-o completamente (⌘Q) e abra-o de novo' ;;
    # ------------------------------------------------------------------ doctor: fixes
    en.fix_reinstall) echo 'run scripts/install.sh again' ;;
    it.fix_reinstall) echo 'rilancia scripts/install.sh' ;;
    fr.fix_reinstall) echo 'relance scripts/install.sh' ;;
    pt.fix_reinstall) echo 'execute scripts/install.sh de novo' ;;
    en.fix_scripts) echo 'open Regista: it replaces them with its own copy at launch (or run scripts/install.sh --only %s)' ;;
    it.fix_scripts) echo 'apri Regista: li sostituisce con la sua copia all'"'"'avvio (o rilancia scripts/install.sh --only %s)' ;;
    fr.fix_scripts) echo 'ouvrez Regista : il les remplace par sa copie au lancement (ou relancez scripts/install.sh --only %s)' ;;
    pt.fix_scripts) echo 'abra o Regista: ele os substitui pela própria cópia ao iniciar (ou execute scripts/install.sh --only %s)' ;;
    en.fix_run) echo 'run: %s' ;;
    it.fix_run) echo 'esegui: %s' ;;
    fr.fix_run) echo 'exécute : %s' ;;
    pt.fix_run) echo 'execute: %s' ;;
    en.fix_update_macos) echo 'update macOS (System Settings › General › Software Update)' ;;
    it.fix_update_macos) echo 'aggiorna macOS (Impostazioni di Sistema › Generali › Aggiornamento Software)' ;;
    fr.fix_update_macos) echo 'mets à jour macOS (Réglages Système › Général › Mise à jour de logiciels)' ;;
    pt.fix_update_macos) echo 'atualize o macOS (Ajustes do Sistema › Geral › Atualização de Software)' ;;
    en.fix_brew) echo 'install Homebrew from https://brew.sh, then run scripts/install.sh again' ;;
    it.fix_brew) echo 'installa Homebrew da https://brew.sh, poi rilancia scripts/install.sh' ;;
    fr.fix_brew) echo 'installe Homebrew depuis https://brew.sh, puis relance scripts/install.sh' ;;
    pt.fix_brew) echo 'instale o Homebrew pelo https://brew.sh e execute scripts/install.sh de novo' ;;
    en.fix_pin) echo 'pick a version released at least 2 weeks earlier (scripts/engines.lock)' ;;
    it.fix_pin) echo 'scegli una versione uscita almeno 2 settimane prima (scripts/engines.lock)' ;;
    fr.fix_pin) echo 'choisis une version sortie au moins 2 semaines avant (scripts/engines.lock)' ;;
    pt.fix_pin) echo 'escolha uma versão publicada pelo menos 2 semanas antes (scripts/engines.lock)' ;;
    en.fix_restore) echo 'restore the file with git checkout, or update its pin' ;;
    it.fix_restore) echo 'ripristina il file con git checkout, o aggiorna il pin' ;;
    fr.fix_restore) echo 'restaure le fichier avec git checkout, ou mets à jour le pin' ;;
    pt.fix_restore) echo 'restaure o arquivo com git checkout ou atualize o pin' ;;
    en.fix_delete_reinstall) echo 'delete the file and run scripts/install.sh again' ;;
    it.fix_delete_reinstall) echo 'cancella il file e rilancia scripts/install.sh' ;;
    fr.fix_delete_reinstall) echo 'supprime le fichier et relance scripts/install.sh' ;;
    pt.fix_delete_reinstall) echo 'apague o arquivo e execute scripts/install.sh de novo' ;;
    en.fix_json) echo 'fix the file, or delete it and run scripts/install.sh again' ;;
    it.fix_json) echo 'correggi il file, o cancellalo e rilancia scripts/install.sh' ;;
    fr.fix_json) echo 'corrige le fichier, ou supprime-le et relance scripts/install.sh' ;;
    pt.fix_json) echo 'corrija o arquivo, ou apague-o e execute scripts/install.sh de novo' ;;
    en.fix_reopen) echo 'quit Regista and open it again' ;;
    it.fix_reopen) echo 'chiudi e riapri Regista' ;;
    fr.fix_reopen) echo 'quitte et rouvre Regista' ;;
    pt.fix_reopen) echo 'feche e abra de novo o Regista' ;;
    en.fix_claude_edit) echo 'fix it in Claude › Settings › Developer › Edit Config, then run scripts/install.sh again' ;;
    it.fix_claude_edit) echo 'correggilo in Claude › Impostazioni › Sviluppatore › Modifica configurazione, poi rilancia scripts/install.sh' ;;
    fr.fix_claude_edit) echo 'corrige-le dans Claude › Réglages › Développeur › Modifier la config, puis relance scripts/install.sh' ;;
    pt.fix_claude_edit) echo 'corrija-o em Claude › Configurações › Desenvolvedor › Editar configuração e execute scripts/install.sh de novo' ;;
    en.fix_install_claude) echo 'install Claude Desktop (https://claude.ai/download), sign in, then run scripts/install.sh again' ;;
    it.fix_install_claude) echo 'installa Claude Desktop (https://claude.ai/download), accedi, poi rilancia scripts/install.sh' ;;
    fr.fix_install_claude) echo "installe Claude Desktop (https://claude.ai/download), connecte-toi, puis relance scripts/install.sh" ;;
    pt.fix_install_claude) echo 'instale o Claude Desktop (https://claude.ai/download), entre na sua conta e execute scripts/install.sh de novo' ;;
    en.fix_repoint) echo 'repoint it to the app: Regista › Settings › Claude › Repoint to this app…, or scripts/install.sh --claude %s' ;;
    it.fix_repoint) echo "ricollegalo all'app: Regista › Impostazioni › Claude › Ricollega a questa app…, o scripts/install.sh --claude %s" ;;
    fr.fix_repoint) echo "reconnecte-le à l'app : Regista › Réglages › Claude › Pointer vers cette app…, ou scripts/install.sh --claude %s" ;;
    pt.fix_repoint) echo 'reconecte-o ao app: Regista › Ajustes › Claude › Reconectar a este app…, ou scripts/install.sh --claude %s' ;;
    en.fix_optin) echo 'opt-in, non-commercial licence: scripts/install.sh --only %s (shows the licence first), or Settings › Engines' ;;
    it.fix_optin) echo 'su richiesta, licenza non commerciale: scripts/install.sh --only %s (mostra prima la licenza), o Impostazioni › Motori' ;;
    fr.fix_optin) echo 'sur demande, licence non commerciale : scripts/install.sh --only %s (affiche la licence avant), ou Réglages › Moteurs' ;;
    pt.fix_optin) echo 'sob demanda, licença não comercial: scripts/install.sh --only %s (mostra a licença antes) ou Ajustes › Motores' ;;
    en.doctor_ok) echo 'All good' ;;
    it.doctor_ok) echo 'Tutto a posto' ;;
    fr.doctor_ok) echo 'Tout est en ordre' ;;
    pt.doctor_ok) echo 'Está tudo em ordem' ;;
    en.doctor_bad) echo '%s problem(s) to fix (see above)' ;;
    it.doctor_bad) echo '%s problema/i da sistemare (vedi sopra)' ;;
    fr.doctor_bad) echo '%s problème(s) à corriger (voir ci-dessus)' ;;
    pt.doctor_bad) echo '%s problema(s) para resolver (ver acima)' ;;
    en.fix) echo 'fix' ;;
    it.fix) echo 'come fare' ;;
    fr.fix) echo 'solution' ;;
    pt.fix) echo 'solução' ;;
  esac
}
