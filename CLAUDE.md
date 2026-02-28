# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A **BOSH release** that packages the [Shout!](https://github.com/cloudfoundry-community/shout) notifications gateway for deployment on Cloud Foundry infrastructure.

## Commands

```bash
bosh create-release                    # Create a dev release
bosh -e <director> -d shout deploy \
     -v slack_webhook=https://...  \
     manifests/shout.yml               # Deploy to BOSH director
```

## BOSH Release Structure

### Job: `shout` (`jobs/shout/`)

- **`spec`** — Job properties schema: `port` (default 7109), `log-level`, `ops.username`/`ops.password`, `admin.username`/`admin.password`, `rules`
- **`monit`** — Process monitoring via pidfile
- **`templates/bin/shout`** — Start/stop script. Sets env vars (`SHOUT_PORT`, `SHOUT_DATABASE`, `SHOUT_OPS_CREDS`, `SHOUT_ADMIN_CREDS`, `SHOUT_LOG_LEVEL`), runs as `vcap:vcap` via `chpst`, stores DB at `/var/vcap/store/shout/shout.db`
- **`templates/bin/post-start`** — Uploads notification rules to the running server via `curl POST /rules` with admin credentials
- **`templates/config/shout.rules`** — ERB template rendering the `rules` property into the Shout! DSL format

### Package: `shout` (`packages/shout/`)

Copies a precompiled ELF binary from `blobs/shout/shout` into the install target. No compilation step — the binary is stored as a blob.

### Deployment Manifest (`manifests/shout.yml`)

Single-instance deployment on `ubuntu-noble` stemcell. Takes `slack_webhook` as a deployment variable. Includes default notification rules that send all break/fix events to Slack with 24-hour reminders.

## Key Paths on Deployed VMs

| Path | Purpose |
|------|---------|
| `/var/vcap/packages/shout/bin/shout` | Shout! binary |
| `/var/vcap/jobs/shout/config/shout.rules` | Notification rules |
| `/var/vcap/store/shout/shout.db` | Persistent state database |
| `/var/vcap/sys/log/shout/shout.log` | Log output |
| `/var/vcap/sys/run/shout/shout.pid` | PID file |

## Blob Storage

Configured in `config/final.yml` to use S3 bucket `shout-boshrelease`. The Shout! binary blob is registered in `config/blobs.yml`.
