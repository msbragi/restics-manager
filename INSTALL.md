# Prima installazione sulla VPS

Procedura per Ubuntu/Debian. Eseguire manualmente; iniziare con uno stack di prova.

## 1. Layout consigliato

```text
/opt/restics-manager/           script e backup.env (repository Git)
/srv/restics/
├── repositories/              repository Restic, uno per stack
├── secrets/restic.password    password, fuori da Git
├── logs/                      diagnostica privata
└── restores/                  copie ripristinate per verifica
```

Gli stack rimangono dove sono già installati: configurare `STACKS_DIR` con il loro percorso reale. Non spostare i siti per installare questi script. Evitare link simbolici nei percorsi configurati. Conservare dati e secret fuori dal repository Git facilita gli aggiornamenti degli script.

## 2. Prerequisiti

- Docker Engine attivo e Docker Compose v2 funzionante. Se mancano, seguire le [istruzioni ufficiali Docker](https://docs.docker.com/engine/install/).
- Bash, coreutils, util-linux (`flock`), `jq`; Git per scaricare il progetto e OpenSSL per generare la password.

```bash
sudo apt update
sudo apt install git jq openssl coreutils util-linux
sudo docker info
sudo docker compose version
```

Non installare Python né Restic sull'host. L'immagine Restic viene scaricata automaticamente al primo utilizzo, se manca.

## 3. Script e directory

```bash
sudo git clone https://github.com/msbragi/restics-manager.git /opt/restics-manager
sudo install -d -m 700 /srv/restics
sudo install -d -m 700 /srv/restics/repositories /srv/restics/secrets /srv/restics/logs /srv/restics/restores
```

Se stai migrando repository esistenti, riutilizza i loro dati e la loro password: non generarne una nuova al posto di quella originale.

## 4. Generare la password, una sola volta

```bash
sudo bash -c 'umask 077; set -o noclobber; openssl rand -base64 48 > /srv/restics/secrets/restic.password'
```

Il comando crea il file con permessi `600` e rifiuta di sovrascriverne uno esistente. Usa il generatore casuale di [OpenSSL](https://docs.openssl.org/master/man1/openssl-rand/).

Conserva una copia della password in un password manager separato dalla VPS: perderla impedisce il recupero dei backup. Non inserirla in `backup.env`, Git o nei comandi del terminale.

## 5. Configurare backup.env

```bash
sudoedit /opt/restics-manager/backup.env
```

Impostare questi percorsi, adattando `STACKS_DIR` alla VPS:

```dotenv
BACKUP_ROOT=/srv/restics
STACKS_DIR=/opt/stacks
REPOSITORIES_DIR=/srv/restics/repositories
RESTIC_PASSWORD_FILE=/srv/restics/secrets/restic.password
BACKUP_LOG_DIR=/srv/restics/logs
RESTORE_DIR=/srv/restics/restores
RESTIC_IMAGE=restic/restic:0.19.1
#RESTIC_PULL_TIMEOUT=600
#RESTIC_CHECK_TIMEOUT=60
#RESTIC_BACKUP_TIMEOUT=3600
#DOCKER_TIMEOUT=30
#STOP_RECOVERY_TIMEOUT=120
```

Lasciare inizialmente invariati i timeout già presenti. Usare percorsi assoluti letterali, senza virgolette o variabili shell. Tutte le cartelle sotto `STACKS_DIR` con un file `.backup` vengono considerate: per il primo test abilita soltanto lo stack di prova.

## 6. Abilitare lo stack di prova

Nella sua directory, accanto a `docker-compose.yml`, creare `.backup`:

```text
docker-stop=true
docker-compose.yml
```

Questo esempio salva soltanto Compose e il descrittore. Per un backup reale aggiungere i percorsi relativi di dati, configurazioni e secret applicativi necessari al ripristino; devono esistere. I volumi Docker esterni a questi percorsi non vengono inclusi automaticamente.

## 7. Primo controllo, backup e restore

```bash
cd /opt/restics-manager
sudo bash stacks-backup.sh -c backup.env --check
echo $?
```

Atteso: exit `0`; `NOT_INITIALIZED` è normale al primo controllo. Il check non ferma i container. Se manca l'immagine, scarica `restic/restic:0.19.1`.

Quando il check passa, eseguire sullo stack di prova:

```bash
sudo bash stacks-backup.sh -c backup.env --backup
echo $?
sudo bash stacks-restore.sh -c backup.env --list
```

Il backup inizializza automaticamente il repository. Con `docker-stop=true` ferma temporaneamente i container attivi e tenta di riavviarli dopo l'acquisizione. Verificare exit `0`, snapshot creato, stato dei container e risposta del sito.

Sostituire `NOME_STACK` con il nome della directory dello stack:

```bash
sudo bash stacks-restore.sh -c backup.env NOME_STACK --snapshot latest
echo $?
```

Il restore verificato viene scritto in una nuova directory sotto `/srv/restics/restores`, senza avviare container né sovrascrivere lo stack originale. Controllare i file ripristinati. Tenere spazio libero anche per questa copia, oltre ai repository. I restore contengono dati decifrati: rimuovere le copie di prova quando non servono più.

Completare questa prova prima di introdurre pianificazione, rotazione e trasferimento remoto. I backup locali da soli non proteggono dalla perdita della VPS.
