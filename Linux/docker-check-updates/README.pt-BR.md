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
- Código e interface de linha de comando em inglês, com documentação também disponível em Português do Brasil.

## Requisitos

- Linux
- Bash 4+
- Docker Engine
- Plugin Docker Compose (`docker compose`) para atualizações
- Permissão de acesso ao Docker daemon
- Imagem auxiliar `alpine:3.20` para `--backup-volumes`

Não requer `jq`, Python ou pacotes adicionais no host.

## Instalação

```bash
sudo wget -O /usr/local/sbin/docker-check-updates.sh \
  https://raw.githubusercontent.com/kmansur/Scripts/main/Linux/docker-check-updates/docker-check-updates.sh

sudo chmod 755 /usr/local/sbin/docker-check-updates.sh
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

Nesse cenário o script não executa `git pull` automaticamente. É necessário revisar release notes, plugins e o procedimento de upgrade do NetBox.

### Backup do NetBox

Antes de um rebuild/update compatível, o script tenta salvar:

- a imagem custom atual;
- metadados/configuração Compose;
- um `pg_dump` do PostgreSQL quando o serviço Compose `postgres` puder ser identificado.

Ainda assim, um ambiente NetBox em produção deve possuir backup de banco independente e testado.

## Segurança

- Sem `--update`, nenhum container é recriado.
- Containers criados por `docker run` não são recriados automaticamente.
- Backup é feito antes das atualizações Compose por padrão.
- `--no-backup` precisa ser solicitado explicitamente.
- O script não atualiza automaticamente o repositório `netbox-docker`.
- O rollback não restaura automaticamente bancos de dados.
- O script não executa `docker image prune` nem apaga backups automaticamente.

## Versionamento

O projeto segue Versionamento Semântico (SemVer).

Versão atual: **2.0.0**.

## Licença

MIT License. Consulte [LICENSE](LICENSE).
