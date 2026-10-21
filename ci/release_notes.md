# Shout! BOSH release 0.2.0

This release replaces the Common Lisp server with the Go version of Shout!, which ships as a static linux/amd64 binary. It is a breaking release, because the rules format, some job properties, and the start-up behaviour have all changed.

## What changed

- **The Go server**

  The `shout` package installs a static binary built with `CGO_ENABLED=0` and `-trimpath`. The `sbcl` package and the Lisp source blob are gone, and nothing is compiled on the stemcell any more. The server saves its state once a minute and again when monit stops it, and it exits cleanly on SIGTERM. `bin/ctl` waits 20 seconds for that before it sends SIGKILL, which keeps it inside monit's 30-second limit for the stop program.

- **Resolute support**

  The job drops privileges with `setpriv` instead of `chpst`, so it runs on ubuntu-resolute stemcells, which ship without runit. It runs on ubuntu-jammy and ubuntu-noble as before. Like `chpst -u vcap:vcap`, it clears the supplementary groups, so the server runs with the `vcap` group only and cannot read files that `vcap` reaches through groups such as `adm`.

- **YAML rules**

  The `rules` property now takes the YAML rules format of the Go server, either as a string or as a map. The job validates the rules when it renders, and the server loads them from `config/rules.yml` when it starts, so `post-start` no longer posts them to the API. A failed rule set now fails the deploy instead of leaving a running server with no rules.

  The validation follows the Go server closely. It refuses handler arguments that a handler does not read, so a typo such as `chanel` fails the render instead of sending to the default channel. It accepts Go template fields inside `with`, `range`, `define`, and `block`, where the dot no longer means the event, and it reads `re:` patterns with Go's syntax, so `(?P<name>...)` and `(?s)` pass while `\Z`, possessive quantifiers, and lookaround fail. In the string form it refuses plain `yes`, `no`, `on`, and `off`, because the director reads them as booleans and the Go server reads them as text.

- **Credentials**

  `ops.password` and `admin.password` no longer have defaults and must be set. The environment variables the server reads are now `SHOUT_OPS_AUTH` and `SHOUT_ADMIN_AUTH`, and the job writes them to a root-only file instead of putting them in the start script.

- **New properties**

  The job adds `expiry`, `startup_timeout`, `email.smtp_host`, `email.smtp_port`, `email.from`, `slack_app.token`, and `slack_app.channel`.

- **Removed properties**

  `log-level` is gone, because the Go server has no log levels.

- **Job tests**

  The release now has rspec tests for its templates, which `make spec` runs through Bundler. They also run `bin/ctl` against a scratch store to check how it treats each kind of state file.

## Upgrading

We have to rewrite our rules in the YAML format before we upgrade, because the job refuses the Lisp DSL. Template fields are capitalised in the Go format, so `$topic` becomes `{{ .Topic }}` and `$status` becomes `{{ .Status }}`. A Lisp reminder such as `(remind 24 hours)` becomes `remind: 24h`.

Topic state stays in `/var/vcap/store/shout/shout.db`. The Lisp server saved it as a JSON list, and the Go server converts that list when it first starts. It keeps the original bytes as `shout.db.lisp-<timestamp>` next to the converted file and logs how many topics it imported, so open topics carry over the upgrade.

Before each start, `bin/ctl` asks the server's read-only state check about the file. When the server would refuse the file because it is in neither format, ctl moves it to `shout.db.unreadable-<timestamp>` and the server starts with empty state. When the check cannot read the file at all, ctl stops without moving anything, so the job fails visibly instead of discarding state. An empty or whitespace-only file holds no state, so ctl deletes it. Every start logs a reminder in `ctl.log` while any `shout.db.unreadable-*` file remains, and those files are ours to restore or delete.

Earlier 0.2.0 development builds moved Lisp state aside to `shout.db.unreadable-<timestamp>` without converting it. To recover that state, we stop the job, move the newest of those files to `shout.db`, and start the job again, and the server converts it.

Event payloads use `occurred_at` instead of `occurred-at`, and `POST /events` answers with `{"ok": ..., "transition": ...}`. `GET /state` now needs a `topic` query parameter, and `GET /states` returns every topic.

## Rolling back

The Lisp server cannot read the state that the Go server saves, so a plain redeploy of release 0.1.0 leaves the job failing at start. Release 0.1.0 also needs `chpst`, so a rollback works only on ubuntu-jammy or ubuntu-noble stemcells. To roll back, we follow these steps on each instance, as root.

1. Stop the job with `monit stop shout`, and wait until `monit summary` shows it stopped.

2. Move the Go state file aside, for example with `mv /var/vcap/store/shout/shout.db /var/vcap/store/shout/shout.db.go-backup`.

3. Copy the newest `shout.db.lisp-<timestamp>` file to `/var/vcap/store/shout/shout.db`, and run `chown vcap:vcap` on it.

4. Deploy release 0.1.0 with the Lisp rules it expects.

The Lisp server then starts from the state it had at the upgrade. Events that arrived while the Go server ran are not in that file, so the topics they touched are tracked again from their next event.
