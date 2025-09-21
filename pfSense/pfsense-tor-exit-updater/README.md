# pfSense IPv4 TOR Exit IP Updater (Merged Feeds)

**Version:** 1.4.0  
**Platforms:** pfSense 2.7.x / FreeBSD  
**Language:** Perl

Downloads TOR exit-node IPs from official sources, keeps **IPv4 only**, **merges & deduplicates** feeds, and **updates a pf table only if the list changed** (short-circuit). Atomic file replace and correct `pfctl` invocation order.

## Sources (merged)
1. **Onionoo** (Tor Project JSON API): `exit_addresses` for running exits  
2. **Tor exit-addresses** (official plain text): observed exit IPs  
3. *(Optional)* **dan.me.uk/torlist** (third-party; disabled by default)

## pf Table
Default table name: **`_Tor_IP_List_`**  
Create it in **Firewall → Aliases → IP** (URL Table) or adjust the name in the script (`$table_name`).

## Why merge Onionoo + exit-addresses?
They’re authoritative but not identical. Merging improves coverage with minimal false positives for the “block Tor exits” use case. Third-party **dan.me.uk** is optional due to reliability/criteria considerations.

## Install
1. Copy the script to your pfSense:
   ```sh
   scp atualiza_tor_list.pl root@<pfsense>:/usr/local/scripts/atualiza_tor_list.pl
   ssh root@<pfsense> 'chmod +x /usr/local/scripts/atualiza_tor_list.pl'
   ```
2. Ensure directory exists for the list file:
   ```sh
   ssh root@<pfsense> 'mkdir -p /usr/local/www/aliastables && chmod 755 /usr/local/www/aliastables'
   ```
3. Create the pf table alias **`_Tor_IP_List_`** in the GUI (or adjust `$table_name`).

## Cron (recommended)
Run every **2–4 hours** (short-circuit avoids unnecessary pf updates). Example cron:
```cron
0 */2 * * * /usr/local/scripts/atualiza_tor_list.pl >/dev/null 2>&1
```

## Configuration flags (top of script)
- `my $USE_DANME = 0;` – enable third-party dan.me.uk merge (default **off**)  
- `my $VERBOSE  = 1;` – 0=quiet (cron-friendly), 1=info, 2=debug  
Paths, table name, timeouts and URLs are also adjustable in the CONFIG block.

## What it does
- Fetch Onionoo JSON → extract `exit_addresses` (IPv4)  
- Fetch Tor `exit-addresses` text → extract IPv4  
- *(Optional)* Fetch **dan.me.uk** → IPv4 filter  
- **Merge & dedupe** → sort for stable diffs  
- **Compare** with current list (`cmp -s`) → **update only if changed**  
- Update pf table: `pfctl -t _Tor_IP_List_ -T replace -f <file>`

## Logging
Uniform messages: `[info]`, `[warn]`, `[debug]`, `[error]`.  
Use `VERBOSE=0` for silent cron unless an error occurs.

## Security notes
- Only **IPv4** is applied by design.  
- Atomic replace prevents partial updates.  
- Optional dan.me.uk is disabled by default to minimize false positives and rate-limit issues.

## Credits
- Based on the original 2016 script by **Aurelio de Souza Ribeiro Neto**.  
- Modernization, hardening, merged feeds, and docs by **ChatGPT (GPT-5 Thinking), 2025**.

## License
MIT – see [LICENSE](./LICENSE).
