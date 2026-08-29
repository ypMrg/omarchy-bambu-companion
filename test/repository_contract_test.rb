# frozen_string_literal: true

require_relative "test_helper"
require "json"

class RepositoryContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  REQUIRED = %w[
    .gitignore .github/workflows/ci.yml manifest.json
    BambuWidget.qml BambuService.qml BambuDashboard.qml BambuStyle.qml
    BambuPrinterIcon.qml BambuApp.qml bambu-companion
    bambu-companion-update-check daemon.rb Gemfile Gemfile.lock
    README.md LICENSE bin/test native/build
  ].freeze

  def test_required_installable_files_exist
    REQUIRED.each { |path| assert File.file?(File.join(ROOT, path)), "missing #{path}" }
    %w[bambu-companion bambu-companion-update-check
       bin/test test/system/launcher_test.sh
       test/system/update_check_test.sh
       test/support/fake-bundle test/support/fake-gem native/build].each do |path|
      assert File.executable?(File.join(ROOT, path)), "#{path} must be executable"
    end
  end

  def test_frozen_lockfile_has_a_checksum_for_every_gem
    lockfile = File.read(File.join(ROOT, "Gemfile.lock"))
    checksums = lockfile[/^CHECKSUMS\n(?<entries>.*?)(?=\n^[A-Z][A-Z ]+\n)/m, :entries]
    refute_nil checksums

    entries = checksums.lines.map(&:strip).reject(&:empty?)
    refute_empty entries
    entries.each do |entry|
      assert_match(/\A.+ sha256=[0-9a-f]{64}\z/, entry,
                   "missing locked checksum for #{entry}")
    end
  end

  def test_manifest_identifies_the_bar_widget_and_uses_non_secret_defaults
    manifest = JSON.parse(File.read(File.join(ROOT, "manifest.json")))
    defaults = manifest.fetch("barWidget").fetch("defaults")

    assert_equal "io.github.ypmrg.bambu-companion", manifest.fetch("id")
    assert_equal "1.7.2", manifest.fetch("version")
    assert_includes manifest.fetch("kinds"), "bar-widget"
    assert_includes manifest.fetch("kinds"), "service"
    assert_includes manifest.fetch("kinds"), "panel"
    assert_equal "BambuWidget.qml", manifest.fetch("entryPoints").fetch("barWidget")
    assert_equal "BambuService.qml", manifest.fetch("entryPoints").fetch("service")
    assert_equal "BambuApp.qml", manifest.fetch("entryPoints").fetch("panel")
    assert_equal "", defaults.fetch("host")
    assert_equal 8883, defaults.fetch("mqttPort")
    assert_equal 990, defaults.fetch("ftpsPort")
    assert_equal "", defaults.fetch("serial")
    assert_equal "3D Printer", defaults.fetch("printerName")
    assert_equal "bblp", defaults.fetch("username")
    refute defaults.key?("accessCode")
    refute defaults.key?("password")
  end

  def test_readme_documents_installation_security_dependencies_and_vm_validation
    readme = File.read(File.join(ROOT, "README.md"))

    ["omarchy plugin add", "GNOME Keyring", "omarchy plugin validate", "MQTT", "FTPS", "Node.js"].each do |text|
      assert_includes readme, text
    end
    assert_includes readme, "Omarchy Quattro"
    assert_includes readme, "bin/test"
    assert_includes readme, "development only"
    assert_includes readme, "COMPILING ROUTE RENDERER"
    assert_includes readme, "cmake"
    assert_includes readme, "g++"
    assert_includes readme, "GcodeRoute"
    refute_includes readme, "samples large routes within fixed budgets"
    refute_includes readme, "Canvas renderer"
    refute_includes readme, "Canvas rendering"
  end

  def test_readme_documents_explicit_first_use_certificate_approval
    readme = File.read(File.join(ROOT, "README.md"))

    assert_match(/Save & Connect.*check.*certificate.*TRUST & CONNECT/im, readme)
    assert_match(/SHA-256.*MQTT.*FTPS/im, readme)
    assert_match(/certificate changes.*block.*reconnect/im, readme)
    assert_match(/existing installations.*approve.*once/im, readme)
    refute_match(/certificate.*verification.*disabled/i, readme)
  end

  def test_vm_instructions_do_not_claim_that_plugin_add_installs_a_local_checkout
    readme = File.read(File.join(ROOT, "README.md"))

    refute_includes readme, 'omarchy plugin add "$PWD"'
    assert_includes readme, "omarchy-shell shell rescanPlugins"
    assert_includes readme, "omarchy plugin enable io.github.ypmrg.bambu-companion"
  end

  def test_production_configuration_has_no_default_lan_code
    production = %w[
      manifest.json BambuWidget.qml BambuService.qml BambuDashboard.qml
      daemon.rb bambu-companion
    ]
      .concat(Dir[File.join(ROOT, "lib/**/*.rb")].map { |path| path.delete_prefix("#{ROOT}/") })
      .map { |path| File.read(File.join(ROOT, path)) }.join("\n")

    refute_match(/access(?:_|)code\s*[=:]\s*["']12345678["']/i, production)
    refute_match(/password\s*[=:]\s*["']12345678["']/i, production)
    refute_match(/192\.168\.1\.54|0309DA541001354|grMpy|Fabricator/i, production)
  end

  def test_local_transports_explicitly_use_required_tls_modes
    mqtt = File.read(File.join(ROOT, "lib/bambu_companion/mqtt_session.rb"))
    ftps = File.read(File.join(ROOT, "lib/bambu_companion/ftps_client.rb"))
    native_storage = File.read(
      File.join(ROOT, "lib/bambu_companion/native_storage_client.rb")
    )
    tls = File.read(File.join(ROOT, "lib/bambu_companion/tls_certificate.rb"))

    assert_includes mqtt, "verify_host: false"
    assert_includes mqtt, "configure_pinned_context"
    assert_includes ftps, "implicit_ftps: true"
    assert_includes ftps, "private_data_connection: false"
    assert_includes ftps, 'sendcmd("PBSZ 0")'
    assert_includes ftps, 'sendcmd("PROT P")'
    assert_includes ftps, "instance_variable_set(:@private_data_connection, true)"
    assert_includes ftps, "configure_pinned_context"
    assert_includes native_storage, "TlsCertificate.open_pinned"
    assert_includes native_storage, 'list_entries(protocol, storage: "internal")'
    refute_match(/FILE_(?:UPLOAD|DEL)/, native_storage)
    assert_includes tls, "OpenSSL::SSL::VERIFY_PEER"
    refute_includes mqtt, "OpenSSL::SSL::VERIFY_NONE"
    refute_includes ftps, "OpenSSL::SSL::VERIFY_NONE"
  end

  def test_development_checks_run_high_signal_linters
    rubocop_path = File.join(ROOT, ".rubocop.yml")
    assert File.file?(rubocop_path), "missing .rubocop.yml"

    rubocop_config = File.read(rubocop_path)
    test_all = File.read(File.join(ROOT, "bin/test"))

    assert_includes rubocop_config, "DisabledByDefault: true"
    assert_match(/^Lint:\n\s+Enabled: true$/m, rubocop_config)
    assert_match(/^Security:\n\s+Enabled: true$/m, rubocop_config)
    assert_includes test_all, "rubocop --cache false"
    assert_includes test_all, "shellcheck"
    assert_match(/qmllint_command.*\*\.qml/m, test_all)
    assert_includes test_all, "--max-warnings 0"
    assert_includes test_all, "--unused-imports warning"
    assert_includes test_all, 'qml_import_root="$(mktemp -d)"'
    assert_includes test_all,
                    '"$qmllint_command" --max-warnings 0 --unused-imports warning'

    workflow = File.read(File.join(ROOT, ".github/workflows/ci.yml"))
    assert_includes workflow, "archlinux:base"
    assert_includes workflow, "pkgconf"
    assert_includes workflow, "ruby-erb"
    assert_includes workflow, "--bindir /usr/local/bin"
    assert_equal 2, workflow.scan("actions/checkout@v7").length
    assert_includes workflow, "OMARCHY_PATH:"
    assert_includes workflow, "bin/test"
  end

  def test_user_configuration_changes_require_an_explicit_widget_action
    widget = File.read(File.join(ROOT, "BambuWidget.qml"))
    service = File.read(File.join(ROOT, "BambuService.qml"))
    launcher = File.read(File.join(ROOT, "bambu-companion"))
    readme = File.read(File.join(ROOT, "README.md"))

    assert_equal 1, service.scan("root.shell.updateEntryInline(root.moduleName, entry)").length
    assert_match(/function commitSettingsEntry\(entry\).*updateEntryInline\(root\.moduleName, entry\)/m,
                 service)
    assert_match(/function saveSettings\(.*persistSettings\(draft\)/m, service)
    assert_match(/BambuDashboard\s*\{/, widget)
    refute_match(%r{(?:\$HOME|~)/\.config}, launcher)
    assert_includes readme, "does not overwrite user configuration"
  end
end
