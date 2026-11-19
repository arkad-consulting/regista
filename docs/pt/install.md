# Instalação e motores

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

## A partir de uma imagem de disco

Quando uma versão é publicada como `Regista-<versão>.dmg`, você não precisa do Terminal, nem das ferramentas da Apple,
nem do Homebrew: abra o arquivo, arraste o Regista para Aplicativos e abra-o de lá (aberto a partir da imagem ou de
Downloads, o Regista propõe mover-se sozinho). Depois, em Regista › Ajustes › Motores, instale o modelo de transcrição
(1,6 GB): ffmpeg, whisper.cpp e DeepFilterNet já estão no app. Conecte o Claude em Ajustes › Claude.

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
