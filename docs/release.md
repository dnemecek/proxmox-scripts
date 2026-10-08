# Zmeny a nasazeni nove verze

Vetev `main` je posledni overena verze. Zmeny se delaji na pracovni vetvi a do `main` jdou pres pull request.

## Cyklus

1. **Vetev** z aktualniho `main`: `<inicialy>-<YYMMDD>/<typ>-<popis>`, napr. `DN-261008/feat-deploy`.
   Typ je `feat`, `fix`, `docs`, `refactor`, `chore`.
2. **Commit** ve tvaru `<komponenta>: <vecny popis>`, cesky, pritomny cas, prvni radek do 72 znaku.
   Soubory pridavej jmenovite, ne `git add .`.
3. **Nasazeni z vetve** na jeden node a overeni:

   ```bash
   ./deploy.sh <node> --config-dir <conf>
   ssh root@<node> '/root/bin/<skript>.sh'      # policy skripty s DRY_RUN=true v konfiguraci
   ```

4. **Ostatni nody** az po overeni na prvnim.
5. **Rollback** pri problemu: `git checkout main && ./deploy.sh <node> --config-dir <conf>`.
6. **Pull request** do `main`, po merge tag `vX.Y.Z` na `main` a smazani vetve.
   Tag znamena "tohle bezi na nodech".

## Pouziti jako submodule

Repo clusteru muze tento repozitar pripojit jako git submodule pripnuty na commit; nasazuje se pak
`<submodule>/deploy.sh <node> --config-dir <conf>`. Novou verzi skriptu prinasi az vedomy commit
odkazu v repu clusteru. Odkaz smi ukazovat jen na commit dosazitelny z `main`: po squash merge
pull requestu nejdriv prepnout odkaz na commit z `main`, az pak mazat pracovni vetev.
