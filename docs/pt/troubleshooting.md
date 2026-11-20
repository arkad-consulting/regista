# Solução de problemas

## Um botão ou um item está cinza

O Regista não esconde nada: uma função que não pode começar agora continua visível, cinza, com o motivo ao lado ou
embaixo. Os casos mais comuns:

- *Falta um motor.* Por exemplo "Falta o motor que transcreve a fala: instale-o em Ajustes › Motores." ou "Requer o
  Blender: instale em Ajustes › Motores.". Aperte **Instalar…** quando aparecer, ou abra **Ajustes › Motores** e instale
  por lá (veja [Instalação e motores](install.md)).
- *O Mac tem pouca memória para essa função.* Por exemplo "Requer o nível Pro" ou "A voz clonada requer um Mac com pelo
  menos 16 GB de RAM". A voz clonada pede o nível Médio (16 GB); o treinamento da voz e a geração local, o nível Pro
  (32 GB).
- *Falta um passo antes.* Por exemplo "Transcreva primeiro." ou "Coloque primeiro o vídeo na linha do tempo: corte as
  pausas.". Faça antes o passo indicado: no Simples, cada passo também diz qual é o próximo.
- *Não há um projeto aberto.* Muitos botões precisam de um vídeo no projeto: em **Início**, abra um projeto ou importe
  um vídeo.
- *A geração não tem um gerador pronto.* Em **Gerar**, cada gerador cinza diz por quê: ComfyUI não instalado ou não
  pronto (faltam arquivos de modelo ou nós), Higgsfield sem uma conta conectada. O gerador local é preparado à mão:
  **Ajustes › Motores**, **Como instalar**.

## Um motor falta ou não funciona

1. Abra **Ajustes › Motores** e veja o estado do motor. Se aparecer **Instalar**, aperte e acompanhe o andamento em
   **Tarefas**.
2. Se a instalação falhar, a tarefa mostra "Falha na instalação" e o motivo. Confira o espaço livre e a conexão, depois
   tente de novo.
3. No Terminal, `~/code/regista/scripts/doctor.sh` confere toda a instalação e diz como resolver cada problema.
4. Se não bastar, rode a instalação de novo: `~/code/regista/scripts/install.sh`. O que já está instalado e conferido
   continua como está.

## O ComfyUI não inicia ou uma geração falha

- *"ComfyUI does not answer … and Regista does not know where it is".* Escolha a pasta do ComfyUI em
  **Ajustes › Motores › ComfyUI**, ou inicie o ComfyUI por conta própria e defina ali o **Endereço**.
- *"… has no Python environment of its own".* Crie-o na pasta do ComfyUI como dizem as instruções do ComfyUI (`.venv`
  ou `venv`), instale nele os requisitos do ComfyUI e depois **Verificar de novo**.
- *O ComfyUI para antes de responder, ou não responde em cinco minutos.* O Regista para o que iniciou e mostra as últimas
  linhas do log do ComfyUI: normalmente um pacote Python faltando ou um pacote de nós que não carrega. Inicie o ComfyUI
  uma vez à mão a partir da pasta dele para ver a mensagem inteira.
- *"node … is not in ComfyUI".* Instale o pacote de nós indicado (ComfyUI-GGUF para o Wan 2.2) e reinicie o ComfyUI;
  para um nó do próprio ComfyUI, atualize o ComfyUI.
- *"model file … is missing: put it in ComfyUI's models/… folder".* A linha do modelo em **Ajustes › Motores** lista cada
  arquivo com a pasta e a página de onde baixá-lo. Reinicie o ComfyUI depois de adicionar arquivos.
- *Um arquivo de modelo não baixa.* Sem o botão **Baixar**: escolha a **Pasta do ComfyUI** na linha do ComfyUI (o Regista
  só baixa em uma pasta que conhece). "Não há espaço suficiente": libere o que ele diz e **Baixar** de novo. "Não
  corresponde ao seu checksum": o arquivo foi apagado; baixe-o de novo, e se acontecer outra vez o arquivo na página do
  autor mudou. "A conexão caiu": **Baixar** de novo retoma de onde parou. "Já existe um arquivo com este nome, mas de
  outro tamanho": mova esse arquivo e baixe.
- *"ComfyUI ran out of memory".* Feche outros apps pesados, ou peça um tamanho menor ou um clipe mais curto.
- *O app de desktop do ComfyUI.* Ele escuta em outra porta que não a 8188: defina o **Endereço** (por exemplo
  `http://127.0.0.1:8000`).

## Permissões: câmera, microfone, tela

O macOS pede permissão na primeira vez que o Regista usa a câmera, o microfone ou a tela. Se você recusou, ou se a
permissão ainda não vale:

- Em **Gravar**, a linha da fonte diz que falta a permissão do macOS. Aperte **Permitir…**: abre Ajustes do Sistema ›
  Privacidade e Segurança, onde você permite o Regista.
- **Câmera** e **Microfone**: Privacidade e Segurança › Câmera e Microfone, ative o Regista.
- **Tela** (e **Áudio do Mac**): Privacidade e Segurança › Gravação de Tela e Áudio do Sistema, ative o Regista. Depois
  feche e abra o Regista de novo: em **Gravar** há **Reabrir o Regista**. A permissão só vale a partir daí; enquanto não
  vale, o Regista mostra **Gravação de tela ainda não ativa**.
- **Teclas pressionadas no vídeo** (nos tutoriais): também é preciso Privacidade e Segurança › Acessibilidade. Cliques e
  cursor não precisam.
- O **Teleprompter** que segue a voz usa a permissão do microfone; no macOS 15, também é preciso o Reconhecimento de
  Fala.

Uma atualização do Regista não deveria pedir as permissões de novo. Se pedir, permita outra vez e abra o app de novo.

## "Claude não conectado"

A aba **Claude** do painel da direita, e a barra do alto, mostram **Claude não conectado** até o Claude usar o Regista.
Isso é normal enquanto você não pedir nada. Se o Claude não encontrar o Regista:

1. Abra **Ajustes › Claude**. Em **Claude Desktop** (ou **Claude Code**) deve aparecer **Conectado a este app**. Se
   aparecer **Não conectado**, aperte **Conectar o Claude Desktop…** (ou **Conectar o Claude Code…**). Se aparecer
   **Conectado a outra cópia do Regista**, aperte **Reconectar a este app…**.
2. Feche o Claude Desktop por completo (⌘Q, não só a janela) e abra de novo. No Claude Code, abra uma nova sessão.
3. Nos ajustes de desenvolvedor do Claude Desktop, "regista" deve aparecer como ativo.
4. Abra o Regista e depois peça ao Claude, por exemplo: "Com o Regista, liste os meus vídeos".

O Claude trabalha mas você não vê nada na janela? O Regista estava fechado na primeira vez que o Claude o usou: aí o
Claude trabalha sem janela e salva o projeto, que você abre depois em **Início**. Para acompanhar ao vivo, abra o
Regista e depois feche e abra de novo o Claude Desktop (ou abra uma nova sessão do Claude Code).

Se o Claude disser "timed out" durante uma tarefa longa (uma transcrição, uma exportação), o Regista ainda está
trabalhando. Peça a ele que espere um minuto e veja o estado do projeto, sem começar tudo de novo.

## Uma tarefa falha

Transcrições, limpeza da voz, exportações, instalações e gerações são tarefas. Elas ficam em **Tarefas**, na barra de
status: cada uma tem o andamento e **Cancelar**. Uma tarefa que falha deixa o projeto como estava e explica o motivo em
palavras simples; uma tarefa cancelada mostra **Cancelado: nada foi alterado.**. Leia o motivo, resolva a causa (um
motor, o espaço livre, um arquivo que mudou de lugar) e rode de novo. **Remover da lista** tira a linha.

Um comando que falha, seu ou do Claude, também não muda nada: dá para tentar de novo sem risco.

## Onde estão os registros

- Instalação: `~/Library/Application Support/Regista/logs` (um arquivo para cada passo que pode falhar).
- A conexão com o Claude Desktop: `~/Library/Logs/Claude/mcp-server-regista.log`, escrito pelo Claude Desktop.
- A verificação completa, para anexar a um relato: no Terminal,
  `~/code/regista/scripts/doctor.sh > ~/Desktop/regista-doctor.txt 2>&1` cria o arquivo `regista-doctor.txt` na Mesa.

## Relatar um problema

No menu **Ajuda**, **Relatar um problema…** abre a página pública de relatos:
https://github.com/arkad-consulting/regista/issues. Escreva:

- o que você fez ou pediu (copie o pedido ao Claude, se houver);
- o que você esperava e o que aconteceu;
- uma captura de tela (⇧⌘4 ou ⇧⌘5) e a duração do vídeo;
- o arquivo `regista-doctor.txt`, se o problema for na instalação ou num motor.

A página é pública: não anexe vídeos, vozes ou dados que você não queira mostrar.
