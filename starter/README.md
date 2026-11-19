# Puff starter, your cloud on your laptop

Your AWS for this course is **Floci**, a local AWS emulator. Same AWS CLI, same APIs, runs in Docker.
Full guide: https://ricoleabricot.github.io/puff/setup/

## Run it

On your laptop (Docker Desktop running):

    docker compose up -d
    source env.sh
    ./doctor.sh

Or in a GitHub Codespace: open your group repo on GitHub → Code → Codespaces → Create. Floci starts by itself, then `source env.sh && ./doctor.sh`.

## Files

| File | What |
|---|---|
| `docker-compose.yml` | Floci 2.5.0, don't change it |
| `env.sh` | `source env.sh` in every new terminal |
| `doctor.sh` | checks your setup |
| `wipe.sh` | deletes all your local AWS resources |
| `infra/deploy.sh` | your group's infra, command by command |
| `checks/check.sh` | milestone checks, `./checks/check.sh M1` |
| `NOTES.md` | your decisions, becomes your pitch |
