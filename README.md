Shout! (via BOSH)
=================

A notifications gateway for helping your little robot friends to be heard.

This release ships the Go version of [Shout!](https://github.com/cloudfoundry-community/shout) as a static linux/amd64 binary. Nothing is compiled on the stemcell, and the job runs on ubuntu-jammy, ubuntu-noble, and ubuntu-resolute stemcells alike.

Deploying
---------

The example manifest generates the ops and admin passwords and takes the Slack webhook as a deployment variable:

    bosh -e <your-bosh-director> -d shout deploy \
         -v slack_webhook=https://...your-slack-webhook... \
         manifests/shout.yml

Then we can talk to it on the standard port, 7109, through the [Concourse resource][concourse] or [with curl][api].

The `shout` job
---------------

The job starts the server under monit and drops from root to `vcap` with `setpriv` before the server runs. The server runs with the `vcap` group only, without vcap's supplementary groups. It keeps topic state in `/var/vcap/store/shout/shout.db`, so the instance group should have a persistent disk. On its first start after an upgrade from release 0.1.0, the server converts the Lisp state file and keeps the original as `shout.db.lisp-<timestamp>`. If the server could not read the file at all, the job moves it to `shout.db.unreadable-<timestamp>` and starts with empty state, and `ci/release_notes.md` explains how to restore it or roll back.

| Property | Default | Description |
|----------|---------|-------------|
| `port` | `7109` | The TCP port for the API. It must be 1024 or higher, because the server runs as `vcap`. |
| `ops.username` | `shouty` | The username for `POST /events`, `POST /announcements`, `GET /state`, and `GET /states`. |
| `ops.password` | none, required | The password for the ops endpoints. |
| `admin.username` | `admin` | The username for `GET /rules` and `POST /rules`. |
| `admin.password` | none, required | The password for the admin endpoints. |
| `expiry` | `86400` | How many seconds a topic's state is kept after its last event. Set it to `0` to keep state forever. |
| `startup_timeout` | `60` | How many seconds `post-start` waits for `GET /info` to answer. |
| `tls.certificate` | `""` | A PEM certificate. Setting it together with `tls.key` makes the server speak HTTPS. |
| `tls.key` | `""` | The PEM private key that goes with `tls.certificate`. |
| `email.smtp_host` | `localhost` | The SMTP relay that the `email` handler uses. |
| `email.smtp_port` | `25` | The port of the SMTP relay. |
| `email.from` | `shout@localhost` | The From address of notification emails. |
| `slack_app.token` | `""` | A default bot token for the `slack-app` handler. |
| `slack_app.channel` | `""` | A default channel for the `slack-app` handler. |
| `rules` | none, required | The notification rules, as a YAML string or as a map. |

Usernames must not contain a colon, because the server splits `user:pass` at the first one.

Rules
-----

The rules are YAML. Every `for` block whose topic pattern matches an event is evaluated, and inside a block the first `when` clause whose `match` expression is true fires its `do` actions. A `remind` duration makes Shout! repeat the notification while the topic stays broken.

```yaml
vars:
  webhook: https://hooks.slack.com/services/T00/B00/xxx

rules:
  - for: "*"
    when:
      - match: "*"
        remind: 24h
        do:
          - slack:
              webhook: "{{ .Vars.webhook }}"
              text:    "{{ .Topic }} is {{ .Status }}"
              color:   '{{ if .OK }}good{{ else }}danger{{ end }}'
```

A `for` pattern is `*`, an exact topic, a glob such as `shield-*`, or a Go regular expression prefixed with `re:`. A `match` expression uses [expr](https://expr-lang.org) syntax over `topic`, `ok`, `status`, `weekday`, `time`, `hour`, `minute`, and `between("08:00", "17:00")`. A `remind` value is a Go duration such as `30m`, `4h`, or `1h30m`. The handlers are `slack` (needs `webhook`), `slack-app` (needs `token` and `channel` unless the job sets defaults), `webhook` (needs `url`), and `email` (needs `to`). Handler arguments are Go templates over `.Topic`, `.OK`, `.Status`, `.Message`, `.Link`, `.Meta`, and `.Vars`, and the field names are capitalised.

The job checks the structure of the rules, the handler names and their required arguments, the `remind` durations, and the template field names when it renders, so most mistakes fail the deploy before anything starts. The server compiles the `match` expressions when it starts and refuses to run if one of them is invalid, and `post-start` then fails the deploy and points at `/var/vcap/sys/log/shout/shout.log`.

The rules in the job's configuration are loaded every time the server starts. Rules posted to `POST /rules` replace them until the next restart.

Building the release
--------------------

The blob is built from a checkout of the Go source:

    make shout-blob SHOUT_REPO=/path/to/shout SHOUT_VERSION=0.1.0-dev
    make spec
    bosh create-release --force

`make spec` runs the job tests through Bundler, so we run `bundle install` once before the first run. `make shout-blob` refuses a checkout with uncommitted changes, so that the commit stamped into the binary matches what was built. It builds with `CGO_ENABLED=0` and `-trimpath`, and it uses the commit date as the build date, so rebuilding one commit with one Go toolchain gives a byte-identical blob.

How Do I Contribute?
--------------------

  1. Fork this repo
  2. Create your feature branch (`git checkout -b my-new-feature`)
  3. Commit your changes (`git commit -am 'Added some feature'`)
  4. Push to the branch (`git push origin my-new-feature`)
  5. Create a new Pull Request in Github
  6. Profit!


[concourse]: https://github.com/jhunt/shout-resource
[api]:       https://github.com/cloudfoundry-community/shout/blob/main/API.md
