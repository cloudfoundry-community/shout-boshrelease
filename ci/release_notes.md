# Shout! BOSH release 0.2.0

This release replaces the Common Lisp server with the Go version of Shout!, which ships as a static linux/amd64 binary. It is a breaking release, because the rules format, some job properties, and the start-up behaviour have all changed.

## What changed

- **The Go server**

  The `shout` package installs a static binary built with `CGO_ENABLED=0` and `-trimpath`. The `sbcl` package and the Lisp source blob are gone, and nothing is compiled on the stemcell any more.

- **Resolute support**

  The job drops privileges with `setpriv` instead of `chpst`, so it runs on ubuntu-resolute stemcells, which ship without runit. It runs on ubuntu-jammy and ubuntu-noble as before.

- **YAML rules**

  The `rules` property now takes the YAML rules format of the Go server, either as a string or as a map. The job validates the rules when it renders, and the server loads them from `config/rules.yml` when it starts, so `post-start` no longer posts them to the API. A failed rule set now fails the deploy instead of leaving a running server with no rules.

- **Credentials**

  `ops.password` and `admin.password` no longer have defaults and must be set. The environment variables the server reads are now `SHOUT_OPS_AUTH` and `SHOUT_ADMIN_AUTH`, and the job writes them to a root-only file instead of putting them in the start script.

- **New properties**

  The job adds `expiry`, `startup_timeout`, `email.smtp_host`, `email.smtp_port`, `email.from`, `slack_app.token`, and `slack_app.channel`.

- **Removed properties**

  `log-level` is gone, because the Go server has no log levels.

- **Job tests**

  The release now has rspec tests for its templates, which `make spec` runs.

## Upgrading

We have to rewrite our rules in the YAML format before we upgrade, because the job refuses the Lisp DSL. Template fields are capitalised in the Go format, so `$topic` becomes `{{ .Topic }}` and `$status` becomes `{{ .Status }}`. A Lisp reminder such as `(remind 24 hours)` becomes `remind: 24h`.

Topic state stays in `/var/vcap/store/shout/shout.db`, but the Go server cannot read the state file of the Lisp server, which is a JSON list rather than an object keyed by topic. The job moves such a file aside to `shout.db.unreadable-<timestamp>` before the first start, so open topics start fresh and are tracked again from their next event.

Event payloads use `occurred_at` instead of `occurred-at`, and `POST /events` answers with `{"ok": ..., "transition": ...}`. `GET /state` now needs a `topic` query parameter, and `GET /states` returns every topic.

## Known issues

The Go server saves its state once a minute and does not save it again when it stops, so events that arrive in the last minute before a restart are lost. It also exits with status 1 after a clean SIGTERM, which monit does not act on.
