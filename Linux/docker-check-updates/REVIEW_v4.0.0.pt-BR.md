# Relatório Técnico — Docker Check Updates v4.0.0

**Data:** 2026-09-19  
**Versão analisada:** 4.0.0  
**Implementação principal:** `docker-check-updates.py`  
**Fallback legado:** `docker-check-updates.sh` 3.0.1

## Resumo executivo

A v4.0.0 está em condição adequada para ser considerada a primeira versão Python estável do projeto.

O fluxo principal foi validado em produção e o comportamento crítico do Agent Portainer foi exercitado em três situações reais:

1. atualização bem-sucedida de Agent 2.45.0 para 2.45.1;
2. falha de validação seguida de rollback automático para 2.45.0;
3. nova tentativa com validação pelo Image ID em execução e snapshot forçado, concluindo em 2.45.1.

O resultado final observado no Portainer foi de ambos os Agents remotos testados em 2.45.1.

## Estado do código

Após a revisão final:

- aproximadamente 3.867 linhas Python;
- 16 classes;
- 111 funções/métodos;
- somente biblioteca padrão Python;
- nenhum pacote via pip;
- comandos externos: Docker CLI, Docker Compose e Git nos fluxos que precisam deles;
- CI validando sintaxe, CLI e smoke tests de componentes críticos;
- documentação EN/PT-BR sincronizada;
- Bash v3.0.1 mantido apenas como fallback legado.

Foram removidos caminhos mortos das RCs anteriores relacionados a start/recreate direto de helper e auto-update Standalone que já não faziam parte do fluxo suportado.

## Arquitetura atual

O desenho principal está coerente:

```text
DISCOVER
   -> ANALYZE
   -> PLAN
   -> BACKUP
   -> EXECUTE
   -> VALIDATE
   -> COMMIT / ROLLBACK
```

A separação entre descoberta e alteração reduz o risco de mudanças durante a fase de análise e facilita a evolução futura.

## Docker local

### Pontos positivos

- saída em tempo real em formato tabular;
- cache de pulls por referência de imagem evita trabalho duplicado;
- Compose é identificado por labels nativos;
- atualização genérica é limitada a serviços Compose;
- containers `docker run` não são recriados genericamente;
- healthcheck é respeitado quando presente;
- backup da imagem anterior é criado antes de updates suportados;
- rollback utiliza `--pull never`.

### Limitação principal

O check genérico ainda usa `docker pull` para descobrir mudança de imagem. É confiável, mas não é a forma mais eficiente para ambientes grandes ou sujeitos a rate limit.

## NetBox

O NetBox continua sendo um diferencial importante do projeto.

O fluxo específico cobre:

- distinção entre versão da aplicação e versão do `netbox-docker`;
- manutenção dentro da série compatível;
- dump PostgreSQL obrigatório;
- backup do checkout/workdir;
- preservação e reaplicação de customizações;
- validação do Compose;
- rebuild com `--pull`;
- healthcheck da aplicação;
- coleta de diagnóstico em falha;
- rollback do repositório/workdir.

O restore TAR foi endurecido na v4.0.0 para rejeitar path traversal e links que escapem do diretório de destino.

## Portainer

### Fluxo validado

A atualização automática da v4.0.0 é limitada a Agent Standard Docker gerenciado por Docker Compose.

O fluxo atual:

1. detecta o Agent desatualizado pela API do Portainer;
2. valida labels/caminhos Compose;
3. pré-baixa a imagem exata da versão do Portainer Server;
4. registra o Image ID alvo;
5. pré-baixa `docker:cli`;
6. cria uma stack helper temporária pelo próprio Portainer;
7. o helper opera localmente no host remoto via Docker socket;
8. recria somente o serviço do Agent;
9. o controlador valida o Image ID em execução;
10. força snapshot do environment;
11. confirma `Agent.Version` quando disponível;
12. envia commit;
13. remove a stack helper.

Sem commit, o helper restaura o estado anterior.

### Tags móveis

`sts`, `lts` e `latest` permanecem no arquivo Compose.

A imagem exata previamente baixada recebe localmente a tag móvel e o Compose recria o serviço com `--pull never`.

Isso reduz a dependência de registry durante a janela em que o próprio Agent está sendo reiniciado.

### Tags fixas

O fluxo foi endurecido antes da stable:

- exige exatamente uma ocorrência literal da referência antiga;
- cria backup do arquivo;
- substituição literal via `awk`;
- write-back através do arquivo existente;
- evita `sed -i`;
- preserva inode/permissões/proprietário;
- rollback restaura o backup.

Esse caminho está coberto por smoke test, mas ainda merece um teste de produção controlado separado, pois o ambiente real utilizado nesta validação usava `sts`.

### Escopo deliberadamente não automatizado

Na v4.0.0:

- Agent Standard criado por `docker run`: report-only;
- Edge Agent: report-only;
- Kubernetes Agent: report-only;
- Swarm Agent: report-only.

Isso é uma decisão conservadora.

## Segurança

### Pontos positivos

- token do Portainer fica somente no host central;
- token não é passado por linha de comando;
- helper remoto não recebe token;
- nomes de projeto/serviço Compose são validados;
- caminhos Compose devem ser absolutos e permanecer no workdir;
- helper usa `network_mode: none`;
- imagem alvo é pré-baixada antes da troca;
- rollback não faz pull;
- TAR restore possui validação de caminho;
- nenhum `shell=True` é usado no subprocess local.

### Risco inerente

A stack helper monta `/var/run/docker.sock`, portanto possui capacidade administrativa equivalente a root no Docker remoto durante a atualização.

Esse risco é aceitável para o desenho atual desde que:

- a stack seja temporária;
- o conteúdo do helper seja controlado pela ferramenta;
- o token permaneça central;
- seja implementada futuramente detecção/limpeza de stacks helper órfãs.

## Backup e rollback

O modelo está adequado para rollback de imagem/configuração, mas não deve ser confundido com rollback transacional de dados da aplicação.

Limitações:

- migrações de banco não são revertidas genericamente;
- volumes não são restaurados automaticamente;
- backup de volume nomeado é opt-in;
- bind mounts dependem do backup externo da aplicação.

A documentação agora deixa essas limitações explícitas.

## Comparação com soluções similares

### WUD

WUD é mais amplo em monitoramento contínuo, UI web, REST API, registries, semver, labels e triggers.

Docker Check Updates tem foco diferente: operação pontual/controlada, NetBox custom e transação específica para Agent Portainer.

Referência: https://getwud.app/docs/

### Dockcheck

É a solução mais próxima em filosofia CLI.

Possui recursos maduros de filtros, labels, notificações, backup de imagens e integração Prometheus opcional.

Nosso diferencial atual é o tratamento específico de NetBox e a atualização transacional do Agent Portainer.

Referência: https://github.com/mag37/dockcheck

### Diun

Diun é excelente referência para detecção e notificações, mas não tem como objetivo substituir containers automaticamente.

É uma boa fonte de ideias para a futura camada de alerts/registries.

Referência: https://crazymax.dev/diun/

### Drydock

Drydock já combina UI, agentes distribuídos, updates, rollback, notificações, métricas e controles de segurança mais amplos.

Nosso projeto deve evitar tentar reproduzir toda essa plataforma. O valor atual está na simplicidade operacional e nos fluxos específicos.

Referência: https://github.com/CodeSWhat/drydock

### Watchtower

O Watchtower original foi arquivado em dezembro de 2025 e não deve ser usado como principal referência futura de arquitetura.

Referência: https://github.com/containrrr/watchtower

## Pontos que eu priorizaria

### Prioridade alta — v4.0.x

- detectar stacks `dcu-agent-helper-*` órfãs;
- política opcional de retenção das tags `dcu-backup-*`;
- `--portainer-only`;
- `--local-only`;
- timeouts configuráveis;
- teste de integração do fluxo de tag fixa;
- diferenciar no summary: unsupported, skipped, failed.

### Prioridade média — v4.1/v4.2

- include/exclude;
- labels opt-in/opt-out;
- idade mínima de imagem;
- configuração em `/etc/docker-check-updates/`;
- schema JSON versionado;
- saída específica para Zabbix;
- Prometheus textfile opcional;
- notificações webhook/email;
- histórico/auditoria local.

### Prioridade futura

- consulta OCI manifest/digest sem pull;
- autenticação estruturada em registries;
- semver/tag policy;
- modularização interna mantendo distribuição single-file;
- integração de segurança opcional com ferramentas externas, sem transformar o projeto em scanner.

## O que não implementaria agora

- dashboard web completo;
- autenticação/RBAC;
- daemon obrigatório;
- Kubernetes updater;
- scanner próprio de vulnerabilidade/SBOM;
- clone de funcionalidades do Portainer.

Esses recursos aumentariam muito o escopo e já possuem soluções maduras no ecossistema.

## Conclusão

A v4.0.0 representa uma evolução substancial em relação à versão Bash:

- arquitetura mais controlável;
- melhor visibilidade operacional;
- tratamento de erros mais claro;
- testes automatizados;
- documentação alinhada;
- Portainer Agent update validado em produção com rollback real;
- NetBox mantido como fluxo protegido específico.

A recomendação para o ciclo imediatamente seguinte é estabilizar a série 4.0.x e aumentar cobertura de testes, sem adicionar funcionalidades grandes antes de acumular mais uso real da stable.

