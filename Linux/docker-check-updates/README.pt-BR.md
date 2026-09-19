# Docker Check Updates

> **Status de desenvolvimento:** este projeto está em desenvolvimento ativo. O uso é por conta e risco do usuário.
>
> **Alerta de backup:** mantenha sempre um backup testado das aplicações Docker e dos dados persistentes antes de aplicar atualizações. O rollback da imagem do container **não desfaz automaticamente** migrações de banco de dados ou alterações nos dados da aplicação.

`docker-check-updates` é um utilitário em Bash para verificar se containers Docker possuem imagens mais novas disponíveis e, opcionalmente, atualizar serviços gerenciados pelo Docker Compose.

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
- Pode atualizar com segurança Agents Portainer Docker Standalone suportados para a mesma versão do Portainer Server.
- Código e interface de linha de comando em inglês, com documentação também disponível em Português do Brasil.

## Requisitos

- Linux
- Bash 4+
- Docker Engine
- Plugin Docker Compose (`docker compose`) para atualizações
- Git para atualização automática do repositório `netbox-docker`
- Permissão de acesso ao Docker daemon
- Imagem auxiliar `alpine:3.20` para `--backup-volumes`
- Python 3 (somente biblioteca padrão) para a integração opcional com Agents remotos do Portainer

O verificador principal de Docker/NetBox não requer `jq` nem Python. O Python 3 é necessário apenas para a integração com Agents remotos do Portainer.

## Instalação

```bash
sudo wget -O /usr/local/sbin/docker-check-updates.sh \
  https://raw.githubusercontent.com/kmansur/Scripts/main/Linux/docker-check-updates/docker-check-updates.sh

sudo wget -O /usr/local/sbin/portainer-agent-manager.py \
  https://raw.githubusercontent.com/kmansur/Scripts/main/Linux/docker-check-updates/portainer-agent-manager.py

sudo chmod 755 /usr/local/sbin/docker-check-updates.sh
sudo chmod 755 /usr/local/sbin/portainer-agent-manager.py
```

## Uso

Verificar containers em execução:

```bash
docker-check-updates.sh
```

Incluir containers parados:

```bash
docker-check-updates.sh --all
```

Verificar e atualizar de forma interativa:

```bash
docker-check-updates.sh --update
```

Atualizar sem confirmação:

```bash
docker-check-updates.sh --update --yes
```

## Backup

Criar backup sem atualizar:

```bash
docker-check-updates.sh --all --backup
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
docker-check-updates.sh --all --backup --backup-volumes
```

**Limitações importantes**

- Bind mounts não são copiados.
- TAR de volume de banco em execução pode não ser consistente.
- Mantenha também backups nativos de PostgreSQL/MySQL/MariaDB/etc.
- Teste a restauração antes de depender de qualquer backup.

## Rollback

```bash
docker-check-updates.sh --rollback /var/backups/docker-check-updates/20260918-203000
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

O Portainer recomenda manter a versão dos Agents alinhada à versão do Portainer Server. A integração opcional consulta a API do Portainer, identifica environments que o próprio Portainer considera desatualizados e inclui essas informações no relatório.

### Configuração única do token da API

No Portainer, crie um Access Token em **My account → Access tokens**. Depois salve o token no host Docker:

```bash
sudo install -d -m 700 /etc/docker-check-updates
sudo install -m 600 /dev/null /etc/docker-check-updates/portainer-api-token
sudo sh -c 'printf "%s\n" "COLE_AQUI_O_TOKEN_DA_API_DO_PORTAINER" > /etc/docker-check-updates/portainer-api-token'
```

O arquivo padrão é:

```text
/etc/docker-check-updates/portainer-api-token
```

O token nunca é aceito como argumento de linha de comando, evitando exposição no histórico do shell ou na lista de processos.

Quando o Portainer está no mesmo host Docker, a porta HTTPS publicada é descoberta automaticamente. Também é possível informar a URL:

```bash
docker-check-updates.sh \
  --portainer-url https://portainer.exemplo.com.br:9443
```

Para certificado autoassinado em uma URL configurada manualmente:

```bash
docker-check-updates.sh \
  --portainer-url https://portainer.exemplo.com.br:9443 \
  --portainer-insecure
```

Para desabilitar completamente a integração:

```bash
docker-check-updates.sh --no-portainer
```

### Verificação

O modo normal passa a mostrar também os Agents remotos desatualizados:

```bash
docker-check-updates.sh --all
```

Exemplo:

```text
PORTAINER REMOTE AGENTS
ENVIRONMENT                    TYPE             INSTALLED      REQUIRED       STATUS
docker-01                      Docker Agent     2.38.1         2.39.0         UPDATE
docker-02                      Docker Agent     2.38.1         2.39.0         UPDATE
```

### Atualização dos Agents

Com `--update`, um Agent Docker Standalone suportado pode ser atualizado exatamente para a versão do Portainer Server:

```bash
docker-check-updates.sh --update
```

Sem confirmação interativa:

```bash
docker-check-updates.sh --update --yes
```

A atualização automática é propositalmente limitada a um perfil conservador:

- environment do tipo Docker Agent;
- exatamente um container `portainer/agent`;
- Agent não gerenciado por Docker Compose;
- Agent não pertencente a serviço Docker Swarm;
- bind padrão `/var/run/docker.sock` presente;
- nenhuma configuração de mount/rede fora do perfil seguro detectada.

Edge Agent, Kubernetes Agent e Agents gerenciados por Swarm são identificados e exibidos no relatório, mas não são recriados genericamente nesta versão.

### Segurança e rollback do Agent

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
- Containers criados por `docker run` não são recriados automaticamente.
- Backup é feito antes das atualizações Compose por padrão.
- `--no-backup` precisa ser solicitado explicitamente.
- A atualização do repositório `netbox-docker` é limitada à versão exata de suporte exigida pela série atual do NetBox e sempre força a criação de backup.
- O rollback não restaura automaticamente bancos de dados.
- O script não executa `docker image prune` nem apaga backups automaticamente.

## Versionamento

O projeto segue Versionamento Semântico (SemVer).

Versão atual: **2.2.0**.

## Licença

MIT License. Consulte [LICENSE](LICENSE).
