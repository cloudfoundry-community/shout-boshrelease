require 'spec_helper'

describe 'shout job' do
  let(:job) { Bosh::Template::Test::ReleaseDir.new(RELEASE_DIR).job('shout') }

  let(:valid_rules) do
    <<~YAML
      vars:
        webhook: "https://hooks.slack.com/services/T00/B00/secret-token"
      rules:
        - for: "*"
          when:
            - match: "*"
              remind: 24h
              do:
                - slack:
                    webhook: "{{ .Vars.webhook }}"
                    text: "{{ .Topic }} is {{ .Status }}"
                    color: '{{ if .OK }}good{{ else }}danger{{ end }}'
    YAML
  end

  let(:base_properties) do
    {
      'ops'   => { 'password' => 'ops-secret' },
      'admin' => { 'password' => 'admin-secret' },
      'rules' => valid_rules,
    }
  end

  def render(template_path, properties)
    job.template(template_path).render(properties)
  end

  # Source the rendered env file in a clean bash and return the exported
  # variables, which proves the quoting survives the shell.
  def source_env(content)
    script = "set -eu\n#{content}\nenv -0"
    out, err, status = Open3.capture3({}, '/bin/bash', '--noprofile', '--norc', '-c', script)
    raise "bash failed: #{err}" unless status.success?
    out.split("\0").map { |kv| kv.split('=', 2) }.to_h.select { |k, _| k.start_with?('SHOUT_') }
  end

  describe 'config/env' do
    it 'exports the server settings with their defaults' do
      env = source_env(render('config/env', base_properties))
      expect(env).to eq(
        'SHOUT_PORT'       => '7109',
        'SHOUT_DATABASE'   => '/var/vcap/store/shout/shout.db',
        'SHOUT_RULES'      => '/var/vcap/jobs/shout/config/rules.yml',
        'SHOUT_EXPIRY'     => '86400',
        'SHOUT_OPS_AUTH'   => 'shouty:ops-secret',
        'SHOUT_ADMIN_AUTH' => 'admin:admin-secret',
        'SHOUT_SMTP_HOST'  => 'localhost',
        'SHOUT_SMTP_PORT'  => '25',
        'SHOUT_EMAIL_FROM' => 'shout@localhost',
      )
    end

    it 'quotes credentials that contain shell metacharacters' do
      props = base_properties.merge('ops' => { 'username' => 'ops', 'password' => %q{a'b"c $d `e` :f} })
      env = source_env(render('config/env', props))
      expect(env['SHOUT_OPS_AUTH']).to eq(%q{ops:a'b"c $d `e` :f})
    end

    it 'accepts an expiry of 0 to keep state forever' do
      env = source_env(render('config/env', base_properties.merge('expiry' => 0)))
      expect(env['SHOUT_EXPIRY']).to eq('0')
    end

    it 'exports the slack-app defaults only when they are set' do
      env = source_env(render('config/env', base_properties))
      expect(env).not_to have_key('SHOUT_SLACK_TOKEN')
      props = base_properties.merge('slack_app' => { 'token' => 'xoxb-1', 'channel' => '#ops' })
      env = source_env(render('config/env', props))
      expect(env['SHOUT_SLACK_TOKEN']).to eq('xoxb-1')
      expect(env['SHOUT_SLACK_CHANNEL']).to eq('#ops')
    end

    it 'points the server at the TLS files when a certificate and key are set' do
      props = base_properties.merge('tls' => {
        'certificate' => "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
        'key'         => "-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----\n",
      })
      env = source_env(render('config/env', props))
      expect(env['SHOUT_TLS_CERT']).to eq('/var/vcap/jobs/shout/config/tls.crt')
      expect(env['SHOUT_TLS_KEY']).to eq('/var/vcap/jobs/shout/config/tls.key')
    end

    it 'leaves TLS off by default' do
      env = source_env(render('config/env', base_properties))
      expect(env.keys.grep(/TLS/)).to be_empty
    end

    it 'refuses a certificate without a key' do
      props = base_properties.merge('tls' => { 'certificate' => "-----BEGIN CERTIFICATE-----\n" })
      expect { render('config/env', props) }.to raise_error(/must be set together; only tls.certificate is set/)
    end

    it 'refuses a key that is not PEM' do
      props = base_properties.merge('tls' => { 'certificate' => "-----BEGIN CERTIFICATE-----\n", 'key' => 'nope' })
      expect { render('config/env', props) }.to raise_error(/tls.key is not a PEM-encoded private key/)
    end

    it 'refuses a missing password' do
      props = base_properties.merge('admin' => {})
      expect { render('config/env', props) }.to raise_error(/admin.password/)
    end

    it 'refuses an empty password' do
      props = base_properties.merge('ops' => { 'password' => '' })
      expect { render('config/env', props) }.to raise_error(/ops.password must not be empty/)
    end

    it 'refuses a username with a colon' do
      props = base_properties.merge('ops' => { 'username' => 'a:b', 'password' => 'x' })
      expect { render('config/env', props) }.to raise_error(/must not contain a colon/)
    end

    it 'refuses a privileged port' do
      expect { render('config/env', base_properties.merge('port' => 443)) }.to raise_error(/port must be between 1024 and 65535/)
    end

    it 'refuses a port that is not a number' do
      expect { render('config/env', base_properties.merge('port' => 'http')) }.to raise_error(/port must be an integer/)
    end

    it 'accepts a numeric string port' do
      env = source_env(render('config/env', base_properties.merge('port' => '8443')))
      expect(env['SHOUT_PORT']).to eq('8443')
    end

    it 'refuses a negative expiry' do
      expect { render('config/env', base_properties.merge('expiry' => -1)) }.to raise_error(/expiry must be at least 0, got -1/)
    end

    it 'refuses an SMTP port out of range' do
      props = base_properties.merge('email' => { 'smtp_port' => 70000 })
      expect { render('config/env', props) }.to raise_error(/email.smtp_port must be between 1 and 65535/)
    end
  end

  describe 'config/rules.yml' do
    it 'renders a YAML string verbatim' do
      expect(render('config/rules.yml', base_properties)).to eq(valid_rules + "\n")
    end

    it 'renders a map as YAML' do
      props = base_properties.merge('rules' => YAML.safe_load(valid_rules))
      expect(YAML.safe_load(render('config/rules.yml', props))).to eq(YAML.safe_load(valid_rules))
    end

    it 'accepts an empty rule list' do
      expect { render('config/rules.yml', base_properties.merge('rules' => "rules: []\n")) }.not_to raise_error
    end

    it 'accepts every handler with its required arguments' do
      rules = {
        'rules' => [{
          'for'  => 're:^prod-.*',
          'when' => [
            { 'match' => 'between("08:00", "17:00") && !ok', 'remind' => '1h30m', 'do' => [
              { 'slack-app' => { 'token' => 'xoxb', 'channel' => '#ops', 'text' => '{{ .Topic }}' } },
              { 'webhook'   => { 'url' => 'https://example.com/hook' } },
              { 'email'     => { 'to' => 'ops@example.com', 'subject' => '{{ .Topic }} {{ .Status }}', 'body' => '{{ .Message }} {{ .Meta.build }}' } },
            ] },
            { 'do' => [] },
          ],
        }],
      }
      expect { render('config/rules.yml', base_properties.merge('rules' => rules)) }.not_to raise_error
    end

    it 'lets slack-app rely on the job defaults for token and channel' do
      rules = "rules:\n  - for: x\n    when:\n      - do:\n          - slack-app: { text: hi }\n"
      expect { render('config/rules.yml', base_properties.merge('rules' => rules)) }.to raise_error(/missing required argument\(s\) token, channel/)
      props = base_properties.merge('rules' => rules, 'slack_app' => { 'token' => 't', 'channel' => 'c' })
      expect { render('config/rules.yml', props) }.not_to raise_error
    end

    it 'accepts lookup calls and template comments' do
      rules = "rules:\n  - for: x\n    when:\n      - do:\n          - webhook: { url: '{{/* .nope */}}{{ lookup .Vars.hooks .Topic \"de.fault\" }}' }\n"
      expect { render('config/rules.yml', base_properties.merge('rules' => rules)) }.not_to raise_error
    end

    it 'refuses the Lisp DSL' do
      props = base_properties.merge('rules' => "(for *\n  (when *\n    (remind 24 hours)))\n")
      expect { render('config/rules.yml', props) }.to raise_error(/Lisp rules DSL is no longer supported/)
    end

    it 'refuses YAML that does not parse, without echoing it' do
      props = base_properties.merge('rules' => "rules:\n  - for: \"x\n    secret-token: [\n")
      expect { render('config/rules.yml', props) }.to raise_error { |e|
        expect(e.message).to match(/could not be loaded as plain YAML/)
        expect(e.message).not_to include('secret-token')
      }
    end

    it 'refuses a top level that is not a map' do
      expect { render('config/rules.yml', base_properties.merge('rules' => "- a\n- b\n")) }.to raise_error(/top level must be a map/)
    end

    it 'refuses unknown top-level keys' do
      props = base_properties.merge('rules' => "rule: []\n")
      expect { render('config/rules.yml', props) }.to raise_error(/unknown key\(s\) rule/)
    end

    it 'refuses a missing rules list' do
      props = base_properties.merge('rules' => "vars: {}\n")
      expect { render('config/rules.yml', props) }.to raise_error(/rules: rules: is missing/)
    end

    it 'refuses a rule without a when list' do
      props = base_properties.merge('rules' => "rules:\n  - for: x\n")
      expect { render('config/rules.yml', props) }.to raise_error(/rules\[0\].when: must be a non-empty list/)
    end

    it 'refuses a remind without a unit' do
      props = base_properties.merge('rules' => valid_rules.sub('remind: 24h', 'remind: 24'))
      expect { render('config/rules.yml', props) }.to raise_error(/rules\[0\].when\[0\].remind: must be a Go duration/)
    end

    it 'refuses the Lisp-style remind phrase' do
      props = base_properties.merge('rules' => valid_rules.sub('remind: 24h', 'remind: 24 hours'))
      expect { render('config/rules.yml', props) }.to raise_error(/must be a Go duration/)
    end

    it 'refuses an unknown handler' do
      props = base_properties.merge('rules' => valid_rules.sub('- slack:', '- pager:'))
      expect { render('config/rules.yml', props) }.to raise_error(/do\[0\].pager: unknown handler/)
    end

    it 'refuses a slack action without a webhook' do
      props = base_properties.merge('rules' => valid_rules.sub(/^ *webhook: "\{\{ \.Vars\.webhook \}\}"\n/, ''))
      expect { render('config/rules.yml', props) }.to raise_error(/slack: is missing required argument\(s\) webhook/)
    end

    it 'refuses lowercase template fields and suggests the right one' do
      props = base_properties.merge('rules' => valid_rules.sub('{{ .Topic }}', '{{ .topic }}'))
      expect { render('config/rules.yml', props) }.to raise_error(/slack.text: template refers to .topic, which is not a field; use .Topic instead/)
    end

    it 'refuses unknown template fields without echoing the value' do
      props = base_properties.merge('rules' => valid_rules.sub('{{ .Vars.webhook }}', 'https://x/secret-token{{ .Nope }}'))
      expect { render('config/rules.yml', props) }.to raise_error { |e|
        expect(e.message).to match(/template refers to .Nope/)
        expect(e.message).not_to include('secret-token')
      }
    end

    it 'accepts a boolean match, which the server reads as an expression' do
      rules = { 'rules' => [{ 'for' => '*', 'when' => [{ 'match' => true, 'do' => [] }] }] }
      expect { render('config/rules.yml', base_properties.merge('rules' => rules)) }.not_to raise_error
    end

    it 'refuses a match that is not a string' do
      rules = { 'rules' => [{ 'for' => '*', 'when' => [{ 'match' => ['ok'], 'do' => [] }] }] }
      expect { render('config/rules.yml', base_properties.merge('rules' => rules)) }
        .to raise_error(/when\[0\]\.match: must be a string expression/)
    end

    it 'refuses a nested argument value' do
      props = base_properties.merge('rules' => valid_rules.sub(/color: .*$/, 'color: { a: b }'))
      expect { render('config/rules.yml', props) }.to raise_error(/slack.color: must be a string/)
    end

    it 'refuses Go-incompatible regular expressions' do
      props = base_properties.merge('rules' => valid_rules.sub('for: "*"', 'for: "re:^prod-(?!test)"'))
      expect { render('config/rules.yml', props) }.to raise_error(/lookaround and backreferences/)
    end

    it 'refuses invalid regular expressions' do
      props = base_properties.merge('rules' => valid_rules.sub('for: "*"', 'for: "re:^prod-("'))
      expect { render('config/rules.yml', props) }.to raise_error(/rules\[0\].for: invalid regular expression/)
    end

    it 'refuses a missing rules property' do
      props = base_properties.reject { |k, _| k == 'rules' }
      expect { render('config/rules.yml', props) }.to raise_error(/Can't find property .*rules/)
    end

    it 'refuses the Lisp DSL when it opens with a set form or a comment' do
      lisp = "; old rules\n\n((set webhook \"https://hooks.example.com/x\")\n  (for *\n    (when *\n      (notify (slack webhook)))))\n"
      expect { render('config/rules.yml', base_properties.merge('rules' => lisp)) }
        .to raise_error(/Lisp rules DSL is no longer supported/)
    end

    def action_rules(handler, args)
      { 'rules' => [{ 'for' => 'x', 'when' => [{ 'do' => [{ handler => args }] }] }] }
    end

    it 'accepts fields of a rebound dot inside with, range, define, and block' do
      [
        '{{ with .Meta }}{{ .host }}{{ end }}',
        '{{ range $k, $v := .Vars.hooks }}{{ .url }}{{ $.Topic }}{{ end }}',
        '{{ with .Vars.hooks }}{{ .prod }}{{ else with .Meta }}{{ .host }}{{ else }}{{ .Topic }}{{ end }}',
        '{{ define "t" }}{{ .anything }}{{ end }}{{ template "t" .Meta }}',
        '{{ block "b" .Meta }}{{ .host }}{{ end }}',
        '{{- .Topic -}} {{- if .OK }}ok{{ end -}}',
      ].each do |tmpl|
        props = base_properties.merge('rules' => action_rules('webhook', 'url' => tmpl))
        expect { render('config/rules.yml', props) }.not_to raise_error, tmpl
      end
    end

    it 'checks root fields outside rebound blocks, in else branches, and through $' do
      [
        ['{{ with .Meta }}{{ .host }}{{ end }}{{ .host }}', '.host'],
        ['{{ with .Meta }}{{ .host }}{{ else }}{{ .host }}{{ end }}', '.host'],
        ['{{ with .meta }}{{ end }}', '.meta'],
        ['{{ range .Vars.x }}{{ $.Nope }}{{ end }}', '.Nope'],
        ['{{- .topic -}}', '.topic'],
      ].each do |tmpl, field|
        props = base_properties.merge('rules' => action_rules('webhook', 'url' => tmpl))
        expect { render('config/rules.yml', props) }.to raise_error(/template refers to #{Regexp.escape(field)},/), tmpl
      end
    end

    it 'accepts regular expressions that Go accepts and Ruby reads differently' do
      ['^(?P<env>prod|stage)-', '^(?<env>prod)-', '(?s)a.b', '(?U)a+', '(?i:prod)|stage', '\\pL+', '\\p{Greek}',
       '\\x{41}', '\\Qa.b\\E', '[[:alpha:]]+', '[]a]', 'a{2}?', '\\12', 'a\\z'].each do |pattern|
        props = base_properties.merge('rules' => valid_rules.sub('for: "*"') { "for: 're:#{pattern}'" })
        expect { render('config/rules.yml', props) }.not_to raise_error, pattern
      end
    end

    it 'refuses regular expressions that Go refuses' do
      {
        '\\Z'      => /uses \\Z, which Go/,
        '[\\A]'    => /uses \\A inside a character class/,
        '[\\z]'    => /uses \\z inside a character class/,
        '\\h'      => /uses \\h, which Go/,
        'a*+'      => /possessive and nested quantifiers/,
        'a{2}+'    => /possessive and nested quantifiers/,
        'a**'      => /possessive and nested quantifiers/,
        '(?>a)'    => /uses \(\?>, which Go/,
        '(?P=n)'   => /uses \(\?P=, which Go/,
        '(?x)a'    => /uses \(\?x, which Go/,
        '(?<=a)b'  => /lookaround and backreferences/,
        '(a)\\1'   => /lookaround and backreferences/,
        '\\k<n>'   => /lookaround and backreferences/,
        'a{1001}'  => /repeat counts above 1000/,
      }.each do |pattern, message|
        props = base_properties.merge('rules' => valid_rules.sub('for: "*"') { "for: 're:#{pattern}'" })
        expect { render('config/rules.yml', props) }.to raise_error(message), pattern
      end
    end

    it 'refuses YAML 1.1 booleans in the string form, which the server reads as text' do
      %w[yes No ON off True FALSE].each do |word|
        props = base_properties.merge('rules' => valid_rules.sub('match: "*"', "match: #{word}"))
        expect { render('config/rules.yml', props) }
          .to raise_error(/line 6: the plain value #{word} is a boolean to the BOSH director but a string to the Go server/), word
      end
    end

    it 'accepts quoted YAML 1.1 booleans and lowercase true and false' do
      ["'yes'", '"on"', 'true', 'false'].each do |word|
        props = base_properties.merge('rules' => valid_rules.sub('match: "*"', "match: #{word}"))
        expect { render('config/rules.yml', props) }.not_to raise_error, word
      end
    end

    it 'refuses handler arguments that the handler does not read' do
      {
        'slack'     => { 'webhook' => 'https://x', 'icon' => ':bell:' },
        'slack-app' => { 'token' => 't', 'chanel' => '#ops' },
        'email'     => { 'to' => 'ops@example.com', 'from' => 'x@example.com' },
      }.each do |handler, args|
        typo = (args.keys - %w[webhook token to]).first
        props = base_properties.merge('rules' => action_rules(handler, args))
        expect { render('config/rules.yml', props) }
          .to raise_error(/do\[0\]\.#{Regexp.escape(handler)}: unknown key\(s\) #{typo}; allowed keys are/), handler
      end
    end

    it 'accepts every argument each handler reads, and any argument for webhook' do
      {
        'slack'     => %w[webhook text username icon_url color attach],
        'slack-app' => %w[token channel text username icon_url color attach],
        'email'     => %w[to subject body],
        'webhook'   => %w[url anything_at_all],
      }.each do |handler, names|
        props = base_properties.merge('rules' => action_rules(handler, names.to_h { |n| [n, 'v'] }))
        expect { render('config/rules.yml', props) }.not_to raise_error, handler
      end
    end
  end

  describe 'bin/post-start' do
    it 'checks /info over HTTP by default' do
      out = render('bin/post-start', base_properties)
      expect(out).to include('url=http://127.0.0.1:7109/info')
      expect(out).to include('deadline=$((SECONDS + 60))')
    end

    it 'checks /info over HTTPS when TLS is on' do
      props = base_properties.merge('port' => 8443, 'tls' => { 'certificate' => 'c', 'key' => 'k' })
      expect(render('bin/post-start', props)).to include('url=https://127.0.0.1:8443/info')
    end

    it 'refuses a startup timeout below one second' do
      expect { render('bin/post-start', base_properties.merge('startup_timeout' => 0)) }.to raise_error(/at least 1 second/)
    end

    it 'renders valid bash' do
      _, err, status = Open3.capture3('/bin/bash', '-n', stdin_data: render('bin/post-start', base_properties))
      expect(status).to be_success, err
    end
  end

  describe 'bin/ctl' do
    let(:ctl) { render('bin/ctl', base_properties) }

    it 'drops privileges with setpriv, clearing supplementary groups' do
      expect(ctl).to include('exec setpriv --reuid=vcap --regid=vcap --clear-groups --no-new-privs --')
      expect(ctl).not_to include('--init-groups')
      expect(ctl).not_to include('chpst')
    end

    it 'renders valid bash' do
      _, err, status = Open3.capture3('/bin/bash', '-n', stdin_data: ctl)
      expect(status).to be_success, err
    end

    it 'gives up on SIGTERM before monit gives up on the stop program' do
      expect(ctl[/^STOP_TIMEOUT=(\d+)$/, 1].to_i).to be < 30
    end

    # A stand-in for the server's read-only state probe, following its exit
    # codes: 0 for state it reads or converts, 3 for a file in neither format,
    # and 1 for a file it cannot read at all.
    FAKE_STATE_PROBE = <<~'BASH'
      #!/bin/bash
      [[ $1 == -check-state && $2 == --db=* ]] || { echo "unexpected arguments: $*" >&2; exit 2; }
      db=${2#--db=}
      [[ -e $db ]] || exit 0
      [[ -f $db && -r $db ]] || { echo "shout: reading state file $db: permission denied" >&2; exit 1; }
      case $(tr -d '[:space:]' <"$db") in
        '{'*|null) exit 0 ;;
        '['*) echo "state file $db: Lisp format, 1 topics to import, 0 skipped; the server converts it at startup"; exit 0 ;;
        *) echo "shout: parsing state file $db: state file is unreadable: invalid character" >&2; exit 3 ;;
      esac
    BASH

    # Run a bash snippet against the rendered ctl with every path moved under
    # a scratch directory and chown recorded instead of run, so that the
    # functions can be exercised without root or a vcap user.
    def run_ctl(snippet, files: {})
      Dir.mktmpdir do |dir|
        ctl_path = File.join(dir, 'ctl')
        File.write(ctl_path, ctl)
        File.write(File.join(dir, 'fake-shout'), FAKE_STATE_PROBE)
        files.each do |name, content|
          path = File.join(dir, name)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, content)
        end
        script = <<~BASH
          source #{ctl_path}
          JOB_DIR=#{dir}/job PKG_DIR=#{dir}/pkg RUN_DIR=#{dir}/run LOG_DIR=#{dir}/log STORE_DIR=#{dir}/store
          PIDFILE=$RUN_DIR/shout.pid
          mkdir -p "$RUN_DIR" "$LOG_DIR"
          chown() { echo "chown $*" >>#{dir}/chown.log; }
          mkdir -p "$PKG_DIR/bin"
          cp #{dir}/fake-shout "$PKG_DIR/bin/shout"
          chmod +x "$PKG_DIR/bin/shout"
          #{snippet}
        BASH
        out, err, status = Open3.capture3({ 'PATH' => "#{dir}/bin:#{ENV.fetch('PATH')}" }, '/bin/bash', '--noprofile', '--norc', '-c', script)
        listing = Dir.glob("#{dir}/store/*", File::FNM_DOTMATCH).reject { |f| f.end_with?('/.', '/..') }.map { |f| File.basename(f) }.sort
        chowns = File.exist?("#{dir}/chown.log") ? File.read("#{dir}/chown.log").gsub(dir, '') : ''
        modes = Dir.glob("#{dir}/{store,job/config/*}").to_h { |f| [f.sub("#{dir}/", ''), format('%o', File.stat(f).mode & 0o777)] }
        db = File.file?("#{dir}/store/shout.db") ? File.read("#{dir}/store/shout.db") : nil
        yield(out: out, err: err, status: status, store: listing, chowns: chowns, modes: modes, db: db)
      end
    end

    it 'creates the store for vcap when it is missing' do
      run_ctl('prepare_store') do |r|
        expect(r[:status]).to be_success, r[:err]
        expect(r[:store]).to eq([])
        expect(r[:modes]['store']).to eq('750')
        expect(r[:chowns]).to eq("chown vcap:vcap /store\n")
      end
    end

    {
      'an empty file'           => '',
      'a whitespace-only file'  => "  \n\t\n",
    }.each do |what, content|
      it "removes #{what}, which holds no state and which the server refuses" do
        run_ctl('prepare_store', files: { 'store/shout.db' => content }) do |r|
          expect(r[:status]).to be_success, r[:err]
          expect(r[:store]).to eq([])
          expect(r[:out]).to include('removed an empty shout.db')
          expect(r[:out]).not_to match(/\bmoved\b/)
        end
      end
    end

    {
      'Go state'        => [%({"states":{"x":{"name":"x"}}}\n), nil],
      'a null document' => ["null\n", nil],
      'Lisp-era state'  => [%(  [{"name":"prod-deploy","ok":false}]\n), /Lisp format, 1 topics to import/],
    }.each do |what, (content, logged)|
      it "leaves #{what} in place for the server to read or convert" do
        run_ctl('prepare_store', files: { 'store/shout.db' => content }) do |r|
          expect(r[:status]).to be_success, r[:err]
          expect(r[:store]).to eq(['shout.db'])
          expect(r[:db]).to eq(content)
          expect(r[:chowns]).to include("chown vcap:vcap /store/shout.db\n")
          expect(r[:out]).not_to match(/removed|moved/)
          expect(r[:out]).to match(logged) if logged
        end
      end
    end

    it 'sets aside a file that the server would refuse, and logs why' do
      run_ctl('prepare_store', files: { 'store/shout.db' => "garbage\n" }) do |r|
        expect(r[:status]).to be_success, r[:err]
        expect(r[:store].size).to eq(1)
        expect(r[:store].first).to match(/\Ashout\.db\.unreadable-\d{8}T\d{6}Z\z/)
        expect(r[:out]).to include('state file is unreadable')
        expect(r[:out]).to match(/moved \S+ to \S+unreadable-\S+ because the server cannot read it/)
        expect(r[:out]).to include('found state that was set aside')
      end
    end

    it 'stops without moving anything when the probe cannot read the file' do
      run_ctl('mkdir -p "$STORE_DIR/shout.db"; prepare_store; echo after') do |r|
        expect(r[:status]).not_to be_success
        expect(r[:store]).to eq(['shout.db'])
        expect(r[:out]).to include('probe exit 1')
        expect(r[:out]).not_to include('after')
      end
    end

    it 'does not start the server when the store cannot be prepared' do
      files = %w[env rules.yml tls.crt tls.key].to_h { |f| ["job/config/#{f}", ''] }
      files['bin/setpriv'] = "#!/bin/bash\necho SETPRIV-RAN >&3\n"
      run_ctl('chmod +x "$(dirname "$JOB_DIR")/bin/setpriv"; mkdir -p "$STORE_DIR/shout.db"; exec 3>&1; main start', files: files) do |r|
        expect(r[:status]).not_to be_success
        expect(r[:out]).not_to include('SETPRIV-RAN')
      end
    end

    it 'removes the temporary file of the Lisp server and hands the Go one to vcap' do
      run_ctl('prepare_store', files: { 'store/shout.tmp' => '[]', 'store/shout.db.tmp' => '{}' }) do |r|
        expect(r[:status]).to be_success, r[:err]
        expect(r[:store]).to eq(['shout.db.tmp'])
        expect(r[:chowns]).to include("chown vcap:vcap /store/shout.db.tmp\n")
      end
    end

    it 'points at state that was set aside earlier, and keeps it' do
      files = { 'store/shout.db' => '{}', 'store/shout.db.unreadable-20261001T000000Z' => '[]' }
      run_ctl('prepare_store', files: files) do |r|
        expect(r[:status]).to be_success, r[:err]
        expect(r[:store]).to eq(['shout.db', 'shout.db.unreadable-20261001T000000Z'])
        expect(r[:out]).to match(%r{found state that was set aside because the server could not read it: \S+/store/shout.db.unreadable-20261001T000000Z})
      end
    end

    it 'starts the server through setpriv with the environment loaded and the files locked down' do
      files = {
        'job/config/env'       => "export SHOUT_PORT=7109\n",
        'job/config/rules.yml' => "rules: []\n",
        'job/config/tls.crt'   => '',
        'job/config/tls.key'   => '',
        'bin/setpriv'          => "#!/bin/bash\necho \"setpriv $* SHOUT_PORT=$SHOUT_PORT\" >&3\n",
      }
      run_ctl('chmod +x "$(dirname "$JOB_DIR")/bin/setpriv"; exec 3>&1; main start', files: files) do |r|
        expect(r[:status]).to be_success, r[:err]
        expect(r[:out]).to match(%r{^setpriv --reuid=vcap --regid=vcap --clear-groups --no-new-privs -- \S+/pkg/bin/shout SHOUT_PORT=7109$})
        expect(r[:modes]).to include('job/config/env' => '600', 'job/config/rules.yml' => '640', 'job/config/tls.key' => '640')
        expect(r[:chowns]).to include("chown root:root /job/config/env\n", "chown root:vcap /job/config/tls.key\n")
      end
    end

    it 'acts only when run, so that sourcing it changes nothing' do
      out, err, status = Open3.capture3('/bin/bash', '--noprofile', '--norc', '-c', "source /dev/stdin; declare -F main prepare_store running_pid", stdin_data: ctl)
      expect(status).to be_success, err
      expect(out.split("\n")).to eq(%w[main prepare_store running_pid])
    end
  end

  describe 'monit' do
    it 'tracks the pidfile that bin/ctl writes' do
      monit = File.read(File.join(RELEASE_DIR, 'jobs/shout/monit'))
      expect(monit).to include('with pidfile /var/vcap/sys/run/shout/shout.pid')
      expect(monit).to include('/var/vcap/jobs/shout/bin/ctl start')
    end
  end

  describe 'manifests/shout.yml' do
    it 'carries rules that the job accepts' do
      manifest = YAML.safe_load(File.read(File.join(RELEASE_DIR, 'manifests/shout.yml')))
      props = manifest['instance_groups'][0]['jobs'][0]['properties']
      expect { render('config/rules.yml', props) }.not_to raise_error
      expect { render('config/env', props) }.not_to raise_error
    end
  end
end
