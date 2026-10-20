# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A **BOSH release** that packages the Go version of the [Shout!](https://github.com/cloudfoundry-community/shout) notifications gateway as a static linux/amd64 binary.

## Commands

```bash
make shout-blob SHOUT_REPO=/path/to/shout SHOUT_VERSION=0.1.0-dev  # build the binary and add it as a blob
make spec           # run the rspec job template tests
make upload-blobs   # upload blobs to the S3 blobstore
make release        # create a BOSH dev release

bosh -e <director> -d shout deploy \
     -v slack_webhook=https://...  \
     manifests/shout.yml
```

`scripts/build-shout-blob` does the work behind `make shout-blob`. It refuses a source checkout with uncommitted changes unless `ALLOW_DIRTY=1` is set, builds with `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath`, stamps the version and commit into `pkg/version` through `-ldflags`, and uses the commit date as the build date so that the blob is reproducible.

## BOSH Release Structure

### Package: `shout` (`packages/shout/`)

Installs the `shout/shout-linux-amd64` blob as `bin/shout` and runs `shout -version` to prove that it runs on the stemcell. It has no dependencies.

### Job: `shout` (`jobs/shout/`)

- **`spec`** lists the properties, which are `port`, `ops.*`, `admin.*`, `expiry`, `startup_timeout`, `tls.*`, `email.*`, `slack_app.*`, and `rules`.

- **`monit`** watches the pidfile that `bin/ctl` writes.

- **`templates/bin/ctl`** prepares the store and file permissions, sources `config/env`, and execs the server through `setpriv --reuid=vcap --regid=vcap --init-groups --no-new-privs`. Never use `chpst`, because ubuntu-resolute stemcells do not ship runit. It moves a Lisp-era or empty state file aside, because the Go server refuses to start on one.

- **`templates/bin/post-start`** waits for `GET /info` to answer.

- **`templates/config/env`** renders the `SHOUT_*` environment variables, with every value shell-quoted, and validates ports, credentials, and TLS.

- **`templates/config/rules.yml`** validates the YAML rules and renders them. Its error messages must never echo rule values, because rules carry webhook URLs and tokens.

### Tests (`spec/`)

`spec/shout_job_spec.rb` renders every template with `bosh-template` and checks both the output and the validation errors.

## Key Paths on Deployed VMs

| Path | Purpose |
|------|---------|
| `/var/vcap/packages/shout/bin/shout` | Shout! binary |
| `/var/vcap/jobs/shout/config/rules.yml` | Notification rules, loaded at start |
| `/var/vcap/jobs/shout/config/env` | Server environment, root-only |
| `/var/vcap/store/shout/shout.db` | Persistent state, saved once a minute |
| `/var/vcap/sys/log/shout/shout.log` | Server output |
| `/var/vcap/sys/log/shout/ctl.log` | Start and stop messages |
| `/var/vcap/sys/run/shout/shout.pid` | PID file |

## Blob Storage

`config/final.yml` points at the S3 bucket `shout-boshrelease`, and `config/blobs.yml` registers the single blob `shout/shout-linux-amd64`. After updating it, `make upload-blobs` pushes it to S3, which needs `config/private.yml`.
