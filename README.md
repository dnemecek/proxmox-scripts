# proxmox-scripts

Maintenance skripty pro Proxmox VE a Ceph (bash).

Skripty neobsahuji hodnoty konkretniho clusteru; ty patri do konfiguracniho souboru vedle skriptu.

## Obsah

| Soubor | Ucel |
|---|---|
| `bin/` | maintenance skripty; kazdy cte svuj `.conf` ze sve slozky |
| `deploy.sh` | z pracovni stanice: scp skriptu (a konfigurace) do `/root/bin/` na node |

## Nasazeni

```bash
./deploy.sh <node>                                # jen skripty
./deploy.sh <node> --config-dir ../muj-cluster/conf   # skripty + konfigurace
```

Na kazdy node jedno volani; seznam nodu neni v repu. Vyzaduje SSH klic pro root na node.

- Konfigurace patri do git repa clusteru, ne sem. `--config-dir` musi lezet v git repu a nesmi mit
  necommitnute zmeny. Kopiruji se jen commitnute soubory primo v DIR; gitignored soubor
  (napr. konfigurace s heslem) se nekopiruje a na node zustane, jak je.
- Opakovane nasazeni prepise skripty a konfiguraci ze seznamu, nic nemaze.

Postup zmen a rollback: [docs/release.md](docs/release.md).

## Licence

MIT, viz `LICENSE`.
