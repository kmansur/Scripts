# Docker Check Updates v4.0.0

Lançamento: 2026-09-19

## Destaques

A v4.0.0 promove a implementação Python para versão estável.

O projeto continua sendo distribuído em um único arquivo, sem dependências Python externas, e utiliza um fluxo mais estruturado:

```text
DISCOVER
  -> ANALYZE
  -> PLAN
  -> BACKUP
  -> EXECUTE
  -> VALIDATE
  -> COMMIT / ROLLBACK
```

## Principais recursos

- Descoberta de updates Docker com tabela em colunas em tempo real.
- Atualização de serviços Docker Compose.
- Backup/rollback de imagem e configuração.
- Backup opcional de volumes nomeados.
- Leitura compatível dos backups das versões Bash v2/v3.
- Fluxo específico para NetBox Docker customizado.
- Descoberta de Agents desatualizados pelo Portainer.
- Update transacional de Agents Standard Docker suportados e gerenciados por Compose.
- Validação pelo Image ID exato do Agent em execução.
- Snapshot forçado do Portainer após a troca do Agent.
- Rollback automático quando não há commit.
- Saída JSON para consulta.
- Somente biblioteca padrão do Python.

## Validação do Agent Portainer

O fluxo de update remoto foi validado em produção com Portainer Server 2.45.1:

1. um Agent 2.45.0 -> 2.45.1 foi atualizado com sucesso;
2. um segundo Agent falhou na validação e retornou automaticamente para 2.45.0;
3. foi adicionada validação do Image ID em execução e refresh forçado do snapshot do Portainer;
4. o segundo Agent então concluiu 2.45.0 -> 2.45.1;
5. estado final: os dois Agents testados em 2.45.1.

## Hardening antes do release

- alteração de tag fixa exige exatamente uma ocorrência literal da imagem;
- o write-back dos arquivos não usa mais `sed -i` e preserva metadados/inode;
- nomes de projeto e serviço Compose são validados antes do helper shell;
- timeout de segurança do helper: seis minutos;
- rollback usa `--pull never`;
- restore TAR rejeita path traversal e links fora do diretório;
- validação do Agent usa o Image ID exato pré-baixado;
- token da API do Portainer continua somente no host central.

## Escopo Portainer

Update automático suportado para Agent Standard Docker gerenciado por Docker Compose.

Somente reportados na v4.0.0:

- Agent Standard criado com `docker run`;
- Edge Agent;
- Kubernetes Agent;
- Agent gerenciado por Swarm.

## Upgrade da v3

Instale a v4 ao lado da v3:

```bash
wget -O /usr/local/scripts/docker-check-updates.py \
  https://raw.githubusercontent.com/kmansur/Scripts/main/Linux/docker-check-updates/docker-check-updates.py

chmod 755 /usr/local/scripts/docker-check-updates.py

/usr/local/scripts/docker-check-updates.py --version
```

Esperado:

```text
docker-check-updates.py v4.0.0 (2026-09-19)
```

A v3.0.1 Bash pode permanecer instalada como fallback legado.

## Documentação

- README.md
- README.pt-BR.md
- CHANGELOG.md
- ROADMAP.md
- ROADMAP.pt-BR.md
