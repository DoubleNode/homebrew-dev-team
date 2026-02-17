class DevTeam < Formula
  desc "Starfleet Development Environment - AI-powered multi-team development infrastructure"
  homepage "https://github.com/DoubleNode/homebrew-dev-team"
  url "https://github.com/DoubleNode/homebrew-dev-team.git",
      tag: "v1.0.0",
      revision: "0492e40fe14a071cd34c4f55bd9d351b3e4f6c7d"
  license "MIT"
  version "1.0.0"

  # Core dependencies required for dev-team to function
  depends_on "python@3.13"
  depends_on "node"
  depends_on "jq"
  depends_on "gh"
  depends_on "git"
  depends_on :macos => :big_sur # iTerm2 and macOS-specific features

  # Optional dependencies for advanced features
  uses_from_macos "rsync" # For sync scripts

  def install
    # Install all core files to libexec (framework location)
    libexec.install Dir["*"]

    # Create bin stubs for main commands
    (bin/"dev-team").write <<~EOS
      #!/bin/bash
      # Dev-Team CLI dispatcher
      DEV_TEAM_HOME="#{libexec}"
      export DEV_TEAM_HOME
      exec "#{libexec}/bin/dev-team-cli.sh" "$@"
    EOS

    (bin/"dev-team-setup").write <<~EOS
      #!/bin/bash
      # Dev-Team interactive setup wizard
      DEV_TEAM_HOME="#{libexec}"
      export DEV_TEAM_HOME
      exec "#{libexec}/bin/dev-team-setup.sh" "$@"
    EOS

    (bin/"dev-team-doctor").write <<~EOS
      #!/bin/bash
      # Dev-Team health check and diagnostics
      DEV_TEAM_HOME="#{libexec}"
      export DEV_TEAM_HOME
      exec "#{libexec}/bin/dev-team-doctor.sh" "$@"
    EOS

    chmod 0755, bin/"dev-team"
    chmod 0755, bin/"dev-team-setup"
    chmod 0755, bin/"dev-team-doctor"
  end

  def post_install
    # Create installation marker
    (HOMEBREW_PREFIX/"var/dev-team").mkpath
    (HOMEBREW_PREFIX/"var/dev-team/.installed").write "#{version}\n#{Time.now}"

    # Suggest running setup
    ohai "Dev-Team framework installed successfully"
    ohai "Run 'dev-team setup' to configure your environment"
  end

  def caveats
    <<~EOS
      Dev-Team has been installed to:
        #{libexec}

      Available commands:
        dev-team setup     - Interactive setup wizard
        dev-team doctor    - Health check and diagnostics
        dev-team status    - Show current environment status
        dev-team upgrade   - Upgrade components
        dev-team help      - Show help information

      To get started:
        1. Run: dev-team setup
        2. Follow the interactive wizard to:
           - Install iTerm2 (if needed)
           - Install Claude Code (if needed)
           - Select teams to configure
           - Set up LCARS Kanban system
           - Configure terminal environment

      The setup wizard will guide you through creating your
      team environment in ~/dev-team (or custom location).

      IMPORTANT: The formula installs the FRAMEWORK only.
      Run 'dev-team setup' to create your working environment.

      For troubleshooting: dev-team doctor
      For documentation: #{libexec}/docs/
    EOS
  end

  test do
    # Verify main commands exist and are executable
    assert_predicate bin/"dev-team", :exist?
    assert_predicate bin/"dev-team-setup", :exist?

    # Verify core directories exist (libexec/ subdir mirrors repo structure)
    assert_predicate libexec/"libexec/commands", :exist?
    assert_predicate libexec/"libexec/installers", :exist?
    assert_predicate libexec/"libexec/lib", :exist?
    assert_predicate libexec/"share/templates", :exist?
    assert_predicate libexec/"share/teams", :exist?

    # Verify library files exist
    assert_predicate libexec/"libexec/lib/common.sh", :exist?
    assert_predicate libexec/"libexec/lib/config.sh", :exist?
    assert_predicate libexec/"libexec/lib/wizard-ui.sh", :exist?

    # Test that setup wizard shows version
    system "#{bin}/dev-team-setup", "--help"
  end
end
