# netdev_backup

Script Python para backup automatizado de configurações de dispositivos de rede (routers e switches) via SSH.

## Funcionalidades

- **Suporte a múltiplos vendors**: Juniper MX, Extreme Networks (e expansível para outros).
- **Coleta vendor-specific**: Usa comandos apropriados para cada fabricante.
- **Backup local**: Salva arquivos de configuração em diretório local com timestamp.
- **Integração Git**: Comita e envia backups para repositório Git interno.
- **Notificações por email**: Envia alertas HTML apenas em caso de falhas.
- **Autenticação flexível**: Suporte a senha ou chave SSH.
- **Processamento paralelo**: Usa threads para backups simultâneos.
- **Retries e logging**: Tentativas automáticas e logs detalhados.

## Requisitos

- Python 3.6+
- Bibliotecas: `paramiko`, `python-dotenv`, `GitPython`, `mysql-connector-python` (opcional para DB)
- Acesso SSH aos dispositivos
- Repositório Git configurado

## Instalação

1. Clone ou copie o script para `/usr/local/scripts/netdev_backup.py`
2. Instale dependências: `pip install paramiko python-dotenv GitPython`
3. Crie diretório de configuração: `mkdir -p /usr/local/etc/netdev_backup`
4. Configure arquivo `.env` (veja exemplo abaixo)
5. Configure arquivo JSON de dispositivos (veja exemplo abaixo)
6. Configure log: `touch /var/log/netdev_backup.log && chmod 644 /var/log/netdev_backup.log`

## Configuração

### Arquivo .env (`/usr/local/etc/netdev_backup/netdev_backup.env`)

```bash
# Diretórios
BACKUP_DIR=/var/backups/netdev
GIT_REPO_DIR=/var/git/netdev_backups

# Dispositivos
DEVICES_FILE=/usr/local/etc/netdev_backup/devices.json

# Email (opcional)
SMTP_HOST=smtp.exemplo.com
SMTP_PORT=587
SMTP_USER=usuario@exemplo.com
SMTP_PASS=senha
EMAIL_FROM=backup@exemplo.com
EMAIL_TO=admin@exemplo.com,suporte@exemplo.com

# SSH
SSH_TIMEOUT=15
MAX_WORKERS=4
RETRY_COUNT=2
```

### Arquivo de dispositivos (`/usr/local/etc/netdev_backup/devices.json`)

```json
[
  {
    "ip": "192.168.1.1",
    "vendor": "juniper",
    "user": "backup",
    "password": "senha123",
    "ssh_key": null,
    "ssh_passphrase": null
  },
  {
    "ip": "192.168.1.2",
    "vendor": "extreme",
    "user": "admin",
    "password": null,
    "ssh_key": "/home/backup/.ssh/id_rsa",
    "ssh_passphrase": null
  }
]
```

## Uso

### Backup completo
```bash
python3 netdev_backup.py
```

### Backup com opções
```bash
# Apenas um IP específico
python3 netdev_backup.py --ip 192.168.1.1

# Apenas um vendor
python3 netdev_backup.py --vendor juniper

# Com email em caso de falha
python3 netdev_backup.py --email

# Tentando coletar segredos (se suportado)
python3 netdev_backup.py --with-secrets

# Usando arquivo de dispositivos alternativo
python3 netdev_backup.py --devices-file /caminho/alternativo/devices.json
```

## Logs

Logs são gravados em `/var/log/netdev_backup.log`. Nível INFO por padrão.

## Segurança

- Use usuários dedicados com privilégios mínimos (ex: `read-only` no Juniper).
- Prefira autenticação por chave SSH em vez de senha.
- Restrinja acesso aos arquivos de configuração e backups.

## Expansão

Para adicionar suporte a novos vendors:
1. Adicione função `collect_<vendor>()` em `export_config()`.
2. Atualize `get_hostname()` se necessário.
3. Teste com dispositivo real.

## Exemplo de cron

```bash
# Backup diário às 2h da manhã
0 2 * * * /usr/bin/python3 /usr/local/scripts/netdev_backup.py --email
```

## Troubleshooting

- **Erro de conexão SSH**: Verifique credenciais, firewall e acesso à porta 22.
- **Comando não encontrado**: Confirme se o dispositivo suporta os comandos usados.
- **Git push falha**: Verifique se o repositório está configurado e acessível.
- **Email não enviado**: Confirme configurações SMTP e se há falhas no backup.

## Licença

Este script é fornecido "como está", sem garantias. Use por sua conta e risco.