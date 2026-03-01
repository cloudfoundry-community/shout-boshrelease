# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A **BOSH release** that packages the [Shout!](https://github.com/cloudfoundry-community/shout) notifications gateway for deployment on Cloud Foundry infrastructure.

## Commands

```bash
make sbcl-blob      # Download Roswell SBCL binary and add as blob
make shout-blob     # Create shout source tarball (git archive) and add as blob
make blobs          # Both of the above
make upload-blobs   # Upload blobs to S3 blobstore
make release        # Create a BOSH dev release

bosh -e <director> -d shout deploy \
     -v slack_webhook=https://...  \
     manifests/shout.yml           # Deploy to BOSH director
```

The `SBCL_VERSION` (default 2.6.2) and `SHOUT_REPO` (default `../shout`) variables can be overridden:
```bash
make sbcl-blob SBCL_VERSION=2.6.3
make shout-blob SHOUT_REPO=/path/to/shout
```

## BOSH Release Structure

### Job: `shout` (`jobs/shout/`)

- **`spec`** — Job properties schema: `port` (default 7109), `log-level`, `ops.username`/`ops.password`, `admin.username`/`admin.password`, `rules`
- **`monit`** — Process monitoring via pidfile
- **`templates/bin/shout`** — Start/stop script. Sets env vars (`SHOUT_PORT`, `SHOUT_DATABASE`, `SHOUT_OPS_CREDS`, `SHOUT_ADMIN_CREDS`, `SHOUT_LOG_LEVEL`), runs as `vcap:vcap` via `chpst`, stores DB at `/var/vcap/store/shout/shout.db`
- **`templates/bin/post-start`** — Uploads notification rules to the running server via `curl POST /rules` with admin credentials
- **`templates/config/shout.rules`** — ERB template rendering the `rules` property into the Shout! DSL format

### Package: `sbcl` (`packages/sbcl/`)

Installs a pre-built SBCL binary from [Roswell sbcl_bin](https://github.com/roswell/sbcl_bin/releases). The binary is built with `--fancy` (includes core compression and threading). Currently uses SBCL 2.6.2 for linux x86-64.

### Package: `shout` (`packages/shout/`)

Depends on the `sbcl` package. Compiles Shout! from source on the stemcell using SBCL and vendored Quicklisp dependencies. The source is a git archive tarball (`shout/shout-src.tar.gz`) of the [shout repo](https://github.com/cloudfoundry-community/shout) including vendored Quicklisp in `vendor/quicklisp/`.

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

Configured in `config/final.yml` to use S3 bucket `shout-boshrelease`. Blobs are registered in `config/blobs.yml`.

Current blobs:
- `sbcl/sbcl-2.6.2-x86-64-linux-binary.tar.bz2` — Roswell pre-built SBCL binary
- `shout/shout-src.tar.gz` — Shout! source (git archive of the shout repo with vendored Quicklisp)

### Updating Blobs

Use the Makefile targets to update blobs. To change the SBCL version, update `SBCL_VERSION` in the Makefile and in `packages/sbcl/spec` and `packages/sbcl/packaging`, then run `make sbcl-blob`.

To refresh the shout source after code changes: `make shout-blob`

After updating blobs: `make upload-blobs` to push to S3.
