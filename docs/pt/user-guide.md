# Guia do Regista

O Regista é um editor de vídeo para Mac: reels em que você fala para a câmera, tutoriais de tela, vídeos sem rosto com
a sua própria voz. Você pode editar sozinho com os botões, ou pedir ao Claude que edite por você: cada passo aparece na
janela e pode ser desfeito.

A instalação é um único comando no Terminal: está tudo em [Instalação e motores](install.md).

## A janela

- *A barra da esquerda* tem um ícone para cada atividade: **Início**, **Gravar**, **Mídia**, **Textos e legendas**,
  **Áudio**, **Voz**, **Gráficos**, **Gerar**, **Exportar**. Embaixo ficam **Motores** e **Ajustes**. De ⌘1 a ⌘9 você
  abre as atividades na mesma ordem. Pare o ponteiro sobre um ícone para ver o nome dele.
- *O painel lateral* mostra o conteúdo da atividade escolhida. ⌃⌘S esconde e mostra o painel; arraste a borda para
  alargá-lo.
- *As abas de projeto* ficam no alto, no centro. Cada projeto aberto tem a sua aba; a bolinha indica se ele está salvo.
  O + abre uma **Nova aba**.
- *A área central* muda com a atividade: em **Início** você escolhe por onde começar, em **Gravar** vê a prévia, nas
  atividades de edição vê a edição, em **Exportar** vê o resultado.
- *O painel da direita* tem as abas **Claude** (cada passo do Claude, em palavras simples) e **Inspetor** (os ajustes
  do clipe selecionado); em **Gravar** tem também **Teleprompter** (o texto que você lê enquanto grava). ⌥⌘I esconde
  o painel.
- *A barra de status*, lá embaixo, mostra a memória e o nível do Mac, o volume da edição e se o projeto está salvo.
  Quando o Regista está trabalhando (uma transcrição, uma exportação), aparece **Tarefas**: um clique mostra o
  andamento, **Cancelar** e os erros, se houver.

Cada botão faz um passo que você desfaz com ⌘Z e refaz com ⇧⌘Z, inclusive os passos do Claude.

## O seu primeiro reel, passo a passo

Este é o caminho mais simples: você grava, o Regista edita sozinho, você confere e exporta.

1. Em **Início**, escolha **Reel falado** e depois **Abrir Gravar**. Se você já tem um vídeo gravado, escolha
   **ou importe um vídeo** e pule para o passo 6.
2. Em **Gravar**, em **O que você grava**, escolha **Só o rosto**. **Câmera** e **Microfone** precisam estar ligados.
   Na primeira vez, o macOS pede permissão para a câmera e o microfone: permita.
3. No painel da direita, aba **Teleprompter**, cole o seu texto: uma frase por linha. Com **Teleprompter** ligado em
   **Origens**, o teleprompter abre e começa junto com a gravação.
4. Aperte **Gravar** (⇧⌘R) e leia. Se errar uma frase, comece de novo: o teleprompter volta ao início da frase e marca
   uma nova tomada. Para terminar, aperte ⇧⌘R de novo.
5. Ao fim da gravação você continua em **Gravar**: a tomada vai para o projeto da aba e você pode gravar outra, que
   entra no mesmo projeto. O aviso no alto diz para onde ela foi e quantas tomadas o projeto tem; **Ir para a edição**
   abre a edição com a tomada. Se você ligar **Edição automática ao fim da gravação** (desligada por padrão), o Regista
   abre a edição e faz a edição básica sozinho. Você acompanha em **Tarefas**, na barra de status.
6. Na barra acima da edição, escolha **Simples** (⌥⌘1). À esquerda aparecem seis passos: **Corte e tomadas**,
   **Legendas**, **Aparência**, **Música e sons**, **Voz**, **Gráficos**. Cada um mostra se está feito, por fazer ou se
   é opcional.
7. Se a edição ainda não estiver feita, aperte **Fazer tudo**: ele corta as pausas, escolhe as tomadas, limpa a voz,
   coloca as legendas e uma luz mais viva. Você pode interromper quando quiser; se rodar de novo, ele não acrescenta
   nada duas vezes.
8. Abra os passos um por um e veja o resultado no monitor:
   - **Corte e tomadas**: o quanto o corte é apertado (as pausas longas somem) e, para as frases lidas mais de uma vez,
     qual tomada manter. O Regista escolhe a melhor; você pode testar outra.
   - **Legendas**: **Legendas no vídeo** ligadas ou desligadas, e o estilo: **Talking head** (maiúsculas grandes, poucas
     palavras de cada vez, o destaque numa caixa colorida), **Serifa elegante**, **Negrito + destaque**, **Karaokê fantasma**.
   - **Aparência**: **Luz leve** e, se quiser, uma cor para o vídeo todo.
   - **Música e sons**: **Escolher uma música…** (ela abaixa sozinha quando você fala) e **Um whoosh nos cortes**. Os dois
     são opcionais: no Instagram, a música do momento costuma ser colocada no próprio app.
   - **Voz**: **Limpar a voz** tira o ruído e deixa a voz em −15 LUFS, o volume certo para as redes sociais.
   - **Gráficos**: um título, o **Logo no vídeo**, um cartão animado. Os cartões entram no ponto do indicador: leve-o
     antes para a frase certa.
9. Aperte **Exportar o reel**. **Exportar** abre no formato **Reel 9:16**. Olhe as **Verificações** (duração, volume,
   pico, legendas atualizadas), depois aperte **Exportar vídeo…** e escolha o nome e a pasta. No fim,
   **Mostrar no Finder** abre a pasta.

O Regista tira as pausas longas e mantém a melhor tomada de cada frase. Ele ainda não tira palavras de preenchimento
como "é…" no meio de uma frase: se encontrar uma, tire à mão na transcrição (veja mais abaixo).

Com o Claude: peça para ele tirar as palavras de preenchimento. Ele diz quantas hesitações ("hã") encontrou e
quantos segundos elas ocupam, tira se você concordar, e palavras como "então" ou "tipo" só as que você indicar. A
transcrição muitas vezes não escreve as hesitações: elas ficam como pausa, e o corte das pausas longas geralmente as tira.

## O que o Pro acrescenta

Escolha **Pro** (⌥⌘2) na barra acima da edição. Você tem dois monitores, **Origem** e **Programa**, e embaixo a linha do
tempo com as trilhas: legendas, gráficos, tomadas, voz, música e efeitos sonoros. À esquerda da linha do tempo ficam as
ferramentas seleção (V), lâmina (C), texto (T) e mão (H); à direita, o medidor de volume. Simples e Pro mostram o mesmo
projeto: o que você muda em um, vê no outro.

- **Mídia**: os arquivos do projeto. **Importar…** acrescenta vídeos, sons e imagens. Dê um clique duplo num arquivo
  para vê-lo no monitor **Origem**.
- **Textos e legendas** tem quatro abas. **Passos** vai do vídeo às legendas um passo de cada vez (**Transcrever**,
  **Roteiro**, **Escolher as tomadas**, **Cortar as pausas**, **Limpar a voz**, **Legendas**), ou tudo de uma vez com
  **Fazer tudo**. **Legendas** muda o estilo e as palavras-chave. **Transcrição** acompanha o indicador: um clique numa
  palavra leva você até ela; selecione palavras (⌥clique, ⇧clique) e tire-as da edição com ⌫. **Tomadas** mostra cada
  leitura de cada frase: aprove a escolhida ou pegue outra, depois refaça o corte.
- **Áudio** tem duas abas. **Mixagem**: o volume da edição, a limpeza da voz, a música (**Adicionar música…**, o volume
  e o quanto ela abaixa sob a voz). **Efeitos sonoros**: procure um som, ouça com um clique e coloque no indicador.
- **Gráficos**: **Filtros**, **Ajustar**, **Efeitos**, **Estilos**, **Motion design** e **Logo**. Cada item diz o que
  faz e, quando dá, mostra uma prévia no seu próprio quadro. Um clique aplica no clipe selecionado ou no indicador. Um
  item que não pode funcionar agora continua visível, cinza, com o motivo (um título 3D sem o Blender, por exemplo).
- **Gerar**: uma **Imagem** a partir de uma descrição, um **Clipe** a partir de um quadro, uma **Música**, ou **Ampliar**
  um clipe gerado. O gerador local (ComfyUI, gratuito) pede um Mac do nível Pro (32 GB) e é preparado à parte (veja
  [Instalação e motores](install.md)). O gerador na nuvem (Higgsfield) é pago: primeiro você vê o custo, depois aprova o
  gasto (o botão mostra o valor) ou clica em **Recusar**. A aprovação vale só para aquela geração. O que você gera vai
  para **Mídia**.
- **Exportar**: o formato (**Reel 9:16**, **Feed 4:5**, **Quadrado**, **Horizontal**), **Legendas embutidas**, a
  **Taxa de bits**, as **Verificações** e os arquivos: **Exportar vídeo…**, **Legendas .srt…** e
  **Projeto do Shotcut…** (para terminar a edição no Shotcut).
- **Capa**, em **Exportar** (só vídeos verticais 9:16): leve o indicador de reprodução até o quadro certo e clique em
  **Usar este quadro**, digite o título (3 a 5 palavras) e escolha onde ele fica: **Em cima**, **No centro** ou
  **Embaixo**. As duas molduras tracejadas são os recortes da grade do Instagram (3:4) e da prateleira dos Shorts (2:3):
  se o título sair delas, a linha embaixo diz quantos pixels e o que escolher. **Salvar capa…** grava o PNG para enviar
  como capa. A capa não tem legendas; a fonte e as cores do título vêm do kit da **Marca**.
- **Inspetor**, no painel da direita: os ajustes do clipe selecionado (tempos, posição, cor, volume, velocidade).

### Mover legendas e gráficos

No monitor **Programa** (ou no monitor do Simples), clique numa legenda, num título, num sticker ou no logo: aparece uma
moldura. Arraste para onde quiser. Enquanto você arrasta, aparecem guias e, em vermelho, as áreas que a interface do
Instagram cobre. Para o tamanho, puxe um canto ou use o controle que aparece embaixo. Um clique duplo devolve o elemento
ao lugar. As setas movem um pixel, com ⇧ dez; Esc solta o elemento. Cada movimento é um único passo de ⌘Z, e a
exportação coloca tudo exatamente onde você vê.

## O teleprompter

O teleprompter é uma janela que só você vê: fica por cima das outras, perto da webcam, e nunca aparece numa gravação de
tela nem num compartilhamento de tela. O texto é escrito na aba **Teleprompter** do painel da direita: cada linha
numerada é uma frase, ou seja, uma tomada.

- **Rolagem**: **Voz** (o teleprompter escuta e avança enquanto você lê), **Velocidade** (rola sozinho) ou **Manual**.
- **Segue sua voz**: o idioma em que você lê. O reconhecimento acontece no Mac: nenhum áudio sai do computador.
- **Espelhado** inverte o texto para o vidro de um teleprompter.
- **Refaço** e **Parar**: as palavras que, ditas em voz alta, recomeçam a frase ou param a gravação.
- **Mostrar o teleprompter**, **Ouvir e acompanhar** e **Recomeçar** servem para testar sem gravar.

Espaço inicia e para a rolagem; ↓ passa para a frase seguinte, ↑ recomeça a frase. Um pedal Bluetooth ou um controle de
apresentação funciona sem configuração.

## Um tutorial de tela

1. Em **Início**, escolha **Tutorial de tela**, ou em **Gravar** escolha **Só a tela** ou **Tela + rosto**.
2. Na linha **Tela**, escolha o que gravar: uma tela inteira, uma janela ou **Escolher uma área…**. Ligue
   **Áudio do Mac** se precisar do som do computador.
3. Com o rosto ligado, em **Rosto no vídeo** escolha onde ele fica: **Balão**, **Lado a lado**, **Empilhado**,
   **Rosto**, **Recorte** ou **Só a tela**. Você pode mudar isso também durante a gravação.
4. Aperte **Gravar** (⇧⌘R); ⇧⌘P pausa. As janelas do Regista e o teleprompter nunca entram no vídeo.
5. No fim, abre um projeto 16:9 com a tela, a câmera e o microfone já sincronizados. Daí você edita como sempre, ou pede
   ao Claude, por exemplo: "faça zoom nos cliques".

Na primeira vez, o macOS pede permissão para gravar a tela: veja [Solução de problemas](troubleshooting.md).

## Direção e skills: o seu jeito de editar

Em **Ajustes › Direção e skills** ficam as regras de todo vídeo (**Para todos os vídeos**: as verificações antes da
exportação, as escolhas como o estilo das legendas ou o ritmo, e as regras que o Claude lê), as cinco receitas **Do
Regista** e **As suas** skills. Uma skill é um jeito de editar: regras, escolhas e passos, em um arquivo.

- As receitas do Regista podem ser lidas, não alteradas: **Duplicar** faz uma cópia sua, para mudar como quiser.
- **+ Nova skill…** cria uma vazia; **Importar uma skill…** abre o arquivo que um colega enviou e mostra o que ele diz
  antes de adicioná-la; **Exportar…** cria o arquivo para enviar.
- Cada skill tem três abas: **Regras**, **Escolhas** e **Passos** (os passos que o Claude segue). Cada mudança se
  desfaz com ⌘Z.
- Você também pode pedir ao Claude, por exemplo: "faça uma skill para entrevistas longas, com legendas elegantes e sem
  zoom". Nenhuma skill muda as regras que valem sempre (só a sua voz, originais nunca tocados, nenhum gasto sem o seu
  ok).

## Marca: cores, fontes e logo

Um kit de marca reúne as cores, as fontes e o logo de uma marca. Na barra acima da edição, o botão **Marca** mostra o kit
do projeto: um clique abre a lista e outro escolhe o kit. Legendas, títulos e logo pegam as cores dele de uma vez.

Os kits são criados e editados em **Ajustes › Kit de marca**: nome, cores, fontes, logo e onde ele fica. Cada mudança
pode ser desfeita com ⌘Z. Para passar um kit para outra pessoa, **Exportar…** cria um único arquivo `.registakit`
(cores, fontes e logo dentro); quem recebe usa **Importar…** na mesma tela. O logo entra no vídeo por **Gráficos › Logo** ou, no Simples, pelo passo **Gráficos**.

## Trabalhar com o Claude

O Claude consegue fazer tudo o que os botões fazem, e também o que ainda é complicado na interface. Para conectá-lo,
veja [Instalação e motores](install.md). Deixe o Regista aberto: assim você acompanha cada passo ao vivo.

O que você pode pedir, por exemplo:

> Com o Regista, liste os meus vídeos e diga o que você pode fazer com eles.

> Edite "teste.mov" como reel: as melhores tomadas, sem pausas, voz limpa, legendas em português, com o meu kit de
> marca. Me mostre alguns quadros antes de exportar.

> Suba as legendas. Tire a segunda frase. O nome da minha marca está escrito errado em 0:12.

- Na aba **Claude** do painel da direita, você lê cada passo do Claude, em palavras simples.
- Cada passo do Claude se desfaz com ⌘Z, como os seus.
- O Claude não gasta nada sozinho: uma geração paga só começa depois que você aprova no app.
- O Claude trabalha com os arquivos de Filmes › Regista e nunca apaga nem altera os seus originais.

## Onde ficam os arquivos

Tudo vai para a pasta Filmes › Regista (você muda em **Ajustes › Geral**, **Pasta do Regista**):

- `Registrazioni`: os vídeos que você grava;
- `Progetti`: os projetos (`.regista`);
- `Export`: os vídeos exportados, as legendas `.srt` e os projetos do Shotcut.

Com **Salvamento automático** ligado, o Regista salva a cada minuto os projetos que já têm uma pasta. Um projeto que
nunca foi salvo, você salva com ⌘S.

Todos os atalhos de teclado estão em **Ajustes › Atalhos**. Se algo der errado, leia
[Solução de problemas](troubleshooting.md); para a sua voz clonada, [Gravar sua voz](voice.md).
