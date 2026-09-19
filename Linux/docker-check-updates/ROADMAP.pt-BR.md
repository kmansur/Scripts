# Docker Check Updates — Estado do Projeto e Roadmap

**Versão estável atual:** 4.0.0  
**Data:** 2026-09-19  
**Implementação principal:** `docker-check-updates.py`  
**Fallback legado:** `docker-check-updates.sh` v3.0.1

## Posicionamento atual

Docker Check Updates é uma ferramenta de linha de comando voltada ao operador, distribuída em um único arquivo e focada em manutenção Docker controlada com poucas dependências no host.

O projeto não tenta competir principalmente por dashboard web ou execução contínua em daemon. O foco atual é inspeção explícita, backup, validação e rollback:

- descoberta de atualizações Docker locais;
- atualização de serviços Docker Compose;
- backup/rollback de imagens e configuração;
- tratamento específico de NetBox Docker customizado;
- atualização transacional de Agents Standard do Portainer gerenciados por Compose;
- progresso ao vivo no terminal e saída JSON para consulta;
- apenas biblioteca padrão do Python, sem pacotes via pip.

## Fluxos validados em produção

Os seguintes caminhos já foram exercitados em ambientes reais:

- verificação de imagens Docker;
- descoberta de metadados Docker Compose;
- detecção de versão do NetBox customizado;
- tratamento do repositório de suporte `netbox-docker`;
- descoberta de Agents com Portainer Server 2.45.1;
- atualização de Agent Standard Docker 2.45.0 → 2.45.1;
- tag móvel `portainer/agent:sts`;
- stack helper temporária criada pelo Portainer;
- validação pelo Image ID exato do Agent em execução;
- snapshot forçado do environment para atualizar `Agent.Version`;
- falha de validação seguida de rollback automático;
- nova tentativa seguida de commit bem-sucedido.

## Comparação com ferramentas similares

A tabela abaixo descreve foco arquitetural, não um ranking.

| Projeto | Modelo principal | Atualiza automaticamente | Compose | Hosts remotos | Backup / rollback | UI / notificações | Diferença principal |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Docker Check Updates** | CLI operacional | Sim, nos fluxos suportados | Sim | Fluxo de Agent Portainer | Forte em imagem/configuração e rollback transacional do Agent | CLI; JSON | NetBox específico + manutenção transacional de Agent Portainer |
| **WUD (What's Up Docker?)** | Serviço contínuo | Sim | Sim | Sim | Não é o foco principal documentado | UI web, REST API e muitos triggers | Monitoramento contínuo, semver, registries e notificações muito mais amplos |
| **Dockcheck** | Script shell interativo | Sim | Sim | Principalmente hosts acessíveis ao script | Backup de imagens | CLI, notificações, addon Prometheus | Modelo operacional mais próximo; nosso projeto adiciona NetBox e transação de Agent Portainer |
| **Diun** | Notificador contínuo | Não substitui containers por design | Descoberta | Providers Docker | Não faz rollback porque não executa update | Muitas notificações | Boa referência para detecção/alertas, não para execução de update |
| **Drydock** | Controlador/UI contínuo | Sim | Sim | Agents distribuídos | Backup de imagem e rollback automático | Dashboard, REST, notificações, métricas | Plataforma de atualização mais ampla; nosso projeto permanece utilitário leve no host |
| **Watchtower** | Atualizador contínuo | Sim | Semântica Compose limitada | Docker daemon | Rollback limitado | Notificações/hooks | Projeto histórico importante, mas o repositório original foi arquivado em dez/2025 |

Documentações de referência:

- WUD: https://getwud.app/docs/
- WUD Docker trigger: https://getwud.app/docs/configuration/triggers/docker/
- Dockcheck: https://github.com/mag37/dockcheck
- Diun: https://crazymax.dev/diun/
- Drydock: https://github.com/CodeSWhat/drydock
- Watchtower arquivado: https://github.com/containrrr/watchtower

## Limitações atuais

### Detecção de updates

A verificação genérica atualmente usa `docker pull` durante a descoberta. É confiável, porém mais pesada do que consultar somente manifest/digest e pode consumir banda e limites do registry.

Quando a imagem não disponibiliza versão adequada via labels OCI/metadados, o programa usa o Image ID como identificação.

### Updates Docker genéricos

A atualização genérica automática é limitada a serviços gerenciados por Compose.

Containers criados diretamente com `docker run` são verificados, mas não recriados genericamente. Essa decisão é proposital: clonar corretamente todas as opções de um container exige tratamento muito mais abrangente antes de ser considerado seguro.

### Portainer

A v4.0.0 atualiza automaticamente somente Agent Standard Docker gerenciado por Compose.

Agent Standard criado com `docker run`, Edge Agent, Kubernetes Agent e Agent em Swarm são apenas reportados.

A stack helper temporária precisa de acesso ao Docker socket remoto, equivalente a controle administrativo daquele Docker. O acesso deve continuar restrito à janela da atualização.

Uma interrupção anormal do processo pode, em teoria, deixar uma stack `dcu-agent-helper-*` órfã. Os fluxos normais de commit/rollback removem a stack.

### Backup e rollback

Rollback de imagem/configuração não desfaz automaticamente migrações de banco de dados nem restaura volumes.

Backup de volumes nomeados é opcional.

NetBox recebe proteção mais forte e específica, incluindo dump PostgreSQL e backup do repositório/diretório de trabalho.

### Registries e políticas

Ainda não existe um modelo próprio para múltiplos registries privados, credential helpers, rate limits, regras semver, janela de maturidade ou políticas allow/deny.

### Observabilidade

Existe saída JSON, mas ainda não há exporter Prometheus nativo, modo Zabbix sender, notificações, banco de auditoria nem histórico persistente de updates.

### Testes

O CI cobre sintaxe, carregamento da CLI e smoke tests direcionados. Ainda não existe um laboratório de integração Docker completo que execute Compose real e rollback automaticamente dentro do CI.

## Roadmap recomendado

### v4.0.x — estabilização

Evitar recursos grandes e priorizar robustez:

- testes para alteração de tag fixa no Compose;
- testes de extração TAR segura e rejeição de arquivos maliciosos;
- detectar/reportar stacks `dcu-agent-helper-*` órfãs;
- retenção/prune opcional das imagens `dcu-backup-*`;
- melhorar classificação de erro (unsupported, failed, skipped);
- opção `--portainer-only`;
- opção `--local-only`.

### v4.1 — políticas e controles operacionais

- include/exclude de containers;
- opt-in/opt-out por label;
- política por container;
- idade mínima da imagem;
- política de versão semântica quando houver tags disponíveis;
- timeouts configuráveis;
- arquivo de configuração em `/etc/docker-check-updates/`;
- janelas de manutenção;
- alvo explícito `--container NAME` e `--project NAME`.

### v4.2 — observabilidade e integrações

- versionamento formal do schema JSON;
- saída amigável ao discovery/status do Zabbix;
- métricas opcionais no formato textfile do Prometheus;
- notificações via webhook/email ou interface simples de notifiers;
- log de auditoria persistente para checks, plans, updates, commits e rollbacks;
- links de release/changelog para imagens conhecidas.

### v4.3 — descoberta eficiente via registry

Reduzir pulls durante check-only quando possível:

- API HTTP OCI/Docker Registry para manifest;
- comparação de digest sem baixar layers;
- autenticação Docker Hub/GHCR/private registry;
- tratamento de rate limit;
- seleção de manifest por plataforma;
- descoberta opcional de tags semver.

A preferência continua sendo biblioteca padrão do Python quando viável.

### v5 — modularização opcional

A distribuição em arquivo único é útil, mas o código-fonte já ficou grande o suficiente para justificar módulos e testes separados:

```text
src/docker_check_updates/
  cli.py
  docker.py
  compose.py
  backup.py
  netbox.py
  portainer.py
  registry.py
  reporting.py
```

O release ainda pode gerar um único arquivo executável se a instalação single-file continuar sendo requisito.

## Recursos que não recomendo implementar agora

Eles são úteis em outros produtos, mas desviariam o projeto do foco atual se implementados cedo demais:

- dashboard web completo;
- usuários/RBAC;
- daemon obrigatório;
- atualizador Kubernetes;
- plataforma ampla de vulnerabilidade/SBOM;
- substituir o Portainer como interface de gestão Docker.

Para esses casos, faz mais sentido integrar WUD, Drydock, Portainer, Renovate/Dependabot, Trivy/Grype ou outras ferramentas dedicadas.

## Critérios usados para a v4.0.0

A baseline estável exige:

- CI de sintaxe/CLI aprovado;
- nenhuma dependência Python externa;
- saída Docker ao vivo;
- leitura compatível dos backups v2/v3;
- descoberta Docker/Compose testada;
- tratamento customizado de NetBox testado;
- update bem-sucedido de Agent Portainer testado;
- rollback de Agent Portainer testado;
- validação do Image ID exato do Agent;
- documentação sincronizada com o comportamento real.

