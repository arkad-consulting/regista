# Instalação e motores

## O app baixado

Você precisa de um Mac com chip Apple (M1 ou mais novo) e macOS 15 ou mais novo. Não precisa do Terminal, nem das
ferramentas da Apple, nem do Homebrew. Abra o arquivo `Regista-<versão>.dmg`, arraste o Regista para Aplicativos e
abra-o de lá: aberto a partir da imagem de disco ou de Downloads, o Regista propõe mover-se sozinho (**Mover e reabrir**).

ffmpeg, whisper.cpp e DeepFilterNet já estão no app: gravar, cortar, limpar a voz, os gráficos e a exportação funcionam
na hora. Enquanto faltar algo, o Início mostra em **Para começar**, uma linha para cada coisa:

- **Modelo para transcrever e criar legendas**: **Baixar** baixa o modelo de transcrição (1,6 GB; também em
  **Ajustes › Motores**). Quando o download termina, a linha some sozinha.
- **Conecte o Claude para editar falando**: **Conectar…** abre **Ajustes › Claude**. **Não uso o Claude** esconde a linha
  de vez: o Regista também funciona sem o Claude, à mão.

Para instalar a partir do código-fonte (se você desenvolve o Regista, ou para uma versão ainda não publicada como imagem
de disco), siga os passos abaixo.

## O que você precisa

- Um Mac com chip Apple (M1 ou mais novo) e macOS 15 ou mais novo.
- As ferramentas de linha de comando da Apple. Se você não tiver, digite `xcode-select --install` no Terminal e espere a
  instalação da Apple terminar.
- Espaço livre no disco: uns 4 GB para o nível Base, 16 GB para Médio e Pro. A geração local do nível Pro, que é
  preparada à parte, pede bem mais (uns 70 GB).
- Uma boa conexão e de 20 a 40 minutos na primeira vez.
- Para trabalhar com o Claude: o Claude Desktop (https://claude.ai/download) ou o Claude Code, conectado à sua conta.
  Instale antes do Regista, assim a instalação conecta tudo sozinha. O Regista também funciona sem o Claude, à mão.

## Um único comando

Feche o Claude Desktop (⌘Q), abra o Terminal, cole esta linha e aperte Enter:

```
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

A instalação confere o Mac, baixa os motores certos para a memória dele (cada arquivo tem uma versão fixa e uma
assinatura SHA-256 conferida), compila o app no seu Mac, coloca em Aplicativos e conecta o Regista ao Claude Desktop ou
ao Claude Code, o que encontrar. Ela faz algumas perguntas: aperte Enter para a resposta sugerida. Se faltar o Homebrew,
ela oferece a instalação e pode pedir a senha do Mac. No fim, mostra um resumo: o que encontrou, o que falta, como
começar.

Se alguém mandou para você um arquivo `regista-….zip`, abra e clique duas vezes em `INSTALLA.command`: ele faz a mesma
coisa, sem Git.

Para conferir a instalação a qualquer momento:

```
~/code/regista/scripts/doctor.sh
```

A última linha deve dizer "Está tudo em ordem". Se não, embaixo de cada problema há uma linha dizendo como resolver.

## Os níveis

O Regista escolhe um nível pela memória do Mac. Cada nível acrescenta algo ao anterior.

- **Base** (8 GB): gravar, cortar, legendas, voz limpa, gráficos e exportação. É o reel completo.
- **Médio** (16 GB): tempos das palavras mais precisos, então cortes e legendas mais limpos; a sua voz clonada para
  narrações (enquanto trabalha, ela usa uns 8 GB); gráficos animados em HTML; títulos 3D com o Blender, se você aceitar
  instalá-lo.
- **Pro** (32 GB ou mais): o treinamento da sua voz (umas duas horas) e a geração local e gratuita de imagens, clipes e
  música com o ComfyUI. O ComfyUI não se instala sozinho: é preparado à mão, seguindo os passos que o Regista mostra.
- **Na nuvem**, em qualquer nível: a geração paga com o Higgsfield. É opcional, precisa de uma conta, e cada geração
  mostra o custo e espera a sua aprovação.

O Shotcut, para terminar uma edição fora do Regista, é oferecido em todos os níveis. Os alinhadores de italiano e de
francês têm licença só para uso não comercial: a instalação pergunta antes de colocá-los. Sem eles, o Regista transcreve
do mesmo jeito, com o whisper.cpp.

A lista completa, com tamanhos e licenças, está em [docs/reference/engines.md](https://github.com/arkad-consulting/regista/blob/main/docs/reference/engines.md)
(em inglês).

## Instalar um motor depois

Abra **Ajustes › Motores** (também pelo ícone **Motores** embaixo, na barra da esquerda). No topo, **Este Mac** mostra
**Memória**, **Nível** e **Espaço livre**. Embaixo, os motores estão agrupados por nível, cada um com o seu estado:

- **Instalado** ou **Parte do macOS**: está pronto.
- **Instalar**: o Regista baixa e instala. É uma tarefa: o andamento e **Cancelar** ficam em **Tarefas**, na barra de
  status. Se o motor tiver licença não comercial, o Regista mostra antes.
- **Como instalar**: um motor que se prepara à mão (o ComfyUI e os modelos dele). O Regista mostra os passos.
- **Remover…**: apaga os arquivos do motor, depois de dizer o que deixa de funcionar.

**Forçar nível** muda o nível: **Automático** escolhe pela memória. Um nível mais alto mostra e instala motores que
podem deixar o Mac lento ou parar por falta de memória.

## Geração local com o ComfyUI

No nível Pro, o Regista cria imagens, clipes, música e ampliações no seu Mac, de graça, com o ComfyUI. O Regista fala
com o ComfyUI por conta própria, com os workflows que ele traz; o ComfyUI e os arquivos dos modelos são preparados à
mão (cerca de 69 GB para os quatro modelos). **Ajustes › Motores › ComfyUI** mostra os passos; em resumo:

1. Instale o ComfyUI seguindo as instruções dele (https://docs.comfy.org/installation/manual_install), em uma pasta com
   seu próprio ambiente Python (`.venv` ou `venv` dentro dessa pasta).
2. Diga ao Regista onde ele está: em **Ajustes › Motores**, na linha **ComfyUI**, **Pasta do ComfyUI** › **Escolher…**.
   O Regista inicia o ComfyUI quando uma geração precisa, avisa na tarefa enquanto espera que ele responda e o para
   depois. Se você inicia o ComfyUI por conta própria, ou usa o app de desktop dele (não escuta na 8188), defina ali o
   **Endereço**: um ComfyUI iniciado por você continua ligado; depois de uma geração, o Regista só pede que ele libere
   a memória.
3. Instale o pacote de nós ComfyUI-GGUF (https://github.com/city96/ComfyUI-GGUF) na pasta `custom_nodes` do ComfyUI e
   reinicie o ComfyUI: os clipes do Wan 2.2 precisam dele.
4. Obtenha os arquivos de cada modelo. A linha de cada modelo (Z-Image Turbo, Wan 2.2 imagem para vídeo, ACE-Step 1.5,
   Real-ESRGAN + RIFE) lista cada arquivo com a pasta, o tamanho, a licença e a página do autor e, quando o ComfyUI
   responde, quais ele já vê. **Baixar** ao lado de um arquivo que falta (com o tamanho), ou o botão acima de
   vários arquivos que baixa todos, o coloca na pasta `models` da pasta do ComfyUI que o Regista conhece, com o progresso e **Cancelar** na mesma
   linha. Um download cancelado ou interrompido retoma de onde parou; o arquivo é verificado com o seu sha256 antes de
   ir para o lugar; o espaço livre é verificado antes (os arquivos mais 2 GB). Um arquivo que já está lá com o tamanho
   certo não é baixado de novo, e um de outro tamanho nunca é substituído. O Regista só baixa em uma pasta do ComfyUI
   que conhece (a que você escolheu, ou uma encontrada nos locais habituais abaixo): se um programa inicia o ComfyUI, ou
   só o endereço está definido, escolha a pasta dele para ter os botões, ou baixe cada arquivo da página do autor na
   pasta indicada. O Claude pode fazer o mesmo com `generate.fetch`, depois de dizer o tamanho. Depois reinicie o
   ComfyUI para que ele veja os novos arquivos.
5. Verifique: **Verificar de novo** na linha, ou peça ao Claude `generate.check`.

Sem pasta definida e sem nada respondendo no endereço, o Regista procura uma pasta do ComfyUI (com seu ambiente Python)
nestes lugares, nesta ordem: `~/ComfyUI`, `~/comfy/ComfyUI`, `~/Documents/ComfyUI`, `~/Developer/ComfyUI`,
`~/Projects/ComfyUI`, `~/src/ComfyUI`, `~/git/ComfyUI`, `/Applications/ComfyUI`. A linha diz qual encontrou; nada é
gravado nos seus ajustes até você escolher uma pasta.

## Conectar o Claude

Abra **Ajustes › Claude**.

- **Conexão** diz se há um Claude conectado ao app neste momento.
- Em **Claude Desktop**, aperte **Conectar o Claude Desktop…**. O Regista diz o que acrescenta à configuração do Claude
  (mantém todo o resto e faz antes uma cópia de segurança); confirme com **Conectar**. Depois feche o Claude Desktop por
  completo (⌘Q) e abra de novo.
- Em **Claude Code**, aperte **Conectar o Claude Code…**, confirme e abra uma nova sessão do Claude Code.
- Se uma linha disser **Conectado a outra cópia do Regista**, aperte **Reconectar a este app…**: o Claude estava usando
  outra cópia do app e pode não conhecer os comandos novos.
- **Copiar as instruções** copia um texto para colar nas instruções de um projeto do Claude Desktop: todas as conversas
  desse projeto vão saber trabalhar com o Regista.

Na primeira vez que o Claude usar o Regista, o Claude Desktop pede permissão: escolha permitir sempre, senão ele pergunta
a cada passo. Abra o Regista antes de falar com o Claude, assim você acompanha o trabalho ao vivo.

## Atualizar

Rode de novo o comando da instalação, ou:

```
~/code/regista/scripts/install.sh
```

Ele busca a última versão e compila o app de novo. Os seus projetos, ajustes, motores já baixados e a sua voz continuam
como estão. Se você instalou com o arquivo zip, abra um zip mais recente e clique duas vezes no `INSTALLA.command` dele.
Depois da atualização, feche e abra de novo o Regista e o Claude Desktop.

Se algo der errado durante a instalação, veja [Solução de problemas](troubleshooting.md).
