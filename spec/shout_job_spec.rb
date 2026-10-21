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
      expect { render('config/rules.yml', props) }.to raise_error(/rules/)
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

    it 'drops privileges with setpriv instead of chpst' do
      expect(ctl).to include('exec setpriv --reuid=vcap --regid=vcap --init-groups --no-new-privs --')
      expect(ctl).not_to include('chpst')
    end

    it 'renders valid bash' do
      _, err, status = Open3.capture3('/bin/bash', '-n', stdin_data: ctl)
      expect(status).to be_success, err
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
