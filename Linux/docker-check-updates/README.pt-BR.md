# Docker Check Updates

> **Linha atual de desenvolvimento:** **v4.0.0-rc.4 (Python)**.
>
> **Fallback estável:** a **v3.0.1 (Bash)** permanece no repositório e deve ser mantida durante a validação da v4 em produção.
>
> **Status de desenvolvimento:** este projeto está em desenvolvimento ativo. O uso é por conta e risco do usuário.
>
> **Alerta de backup:** mantenha sempre um backup testado das aplicações Docker e dos dados persistentes antes de aplicar atualizações. O rollback da imagem do container **não desfaz automaticamente** migrações de banco de dados ou alterações nos dados da aplicação.

`docker-check-updates` está sendo migrado para uma implementação **single-file em Python**. A versão candidata **v4.0.0-rc.4** verifica imagens Docker, atualiza serviços Docker Compose, faz backup/rollback, trata NetBox Docker customizado e gerencia Agents remotos suportados do Portainer usando apenas a biblioteca padrão do Python e os comandos nativos `docker`, `docker compose` e `git`.

O comportamento é propositalmente conservador: por padrão apenas verifica; atualizações exigem `--update`; containers criados diretamente com `docker run` nunca são recriados automaticamente; e imagens customizadas do NetBox recebem tratamento específico.

> **Idioma:** o código e todas as mensagens exibidas pelo script são mantidos em inglês. Este arquivo fornece a documentação em Português do Brasil.

## Recursos

- Verifica containers em execução ou todos os containers.
- Compara a imagem usada pelo container com a imagem mais recente da tag configurada.
- Mostra versão instalada e disponível quando há metadados adequados.
- Detecção específica de versão para Uptime Kuma e Portainer.
- Identifica imagens locais/build sem tratá-las como erro de registry.
- Atualiza somente serviços Docker Compose e somente quando solicitado.
- Cria backup automático da imagem anterior e dos metadados Compose antes de atualizar, exceto quando `--no-backup` for solicitado explicitamente.
- Backup opcional de volumes Docker nomeados com `--backup-volumes`.
- Rollback para imagens anteriores.
- Tratamento especial de imagens customizadas do NetBox (`netbox-custom:*`).
- Atualização automática, com backup obrigatório, do checkout `netbox-docker` quando uma nova versão de suporte compatível é necessária dentro da mesma série principal/secundária do NetBox.
- Verifica Agents remotos gerenciados pelo Portainer quando o acesso à API está configurado.
- Pode atualizar com segurança Agents Portainer Docker Standalone e gerenciados por Docker Compose para a mesma versão do Portainer Server.
- Suporta tags móveis de Agent como `sts`, `lts` e `latest` com proteção de rollback.
- Código e interface de linha de comando em inglês, com documentação também disponível em Português do Brasil.

## Requisitos

Para a **v4 Python**:

- Linux
- Python 3.9+ (somente biblioteca padrão)
- Docker Engine CLI
- Plugin Docker Compose (`docker compose`) para atualizações Compose
- Git somente para atualização automática do repositório `netbox-docker`
- Permissão de acesso ao Docker daemon
- Imagem auxiliar `alpine:3.20` somente quando `--backup-volumes` for usado

Não é necessário instalar pacotes via `pip`, `requests`, Docker SDK, `jq` ou bibliotecas Python adicionais.

A integração com a API do Portainer utiliza a biblioteca padrão `urllib`. O token permanece somente no servidor central que executa o programa.

## Instalação

### v4.0.0-rc.4 Python — recomendada para validação

Instale ao lado da versão Bash estável:

```bash
sudo wget -O /usr/local/scripts/docker-check-updates.py \
  https://raw.githubusercontent.com/kmansur/Scripts/main/Linux/docker-check-updates/docker-check-updates.py

sudo chmod 755 /usr/local/scripts/docker-check-updates.py
```

Confira:

```bash
/usr/local/scripts/docker-check-updates.py --version
```

Esperado:

```text
docker-check-updates.py v4.0.0-rc.4 (2026-09-19)
```

Durante os testes mantenha também:

```text
/usr/local/scripts/docker-check-updates.sh   # v3.0.1 estável
/usr/local/scripts/docker-check-updates.py   # v4.0.0-rc.4
```

As duas versões podem coexistir porque utilizam nomes diferentes.

## Uso

Verificar containers em execução:

```bash
docker-check-updates.py
```

Incluir containers parados:

```bash
docker-check-updates.py --all
```

Verificar e atualizar de forma interativa:

```bash
docker-check-updates.py --update
```

Atualizar sem confirmação:

```bash
docker-check-updates.py --update --yes
```

## Arquitetura da v4

A implementação Python separa descoberta e análise das ações que alteram o ambiente:

```text
DISCOVER
   ↓
ANALYZE
   ↓
PLAN
   ↓
BACKUP
   ↓
EXECUTE
   ↓
VALIDATE
   ↓
COMMIT / ROLLBACK
```

As principais responsabilidades internas ficam separadas em:

- `DockerClient`
- `VersionInspector`
- `BackupManager`
- `PortainerClient`
- `PortainerManager`
- camada de orquestração para planejamento/execução do NetBox

Tudo continua em **um único arquivo Python**, mantendo a instalação simples.

### Saída de progresso em tempo real

A versão Python agora mostra o trabalho conforme ele acontece, sem esperar toda a descoberta terminar. São exibidos o container atual, consulta ao registry, fase da atualização, passos do Agent Portainer, estado de reconexão e andamento de commit/rollback. A tabela e o resumo final continuam sendo apresentados.

### Stack temporária para atualização do Agent Portainer

Agents Portainer gerenciados por Compose passam a ser atualizados por uma stack Compose temporária criada pelo próprio Portainer. Assim evitamos chamadas diretas de `container start/recreate` para iniciar o helper.

O fluxo é:

1. inspecionar o Agent remoto e seus metadados Compose;
2. fazer pré-pull da imagem exata do Agent alvo e de `docker:cli`;
3. criar uma stack temporária `dcu-agent-helper-*` enquanto o Agent antigo ainda está conectado;
4. o helper usa o Docker socket do host e os arquivos Compose originais para recriar apenas o serviço do Agent;
5. aguardar o Portainer informar exatamente a versão alvo;
6. enviar o commit da operação;
7. remover a stack temporária.

O helper utiliza `network_mode: none`. Todas as imagens necessárias são baixadas antes do reinício do Agent. A imagem oficial `docker:cli` já contém o plugin Docker Compose, portanto não é necessário instalar pacotes durante a atualização.

### Novas opções da v4

```bash
docker-check-updates.py --dry-run --update --yes
docker-check-updates.py --verbose
docker-check-updates.py --json
```

`--dry-run --update --yes` executa descoberta e planejamento, incluindo as verificações de imagens, mas não recria serviços.

No release candidate, `--json` é somente para consulta e não pode ser combinado com `--update`.

### Compatibilidade de rollback

A implementação Python entende tanto os novos manifests JSON quanto os arquivos `manifest.tsv` e `netbox-repo.state` gerados pelas versões Bash v2/v3. Portanto, os backups que já existem continuam utilizáveis durante a migração.

## Backup

Criar backup sem atualizar:

```bash
docker-check-updates.py --all --backup
```

O backup padrão salva:

- saída do `docker inspect`;
- nome do container, referência da imagem e Image ID anterior;
- metadados do projeto/serviço Docker Compose;
- arquivos Compose detectados, `.env` e `VERSION` quando disponíveis;
- imagem anterior com `docker image save`;
- dump PostgreSQL do NetBox quando o serviço Compose `postgres` puder ser identificado.

Diretório padrão:

```text
/var/backups/docker-check-updates/YYYYMMDD-HHMMSS/
```

### Backup de volumes nomeados

```bash
docker-check-updates.py --all --backup --backup-volumes
```

**Limitações importantes**

- Bind mounts não são copiados.
- TAR de volume de banco em execução pode não ser consistente.
- Mantenha também backups nativos de PostgreSQL/MySQL/MariaDB/etc.
- Teste a restauração antes de depender de qualquer backup.

## Rollback

```bash
docker-check-updates.py --rollback /var/backups/docker-check-updates/20260918-203000
```

O rollback carrega a imagem antiga, restaura a tag anterior e recria o serviço Compose correspondente.

Ele **não restaura automaticamente banco de dados, volumes ou bind mounts**. Essa decisão é intencional para evitar sobrescrever dados válidos mais recentes.

## NetBox

Imagens como:

```text
netbox-custom:v4.6-5.0.1
```

são builds locais e não podem ser atualizadas com `docker pull netbox-custom:...`.

O script:

1. detecta `netbox-custom:*` antes do fluxo genérico;
2. tenta obter a versão real do NetBox pelo label `netbox.original-tag` herdado da imagem oficial;
3. usa os metadados internos da imagem como fallback;
4. identifica separadamente a versão de suporte do NetBox Docker;
5. verifica a imagem oficial mais recente da mesma série, por exemplo `v4.6`;
6. somente executa rebuild quando o checkout local `netbox-docker` é compatível com a versão de suporte necessária.

Quando for necessário atualizar o próprio checkout do `netbox-docker`, será exibido algo como:

```text
REPO 5.0.2
```

Com `--update`, o script agora pode atualizar automaticamente o checkout local do `netbox-docker` para a tag exata necessária, por exemplo `5.0.2`, antes de reconstruir a imagem customizada.

O fluxo de atualização do NetBox é conservador:

1. faz backup de todos os containers do projeto Compose do NetBox;
2. salva as imagens atuais;
3. gera um dump do PostgreSQL;
4. arquiva o diretório de trabalho do NetBox, excluindo apenas `.git`;
5. registra commit Git e alterações locais;
6. busca as tags Git e faz checkout da versão exata de suporte;
7. guarda e reaplica customizações locais rastreadas e não rastreadas via Git stash;
8. ajusta referências explícitas da imagem customizada da versão antiga para a nova;
9. valida o Docker Compose;
10. reconstrói a imagem customizada usando `--pull`;
11. executa `docker compose up -d` para o projeto e aguarda o NetBox ficar saudável.

Se houver conflito entre uma customização local e a nova versão do `netbox-docker`, o script interrompe o processo antes de alterar os containers em execução e restaura o diretório anterior usando o snapshot de backup.

O script não faz upgrade automático para outra série principal/secundária do NetBox.

### Backup do NetBox

Antes de um rebuild/update compatível, o script tenta salvar:

- a imagem custom atual;
- metadados/configuração Compose;
- um `pg_dump` do PostgreSQL quando o serviço Compose `postgres` puder ser identificado.

Ainda assim, um ambiente NetBox em produção deve possuir backup de banco independente e testado.


## Integração com Agents remotos do Portainer

O Portainer recomenda manter a versão dos Agents alinhada à versão do Portainer Server. A integração fica embutida no programa principal e consulta a API do Portainer para identificar environments marcados como desatualizados.

O Python 3 é necessário somente para esse recurso opcional e nenhuma biblioteca Python de terceiros é utilizada.

### Configuração única do token da API

Crie um Access Token no Portainer em **My account → Access tokens** e salve-o somente no host onde o `docker-check-updates.py` é executado:

```bash
sudo install -d -m 700 /etc/docker-check-updates
sudo install -m 600 /dev/null /etc/docker-check-updates/portainer-api-token
sudo sh -c 'printf "%s\n" "COLE_AQUI_O_TOKEN_DA_API_DO_PORTAINER" > /etc/docker-check-updates/portainer-api-token'
```

O arquivo padrão é:

```text
/etc/docker-check-updates/portainer-api-token
```

Somente o servidor central que executa o programa precisa desse token. Ele não é copiado para os hosts dos Agents e nunca é aceito como argumento de linha de comando.

Quando o Portainer está no mesmo host Docker, a porta publicada é descoberta automaticamente. Também é possível informar uma URL:

```bash
docker-check-updates.py --portainer-url https://portainer.exemplo.com.br:9443
```

Para certificado autoassinado em uma URL configurada manualmente:

```bash
docker-check-updates.py \
  --portainer-url https://portainer.exemplo.com.br:9443 \
  --portainer-insecure
```

Para desabilitar a integração:

```bash
docker-check-updates.py --no-portainer
```

### Verificação

O modo normal mostra os Agents que o próprio Portainer considera desatualizados:

```bash
docker-check-updates.py --all
```

### Atualização automática dos Agents

Com `--update`, environments Docker Agent suportados são atualizados para a **mesma versão exata do Portainer Server**:

```bash
docker-check-updates.py --update
```

Sem confirmação interativa:

```bash
docker-check-updates.py --update --yes
```

Dois perfis conservadores são suportados.

**Agent Docker Standalone**

- exatamente um container `portainer/agent` é identificado;
- não pode ser serviço Docker Swarm;
- deve possuir o bind padrão `/var/run/docker.sock`;
- layouts de mount/rede fora do perfil seguro são ignorados;
- o Agent antigo é mantido parado como ponto de rollback.

**Agent gerenciado por Docker Compose**

- labels de projeto, serviço, diretório de trabalho e arquivos Compose precisam existir;
- os arquivos Compose devem estar dentro do diretório de trabalho informado;
- Docker Swarm não entra nesse fluxo automático;
- tags fixas, como `portainer/agent:2.45.0`, são alteradas para a versão alvo e os arquivos Compose anteriores são preservados;
- tags móveis `portainer/agent:sts`, `portainer/agent:lts` e `portainer/agent:latest` são **mantidas no arquivo Compose**;
- para tag móvel, o programa executa `pull + force-recreate`, preserva a imagem anterior sob uma tag `dcu-backup-*` e somente confirma a atualização quando o Portainer reporta exatamente a versão alvo;
- se o Agent novo não reconectar ou voltar com versão incorreta, o helper restaura a configuração/imagem anterior e recria o Agent anterior.

O helper remoto temporário usa `docker:cli`. Se o plugin Compose não estiver disponível dentro dele, instala o pacote Alpine `docker-cli-compose`; portanto, pode ser necessário acesso de saída ao repositório de pacotes durante uma atualização Compose.

Edge Agent, Kubernetes Agent e Agents gerenciados por Swarm são identificados e reportados, mas não são recriados genericamente.

### Segurança do update remoto

A troca do Agent usa confirmação em duas fases:

1. salva metadados suficientes para recuperação;
2. prepara/baixa a imagem alvo;
3. atualiza e recria o Agent remotamente através do Docker socket;
4. aguarda o Portainer confirmar a versão exata do Agent;
5. confirma a operação somente após essa validação;
6. faz rollback automaticamente caso a confirmação não ocorra.

Assim, o processo não depende da conexão do próprio Agent para terminar a troca depois que ele for reiniciado.

## Segurança e rollback do Agent

Antes da troca, a ferramenta salva a inspeção/configuração do Agent remoto dentro da árvore normal de backups e realiza o pull antecipado da imagem alvo.

Um container temporário `docker:cli` é criado no host remoto. Ele faz a troca localmente usando o Docker socket, permitindo que o procedimento continue mesmo durante a interrupção temporária da conexão do Agent com o Portainer.

O processo utiliza uma confirmação em duas fases:

1. o Agent antigo é parado e renomeado;
2. o novo Agent é iniciado;
3. o programa aguarda o Portainer confirmar a nova versão;
4. somente depois disso a atualização é confirmada.

Se o novo Agent não reconectar dentro do tempo de segurança, o helper remove o novo container, devolve o nome original ao Agent anterior e o inicia novamente.

Depois de uma atualização bem-sucedida, o Agent anterior é mantido parado com um nome semelhante a:

```text
portainer_agent-dcu-backup-YYYYMMDDHHMMSS
```

Esse container serve como ponto adicional para rollback manual e não é apagado automaticamente.

## Segurança

- Sem `--update`, nenhum container é recriado.
- Containers genéricos criados por `docker run` não são recriados automaticamente; a única exceção é o fluxo explicitamente configurado e validado de Agent Portainer Docker Standalone.
- Backup é feito antes das atualizações Compose por padrão.
- `--no-backup` precisa ser solicitado explicitamente.
- A atualização do repositório `netbox-docker` é limitada à versão exata de suporte exigida pela série atual do NetBox e sempre força a criação de backup.
- O rollback não restaura automaticamente bancos de dados.
- O script não executa `docker image prune` nem apaga backups automaticamente.

## Versionamento

O projeto segue Versionamento Semântico (SemVer).

Versão atual de desenvolvimento: **4.0.0-rc.4**.

Fallback Bash estável: **3.0.1**.

## Licença

MIT License. Consulte [LICENSE](LICENSE).
