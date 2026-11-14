# Regista — instalar e usar

**Regista** é um editor de vídeo para Mac que **o Claude opera por você**. Você coloca um vídeo bruto numa pasta,
escreve para o Claude o que quer ("monte um reel com legendas") e o Claude faz a edição dentro do app Regista:
escolhe as melhores tomadas, tira as pausas, limpa a voz, coloca legendas e a marca, confere o resultado e exporta o
vídeo. Você vê cada passo ao vivo no app e pode retocar à mão. Tudo roda no seu Mac (nenhuma assinatura extra além da
sua conta Claude).

Este arquivo serve para instalar o Regista e fazer os primeiros testes. O guia completo do app (a janela, o primeiro
reel à mão, a sua voz, os problemas mais comuns) está dentro do próprio app: menu **Ajuda** › **Guia do Regista**, sem
internet e no idioma do app. Ele também está online: https://github.com/arkad-consulting/regista/tree/main/docs/pt.

## 1. Antes de começar

- Um Mac com chip Apple (M1 ou mais novo) e **macOS 15** ou mais novo (menu  → Sobre Este Mac).
- Uns **16 GB livres** no disco, uma boa conexão de internet, 20 a 40 minutos na primeira vez.
- **Claude Desktop** (https://claude.ai/download) **ou** Claude Code, conectado com a **sua** conta Claude.
  Instale **antes** do Regista: a instalação conecta automaticamente (senão, execute `INSTALLA.command` de novo depois).
- A senha do seu Mac (conta de administrador): pode ser pedida para instalar as ferramentas da Apple ou o Homebrew.

Você não precisa instalar mais nada à mão: o script confere tudo e, se faltar algo (ferramentas de desenvolvedor da
Apple, Homebrew), diz exatamente o que fazer.

## 2. Instalar

**Com um único comando (recomendado).** Se as ferramentas de desenvolvedor da Apple ainda não estiverem
instaladas, digite primeiro `xcode-select --install` no Terminal e espere a instalação da Apple terminar. Depois feche o
Claude Desktop (⌘Q), cole esta linha no Terminal e aperte Enter:

```
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

O script faz as mesmas perguntas descritas abaixo (passos 4 e 5); no fim, siga para a seção 3.

**Com o zip (sem Git)**, se alguém lhe mandou um pacote `regista-….zip`:

1. **Feche o Claude Desktop** se estiver aberto (⌘Q).
2. Clique duas vezes no **zip**: aparece uma pasta `regista-…` (em Downloads).
3. Nessa pasta, clique duas vezes em **`INSTALLA.command`**. Abre uma janela do Terminal e a instalação começa.
   - Se o macOS disser que não pode abrir o arquivo: **clique com o botão direito** (ou ctrl-clique) em
     `INSTALLA.command` → **Abrir** → **Abrir**. Se não houver botão "Abrir": **Ajustes do Sistema → Privacidade e
     Segurança**, lá embaixo: **"Abrir Mesmo Assim"**, e clique duas vezes de novo.
   - Se ainda não funcionar: abra o app **Terminal**, digite `bash` e um espaço, **arraste `INSTALLA.command` para a
     janela** e aperte Enter. É exatamente a mesma coisa.
   - Se o macOS pedir para o Terminal acessar a pasta Downloads: **Permitir**.
4. O script faz algumas perguntas, em português. **Aperte só Enter** para a resposta padrão:
   - *Instalar o Blender… / Instalar o Shotcut…?* (programas opcionais) → Enter = não;
   - *Conectar o Regista ao Claude Desktop?* → Enter = sim.
5. **Se ele parar** com uma mensagem em vermelho, quase sempre é um passo a fazer e depois executar de novo:
   - *Command Line Tools are missing*: abriu uma janela da Apple → **Instalar**, espere terminar e clique duas
     vezes de novo em `INSTALLA.command`;
   - Homebrew ausente: aceite a instalação oferecida no Terminal. O instalador oficial pode pedir a senha de
     administrador (nada aparece enquanto você digita). O Regista continua automaticamente depois. Se recusar
     ou a instalação falhar, siga a mensagem e execute `INSTALLA.command` de novo.
6. No fim aparece **"O Regista está instalado"** e **"Concluído"**. O app Regista fica em **Aplicativos**.

Executar a instalação de novo (o comando ou `INSTALLA.command`) não estraga nada: o que já está instalado e verificado é mantido.

## 3. Conferir se está tudo certo

No Terminal, cole esta linha e aperte Enter:

```
~/code/regista/scripts/doctor.sh
```

A última linha deve ser **"Está tudo em ordem"**. Se não, cada problema vem seguido de uma linha que diz como
resolver.

## 4. Conectar o Claude

**Claude Desktop**
1. Feche-o **completamente** (⌘Q, não só a janela) e abra de novo.
2. Confira: menu **Claude → Configurações… → Desenvolvedor**: "regista" deve aparecer, com o estado *running*.
3. Numa conversa nova, o botão **＋** (ou o ícone de ferramentas) embaixo da caixa de texto mostra **regista** e as
   ferramentas dele, ativadas.
4. Na primeira vez que o Claude usar uma ferramenta regista, ele pede permissão: escolha **"Sempre permitir"**
   (senão ele pergunta a cada passo).
5. Dica: crie um **Projeto** "Regista" no Claude Desktop e cole o conteúdo de **`START-PROMPT.md`** nas instruções.
   Todas as conversas desse projeto já saberão como trabalhar.

**Claude Code** (se você usa): no Terminal, `claude mcp list` deve mostrar `regista … ✓ Connected`.
A instalação também adiciona o skill **regista** (`~/.claude/skills/regista`): o Claude sabe quando usar o Regista
e quais regras seguir, sem colar nada. Basta pedir "edite este vídeo".

## 5. Onde colocar os vídeos

Na pasta **Filmes › Regista** (`~/Movies/Regista`, criada pela instalação). O Claude só enxerga essa pasta: coloque o
vídeo lá (e o roteiro em `.txt` ou `.md`, se tiver). Os vídeos prontos (`.mp4`) e as legendas (`.srt`) vão para a
subpasta **Export**, os projetos para **Progetti** e as gravações feitas no app para **Registrazioni**; o Claude diz onde.

**Abra o app Regista antes de falar com o Claude**: no canto superior direito ele mostra "Claude Desktop conectado" (ou
Claude Code) e você vê a edição acontecendo ao vivo. Com o app fechado o Claude trabalha mesmo assim, sem janela.

## 6. Primeiros prompts para testar

Escreva em francês ou em português. Para começar:

> Com o Regista, liste meus vídeos e diga o que você pode fazer com eles.

Um reel falando para a câmera:

> Com o Regista, monte o vídeo X.mov como reel talking-head: escolha as melhores tomadas, tire as pausas, voz limpa,
> legendas em francês no estilo aprovado, com o meu kit de marca. Me mostre o resultado.

Um tutorial de tela (gravado no app: **Gravar** → "Só a tela" ou "Tela + rosto"):

> Com o Regista, monte o tutorial Y: a tela grande, meu rosto numa bolha embaixo à direita, zoom automático nos
> cliques, corte os silêncios e as hesitações, voz limpa, legendas em francês, export 16:9. Me mostre algumas imagens
> antes de exportar.

Um vídeo sem ninguém na imagem, com a sua voz clonada (veja 7 bis):

> Com o Regista, faça um vídeo narrado de 30 segundos com este texto: "…". Minha voz em francês, minhas capturas de
> tela da pasta como imagens, legendas, sem música. Me mostre o resultado antes de exportar.

Depois, corrija falando normalmente: "tire a segunda frase", "legendas maiores", "o nome da minha marca está errado em
0:12". Uma edição leva vários minutos; para testar, vídeos de 1 a 3 minutos bastam.

## 7. Primeiros testes

1. A instalação vai até o fim e o `doctor.sh` diz "Está tudo em ordem".
2. O Claude Desktop (ou Claude Code) enxerga as ferramentas regista.
3. "Liste meus vídeos" funciona.
4. Um reel falando para a câmera **em francês**: boas tomadas escolhidas? pausas bem cortadas? som limpo? legendas
   certas e legíveis (nomes próprios, divisão das linhas)? enquadramento (a cabeça não fica cortada)?
5. Um tutorial: grave 1–2 minutos de tela + câmera no app e peça a edição.
6. Correções pedidas ao Claude e retoques à mão no app (níveis **Simples** e **Pro**), depois um export.
7. Anote quanto tempo leva cada passo, travamentos e mensagens incompreensíveis.

## 7 bis. A sua própria voz (opcional)

O Regista pode fazer uma narração **com a sua voz clonada**, no Mac e de graça, num Mac com 16 GB ou mais. O seu Regista chega **sem perfil e
sem nenhuma voz**: nenhuma voz de outra pessoa vem com o Regista.

1. Crie o seu perfil: **Ajustes → Perfil e voz** → o seu nome (ou peça ao Claude "crie o meu perfil, eu sou o Marco").
2. No app, painel **Voz** → **Gravar sua voz…**: uma janela guia você (perfil, idioma, consentimento, o bloco neutro de
   uns 10 minutos, a verificação, depois os outros tons). Os detalhes estão no guia "Gravar sua voz" (menu **Ajuda**).
   Ou peça ao Claude "grave a minha voz em português" (ou em francês): ele dá o texto para ler. O ideal: o celular com
   um microfone externo, num lugar silencioso; um arquivo por bloco.
3. Passe os arquivos ao Claude, um por um. Depois do bloco neutro, a sua voz já funciona.
4. Para o melhor resultado (Mac com 32 GB ou mais): "treine a minha voz em português" — cerca de 2 h.

A sua voz fica no seu Mac, no seu perfil. Você pode apagá-la quando quiser em Ajustes → Perfil e voz.

## 8. Limites conhecidos

- **Interface**: o app segue o idioma do Mac (ou o escolhido em Ajustes → Geral), em português, francês, italiano ou
  inglês. O que não encontrar à mão, peça ao Claude. Ainda não existe: tirar palavras de preenchimento ("é…") no meio de
  uma frase; o Regista tira só as pausas longas.
- **Motores**: Ajustes → Motores mostra o que está instalado no seu Mac de acordo com a memória dele e instala o resto.
- **Gerações pagas** (imagens/vídeos Higgsfield): não instaladas por padrão; mesmo configuradas, cada geração
  precisa ser **aprovada por você no app Regista** e o total tem um **limite fixo**. A geração local gratuita
  (ComfyUI) é configurada à mão e exige um Mac de 32 GB.
- **Gravar** tela, câmera ou microfone: na primeira vez o macOS pede as permissões (Ajustes do Sistema → Privacidade e
  Segurança → Câmera, Microfone, Gravação de Tela); aceite, depois feche e abra o Regista de novo.
- **Claude Desktop** e operações longas (transcrição de um vídeo longo, export): o Claude pode mostrar "timed out"
  enquanto o Regista continua trabalhando. Diga a ele: "espere um minuto e veja o estado do projeto".
- Uma edição completa são dezenas de trocas com o Claude: usa boa parte do limite de uso da sua assinatura.

## 9. Atualizar

Instalado com o comando: execute de novo `~/code/regista/scripts/install.sh` (ele busca a última versão e compila).
Instalado com o zip: descompacte um zip mais recente e clique duas vezes no `INSTALLA.command` dele. Seus vídeos, o
que já foi baixado e as configurações são mantidos; a atualização leva poucos minutos. Depois feche e abra de novo o Claude Desktop e o
app Regista.

## 10. Avisar sobre um problema

Abra uma issue em https://github.com/arkad-consulting/regista/issues (no app: menu **Ajuda** →
**Relatar um problema…**).

Para cada problema: **o que você pediu** (copie o prompt), **o que esperava**, **o que aconteceu**, **capturas de
tela** (⌘⇧4 ou ⌘⇧5), o nome e a duração do vídeo. Junte o relatório de verificação:

```
~/code/regista/scripts/doctor.sh > ~/Desktop/regista-doctor.txt 2>&1
```

(o arquivo `regista-doctor.txt` aparece na sua Mesa). Se foi a instalação que falhou, mande uma captura da janela do
Terminal e a pasta `~/Library/Application Support/Regista/logs`.
