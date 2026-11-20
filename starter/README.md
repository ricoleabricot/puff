# Puff starter, your cloud on your laptop

Your AWS for this course is **Floci**, a local AWS emulator. Same AWS CLI, same APIs, runs in Docker.
Full guide: https://ricoleabricot.github.io/puff/setup/

## Run it

On your laptop (Docker Desktop running), macOS / Linux:

    docker compose up -d
    source env.sh
    ./doctor.sh

Windows (PowerShell):

    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   # once
    docker compose up -d
    . .\env.ps1
    .\doctor.ps1

Or in a GitHub Codespace: open your group repo on GitHub → Code → Codespaces → Create. Floci starts by itself, then `source env.sh && ./doctor.sh`.

## Files

| File | What |
|---|---|
| `docker-compose.yml` | Floci 2.5.0, don't change it |
| `env.sh` / `env.ps1` | `source env.sh` (Windows: `. .\env.ps1`) in every new terminal |
| `doctor.sh` / `doctor.ps1` | checks your setup |
| `wipe.sh` / `wipe.ps1` | deletes all your local AWS resources |
| `infra/deploy.sh` / `.ps1` | your group's infra, command by command |
| `checks/check.sh` / `.ps1` | milestone checks, `./checks/check.sh M1` (Windows: `.\checks\check.ps1 M1`) |
| `NOTES.md` | your decisions, becomes your pitch |
