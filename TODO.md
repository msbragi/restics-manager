# TODO — Backup Docker con Restic

## Wrapper nativo separato — 12 novembre 2026

- [x] Creare run-restic.sh senza modificare stacks-backup.sh o stacks-restore.sh; riusare initialize_config, controlli percorsi e detect_restic dal modulo esistente.
- [x] Supportare --stack NAME facoltativo e --config/-c prima del comando nativo; inoltrare comando e argomenti come array senza correzioni o eval. Senza selettore non montare repository/password: help/version funzionano, gli errori per repository mancante sono demandati a Restic.
- [x] Bloccare backup/init/restore con rimando agli script specialistici, oltre a mount e self-update non supportati.
- [x] Preparare immagine e mount repository/password; esporre direttamente stdout, stderr ed exit code nativi, senza gestione applicativa o dipendenze dai .backup.
- [x] Aggiornare help e README e verificare sintassi e tests/run-restic.sh con Docker simulato: blocchi preventivi, precedenza config, argomenti con spazi, stream/exit code e pull solo quando necessario.
- [ ] Collaudo dell'utente: run-restic.sh --stack traefik-proxy ls --long latest e comando non valido; nessun Docker reale eseguito dall'agente.

## Selezione singolo stack — 12 novembre 2026

- [x] Aggiungere --stack NAME a --check, --init e --backup, combinabile con --config e indipendente dall'ordine degli argomenti.
- [x] Selezionare esclusivamente STACKS_DIR/NAME; errore per directory o descrittore mancanti, link, nomi non sicuri e selettori duplicati. Senza selettore mantenere ricerca normale.
- [x] Aggiornare help e README e aggiungere tests/stack-selection.sh con fixture simulate, senza Docker.
- [ ] Collaudo dell'utente con --stack traefik-proxy --check, --init e --backup, usando docker-stop=skip per lasciare attivo Traefik.

## Modalità docker-stop=skip — 12 novembre 2026

- [x] Accettare esattamente una direttiva docker-stop=true|false|skip; mantenere errore per direttiva assente, duplicata o non valida.
- [x] Con skip evitare Compose e controlli/lifecycle dei container applicativi, anche prima/dopo Restic; conservare controlli percorsi, hash descrittore e gestione repository.
- [x] Conservare true (stop/recupero) e false (container già fermi); Docker resta necessario per eseguire Restic.
- [x] Aggiungere test simulato mirato e documentare precaricamento media seguito da snapshot completo nello stesso repository.
- [x] Verificare sintassi e test simulato tests/skip-policy.sh: skip senza Compose e senza gestione applicativa, direttive invalide rifiutate, protezioni true/false conservate.
- [ ] Collaudo dell'utente: skip su cartella senza Compose e su media con sito attivo, poi backup completo con true. Misurare il fermo effettivo. Nessun test Docker eseguito dall'agente.

## Configurazione da riga di comando e help — 12 novembre 2026

- [x] Aggiungere --config FILE / -c FILE a backup e restore, anche dopo l'operazione, con precedenza su BACKUP_CONFIG.
- [x] Mostrare usage ed esempi senza leggere configurazioni né contattare Docker quando mancano operazioni o viene richiesto --help/-h.
- [x] Validare argomenti prima della configurazione; segnalare opzioni errate, operazioni incomplete e file mancanti.
- [x] Aggiornare README e inizializzazione delle fixture esistenti.
- [x] Verificare sintassi e controlli CLI senza Docker: help con configurazione inesistente, config senza operazione, opzioni errate e precedenza CLI su ambiente.
- [ ] Collaudo dell'utente di backup e restore tramite --config/-c.

## Configurazione unica e Restic Docker — 12 novembre 2026

- [x] Unificare percorsi, immagine e timeout in backup.env; aggiungere backup.env.example senza modificare la configurazione locale dell'utente.
- [x] Eliminare il Compose Restic ridondante e il backend Restic nativo; conservare i Compose degli stack.
- [x] Controllare Docker e immagine prima delle operazioni; scaricare RESTIC_IMAGE solo quando manca, con RESTIC_PULL_TIMEOUT separato (600 s), e verificare nuovamente prima di procedere.
- [x] Segnalare immediatamente un BACKUP_CONFIG esplicito inesistente e aggiornare README.
- [ ] Collaudo dell'utente: immagine presente, immagine assente/pull, errore pull, backup e restore con percorsi personalizzati. Nessun comando Docker eseguito dall'agente.

## Refactor Bash e utility Linux — 11 novembre 2026

- [x] Rimuovere Python dai requisiti e da tutte le operazioni di backup/restore.
- [x] Usare jq per validazione JSON Compose/Restic, selezione snapshot e percorsi di restore; usare date per le date UTC.
- [x] Redigere password letterali e JSON-escaped con Bash e jq, senza passarle negli argomenti dei processi; rifiutare diagnostica binaria con NUL.
- [x] Aggiornare README e aggiungere tests/json-handling.sh.
- [x] Verificare sintassi, regressione lifecycle e test JSON/redazione/selezione snapshot/percorsi restore/summary backup senza Docker reale.
- [ ] Collaudo regressioni reale dell'utente su backup, elenco e restore.

Aggiornato: 11 novembre 2026

## Priorità: fix shutdown Apache/PHP-FPM in produzione

- [x] Individuata la causa: shell PID 1 con `CMD php-fpm8.4 && httpd-foreground`, senza inoltro esplicito dei segnali ai servizi.
- [x] Preparato `config/httpd/start-services.sh`: supervisiona entrambi i servizi foreground, inoltra WINCH ad Apache e ne attende il drain, poi QUIT a PHP-FPM.
- [x] Configurato ioss tramite bind mount RO dello script, `command: ["/bin/bash", "/usr/local/bin/start-services.sh"]` e `stop_signal: SIGTERM`. Nessun rebuild necessario per questa variante.
- [x] Aggiunto lo script e corretto Compose di nospace.net: inizialmente era presente solo il mount, mancavano command e stop_signal.
- [ ] Confermare shutdown rapido di nospace.net dopo ricreazione del container con Compose corretto.
- [ ] Confermare collaudo ioss della variante con bind mount: il test reale riuscito usava lo script incluso nell’immagine.
- [ ] Distribuire script e modifica Compose a tutti gli stack di produzione, verificando comando/versione PHP-FPM e percorsi.
- [ ] In finestra di manutenzione, ricreare solo Apache con immagine esistente (`--no-deps --no-build --pull never --force-recreate apache`); conservare configurazione precedente per rollback. Il primo arresto del vecchio container può essere lento.
- [ ] Verificare sito, richieste PHP, log e shutdown dopo ogni aggiornamento.

Riferimenti locali: `sites/ioss/config/httpd/start-services.sh`, `sites/ioss/docker-compose.yml` e corrispondenti file in `sites/nospace.net/`.
Lo script è incluso nel backup attraverso `config/`. Ricreare il container dopo aggiornamenti dello script rinnova anche il bind mount in caso di sostituzione atomica del file.

## Ambiente e limiti

- Collaudo: WSL, `/workspace`; stack in `/workspace/sites`.
- Produzione: VPS cliente, `/opt`; stack previsti in `/opt/stacks`.
- Continuare i test su WSL; non distribuire l’orchestratore sperimentale in produzione.
- Nessun intervento sulla VPS eseguito durante questo lavoro.
- L’agente non ha accesso al socket Docker: i test Docker reali sono stati eseguiti dall’utente.

## Funzionalità implementate

- [x] Repository Restic separato per stack, password comune per ambiente, descrittore `.backup` opt-in.
- [x] `.backup` elenca percorsi relativi da includere; include automaticamente se stesso; richiede una sola direttiva `docker-stop=true|false`.
- [x] Orchestratore `stacks-backup.sh`: `--check`, `--init`, `--backup`; diagnostica umana su stderr e JSONL su stdout a fine esecuzione.
- [x] `--backup` inizializza automaticamente repository mancanti dopo il preflight globale, sotto lock; riusa quelli esistenti e interrompe se init fallisce.
- [x] Percorsi configurabili tramite `backup.env`; Restic Docker `restic/restic:0.19.1`.
- [x] Snapshot ID completo estratto dall’output JSON; timeout, diagnostica privata con redazione password ed exit code significativi.
- [x] Repository montato RW per i lock Restic, password e dati sorgente RO; probe/init senza mount dei dati sorgente.
- [x] Lock invocazioni concorrenti, controlli link/permessi e hash del descrittore prima/dopo il backup.
- [x] `docker-stop=false`: rifiuta il backup se Compose riporta container attivi o stati non riconosciuti.
- [x] `docker-stop=true`: registra ID/stato, ferma solo i container running, verifica uscita pulita senza OOM e ripristina gli ID inizialmente running. Non usa compose up e non crea servizi.
- [x] Recupero tentato dopo errori e nei trap EXIT/INT/TERM; errori di restart espliciti e ID conservati per nuovo tentativo. Recupero dopo timeout stop ancora da rafforzare.
- [x] Stop con `--timeout -1` per evitare force-kill dell’applicazione; attesa client limitata da DOCKER_TIMEOUT. Verifica container spenti prima e dopo Restic.

## Collaudi completati

- [x] Revisione precedente: 71/71 test simulati superati; artefatti di audit rimossi su richiesta.
- [x] Test attuali in `tests/backup-lifecycle.sh`: preservazione stopped, stop timeout, uscita non pulita, errore/retry restart, ordine init/backup e recupero dopo backup fallito. Sintassi Bash verificata.
- [x] WSL: check, init idempotente precedente e init automatico ioss riusciti; repository esistenti riutilizzati nel successivo backup senza reinizializzazione.
- [x] WSL multi-stack, run `20261111T060146Z-16826`: exit 0, due backup riusciti. ioss inizialmente running, stop circa 2 s, acquisizione 21 s, entrambi gli stessi ID tornati running; intervallo stop/ripristino circa 24 s. nospace.net spento, acquisizione 3 s, nessuna operazione lifecycle.
- [x] nospace.net: restore isolati, confronto SHA-256 completo e controlli integrità/read-data riusciti (dettagli sotto).
- [x] ioss: restore con `--verify` riuscito; MariaDB e sito ripristinati avviati e funzionanti.
- [x] Chiarito il problema permessi ioss: directory data/www/ioss con owner node:node e mode 700 già nell’originale; restore coerente. Correzione manuale a www-data:www-data ha consentito l’accesso Apache. Nessun difetto del backup/restore; possibile precedente estrazione tar, non verificata.

## Prossimo lavoro: affidabilità prima dell’automazione

- [x] Correggere il recupero dopo timeout stop: mantenere il client stop attivo oltre DOCKER_TIMEOUT e attendere conferma di completamento, con STOP_RECOVERY_TIMEOUT (default 120 s). Backup annullato al primo timeout; restart automatico solo dopo esito stop confermato. In caso incerto, rifiutare restart anche nei trap e segnalare ID per recupero manuale.
- [ ] Collaudare sul campo stop normale, completamento durante recupero e scadenza di entrambi i limiti; istruzioni e risultati attesi nel README. Validare anche INT/TERM durante lo stop e gli errori del daemon. Implementazione verificata solo per sintassi; collaudo affidato all'utente.
- [ ] Collaudare realmente errori/timeout Restic, cleanup e interruzioni INT/TERM in un ambiente di prova dedicato.
- [ ] Collaudare stack docker-stop=true con container inizialmente running e stopped insieme: quelli stopped devono rimanere spenti.
- [ ] Verificare ordine dipendenze e disponibilità applicativa dopo riavvio: running non equivale a servizio pronto.
- [ ] Escludere writer esterni sui percorsi inclusi: processi host, altri stack e automazioni concorrenti. Le verifiche prima/dopo non impediscono scritture o restart esterni durante il backup.
- [ ] Eseguire `restic check --read-data` sul repository ioss: restore --verify controlla i file dello snapshot, non tutto il repository.
- [ ] Verificare conservazione ACL se richiesta per il deployment; non ancora collaudata esplicitamente.

SIGKILL, crash host o daemon indisponibile possono richiedere recupero manuale. L’orchestratore non è ancora considerato pronto per la produzione.

## Passaggi successivi

- [ ] Replica verso repository remoti separati (`restic copy`), gestione errori e protezione degli snapshot locali non ancora replicati.
- [ ] Retention: ipotesi iniziale 7 giornalieri, 4 settimanali; definire politica prima di implementarla.
- [ ] Controlli integrità e prove periodiche di ripristino completo.
- [ ] Rotazione dei log privati prima dell’automazione.
- [ ] Timer systemd come root, journald, notifiche e futura integrazione Uptime Kuma.
- [ ] Documentare recupero password fuori dalla VPS, immagini/versioni necessarie e procedura di disaster recovery.

## Evidenze e snapshot di riferimento

### nospace.net

- Primi snapshot: `0772dc87`, `7e0ed3b8`; deduplicazione/compressione verificate (2 snapshot, 67,729 MiB di blob compressi referenziati).
- Restore `7e0ed3b8` in `/workspace/restore-nospace-7e0ed3b8-3viVS6`: exit 0; confronto completo con sudo, 11.867 file e 3.756 directory, 371.692.388 byte, zero differenze/errori. Il primo confronto senza privilegi era incompleto per 29 errori di lettura; superato dal confronto con sudo.
- Snapshot `d6c8c2e112df913108e2794db10d608e1bfe9b5b209e6b4670759ea758b97e79`, run `20261110T105209Z-57334`: backup exit 0; restore in `/workspace/restore-nospace-d6c8c2e1-Bjrcam`, SHA-256 match sugli stessi conteggi, check strutturale 3/3 snapshot e lettura completa 6/6 pack, exit 0.
- Backup riuscito durante il run parzialmente fallito `20261111T054915Z-3553`: `f6b6080eac3ec79dab283c9a4115fb85574cf37651b5c99ff9a3337c3860a719`.
- Backup multi-stack riuscito: `41519aaa79eca9ff35f33a0667de628f8364678add539a9e8611f4b3151a6b4b`.
- Database ripristinato nospace.net non avviato durante quei test.

### ioss

- Run `20261111T054915Z-3553`: init automatico riuscito, stop exit 124, nessun backup ioss; run globale exit 1. MariaDB fermato e riavviato; Apache mai arrestato. Diagnosi PID 1 shell e SIGWINCH ha portato al fix di avvio.
- Run riuscito `20261111T060146Z-16826`, snapshot `3b5ec1207227c8b94da6479513fa8d0ba8b48f0814bf21838800bdd62af93885`.
- Restore in `/workspace/restore-ioss-3b5ec120-khFgte`: 39.202 file/directory, 1,104 GiB in 27 s; `--verify` su 31.328 file in 2,872 s, exit 0.
- Stack ripristinato in `/workspace/restore-ioss-3b5ec120-khFgte/stacks/ioss`; originali non montati durante il restore.
- Utente ha fermato lo stack originale per provare la copia con nomi/porte originali: MariaDB e sito funzionanti dopo correzione dei permessi preesistenti. Non confrontare byte-per-byte un datadir originale attivo con lo snapshot precedente.

## Chiusura e pulizia del collaudo

- [ ] Confermare ritorno allo stack originale ioss dopo il test.
- [ ] Verificare se esistono ancora e rimuovere quando non servono le sole copie di restore: `/workspace/restore-nospace-7e0ed3b8-3viVS6`, `/workspace/restore-nospace-d6c8c2e1-Bjrcam`, `/workspace/restore-ioss-3b5ec120-khFgte`. Prima fermare eventuali container che usano la copia; operazione manuale con sudo su WSL.
- [x] Vecchio backup-audit/, backup-check.jsonl e backup-run.jsonl rimossi su richiesta precedente; successivi test possono aver ricreato backup-run.jsonl.
- Conservare orchestratore, Compose, backup.env, repository/snapshot, password e dati originali.

## Helper restore — 11 novembre 2026

- [x] Aggiunto stacks-restore.sh, riusa backup.env e invocatore Restic per gli elenchi.
- `--list`: una riga per repository, conteggio snapshot e stato AVAILABLE/EMPTY/ERROR.
- `--list NAME`: date, stato AVAILABLE e ID completi. AVAILABLE indica presenza elencata da Restic, non integrità o restore già verificati.
- `NAME --snapshot ID|latest`: risolve ID completo (prefisso minimo 8 caratteri, non ambiguo), crea nuova directory privata sotto RESTORE_DIR, restore --verify senza mount originali e senza avviare container. Mantiene file parziali se fallisce.
- [x] Sintassi e test simulati: elenco distinto, dettagli snapshot, rifiuto nome non sicuro, errore motore; regressione lifecycle superata.
- [ ] Collaudo reale WSL di elenco e restore tramite helper ancora necessario.
- Verifica timeout lifecycle resta il prossimo lavoro, sospesa per introdurre l’helper restore richiesto.

- [x] RESTORE_DIR configurabile in backup.env (default BACKUP_ROOT/restores), attuale /workspace/restores. Directory base creata automaticamente se assente, sottocartelle private uniche; percorsi con symlink rifiutati. Restore precedenti non spostati.
- [x] Restore helper: elimina i livelli ridondanti stacks/NAME usando la sintassi Restic ID:sottocartella. Radice ricavata dai paths dello snapshot tramite .backup (supporta backup Docker e host); rifiuta paths esterni alla radice. Contenuti direttamente in RESTORE_DIR/restore-NAME-ID-casuale/. Collaudo reale della nuova disposizione ancora necessario.
