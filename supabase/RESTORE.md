# Database backups & restore

Encrypted nightly backups run via [`.github/workflows/backup.yml`](../.github/workflows/backup.yml)
at 03:00 IST. Each run uploads one **AES-256 encrypted** artifact named
`almadina-db-<timestamp>` (kept 30 days) to the repo's Actions run.

The repo is public, so the dump is encrypted **before** upload. You need the
`BACKUP_PASSPHRASE` (stored as a GitHub secret) to decrypt it.

## Download a backup
GitHub → **Actions** → **Nightly DB backup** → pick a run → **Artifacts** →
download `almadina-db-<timestamp>` (a `.dump.enc` file inside a zip).

## Restore

```bash
# 1. Decrypt (you'll be prompted for, or pass, the BACKUP_PASSPHRASE)
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in almadina-<timestamp>.dump.enc -out restore.dump -pass pass:'<BACKUP_PASSPHRASE>'

# 2. Restore into a database (needs PostgreSQL 17 client tools)
pg_restore --clean --if-exists --no-owner --no-privileges \
  -d "<SUPABASE_DB_URL>" restore.dump
```

> ⚠️ `--clean` drops and recreates objects. Restore into a fresh/staging
> project first if you're unsure.

## Run a backup on demand
GitHub → **Actions** → **Nightly DB backup** → **Run workflow**, or:

```bash
gh workflow run backup.yml
```

## Secrets used
| Secret | What it is |
|---|---|
| `SUPABASE_DB_URL` | Session-pooler connection string (port 5432) |
| `BACKUP_PASSPHRASE` | Passphrase to encrypt/decrypt dumps — **keep it safe; without it backups are unrecoverable** |
